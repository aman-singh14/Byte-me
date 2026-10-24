// Call a helper: opening a room, uploading frames (newest only, few in
// flight), and acting on the helper's commands.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:omni_glasses/alerts/alert_engine.dart';
import 'package:omni_glasses/helper/helper_call.dart';
import 'package:omni_glasses/net/protocol.dart';

/// The server end of the wearer's socket, in memory.
class FakeSocket implements HelperSocket {
  final _in = StreamController<String>();
  final texts = <Map<String, dynamic>>[];
  final frames = <Uint8List>[];
  bool closed = false;

  @override
  int? closeCode;

  @override
  Stream<String> get messages => _in.stream;

  @override
  void sendText(String text) => texts.add(jsonDecode(text) as Map<String, dynamic>);

  @override
  void sendBytes(Uint8List bytes) => frames.add(bytes);

  @override
  Future<void> close() async {
    closed = true;
    await _in.close();
  }

  /// The server sends [msg].
  void server(Map<String, Object> msg) => _in.add(jsonEncode(msg));

  /// The server closes the socket with [code].
  Future<void> drop([int? code]) async {
    closeCode = code;
    await _in.close();
  }
}

class FakeCameras implements HelperCameras {
  final feeds = {for (final c in HelperCamera.values) c: ValueNotifier<Uint8List?>(null)};
  final opened = <HelperCamera>{};

  @override
  ValueListenable<Uint8List?>? open(HelperCamera which) {
    opened.add(which);
    return feeds[which];
  }

  @override
  void close(HelperCamera which) => opened.remove(which);
}

Uint8List jpeg(int n) => Uint8List.fromList([0xFF, 0xD8, n, 0xFF, 0xD9]);

void main() {
  late List<FakeSocket> sockets;
  late List<Uri> connected;
  late FakeCameras cameras;
  late List<GlassesCommand> toGlasses;
  late StreamController<AlertEvent> alerts;
  late HelperCall call;

  setUp(() {
    sockets = [];
    connected = [];
    cameras = FakeCameras();
    toGlasses = [];
    alerts = StreamController<AlertEvent>.broadcast(sync: true);
    final server = MockClient((r) async {
      expect((r.method, r.url.path), ('POST', '/rooms'));
      return http.Response(
        jsonEncode({'room': 'abc', 'wearer_token': 'wt', 'helper_url': 'https://h.test/h/abc?t=ht'}),
        201,
      );
    });
    call = HelperCall(
      toGlasses: toGlasses.add,
      cameras: cameras,
      alerts: alerts.stream,
      server: Uri.parse('https://h.test'),
      client: server,
      connect: (url) async {
        connected.add(url);
        final s = FakeSocket();
        sockets.add(s);
        return s;
      },
      watchLifecycle: false,
    );
  });

  tearDown(() async {
    call.dispose();
    await alerts.close();
  });

  Future<void> tick([int ms = 120]) => Future<void>.delayed(Duration(milliseconds: ms));

  test('opens a room, connects with the wearer token, and waits', () async {
    expect(await call.start(), isNull);
    expect(call.state, HelperState.waiting);
    expect(call.helperUrl, 'https://h.test/h/abc?t=ht');
    expect(connected.single.toString(), 'wss://h.test/ws/wearer/abc?t=wt');
    expect(cameras.opened, isEmpty); // nothing uploads until the helper is there
  });

  test("can't reach the server: says so", () async {
    final down = HelperCall(
      toGlasses: toGlasses.add,
      cameras: cameras,
      alerts: alerts.stream,
      client: MockClient((_) async => http.Response('nope', 503)),
      watchLifecycle: false,
    );
    expect(await down.start(), contains("Couldn't reach"));
    expect(down.state, HelperState.failed);
    down.dispose();
  });

  test('uploads the newest frame with camera and timestamp, two in flight at most', () async {
    await call.start();
    final socket = sockets.single;
    socket.server({'t': 'helper', 'on': true});
    await tick(0);
    expect(call.state, HelperState.live);
    expect(cameras.opened, {HelperCamera.front});

    final front = cameras.feeds[HelperCamera.front]!;
    front.value = jpeg(1);
    front.value = jpeg(2); // replaces 1 before it was sent
    await tick();
    expect(socket.frames, hasLength(1));
    final f = socket.frames.single;
    expect(String.fromCharCode(f[0]), 'F');
    final ts = ByteData.sublistView(f, 1, 9).getUint64(0);
    expect(DateTime.now().millisecondsSinceEpoch - ts, lessThan(2000));
    expect(f.sublist(9), jpeg(2)); // the JPEG, unchanged

    front.value = jpeg(3);
    await tick();
    front.value = jpeg(4);
    await tick();
    expect(socket.frames, hasLength(2)); // two unacked: holds back
    socket.server({'t': 'ack'});
    await tick();
    expect(socket.frames.last.sublist(9), jpeg(4)); // the newest, 3 was skipped
  });

  test("acts on the helper's commands", () async {
    await call.start();
    final socket = sockets.single;
    socket.server({'t': 'helper', 'on': true});
    socket.server({'t': 'guide', 'dir': 'L'});
    socket.server({'t': 'guide', 'dir': 'nowhere'});
    socket.server({'t': 'cam', 'which': 'R'});
    await tick(0);
    expect(
      [for (final c in toGlasses) c.toJson()],
      [
        {'t': 'guide', 'dir': 'L'},
      ],
    );
    expect(call.lastGuide, GuideDirection.left);
    expect(call.camera, HelperCamera.rear);
    expect(cameras.opened, {HelperCamera.rear}); // the front stream was closed
    expect(socket.texts.last, {'t': 'status', 'camera': 'R', 'video': 'waiting'});

    socket.server({'t': 'end'});
    await tick(0);
    expect(call.state, HelperState.ended);
    expect(socket.texts.last, {'t': 'end'});
    expect(socket.closed, isTrue);
    expect(cameras.opened, isEmpty);
  });

  test('forwards alerts to the helper while live', () async {
    await call.start();
    final socket = sockets.single;
    const car = Alert(side: WearerSide.left, level: AlertLevel.urgent, label: 'car', source: AlertSource.camera);
    alerts.add(const AlertRaised(car)); // not live yet: not sent
    socket.server({'t': 'helper', 'on': true});
    await tick(0);
    alerts.add(const AlertRaised(car));
    alerts.add(const PossiblyFollowing(WearerSide.behind, Duration(minutes: 3)));
    alerts.add(const PossiblyFollowing(WearerSide.behind, Duration(minutes: 4), update: true));
    final sent = socket.texts.where((t) => t['t'] == 'alert').toList();
    expect(sent, [
      {'t': 'alert', 'side': 'L', 'level': 2, 'label': 'car'},
      {'t': 'alert', 'kind': 'following', 'side': 'B', 'minutes': 3},
    ]);
  });

  test('a dropped connection reconnects; the server ending the room ends the call', () async {
    await call.start();
    sockets.single.server({'t': 'helper', 'on': true});
    await tick(0);
    await sockets.single.drop(); // network blip
    await tick(0);
    expect(call.state, HelperState.waiting);
    await tick(2200);
    expect(sockets, hasLength(2));
    sockets.last.server({'t': 'helper', 'on': true});
    await tick(0);
    expect(call.state, HelperState.live);

    await sockets.last.drop(4410); // expired or ended
    await tick(0);
    expect(call.state, HelperState.ended);
  });
}
