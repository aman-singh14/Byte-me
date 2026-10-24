// UDP link to the glasses: discovery, heartbeat, link-lost detection.
//
// Every device sends {"t":"hello","id":...} to the phone every 2 s. The app
// learns each device's address from the sender of that datagram (no broadcast
// or multicast, which iOS restricts). Once the frame ESP32 is known, the app
// sends it a heartbeat every 250 ms. The link counts as lost when no sensor
// sample has arrived for [linkTimeout].

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'protocol.dart';

enum LinkStatus {
  /// Never connected since the app started.
  searching,

  /// Sensor samples are arriving.
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

class GlassesLink extends ChangeNotifier {
  GlassesLink({
    this.port = appUdpPort,
    this.linkTimeout = const Duration(seconds: 1),
    this.heartbeatInterval = const Duration(milliseconds: 250),
  });

  /// UDP port to listen on. 0 picks a free port (tests).
  final int port;
  final Duration linkTimeout;
  final Duration heartbeatInterval;

  RawDatagramSocket? _socket;
  Timer? _heartbeat;
  Timer? _watchdog;
  bool _disposed = false;

  final _sens = StreamController<SensMessage>.broadcast();
  final _fires = StreamController<FireMessage>.broadcast();

  /// Sensor samples, 10 per second while connected. Not stored anywhere.
  Stream<SensMessage> get sens => _sens.stream;

  /// Collision reflex events from Cam B, relayed by the frame.
  Stream<FireMessage> get fires => _fires.stream;

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

  int? _battery;
  int? get batteryPercent => _battery;

  DateTime? _lastSensAt;

  /// When the last sensor sample arrived. Used for "Link lost 12 s ago".
  DateTime? get lastSensAt => _lastSensAt;

  /// The port actually bound (useful when [port] is 0).
  int? get boundPort => _socket?.port;

  Future<void> start() async {
    await _bind();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      if (_frame != null) send(const HeartbeatCommand());
    });
    _watchdog = Timer.periodic(const Duration(milliseconds: 100), (_) => _checkLink());
  }

  Future<void> _bind() async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port);
    _socket = socket;
    socket.listen((event) {
      if (event == RawSocketEvent.read) _drain(socket);
      if (event == RawSocketEvent.closed) _rebindLater();
    }, onError: (_) => _rebindLater());
    _pokeLocalNetwork();
  }

  // iOS drops the socket when the app is suspended. Bind again shortly after.
  void _rebindLater() {
    _socket = null;
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
    final last = _lastSensAt;
    if (_status == LinkStatus.connected && last != null && DateTime.now().difference(last) > linkTimeout) {
      _status = LinkStatus.lost;
      notifyListeners();
    }
  }

  /// Sends a command to the frame ESP32. Does nothing until it has said hello.
  void send(GlassesCommand cmd) {
    final frame = _frame;
    if (frame != null) _sendTo(cmd, frame);
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
    _socket?.close();
    _sens.close();
    _fires.close();
    super.dispose();
  }
}
