// The phone's own back camera, a stand-in when no glasses camera is connected:
// a helper call's video, and the picture for Ask. It gives JPEG frames like the
// glasses' streams. It's on only while something uses it (a call, or a held Ask
// button), and frames are never saved.
//
// The camera plugin streams raw frames (BGRA on iOS, YUV 4:2:0 on Android), so
// each one we keep is turned upright and JPEG-encoded off the main isolate, at
// most [PhoneCamera.fps] a second.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// One raw frame, copied out of the plugin's buffers so it can go to another isolate.
class RawFrame {
  const RawFrame({required this.width, required this.height, required this.bgra, required this.planes, this.rotation = 0});

  final int width, height;

  /// True: one BGRA plane. False: Y, U, V planes.
  final bool bgra;
  final List<RawPlane> planes;

  /// Degrees clockwise to turn the picture upright (the sensor's orientation).
  final int rotation;
}

class RawPlane {
  const RawPlane(this.bytes, this.bytesPerRow, [this.bytesPerPixel = 1]);
  final Uint8List bytes;
  final int bytesPerRow, bytesPerPixel;
}

/// An upright JPEG of [f].
Uint8List encodeFrame(RawFrame f, {int quality = 70}) {
  img.Image picture;
  if (f.bgra) {
    final p = f.planes.first;
    picture = img.Image.fromBytes(
      width: f.width,
      height: f.height,
      bytes: p.bytes.buffer,
      bytesOffset: p.bytes.offsetInBytes,
      rowStride: p.bytesPerRow,
      order: img.ChannelOrder.bgra,
    );
  } else {
    final (y, u, v) = (f.planes[0], f.planes[1], f.planes[2]);
    picture = img.Image(width: f.width, height: f.height);
    for (var row = 0; row < f.height; row++) {
      for (var col = 0; col < f.width; col++) {
        final luma = y.bytes[row * y.bytesPerRow + col];
        final i = (row >> 1) * u.bytesPerRow + (col >> 1) * u.bytesPerPixel;
        final cb = u.bytes[i] - 128, cr = v.bytes[i] - 128;
        picture.setPixelRgb(
          col,
          row,
          (luma + 1.402 * cr).round().clamp(0, 255),
          (luma - 0.344 * cb - 0.714 * cr).round().clamp(0, 255),
          (luma + 1.772 * cb).round().clamp(0, 255),
        );
      }
    }
  }
  if (f.rotation % 360 != 0) picture = img.copyRotate(picture, angle: f.rotation);
  return img.encodeJpg(picture, quality: quality);
}

class PhoneCamera {
  PhoneCamera({this.fps = 5});

  final int fps;

  /// The newest JPEG, or null while the camera is off or warming up.
  final frame = ValueNotifier<Uint8List?>(null);

  /// Why the camera couldn't start, to show.
  String? error;

  bool get on => _users > 0;

  CameraController? _controller;
  Future<void>? _opening;
  int _users = 0;
  int _rotation = 0;
  bool _encoding = false;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Starts the camera for one more user. Each start needs one [stop].
  Future<void> start() async {
    if (_users++ > 0) return _opening;
    error = null;
    await (_opening = _open());
  }

  Future<void> stop() async {
    if (_users == 0 || --_users > 0) return;
    await _opening;
    final c = _controller;
    _controller = null;
    frame.value = null; // an old picture must never answer a new question
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    await c.dispose();
  }

  /// The next frame, or null if none comes within [timeout].
  Future<Uint8List?> next({Duration timeout = const Duration(seconds: 3)}) {
    final now = frame.value;
    if (now != null) return Future.value(now);
    final done = Completer<Uint8List?>();
    void check() {
      if (frame.value != null && !done.isCompleted) done.complete(frame.value);
    }

    frame.addListener(check);
    return done.future.timeout(timeout, onTimeout: () => null).whenComplete(() => frame.removeListener(check));
  }

  Future<void> _open() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.where((c) => c.lensDirection == CameraLensDirection.back).firstOrNull ?? cameras.firstOrNull;
      if (back == null) throw CameraException('none', 'This phone has no camera.');
      final c = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : ImageFormatGroup.yuv420,
      );
      await c.initialize();
      if (_users == 0) {
        await c.dispose(); // stopped while it was opening
        return;
      }
      _rotation = back.sensorOrientation; // held upright
      _controller = c;
      await c.startImageStream(_onImage);
    } on CameraException catch (e) {
      debugPrint('Phone camera: ${e.code} ${e.description}');
      error = e.code.contains('Access')
          ? 'Allow the camera for Omni Glasses in Settings to use your phone camera.'
          : "Couldn't start the phone camera.";
    }
  }

  void _onImage(CameraImage image) {
    final now = DateTime.now();
    if (_encoding || now.difference(_lastAt) < Duration(milliseconds: 1000 ~/ fps)) return;
    _encoding = true;
    _lastAt = now;
    final raw = RawFrame(
      width: image.width,
      height: image.height,
      bgra: image.format.group == ImageFormatGroup.bgra8888,
      planes: [
        for (final p in image.planes) RawPlane(Uint8List.fromList(p.bytes), p.bytesPerRow, p.bytesPerPixel ?? 1),
      ],
      rotation: _rotation,
    );
    unawaited(_encode(raw));
  }

  Future<void> _encode(RawFrame raw) async {
    try {
      final jpeg = await Isolate.run(() => encodeFrame(raw));
      if (_controller != null) frame.value = jpeg;
    } catch (e) {
      debugPrint('Phone camera: encode: $e');
    } finally {
      _encoding = false;
    }
  }
}
