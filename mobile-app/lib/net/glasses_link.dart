// UDP link to the glasses: discovery, heartbeat, link-lost detection.
//
// Two kinds of hardware talk to the phone, each on its own UDP port:
//
//   UDP 4210  the frame ESP32 and its cameras (mock_glasses.py): every device
//             sends {"t":"hello","id":...} every 2 s; the frame sends "sens"
//             and "fire" and takes commands (buzzes, LED, heartbeat).
//   UDP 4310  the camera boards (firmware/): {"t":"cam_hello","role":"eye"|"front",...}
//             every 2 s. Their video is read by UdpCamera.
//   UDP 4300  the back camera + FPGA (firmware/esp_camera3_back): status JSON,
//             {"t":"collision"} and "OMNV" video chunks. Any packet we send it
//             makes us a viewer, so we poke it every 2 s.
//
// The app learns each device's address from the sender of its datagrams (no
// broadcast or multicast, which iOS restricts: the boards have to send to the
// phone directly). The link counts as lost when neither a sensor sample nor a
// back camera status has arrived for [linkTimeout].

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../vision/mjpeg.dart';
import '../vision/udp_camera.dart';
import 'protocol.dart';

enum LinkStatus {
  /// Never connected since the app started.
  searching,

  /// Sensor samples (or back camera reports) are arriving.
  connected,

  /// Was connected, samples stopped. The glasses are not watching.
  lost,
}

class DeviceAddress {
  const DeviceAddress(this.address, this.port);
  final InternetAddress address;
  final int port;

  @override
  bool operator ==(Object other) => other is DeviceAddress && other.address == address && other.port == port;

  @override
  int get hashCode => Object.hash(address, port);

  @override
  String toString() => '${address.address}:$port';
}

/// A camera board that said hello on [camHelloPort], or one on another network
/// whose frames come through a relay (tools/cam_relay.py, cloud/relay.py).
class CameraBoard {
  const CameraBoard(InternetAddress this.address, this.hello) : relay = null;

  /// [role]'s camera at [relay] (e.g. `https://omni-glasses.fly.dev/relay/KEY`): MJPEG only, no /sensor.
  CameraBoard.relayed(Uri this.relay, String role) : address = null, hello = CamHello(role: role, udp: false);

  /// Null for a relayed board.
  final InternetAddress? address;
  final CamHello hello;
  final Uri? relay;

  Uri _relayed(String what) => relay!.replace(path: '${relay!.path}/${hello.role}/$what');

  /// Its video: UDP (WANT / CAMV chunks), or MJPEG over HTTP.
  Uri get video => relay != null
      ? _relayed('stream')
      : Uri.parse('${hello.udp ? 'udp' : 'http'}://${address!.address}:${hello.streamPort}${hello.udp ? '' : '/stream'}');

  /// One still at [size] (qvga, vga, svga, ...), over HTTP. A relay has only the newest frame.
  Uri capture([String size = 'vga']) =>
      relay != null ? _relayed('capture') : Uri.parse('http://${address!.address}:${hello.httpPort}/capture?size=$size');

  /// The front board's exposure and gain (for outside time); a relay has none.
  Uri? get sensor => relay != null ? null : Uri.parse('http://${address!.address}:${hello.httpPort}/sensor');

  /// The relay laptop's distance ahead (tools/cam_relay.py --front-depth): left_cm, center_cm, right_cm.
  Uri? get distance => relay != null ? _relayed('sensor') : null;

  /// Where it is, for Settings: its video address, or the relay it comes through.
  String get where => relay != null ? 'through the camera relay at ${relay!.authority}' : video.toString();

  /// A live feed of its video.
  CameraFeed open() => hello.udp && address != null ? UdpCamera(address!, hello.streamPort) : RearCamera(video);

  @override
  bool operator ==(Object other) =>
      other is CameraBoard &&
      other.address == address &&
      other.relay == relay &&
      other.hello.role == hello.role &&
      other.hello.streamPort == hello.streamPort &&
      other.hello.httpPort == hello.httpPort;

  @override
  int get hashCode => Object.hash(address, relay, hello.role, hello.streamPort, hello.httpPort);
}

const _relayPref = 'camera_relay';

/// A camera relay address as typed in Settings (http(s)://host[:port]/relay/KEY), or null.
Uri? parseRelay(String input) {
  final u = Uri.tryParse(input.trim());
  final path = u?.path.replaceAll(RegExp(r'/+$'), '') ?? '';
  if (u == null || !(u.isScheme('http') || u.isScheme('https')) || u.host.isEmpty) return null;
  if (!RegExp(r'^/relay/[^/]+$').hasMatch(path)) return null;
  return Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null, path: path);
}

