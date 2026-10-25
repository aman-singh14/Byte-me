// The real camera boards over real UDP on localhost: chunked video, the eye
// and front cameras' hellos and WANT, the back camera's FPGA reports,
// collisions and video, and buzzing the phone when there's no frame ESP32.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/alerts/phone_buzzer.dart';
import 'package:omni_glasses/net/glasses_link.dart';
import 'package:omni_glasses/net/protocol.dart';
import 'package:omni_glasses/vision/mjpeg.dart';
import 'package:omni_glasses/vision/udp_camera.dart';

Future<void> wait(int ms) => Future.delayed(Duration(milliseconds: ms));

/// A JPEG-ish payload (the assembler doesn't decode it).
Uint8List jpeg(int n, [int seed = 0]) => Uint8List.fromList([0xFF, 0xD8, for (var i = 0; i < n - 4; i++) (i + seed) % 251, 0xFF, 0xD9]);

/// [frame] cut like the firmware cuts it: 1400 bytes per chunk.
List<Uint8List> chunks(String magic, int id, Uint8List frame) {
  final n = (frame.length + 1399) ~/ 1400;
  return [
    for (var c = 0; c < n; c++)
      chunkDatagram(magic, id, c, n, frame, frame.sublist(c * 1400, (c + 1) * 1400 > frame.length ? frame.length : (c + 1) * 1400)),
  ];
}

