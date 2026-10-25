// Call a helper: a remote helper (friend, family, guide) sees through the
// glasses' front or rear camera and guides the wearer with haptic arrows.
//
// The app opens a room on the helper server (backend/helper.py), shares the
// helper's link, and keeps a WebSocket to the server. Once the helper is
// there it uploads the selected camera's original JPEGs, newest only, at up
// to 10 fps, with at most two frames in flight (the server acks each one), so
// a slow network drops frames instead of building up delay. Helper commands
// come back on the same socket: guidance goes to the frame as a buzz
// ("guide"), camera switches change what's uploaded, "end" ends the call.
// Nothing is recorded: frames are only held until the next one replaces them.
//
// While a helper is watching, the glasses' front LED is on ("live") so
// people nearby can tell, and the two talk through LiveKit (HelperAudio).
// Ending the call stops video, audio, the room and the LED together.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:http/http.dart' as http;

import '../alerts/alert_engine.dart';
import '../alerts/voice.dart';
import '../net/cloud.dart';
import '../net/protocol.dart';
import '../vision/mjpeg.dart';
import '../vision/phone_camera.dart';
import '../vision/rear_vision.dart';
import '../vision/udp_camera.dart';
import 'helper_audio.dart';

/// Where the helper server is: the cloud server (CLOUD_URL) if the app has one.
/// Override with `flutter run --dart-define=HELPER_URL=https://<tunnel>`.
const defaultHelperUrl = String.fromEnvironment(
  'HELPER_URL',
  defaultValue: cloudUrl == '' ? 'http://localhost:8020' : cloudUrl,
);

/// The front ESP32-CAM's stream. With mock_glasses.py, use
/// `--dart-define=FRONT_CAM_URL=http://localhost:81/stream`.
const frontCamUrl = String.fromEnvironment('FRONT_CAM_URL', defaultValue: 'http://front-cam.local:81/stream');

enum HelperCamera {
  front('F', 'Front'),
  rear('R', 'Rear'),

  /// The phone's back camera, used automatically while no glasses camera is connected.
  phone('P', 'Phone');

  /// The glasses' cameras, the ones the wearer or helper can pick.
  static const glasses = [front, rear];

  const HelperCamera(this.wire, this.label);
  final String wire;
  final String label;

  static HelperCamera? fromWire(Object? s) => values.where((c) => c.wire == s).firstOrNull;
}

enum HelperAudioState {
  /// No helper yet, or audio is switched off.
  off,
  connecting,
  on,

  /// Couldn't start ([HelperCall.audioNote] says why); video and buzzes go on.
  unavailable,
}

enum HelperState {
  idle,
  starting,

  /// The link is out; no helper yet (or they left).
  waiting,

  /// A helper is connected and watching.
  live,
  ended,
  failed,
}

/// The connection to the helper server. [IoHelperSocket] in the app, a fake
/// in tests.
abstract class HelperSocket {
  /// Text (JSON) messages from the server.
  Stream<String> get messages;
  void sendText(String text);
  void sendBytes(Uint8List bytes);

  /// The close code once the server has closed it.
  int? get closeCode;
  Future<void> close();
}

class IoHelperSocket implements HelperSocket {
  IoHelperSocket._(this._ws);
  final WebSocket _ws;

  static Future<HelperSocket> connect(Uri url) async =>
      IoHelperSocket._(await WebSocket.connect(url.toString()).timeout(const Duration(seconds: 8)));

  @override
  Stream<String> get messages => _ws.where((m) => m is String).cast<String>();

  @override
  void sendText(String text) => _ws.add(text);

  @override
  void sendBytes(Uint8List bytes) => _ws.add(bytes);

  @override
  int? get closeCode => _ws.closeCode;

  @override
  Future<void> close() => _ws.close();
}

/// Camera frames for the call: the rear camera's existing stream (an
/// ESP32-CAM serves one client at a time, so it's shared with rear vision),
/// and the front camera's stream, opened only while it's selected.
abstract class HelperCameras {
  /// Whether a glasses camera is connected; without one, calls use the phone's.
  bool get glasses;

  /// The newest frame of [which], or null if that camera isn't there yet.
  ValueListenable<Uint8List?>? open(HelperCamera which);
  void close(HelperCamera which);

  /// Why the camera in use can't show anything, to tell the wearer.
  String? problem(HelperCamera which) => null;
}

class GlassesCameras implements HelperCameras {
  GlassesCameras(this.vision, {Uri? front, PhoneCamera? phone})
    : front = front ?? Uri.parse(frontCamUrl),
      phone = phone ?? PhoneCamera();

  final RearVision vision;

  /// The front camera's MJPEG stream when no front camera board said hello (mock_glasses.py).
  final Uri front;
  final PhoneCamera phone;
  CameraFeed? _front;

