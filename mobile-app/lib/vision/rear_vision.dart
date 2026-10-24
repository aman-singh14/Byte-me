// Rear vision: the camera stream plus object detection, running for the whole
// app (alerts must work on every tab, not just while Aware is open).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/glasses_link.dart';
import 'detector.dart';
import 'mjpeg.dart';

/// Detections for one frame, with when the frame was taken.
class DetectionFrame {
  const DetectionFrame(this.at, this.detections);
  final DateTime at;
  final List<Detection> detections;
}

/// Runs [detector] on the newest frame, one at a time. Frames that arrive
/// while a detection is running are skipped, except the newest one.
class DetectionLoop extends ChangeNotifier {
  DetectionLoop(this.detector, this.frames) {
    frames.addListener(_onFrame);
  }

  final ObjectDetector detector;
  final ValueListenable<Uint8List?> frames;

  final _results = StreamController<DetectionFrame>.broadcast();

  /// Every result, for the alert engine (phase 1 step 3).
  Stream<DetectionFrame> get results => _results.stream;

  List<Detection> _latest = const [];

  /// Detections from the most recent finished frame.
  List<Detection> get latest => _latest;

  Duration _lastInference = Duration.zero;
  Duration get lastInference => _lastInference;

  bool _busy = false;
  Uint8List? _lastDone;
  bool _disposed = false;

  void _onFrame() {
    if (frames.value == null && _latest.isNotEmpty) {
      _latest = const []; // stream dropped: don't show stale boxes
      notifyListeners();
    }
    if (!_busy) _run();
  }

  Future<void> _run() async {
    final jpeg = frames.value;
    if (jpeg == null || identical(jpeg, _lastDone) || _disposed) return;
    _busy = true;
    _lastDone = jpeg;
    final at = DateTime.now();
    final watch = Stopwatch()..start();
    try {
      final found = await detector.detect(jpeg);
      if (_disposed) return;
      _lastInference = watch.elapsed;
      _latest = found;
      _results.add(DetectionFrame(at, found));
      notifyListeners();
    } catch (e) {
      debugPrint('DetectionLoop: $e');
    } finally {
      _busy = false;
    }
    // A newer frame may have arrived while we were busy.
    if (!_disposed) await _run();
  }

  @override
  void dispose() {
    _disposed = true;
    frames.removeListener(_onFrame);
    _results.close();
    super.dispose();
  }
}

enum DetectorState { loading, ready, failed }

/// Starts the rear camera when Cam A says hello (and restarts it if its
/// address changes), and runs detection on it.
class RearVision extends ChangeNotifier {
  RearVision(this.link, this.detector) {
    link.addListener(_onLink);
    _loadDetector();
    _onLink();
  }

  final GlassesLink link;
  final ObjectDetector detector;

  RearCamera? _camera;
  RearCamera? get camera => _camera;

  DetectionLoop? _loop;
  DetectionLoop? get loop => _loop;

  DetectorState _detectorState = DetectorState.loading;
  DetectorState get detectorState => _detectorState;

  Future<void> _loadDetector() async {
    try {
      await detector.load();
      _detectorState = DetectorState.ready;
    } catch (e) {
      debugPrint('RearVision: detector failed to load: $e');
      _detectorState = DetectorState.failed;
    }
    _restartLoop();
    notifyListeners();
  }

  void _onLink() {
    final url = link.streamUrl;
    if (url == _camera?.url) return;
    _loop?.dispose();
    _loop = null;
    _camera?.dispose();
    _camera = url == null ? null : (RearCamera(url)..start());
    _restartLoop();
    notifyListeners();
  }

  void _restartLoop() {
    _loop?.dispose();
    final camera = _camera;
    _loop = camera != null && _detectorState == DetectorState.ready ? DetectionLoop(detector, camera.frame) : null;
  }

  @override
  void dispose() {
    link.removeListener(_onLink);
    _loop?.dispose();
    _camera?.dispose();
    detector.dispose();
    super.dispose();
  }
}