class GlassesLink extends ChangeNotifier {
  /// [port] 0 picks free ports for everything (tests).
  GlassesLink({
    this.port = appUdpPort,
    int? helloPort,
    int? backPort,
    this.linkTimeout = const Duration(seconds: 1),
    this.backTimeout = const Duration(milliseconds: 1500),
    this.heartbeatInterval = const Duration(milliseconds: 250),
    this.pokeInterval = const Duration(seconds: 2),
    this.boardTimeout = const Duration(seconds: 7),
  }) : helloPort = helloPort ?? (port == 0 ? 0 : camHelloPort),
       backPort = backPort ?? (port == 0 ? 0 : backCamPort);

  /// UDP port to listen on for the frame. 0 picks a free port (tests).
  final int port;

  /// Where the camera boards say hello, and where the back camera talks.
  final int helloPort, backPort;
  final Duration linkTimeout;

  /// The back camera reports ~5 times a second; this long without one is lost.
  final Duration backTimeout;
  final Duration heartbeatInterval;

  /// How often we poke the back camera so it keeps sending us video.
  final Duration pokeInterval;

  /// The eye and front boards say hello every 2 s; this long without one, the board is gone.
  final Duration boardTimeout;

  /// Called for commands meant for the frame while there's no frame to get
  /// them (the boards have no buzz motor): the phone vibrates instead.
  void Function(GlassesCommand)? onNoFrame;

  RawDatagramSocket? _socket, _helloSocket, _backSocket;
  Timer? _heartbeat;
  Timer? _watchdog;
  Timer? _poke;
  bool _disposed = false;

  final _sens = StreamController<SensMessage>.broadcast();
  final _fires = StreamController<FireMessage>.broadcast();
  final _turns = StreamController<double>.broadcast();

  /// Sensor samples, 10 per second while connected. Not stored anywhere.
  Stream<SensMessage> get sens => _sens.stream;

  /// Sensor samples the phone measures itself from the camera boards
  /// (lib/eyes/phone_eyes.dart), used while there's no frame ESP32 to send them.
  void addPhoneSens(SensMessage s) {
    if (_frame == null && !_sens.isClosed) _sens.add(s);
  }

  /// Collision reflex events: Cam B's relayed by the frame, or the back
  /// camera's FPGA (side "behind": it doesn't say which side).
  Stream<FireMessage> get fires => _fires.stream;

  /// How fast the head turns (degrees per second, size only), from the FPGA's gyro.
  Stream<double> get turnRates => _turns.stream;

  LinkStatus _status = LinkStatus.searching;
  LinkStatus get status => _status;

  DeviceAddress? _frame;
  DeviceAddress? get frame => _frame;

  DeviceAddress? _camA;
  DeviceAddress? get camA => _camA;

  DeviceAddress? _camB;
  DeviceAddress? get camB => _camB;

  /// MJPEG stream of the rear camera, once Cam A has said hello.
  Uri? get streamUrl => _stream(_camA);

  /// MJPEG stream of the reflex camera (the FPGA), once Cam B has said hello.
  Uri? get camBStreamUrl => _stream(_camB);

  static Uri? _stream(DeviceAddress? cam) =>
      cam == null ? null : Uri.parse('http://${cam.address.address}:$camStreamPort/stream');

  final _boards = <String, CameraBoard>{};
  final _boardHeard = <String, DateTime>{};

  /// The eye camera board, once it said hello (else through the relay, if one is set).
  CameraBoard? get eyeCam => _boards['eye'] ?? _relayed['eye'];

  /// The front camera board, once it said hello (else through the relay, if one is set).
  CameraBoard? get frontCam => _boards['front'] ?? _relayed['front'];

  Uri? _relay;
  var _relayed = const <String, CameraBoard>{};

  /// Where the eye and front cameras come from when they're on another network
  /// (tools/cam_relay.py), or null. A board that says hello on the hotspot wins.
  Uri? get relay => _relay;

  set relay(Uri? base) {
    if (base == _relay) return;
    _relay = base;
    _relayed = base == null ? const {} : {for (final r in ['eye', 'front']) r: CameraBoard.relayed(base, r)};
    notifyListeners();
  }

  /// The relay saved in Settings, if any.
  Future<void> loadRelay() async {
    final saved = (await SharedPreferences.getInstance()).getString(_relayPref);
    if (saved != null) relay = parseRelay(saved);
  }

  /// Uses and remembers the relay at [input] (empty: none). False if it isn't a relay address.
  Future<bool> saveRelay(String input) async {
    final base = parseRelay(input);
    if (base == null && input.trim().isNotEmpty) return false;
    relay = base;
    final p = await SharedPreferences.getInstance();
    await (base == null ? p.remove(_relayPref) : p.setString(_relayPref, base.toString()));
    return true;
  }

  DeviceAddress? _backCam;

