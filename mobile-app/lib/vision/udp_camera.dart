// Video from the camera boards over UDP (firmware/esp_camera_eye,
// esp_camera2_front, esp_camera3_back).
//
//   phone                                  eye / front camera (UDP 81)
//   "WANT" every second, from our port ->  remembers us for 5 s
//                                      <-  each frame, in datagrams of
//                                          "CAMV" frame_id chunk chunks jpeg_len + <=1400 JPEG bytes
//   "STOP" when we close               ->  forgets us
//
// The back camera sends the same layout with "OMNV" to UDP 4300, which
// GlassesLink owns, so it pushes those datagrams into a [PushedCamera].
// A frame is shown only once all its chunks arrived; a frame with a missing
// chunk is skipped and the next one replaces it, so a lost datagram costs one
// frame, never a stall. Like backend/udp_camera.py.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../net/protocol.dart';
import 'mjpeg.dart';

/// Puts chunked frames back together.
class FrameAssembler {
  FrameAssembler({this.keep = 4, this.maxJpeg = 2000000});

  /// Frames being assembled at once; older ones are dropped.
  final int keep;
  final int maxJpeg;

  final _partial = <int, _Partial>{};
  int _newest = -1;

  /// Adds one datagram. Returns a whole JPEG when this was its last missing chunk.
  Uint8List? add(Uint8List d) {
    if (d.length <= chunkHeaderBytes) return null;
    final magic = String.fromCharCodes(d, 0, 4);
    if (magic != eyeFrontMagic && magic != backMagic) return null;
    final h = ByteData.sublistView(d, 0, chunkHeaderBytes);
    final id = h.getUint32(4, Endian.little);
    final chunk = h.getUint16(8, Endian.little), chunks = h.getUint16(10, Endian.little);
    final length = h.getUint32(12, Endian.little);
    if (chunks == 0 || chunk >= chunks || length == 0 || length > maxJpeg) return null;
    if (id + 1000 < _newest) {
      _partial.clear(); // the camera restarted and counts from 1 again
      _newest = -1;
    }
    if (id <= _newest - keep) return null; // long gone
    final p = _partial.putIfAbsent(id, () => _Partial(chunks, length));
    if (p.chunks != chunks || p.length != length) return null;
    p.parts[chunk] ??= Uint8List.sublistView(d, chunkHeaderBytes);
    if (id > _newest) _newest = id;
    _partial.removeWhere((k, _) => k <= _newest - keep);
    if (p.parts.any((c) => c == null)) return null;
    _partial.removeWhere((k, _) => k <= id); // this one, and older ones that can only be stale now
    final out = BytesBuilder(copy: false);
    for (final c in p.parts) {
      out.add(c!);
    }
    final jpeg = out.takeBytes();
    return jpeg.length == length ? jpeg : null;
  }
}

class _Partial {
  _Partial(this.chunks, this.length) : parts = List<Uint8List?>.filled(chunks, null);
  final int chunks, length;
  final List<Uint8List?> parts;
}

/// Frames pushed in from elsewhere: the back camera's datagrams on GlassesLink's socket.
class PushedCamera implements CameraFeed {
  PushedCamera(this.source, {this.staleAfter = const Duration(seconds: 2)});

  @override
  final String source;
  final Duration staleAfter;

  @override
  final frame = ValueNotifier<Uint8List?>(null);
  @override
  final state = ValueNotifier<CameraState>(CameraState.connecting);
  @override
  final fps = ValueNotifier<int>(0);

  final _assembler = FrameAssembler();
  Timer? _tick;
  DateTime? _lastAt;
  int _count = 0;

  @override
  void start() {
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      fps.value = _count;
      _count = 0;
      final last = _lastAt;
      if (last != null && DateTime.now().difference(last) > staleAfter && frame.value != null) {
        frame.value = null; // stopped sending (the back camera only streams while tracking)
        state.value = CameraState.retrying;
      }
    });
  }

  /// One datagram from the camera.
  void push(Uint8List datagram) {
    final jpeg = _assembler.add(datagram);
    if (jpeg == null) return;
    _lastAt = DateTime.now();
    _count++;
    frame.value = jpeg;
    state.value = CameraState.streaming;
  }

  @override
  void dispose() {
    _tick?.cancel();
    frame.dispose();
    state.dispose();
    fps.dispose();
  }
}

/// An eye or front camera's video: asks with WANT and puts the chunks together.
class UdpCamera extends PushedCamera {
  UdpCamera(this.host, this.port, {this.wantEvery = const Duration(seconds: 1)})
    : super('udp://${host.address}:$port');

  final InternetAddress host;
  final int port;
  final Duration wantEvery;

  RawDatagramSocket? _socket;
  Timer? _want;
  bool _running = false;

  @override
  void start() {
    if (_running) return;
    _running = true;
    super.start();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      // A random port of our own: several viewers never fight over one.
      final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      if (!_running) return s.close();
      _socket = s;
      s.listen((e) {
        if (e != RawSocketEvent.read) return;
        Datagram? d;
        while ((d = s.receive()) != null) {
          if (d!.address == host) push(d.data);
        }
      });
      _send(videoWant);
      _want = Timer.periodic(wantEvery, (_) => _send(videoWant));
    } catch (e) {
      debugPrint('UdpCamera $source: $e');
      state.value = CameraState.retrying;
      if (_running) Timer(const Duration(seconds: 1), _open);
    }
  }

  void _send(String word) {
    try {
      _socket?.send(utf8.encode(word), host, port);
    } on SocketException {
      // the hotspot is restarting: the next WANT tries again
    }
  }

  @override
  void dispose() {
    _running = false;
    _want?.cancel();
    _send(videoStop);
    _socket?.close();
    super.dispose();
  }
}
