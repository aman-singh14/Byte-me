// MJPEG client for the rear camera (Cam A, http://<ip>:81/stream).
//
// Only the newest frame is kept, in memory. Nothing is written to disk and
// older frames are dropped as soon as a newer one arrives.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Splits an MJPEG byte stream into JPEG frames.
///
/// It looks for the JPEG start (FF D8) and end (FF D9) markers instead of
/// parsing the multipart headers, so it works with any boundary string
/// (the ESP32-CAM and the mock use different ones). This assumes frames have
/// no embedded thumbnail, which is true for the ESP32-CAM and OpenCV.
class MjpegParser {
  /// A "frame" bigger than this means we lost sync; drop it and resync.
  static const maxFrameBytes = 512 * 1024;

  Uint8List _buf = Uint8List(64 * 1024);
  int _len = 0;
  int _start = -1; // index of the current frame's FF D8, or -1 between frames
  int _scanned = 0; // bytes before this index have been scanned

  /// Feeds [chunk] and returns any frames it completed, oldest first.
  List<Uint8List> add(List<int> chunk) {
    _append(chunk);
    final frames = <Uint8List>[];
    for (var i = math.max(_scanned, 1); i < _len; i++) {
      if (_buf[i - 1] != 0xFF) continue;
      final marker = _buf[i];
      if (marker == 0xD8) {
        _start = i - 1; // a new start also resyncs after a cut-off frame
      } else if (marker == 0xD9 && _start >= 0) {
        frames.add(Uint8List.fromList(Uint8List.sublistView(_buf, _start, i + 1)));
        _start = -1;
      }
    }
    _scanned = _len;
    _compact();
    return frames;
  }

  void _append(List<int> chunk) {
    if (_len + chunk.length > _buf.length) {
      final bigger = Uint8List(math.max(_buf.length * 2, _len + chunk.length));
      bigger.setRange(0, _len, _buf);
      _buf = bigger;
    }
    _buf.setRange(_len, _len + chunk.length, chunk);
    _len += chunk.length;
  }

  // Drop bytes we no longer need: everything before the current frame, or
  // everything but the last byte between frames (it may be the FF of a marker).
  void _compact() {
    if (_start >= 0 && _len - _start > maxFrameBytes) _start = -1;
    final keepFrom = _start >= 0 ? _start : math.max(_len - 1, 0);
    if (keepFrom == 0) return;
    _buf.setRange(0, _len - keepFrom, _buf, keepFrom);
    _len -= keepFrom;
    _scanned -= keepFrom;
    if (_start >= 0) _start -= keepFrom;
  }
}

enum CameraState { idle, connecting, streaming, retrying }

/// A live camera: MJPEG over HTTP ([RearCamera]), or JPEG chunks over UDP
/// from the boards (udp_camera.dart). Frames are kept newest-only, never stored.
abstract class CameraFeed {
  /// The newest JPEG frame, or null while there's none.
  ValueNotifier<Uint8List?> get frame;
  ValueNotifier<CameraState> get state;

  /// Frames per second over the last second.
  ValueNotifier<int> get fps;

  /// Where the frames come from, for Settings and to tell feeds apart.
  String get source;

  void start();
  void dispose();
}

/// Pulls the rear camera's MJPEG stream and keeps the newest frame.
/// Reconnects by itself when the stream drops.
class RearCamera implements CameraFeed {
  RearCamera(this.url, {this.retryDelay = const Duration(seconds: 1)});

  final Uri url;
  final Duration retryDelay;

  @override
  String get source => url.toString();

  /// The newest JPEG frame. Replaced (not queued) as frames arrive.
  @override
  final frame = ValueNotifier<Uint8List?>(null);
  @override
  final state = ValueNotifier<CameraState>(CameraState.idle);

  /// Frames per second over the last second.
  @override
  final fps = ValueNotifier<int>(0);

  HttpClient? _client;
  StreamSubscription<List<int>>? _sub;
  Timer? _fpsTimer;
  Timer? _retry;
  int _framesThisSecond = 0;
  bool _running = false;

  @override
  void start() {
    if (_running) return;
    _running = true;
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      fps.value = _framesThisSecond;
      _framesThisSecond = 0;
    });
    _connect();
  }

  Future<void> _connect() async {
    if (!_running) return;
    state.value = CameraState.connecting;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3)
      ..idleTimeout = const Duration(seconds: 3);
    _client = client;
    try {
      final request = await client.getUrl(url);
      final response = await request.close();
      if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}', uri: url);
      final parser = MjpegParser();
      _sub = response
          .timeout(const Duration(seconds: 2)) // stalled stream counts as dropped
          .listen(
            (chunk) {
              final frames = parser.add(chunk);
              if (frames.isEmpty) return;
              _framesThisSecond += frames.length;
              frame.value = frames.last; // newest only
              state.value = CameraState.streaming;
            },
            onError: (_) => _scheduleRetry(),
            onDone: _scheduleRetry,
            cancelOnError: true,
          );
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _sub?.cancel();
    _sub = null;
    _client?.close(force: true);
    _client = null;
    frame.value = null;
    if (!_running) return;
    state.value = CameraState.retrying;
    _retry?.cancel();
    _retry = Timer(retryDelay, _connect);
  }

  void stop() {
    _running = false;
    _retry?.cancel();
    _fpsTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    _client?.close(force: true);
    _client = null;
    frame.value = null;
    fps.value = 0;
    state.value = CameraState.idle;
  }

  @override
  void dispose() {
    stop();
    frame.dispose();
    state.dispose();
    fps.dispose();
  }
}