  /// A glasses camera is on the hotspot: the rear one rear vision uses, or the front board.
  @override
  bool get glasses => vision.camera != null || vision.link.frontCam != null;

  /// The front camera board's UDP video, or the MJPEG stream.
  CameraFeed _openFront() {
    final board = vision.link.frontCam;
    return board == null ? RearCamera(front) : UdpCamera(board.address, board.hello.streamPort);
  }

  @override
  ValueListenable<Uint8List?>? open(HelperCamera which) => switch (which) {
    HelperCamera.rear => vision.camera?.frame,
    HelperCamera.front => (_front ??= _openFront()..start()).frame,
    HelperCamera.phone => (phone..start()).frame,
  };

  @override
  void close(HelperCamera which) {
    switch (which) {
      case HelperCamera.rear:
        return; // the rear stream belongs to rear vision
      case HelperCamera.front:
        _front?.dispose();
        _front = null;
      case HelperCamera.phone:
        unawaited(phone.stop());
    }
  }

  @override
  String? problem(HelperCamera which) => which == HelperCamera.phone ? phone.error : null;
}

/// Builds a frame for the server: camera id, 8-byte big-endian timestamp
/// (ms since epoch), then the JPEG unchanged.
Uint8List helperFrame(HelperCamera camera, DateTime at, Uint8List jpeg) {
  final out = Uint8List(9 + jpeg.length);
  out[0] = camera.wire.codeUnitAt(0);
  ByteData.sublistView(out, 1, 9).setUint64(0, at.millisecondsSinceEpoch);
  out.setRange(9, out.length, jpeg);
  return out;
}

class HelperCall extends ChangeNotifier {
  HelperCall({
    required this.toGlasses,
    required this.cameras,
    required Stream<AlertEvent> alerts,
    this.voice,
    this.wearerName,
    Uri? server,
    http.Client? client,
    Future<HelperSocket> Function(Uri url)? connect,
    HelperAudio? audio,
    this.audioEnabled,
    DateTime Function()? clock,
    bool watchLifecycle = true,
  }) : server = server ?? Uri.parse(defaultHelperUrl),
       audio = audio ?? LiveKitHelperAudio(),
       _http = client ?? http.Client(),
       _connect = connect ?? IoHelperSocket.connect,
       _clock = clock ?? DateTime.now {
    _alerts = alerts.listen(_onAlert);
    if (watchLifecycle) _lifecycle = AppLifecycleListener(onStateChange: _onLifecycle);
  }

  /// Sends a command to the frame ESP32 (GlassesLink.send).
  final void Function(GlassesCommand) toGlasses;
  final HelperCameras cameras;
  final Voice? voice;
  final String? Function()? wearerName;
  final Uri server;
  final http.Client _http;
  final Future<HelperSocket> Function(Uri) _connect;
  final DateTime Function() _clock;
  final HelperAudio audio;

  /// The "Helper call audio" switch; null means always on.
  final bool Function()? audioEnabled;

  /// Upload at most this often (10 fps).
  static const frameInterval = Duration(milliseconds: 100);

  /// Frames sent but not yet acked by the server.
  static const maxInFlight = 2;

  late final StreamSubscription<AlertEvent> _alerts;
  AppLifecycleListener? _lifecycle;

  HelperState _state = HelperState.idle;
  HelperState get state => _state;

  /// Why it failed, to show the wearer.
  String? _error;
  String? get error => _error;

  /// The link to send the helper.
  String? _helperUrl;
  String? get helperUrl => _helperUrl;

  /// The camera the helper sees: the picked glasses camera, or the phone's
  /// while no glasses camera is connected.
  HelperCamera get camera => _uploader != null ? _camera : _wanted;
  HelperCamera _camera = HelperCamera.front;

  /// What the wearer or helper picked last.
  HelperCamera _picked = HelperCamera.front;

  HelperCamera get _wanted => cameras.glasses ? _picked : HelperCamera.phone;

  /// Why the camera in use shows nothing, to tell the wearer.
  String? get cameraProblem => cameras.problem(camera);

  // Status changes (helper connected, call ended) are spoken by
  // HelperAnnouncer, which knows whether a screen reader is on. Guidance words
  // are spoken here, with the buzz.

  /// The last direction the helper sent, for the screen.
  GuideDirection? _lastGuide;
  GuideDirection? get lastGuide => _lastGuide;

  String? _room;
  String? _token;
  HelperSocket? _socket;
  StreamSubscription<String>? _messages;
  Timer? _uploader;
  Timer? _reconnect;
  ValueListenable<Uint8List?>? _feed;
  Uint8List? _latest;
  DateTime? _latestAt;
  int _inFlight = 0;
  bool _cameraOnline = false;

