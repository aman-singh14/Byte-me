// Names what set off a reflex fire, from Cam B's own video.
//
// Cam B is the FPGA running the locust (LGMD) collision detector. It fires
// on looming motion alone and doesn't know what is coming; the frame relays
// the fire with its side. When a fire arrives, this runs YOLO on Cam B's
// newest frames and picks the object on that side. Frames are processed in
// memory and dropped, like Cam A's.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/glasses_link.dart';
import '../net/protocol.dart';
import 'detector.dart';
import 'mjpeg.dart';

abstract class FireNamer {
  /// The class of what is about to hit on [side] ("car"), or null if it
  /// can't tell.
  Future<String?> name(WearerSide side);
}

/// What a fire on [side] is most likely about: the biggest (so nearest)
/// object on that side or straight behind. A fire from straight behind (the
/// back camera's FPGA doesn't say a side) takes the biggest anywhere. Null if
/// there's nothing there.
@visibleForTesting
String? pickFireObject(List<Detection> detections, WearerSide side) {
  Detection? best;
  for (final d in detections) {
    if (side != WearerSide.behind && d.side != side && d.side != WearerSide.behind) continue;
    if (best == null || d.area > best.area) best = d;
  }
  return best?.label;
}

/// Keeps Cam B's stream open (so a frame is ready the moment a fire
/// arrives) and names fires from it. Cam B is assumed to face backward like
/// Cam A, so its image sides flip the same way. With the real boards, the
/// FPGA's own camera is the back camera board, so its video is used instead.
class CamBFireNamer extends ChangeNotifier implements FireNamer {
  CamBFireNamer(this.link, this.detector) {
    link.addListener(_onLink);
    _load();
    _onLink();
  }

  final GlassesLink link;
  final ObjectDetector detector;

  /// Frames tried per fire before giving up, and the longest a fire waits
  /// for a name (the buzz doesn't wait; only the spoken word does).
  static const maxFrames = 3;
  static const maxWait = Duration(milliseconds: 600);

  CameraFeed? _camera;
  CameraFeed? get camera => _camera;
  bool _ownsCamera = false;

  bool _ready = false;
  Future<void> _queue = Future.value(); // one detection at a time

  Future<void> _load() async {
    try {
      await detector.load();
      _ready = true;
    } catch (e) {
      debugPrint('CamBFireNamer: detector failed to load: $e');
    }
  }

  void _onLink() {
    final url = link.camBStreamUrl, back = link.backVideo;
    if (url != null ? url.toString() == _camera?.source : identical(back, _camera)) return;
    if (_ownsCamera) _camera?.dispose();
    _camera = url != null ? (RearCamera(url)..start()) : back;
    _ownsCamera = url != null;
    notifyListeners();
  }

  @override
  Future<String?> name(WearerSide side) {
    final watch = Stopwatch()..start();
    final result = _queue.then((_) => _name(side)).then((label) {
      debugPrint('CamBFireNamer: fire ${side.wire} -> ${label ?? 'no name'} in ${watch.elapsedMilliseconds} ms');
      return label;
    });
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String?> _name(WearerSide side) async {
    final camera = _camera;
    if (camera == null || !_ready) return null;
    final deadline = DateTime.now().add(maxWait);
    Uint8List? tried;
    for (var i = 0; i < maxFrames && DateTime.now().isBefore(deadline); i++) {
      var frame = camera.frame.value;
      if (frame == null || identical(frame, tried)) {
        frame = await _nextFrame(camera.frame, deadline.difference(DateTime.now()));
      }
      if (frame == null) return null;
      tried = frame;
      try {
        final label = pickFireObject(await detector.detect(frame), side);
        if (label != null) return label;
      } catch (e) {
        debugPrint('CamBFireNamer: $e');
        return null;
      }
    }
    return null;
  }

  static Future<Uint8List?> _nextFrame(ValueListenable<Uint8List?> frames, Duration timeout) {
    if (timeout <= Duration.zero) return Future.value();
    final done = Completer<Uint8List?>();
    void onFrame() {
      final f = frames.value;
      if (f != null && !done.isCompleted) done.complete(f);
    }

    frames.addListener(onFrame);
    return done.future.timeout(timeout, onTimeout: () => null).whenComplete(() => frames.removeListener(onFrame));
  }

  @override
  void dispose() {
    link.removeListener(_onLink);
    if (_ownsCamera) _camera?.dispose();
    detector.dispose();
    super.dispose();
  }
}