  /// The back camera (with the FPGA), once it sent us anything.
  DeviceAddress? get backCam => _backCam;

  RearStatus? _backStatus;

  /// The FPGA's latest report, or null if none came (or none lately).
  RearStatus? get backStatus => _backStatus;

  PushedCamera? _backVideo;

  /// The back camera's video (only while the FPGA tracks something, unless
  /// its firmware has STREAM_ALWAYS), once the back camera is known.
  PushedCamera? get backVideo => _backVideo;

  int? _battery;
  int? get batteryPercent => _battery;

  DateTime? _lastSensAt, _lastBackAt;

  /// When the glasses were last heard: a sensor sample or a back camera report.
  /// Used for "Link lost 12 s ago".
  DateTime? get lastHeardAt => switch ((_lastSensAt, _lastBackAt)) {
    (final a?, final b?) => a.isAfter(b) ? a : b,
    (final a, final b) => a ?? b,
  };

  /// The ports actually bound (useful when [port] is 0).
  int? get boundPort => _socket?.port;
  int? get boundHelloPort => _helloSocket?.port;
  int? get boundBackPort => _backSocket?.port;

  Future<void> start() async {
    await _bind();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      if (_frame != null) send(const HeartbeatCommand());
    });
    _watchdog = Timer.periodic(const Duration(milliseconds: 100), (_) => _checkLink());
    _poke = Timer.periodic(pokeInterval, (_) => _pokeBack());
  }

  Future<void> _bind() async {
    _socket = await _listen(port, _drain);
    // The boards' ports are extras: if one is taken, the frame still works.
    for (final (port, read, set) in [
      (helloPort, _drainHello, (RawDatagramSocket s) => _helloSocket = s),
      (backPort, _drainBack, (RawDatagramSocket s) => _backSocket = s),
    ]) {
      try {
        set(await _listen(port, read));
      } on SocketException catch (e) {
        debugPrint('GlassesLink: UDP $port unavailable: ${e.message}');
      }
    }
    _pokeLocalNetwork();
  }

  Future<RawDatagramSocket> _listen(int port, void Function(RawDatagramSocket) read) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    socket.listen((event) {
      if (event == RawSocketEvent.read) read(socket);
      if (event == RawSocketEvent.closed) _rebindLater();
    }, onError: (_) => _rebindLater());
    return socket;
  }

  // iOS drops the sockets when the app is suspended. Bind again shortly after.
  void _rebindLater() {
    if (_socket == null && _helloSocket == null && _backSocket == null) return; // already on it
    for (final s in [_socket, _helloSocket, _backSocket]) {
      s?.close();
    }
    _socket = _helloSocket = _backSocket = null;
    if (_disposed) return;
    Timer(const Duration(seconds: 1), () {
      if (!_disposed && _socket == null) _bind().catchError((_) => _rebindLater());
    });
  }

  // iOS only shows the Local Network permission prompt (and only then lets
  // datagrams from the glasses in) after the app first sends to the local
  // network. The phone's own hotspot is always 172.20.10.0/28 on iOS, so send
  // one heartbeat to the first client address to trigger the prompt.
  void _pokeLocalNetwork() {
    if (!Platform.isIOS) return;
    _sendTo(const HeartbeatCommand(), DeviceAddress(InternetAddress('172.20.10.2'), 4211));
  }

  void _drain(RawDatagramSocket socket) {
    Datagram? d;
    while ((d = socket.receive()) != null) {
      final msg = GlassesMessage.parse(d!.data);
      if (msg != null) _handle(msg, DeviceAddress(d.address, d.port));
    }
  }

  void _drainHello(RawDatagramSocket socket) {
    Datagram? d;
    while ((d = socket.receive()) != null) {
      final hello = CamHello.parse(d!.data);
      if (hello == null) continue;
      final board = CameraBoard(d.address, hello);
      _boardHeard[hello.role] = DateTime.now();
      if (_boards[hello.role] == board) continue;
      _boards[hello.role] = board;
      notifyListeners();
    }
  }

  void _drainBack(RawDatagramSocket socket) {
    Datagram? d;
    while ((d = socket.receive()) != null) {
      final data = d!.data;
      final from = DeviceAddress(d.address, d.port);
      if (data.length > chunkHeaderBytes && String.fromCharCodes(data, 0, 4) == backMagic) {
        _setBack(from);
        _backVideo!.push(data);
        continue;
      }
      final Object? json;
      try {
        json = jsonDecode(utf8.decode(data));
      } on FormatException {
        continue;
      }
      if (json is! Map<String, dynamic>) continue;
      if (json['t'] == 'collision') {
        _setBack(from);
        _fires.add(FireMessage(side: WearerSide.behind, k: _backStatus?.k ?? 0));
        continue;
      }
      final status = RearStatus.fromJson(json);
      if (status == null) continue;
      _setBack(from);
      _lastBackAt = DateTime.now();
      final changed = _backStatus == null;
      _backStatus = status;
      _turns.add(status.turnRate);
      if (status.collision) _fires.add(FireMessage(side: WearerSide.behind, k: status.k));
      if (_status != LinkStatus.connected) {
        _status = LinkStatus.connected;
        notifyListeners();
      } else if (changed) {
        notifyListeners();
      }
    }
  }

  void _setBack(DeviceAddress from) {
    if (_backCam == from) return;
    _backCam = from;
    _backVideo ??= PushedCamera('udp://${from.address.address}:${from.port}')..start();
    notifyListeners();
  }

  // The back camera sends video to whoever sent it a packet lately. Until we
  // know where it is, try every address the iPhone hotspot hands out.
  void _pokeBack() {
    final socket = _backSocket;
    if (socket == null) return;
    final want = utf8.encode(videoWant);
    final back = _backCam;
    try {
      if (back != null) {
        socket.send(want, back.address, back.port);
      } else if (Platform.isIOS) {
        for (var host = 2; host <= 14; host++) {
          socket.send(want, InternetAddress('172.20.10.$host'), backCamPort);
        }
      }
    } on SocketException {
      // the hotspot is restarting: try again next time
    }
  }

  void _handle(GlassesMessage msg, DeviceAddress from) {
    switch (msg) {
      case HelloMessage(id: DeviceId.frame):
        _setFrame(from);
      case HelloMessage(id: DeviceId.camA):
        if (_camA != from) {
          _camA = from;
          notifyListeners();
        }
      case HelloMessage(id: DeviceId.camB):
        if (_camB != from) {
          _camB = from;
          notifyListeners();
        }
      case SensMessage():
        // A sample also tells us where the frame is, in case the app
        // restarted while the glasses were already running.
        _setFrame(from);
        _lastSensAt = DateTime.now();
        if (_status != LinkStatus.connected) {
          _status = LinkStatus.connected;
          notifyListeners();
        }
        if (msg.batteryPercent != null && msg.batteryPercent != _battery) {
          _battery = msg.batteryPercent;
          notifyListeners();
        }
        _sens.add(msg);
      case FireMessage():
        _setFrame(from);
        _fires.add(msg);
    }
  }

  void _setFrame(DeviceAddress from) {
    if (_frame == from) return;
    _frame = from;
    notifyListeners();
  }

  void _checkLink() {
    final now = DateTime.now();
    final gone = [for (final e in _boardHeard.entries) if (now.difference(e.value) > boardTimeout) e.key];
    if (gone.isNotEmpty) {
      for (final role in gone) {
        _boards.remove(role);
        _boardHeard.remove(role);
      }
      notifyListeners();
    }
    final back = _lastBackAt;
    if (_backStatus != null && back != null && now.difference(back) > backTimeout) {
      _backStatus = null;
      notifyListeners();
    }
    final sens = _lastSensAt;
    final sensAlive = sens != null && now.difference(sens) <= linkTimeout;
    if (_status == LinkStatus.connected && !sensAlive && _backStatus == null) {
      _status = LinkStatus.lost;
      notifyListeners();
    }
  }

  /// Sends a command to the frame ESP32. Without one, it goes to [onNoFrame].
  void send(GlassesCommand cmd) {
    final frame = _frame;
    if (frame != null) {
      _sendTo(cmd, frame);
    } else if (cmd is! HeartbeatCommand) {
      onNoFrame?.call(cmd);
    }
  }

  void _sendTo(GlassesCommand cmd, DeviceAddress to) {
    try {
      _socket?.send(cmd.encode(), to.address, to.port);
    } on SocketException {
      // Network briefly unavailable (hotspot restarting). The next heartbeat retries.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    _watchdog?.cancel();
    _poke?.cancel();
    for (final s in [_socket, _helloSocket, _backSocket]) {
      s?.close();
    }
    _backVideo?.dispose();
    _sens.close();
    _fires.close();
    _turns.close();
    super.dispose();
  }
}

/// The datagram bytes of a back camera video chunk, for tests and the simulator's twin.
@visibleForTesting
Uint8List chunkDatagram(String magic, int frameId, int chunk, int chunks, List<int> jpeg, List<int> part) {
  final out = Uint8List(chunkHeaderBytes + part.length);
  out.setAll(0, magic.codeUnits);
  ByteData.sublistView(out, 0, chunkHeaderBytes)
    ..setUint32(4, frameId, Endian.little)
    ..setUint16(8, chunk, Endian.little)
    ..setUint16(10, chunks, Endian.little)
    ..setUint32(12, jpeg.length, Endian.little);
  out.setAll(chunkHeaderBytes, part);
  return out;
}