  bool get active => _state == HelperState.waiting || _state == HelperState.live;

  HelperAudioState _audioState = HelperAudioState.off;
  HelperAudioState get audioState => _audioState;

  /// Why audio isn't on, to show.
  String? _audioNote;
  String? get audioNote => _audioNote;

  bool _muted = false;
  bool get muted => _muted;

  int _audioSession = 0;
  bool _ledOn = false;

  /// Opens a room and connects. Returns an error to show, or null; then
  /// share [helperUrl].
  Future<String?> start() async {
    if (active || _state == HelperState.starting) return null;
    _set(HelperState.starting);
    _error = null;
    try {
      final r = await _http.post(
        server.resolve('/rooms'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'wearer_name': wearerName?.call()}),
      ).timeout(const Duration(seconds: 8));
      if (r.statusCode != 201) throw HttpException('HTTP ${r.statusCode}');
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      _room = j['room'] as String;
      _token = j['wearer_token'] as String;
      _helperUrl = j['helper_url'] as String;
      await _open();
      _set(HelperState.waiting);
      return null;
    } catch (e) {
      debugPrint('HelperCall: could not start: $e');
      _error = "Couldn't reach the helper server. Check the connection and try again.";
      _set(HelperState.failed);
      return _error;
    }
  }

  Future<void> _open() async {
    final url = server.replace(
      scheme: server.scheme == 'https' ? 'wss' : 'ws',
      path: '/ws/wearer/$_room',
      queryParameters: {'t': _token},
    );
    final socket = _socket = await _connect(url);
    _inFlight = 0;
    _messages = socket.messages.listen(_onMessage, onDone: () => _onClosed(socket));
  }

  void _onMessage(String text) {
    final Object? msg;
    try {
      msg = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (msg is! Map) return;
    switch (msg['t']) {
      case 'ack':
        if (_inFlight > 0) _inFlight--;
      case 'helper':
        msg['on'] == true ? _helperJoined() : _helperLeft();
      case 'guide':
        final dir = GuideDirection.fromWire(msg['dir']);
        if (dir == null || _state != HelperState.live) return;
        toGlasses(GuideCommand(dir));
        _lastGuide = dir;
        voice?.say(switch (dir) {
          GuideDirection.left => 'Left',
          GuideDirection.right => 'Right',
          GuideDirection.forward => 'Forward',
          GuideDirection.stop => 'Stop',
        }, interrupt: true);
        notifyListeners();
      case 'cam':
        final which = HelperCamera.fromWire(msg['which']);
        if (which != null) selectCamera(which);
      case 'end':
        end();
    }
  }

  void _helperJoined() {
    if (_state == HelperState.live) return;
    _set(HelperState.live);
    _led(true);
    _startUploading();
    unawaited(_startAudio());
  }

  void _helperLeft() {
    if (_state != HelperState.live) return;
    _stopUploading();
    _stopAudio();
    _led(false);
    _set(HelperState.waiting);
  }

  void _led(bool on) {
    if (on == _ledOn) return;
    _ledOn = on;
    toGlasses(LiveCommand(on: on));
  }

  Future<void> _startAudio() async {
    final session = ++_audioSession;
    _muted = false;
    if (audioEnabled?.call() == false) {
      _setAudio(HelperAudioState.off, 'Call audio is off in Settings. Video and buzzes still work.');
      return;
    }
    _setAudio(HelperAudioState.connecting);
    try {
      final r = await _http
          .get(server.replace(path: '/livekit-token', queryParameters: {'room': _room, 't': _token}))
          .timeout(const Duration(seconds: 8));
      if (session != _audioSession) return;
      if (r.statusCode == 503) {
        _setAudio(HelperAudioState.unavailable, "Call audio isn't set up. Video and buzzes still work.");
        return;
      }
      if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      await audio.join(j['url'] as String, j['token'] as String);
      if (session != _audioSession) {
        await audio.leave(); // the call moved on while joining
        return;
      }
      _setAudio(HelperAudioState.on);
    } catch (e) {
      debugPrint('HelperCall: audio: $e');
      if (session != _audioSession) return;
      unawaited(audio.leave());
      _setAudio(HelperAudioState.unavailable, "Couldn't start call audio. Video and buzzes still work.");
    }
  }

  void _stopAudio() {
    _audioSession++;
    _muted = false;
    unawaited(audio.leave());
    _setAudio(HelperAudioState.off);
  }

  void _setAudio(HelperAudioState s, [String? note]) {
    _audioState = s;
    _audioNote = note;
    notifyListeners();
  }

  /// Mutes or unmutes the wearer's microphone.
  Future<void> setMuted(bool muted) async {
    if (_audioState != HelperAudioState.on) return;
    _muted = muted;
    notifyListeners();
    await audio.setMuted(muted);
  }

  /// The server closed the socket: the call ended (expired, or ended from
  /// elsewhere), or the network dropped, in which case we reconnect.
  void _onClosed(HelperSocket socket) {
    if (socket != _socket || !active) return;
    _stopUploading();
    _messages?.cancel();
    _socket = null;
    final code = socket.closeCode;
    if (code == 4410 || code == 4401) {
      _finish();
      return;
    }
    if (_state == HelperState.live) {
      _stopAudio();
      _led(false);
      _set(HelperState.waiting);
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnect?.cancel();
    _reconnect = Timer(const Duration(seconds: 2), () async {
      if (!active || _socket != null) return;
      try {
        await _open(); // the server says "helper on" again if they're still there
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  /// Switches between the glasses' cameras. Without glasses the phone camera
  /// stays on, and the pick takes effect once they connect.
  void selectCamera(HelperCamera which) {
    if (which == HelperCamera.phone) return; // only ever automatic
    _picked = which;
    _switchTo(_wanted);
  }

  void _switchTo(HelperCamera which) {
    if (which == _camera) return;
    final old = _camera;
    _camera = which;
    if (_uploader != null) {
      _unbindFeed();
      cameras.close(old);
      _bindFeed();
    }
    _sendStatus();
    notifyListeners();
  }

  void _startUploading() {
    _camera = _wanted;
    _bindFeed();
    _uploader?.cancel();
    _uploader = Timer.periodic(frameInterval, (_) => _upload());
    _sendStatus();
  }

  void _stopUploading() {
    _uploader?.cancel();
    _uploader = null;
    _unbindFeed();
    cameras.close(_camera);
  }

  void _bindFeed() {
    _feed = cameras.open(_camera);
    _feed?.addListener(_onFrame);
  }

  void _unbindFeed() {
    _feed?.removeListener(_onFrame);
    _feed = null;
    _latest = null;
    _latestAt = null; // the next camera's video is "waiting" until it sends a frame
    _cameraOnline = false;
  }

  void _onFrame() {
    final frame = _feed?.value;
    if (frame == null) return;
    _latest = frame; // newest only
    _latestAt = _clock();
  }

  void _upload() {
    // The glasses' cameras may only appear after the call started (Cam A's hello).
    if (_wanted != _camera) {
      _switchTo(_wanted);
    } else if (_feed == null) {
      _bindFeed();
    }
    final online = _latestAt != null && _clock().difference(_latestAt!) < const Duration(seconds: 3);
    if (online != _cameraOnline) {
      _cameraOnline = online;
      _sendStatus();
    }
    final frame = _latest, socket = _socket;
    if (frame == null || socket == null || _inFlight >= maxInFlight) return;
    _latest = null;
    _inFlight++;
    socket.sendBytes(helperFrame(_camera, _latestAt ?? _clock(), frame));
  }

  void _sendStatus() => _sendJson({'t': 'status', 'camera': _camera.wire, 'video': _cameraOnline ? 'on' : 'waiting'});

  void _onAlert(AlertEvent e) {
    if (_state != HelperState.live) return;
    switch (e) {
      case AlertRaised(:final alert):
        _sendJson({'t': 'alert', 'side': alert.side.wire, 'level': alert.level.wire, 'label': alert.label});
      case SocialTapped(:final side, :final action, :final lookUp):
        _sendJson({'t': 'tap', 'side': side.wire, 'kind': lookUp ? 'lookup' : 'social', 'action': ?action});
      case PossiblyFollowing(:final side, :final behindFor, update: false):
        _sendJson({'t': 'alert', 'kind': 'following', 'side': side.wire, 'minutes': behindFor.inMinutes});
      case _:
        break;
    }
  }

  void _sendJson(Map<String, Object?> msg) => _socket?.sendText(jsonEncode(msg));

  /// Ends the call for everyone: frames, the room, and the helper's view.
  Future<void> end() async {
    if (!active && _state != HelperState.starting) return;
    _sendJson({'t': 'end'});
    _finish();
  }

  void _finish() {
    _stopUploading();
    _stopAudio();
    _led(false);
    _reconnect?.cancel();
    _messages?.cancel();
    _messages = null;
    _socket?.close();
    _socket = null;
    _room = _token = null;
    _lastGuide = null;
    _set(HelperState.ended);
  }

  /// Leaving the app mid-call ends it rather than streaming silently. While
  /// still waiting (sharing the link) it stays open.
  void _onLifecycle(AppLifecycleState s) {
    if (_state == HelperState.live && (s == AppLifecycleState.paused || s == AppLifecycleState.hidden)) end();
  }

  void _set(HelperState s) {
    _state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    if (active) end();
    _alerts.cancel();
    _lifecycle?.dispose();
    _http.close();
    super.dispose();
  }
}
