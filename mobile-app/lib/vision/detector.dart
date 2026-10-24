// Object detection on rear-camera frames.
//
// Detects behavior-relevant objects only (what, where, how big). No face
// recognition, no identities, no emotion. Frames are passed in and dropped.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../net/protocol.dart';

/// The classes the app warns about. Everything else the model sees is ignored.
const alertClasses = {'person', 'bicycle', 'car', 'motorcycle', 'bus', 'truck', 'dog', 'skateboard'};

class Detection {
  const Detection({required this.label, required this.confidence, required this.box});

  /// COCO class name, e.g. "car".
  final String label;
  final double confidence;

  /// Position in the rear camera's image, normalized 0..1 (image coordinates,
  /// not mirrored).
  final Rect box;

  /// Which side of the wearer this is on.
  WearerSide get side => wearerSideFromRearImageX(box.center.dx);

  /// Share of the frame the box covers. Grows as something approaches.
  double get area => box.width * box.height;

  @override
  String toString() => '$label ${(confidence * 100).round()}% $box';
}

abstract class ObjectDetector {
  Future<void> load();

  /// Detects [alertClasses] in one JPEG frame.
  Future<List<Detection>> detect(Uint8List jpeg);

  void dispose() {}
}

/// YOLO26n through the ultralytics_yolo plugin (Core ML on iOS, LiteRT on
/// Android). Uses the bundled 320 px export from tool/export_yolo.py, and
/// falls back to the plugin's official 640 px model if it is missing.
class YoloDetector implements ObjectDetector {
  YoloDetector({this.confidenceThreshold = 0.35});

  final double confidenceThreshold;
  YOLO? _yolo;

  /// Which model actually loaded, for the debug readout.
  String? modelName;

  static String get _bundledModel =>
      Platform.isIOS ? 'assets/models/yolo26n_320.mlpackage.zip' : 'assets/models/yolo26n_320.tflite';

  @override
  Future<void> load() async {
    var path = _bundledModel;
    try {
      await rootBundle.load(path);
    } on FlutterError {
      debugPrint('YoloDetector: $path not bundled, using the official 640 px yolo26n');
      path = 'yolo26n';
    }
    final yolo = YOLO(modelPath: path, task: YOLOTask.detect);
    if (!await yolo.loadModel()) throw StateError('YOLO model $path failed to load');
    _yolo = yolo;
    modelName = path.split('/').last;
  }

  @override
  Future<List<Detection>> detect(Uint8List jpeg) async {
    final yolo = _yolo;
    if (yolo == null) return const [];
    final result = await yolo.predict(jpeg, confidenceThreshold: confidenceThreshold);
    final raw = result['detections'];
    if (raw is! List) return const [];
    return [
      for (final d in raw)
        if (d is Map) ...parseDetection(YOLOResult.fromMap(d)),
    ];
  }

  @override
  void dispose() => _yolo?.dispose();
}

/// Keeps a plugin result if it is one of [alertClasses].
@visibleForTesting
List<Detection> parseDetection(YOLOResult r) {
  final label = r.className.toLowerCase();
  if (!alertClasses.contains(label)) return const [];
  return [Detection(label: label, confidence: r.confidence, box: r.normalizedBox)];
}