void main() {
  group('FrameAssembler', () {
    test('puts a frame back together, in any order', () {
      final a = FrameAssembler(), f = jpeg(3500);
      final parts = chunks(eyeFrontMagic, 1, f);
      expect(parts, hasLength(3));
      expect(a.add(parts[2]), isNull);
      expect(a.add(parts[0]), isNull);
      expect(a.add(parts[1]), f);
    });

    test('a frame with a lost chunk is skipped; the next one still comes', () {
      final a = FrameAssembler(), next = jpeg(2000, 7);
      a.add(chunks(backMagic, 5, jpeg(3000))[0]); // its second chunk never comes
      final done = [for (final p in chunks(backMagic, 6, next)) a.add(p)].whereType<Uint8List>();
      expect(done.single, next);
    });

    test('garbage is ignored, and a camera that restarts from frame 1 still works', () {
      final a = FrameAssembler();
      expect(a.add(Uint8List.fromList(utf8.encode('{"t":"rear"}'))), isNull);
      expect(a.add(Uint8List(12)), isNull);
      for (final p in chunks(eyeFrontMagic, 5000, jpeg(100))) {
        a.add(p);
      }
      expect(a.add(chunks(eyeFrontMagic, 1, jpeg(100, 3)).single), jpeg(100, 3));
    });
  });

  test('UdpCamera asks with WANT from its own port and shows the frames; STOP when done', () async {
    final camera = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final asked = <String>[];
    InternetAddress? viewer;
    int? viewerPort;
    camera.listen((e) {
      final d = e == RawSocketEvent.read ? camera.receive() : null;
      if (d == null) return;
      asked.add(utf8.decode(d.data));
      (viewer, viewerPort) = (d.address, d.port);
    });
    final feed = UdpCamera(InternetAddress.loopbackIPv4, camera.port, wantEvery: const Duration(milliseconds: 50))
      ..start();
    await wait(150);
    expect(asked.first, videoWant);
    final f = jpeg(4000);
    for (final p in chunks(eyeFrontMagic, 1, f)) {
      camera.send(p, viewer!, viewerPort!);
    }
    await wait(100);
    expect(feed.frame.value, f);
    feed.dispose();
    await wait(50);
    expect(asked.last, videoStop);
    camera.close();
  });

  group('GlassesLink with the camera boards', () {
    late GlassesLink link;
    late RawDatagramSocket board;
    final buzzed = <GlassesCommand>[];
    final heard = <String>[]; // what the link sent the board

    setUp(() async {
      buzzed.clear();
      link = GlassesLink(
        port: 0,
        backTimeout: const Duration(milliseconds: 300),
        pokeInterval: const Duration(milliseconds: 50),
        boardTimeout: const Duration(milliseconds: 300),
      )
        ..onNoFrame = buzzed.add;
      await link.start();
      heard.clear();
      board = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      board.listen((e) {
        final d = e == RawSocketEvent.read ? board.receive() : null;
        if (d != null) heard.add(utf8.decode(d.data, allowMalformed: true));
      });
    });

    tearDown(() {
      board.close();
      link.dispose();
    });

    void toHello(String json) => board.send(utf8.encode(json), InternetAddress.loopbackIPv4, link.boundHelloPort!);
    void toBack(List<int> bytes) => board.send(bytes, InternetAddress.loopbackIPv4, link.boundBackPort!);

    test('the eye and front cameras are found from their hellos, with their ports', () async {
      toHello('{"t":"cam_hello","role":"front","ip":"172.20.10.3","stream":"udp","stream_port":8102,"http_port":8182}');
      toHello('{"t":"cam_hello","role":"eye","ip":"172.20.10.4","stream":"udp","stream_port":81,"http_port":80}');
      await wait(100);
      expect(link.frontCam?.video.toString(), 'udp://127.0.0.1:8102'); // the sender's address, the hello's port
      expect(link.frontCam?.capture().toString(), 'http://127.0.0.1:8182/capture?size=vga');
      expect(link.eyeCam?.hello.streamPort, 81);
      await wait(400); // no more hellos: the boards are gone (Ask goes back to the phone's camera)
      expect((link.frontCam, link.eyeCam), (null, null));
    });

    test('cameras on another network come through the relay; a board on the hotspot wins', () async {
      expect(parseRelay(' https://omni-glasses.fly.dev/relay/k3y/ ').toString(), 'https://omni-glasses.fly.dev/relay/k3y');
      expect(parseRelay('http://100.64.0.2:8030/relay/k').toString(), 'http://100.64.0.2:8030/relay/k');
      for (final bad in ['', 'omni-glasses.fly.dev/relay/k', 'https://omni-glasses.fly.dev', 'ftp://x/relay/k']) {
        expect(parseRelay(bad), isNull, reason: bad);
      }
      var changes = 0;
      link.addListener(() => changes++);
      link.relay = parseRelay('https://omni-glasses.fly.dev/relay/k3y');
      expect(changes, 1);
      expect(link.eyeCam?.video.toString(), 'https://omni-glasses.fly.dev/relay/k3y/eye/stream');
      expect(link.frontCam?.capture().toString(), 'https://omni-glasses.fly.dev/relay/k3y/front/capture');
      expect(link.frontCam?.sensor, isNull); // no exposure numbers through a relay: no outside time
      final feed = link.eyeCam!.open();
      expect(feed, isA<RearCamera>());
      feed.dispose();
      toHello('{"t":"cam_hello","role":"front","stream":"udp","stream_port":8102,"http_port":8182}');
      await wait(100);
      expect(link.frontCam?.video.toString(), 'udp://127.0.0.1:8102');
      expect(link.eyeCam?.relay, isNotNull);
      await wait(400); // the hotspot board is gone: back to the relay
      expect(link.frontCam?.relay, isNotNull);
      link.relay = null;
      expect((link.frontCam, link.eyeCam), (null, null));
    });

    test("the back camera's reports connect the link; collisions fire from behind; turns count", () async {
      final fires = <FireMessage>[], turns = <double>[];
      link.fires.listen(fires.add);
      link.turnRates.listen(turns.add);
      toBack(utf8.encode('{"t":"rear","seq":3,"tracking":1,"collision":0,"turning":0,"imu":1,"fpga":1,"yaw_dps":120.5,"k":900}'));
      await wait(100);
      expect(link.status, LinkStatus.connected);
      expect(link.backCam?.port, board.port);
      expect((link.backStatus?.tracking, link.backStatus?.fpga), (true, true));
      expect(turns, [120.5]);
      expect(heard, contains(videoWant)); // poked, so it sends us video

      toBack(utf8.encode('{"t":"collision","seq":4}'));
      await wait(100);
      expect(fires.single.side, WearerSide.behind);

      await wait(400); // reports stopped
      expect(link.status, LinkStatus.lost);
      expect(link.backStatus, isNull);
    });

    test("the back camera's video shows up as the link's back video", () async {
      toBack(utf8.encode('{"t":"rear","tracking":1,"fpga":1}'));
      await wait(50);
      final f = jpeg(3000);
      for (final p in chunks(backMagic, 1, f)) {
        toBack(p);
      }
      await wait(100);
      expect(link.backVideo?.frame.value, f);
    });

    test('without a frame ESP32, commands go to the phone buzzer (heartbeats never do)', () async {
      link.send(const AlertCommand(side: WearerSide.left, level: 2, label: 'car'));
      link.send(const HeartbeatCommand());
      expect(buzzed.single, isA<AlertCommand>());
    });
  });

  test('phone buzz patterns feel different per message, and a newer one cuts in', () async {
    expect(buzzPattern(const AlertCommand(side: WearerSide.left, level: 2, label: 'car')), hasLength(3));
    expect(buzzPattern(const GuideCommand(GuideDirection.left)), isNot(buzzPattern(const GuideCommand(GuideDirection.right))));
    expect(buzzPattern(const LiveCommand(on: true)), isEmpty);
    final taps = <Tap>[];
    final buzzer = PhoneBuzzer(tap: (t) async => taps.add(t));
    unawaited(buzzer.play(const GuideCommand(GuideDirection.stop)));
    await buzzer.play(const GuideCommand(GuideDirection.forward));
    await wait(450);
    expect(taps, [Tap.heavy, Tap.heavy]); // stop's first tap, then forward cut it short
  });
}
