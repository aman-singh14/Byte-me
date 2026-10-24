import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/net/protocol.dart';
import 'package:omni_glasses/vision/detector.dart';
import 'package:omni_glasses/vision/rear_vision.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

/// Detector that finishes only when the test says so.
class FakeDetector implements ObjectDetector {
  final calls = <Uint8List>[];
  final pending = <Completer<List<Detection>>>[];
  int running = 0;
  int maxRunning = 0;

  @override
  Future<void> load() async {}

  @override
  Future<List<Detection>> detect(Uint8List jpeg) {
    calls.add(jpeg);
    running++;
    if (running > maxRunning) maxRunning = running;
    final c = Completer<List<Detection>>();
    pending.add(c);
    return c.future.whenComplete(() => running--);
  }

  void finish([List<Detection> found = const []]) => pending.removeAt(0).complete(found);

  @override
  void dispose() {}
}

Uint8List frame(int id) => Uint8List.fromList([id]);

YOLOResult yolo(String name, Rect box) => YOLOResult(
  classIndex: 0,
  className: name,
  confidence: 0.9,
  boundingBox: Rect.fromLTWH(box.left * 320, box.top * 240, box.width * 320, box.height * 240),
  normalizedBox: box,
);

void main() {
  test('runs one detection at a time on the newest frame only', () async {
    final frames = ValueNotifier<Uint8List?>(null);
    final detector = FakeDetector();
    final loop = DetectionLoop(detector, frames);
    final results = <DetectionFrame>[];
    loop.results.listen(results.add);

    frames.value = frame(1); // starts detecting frame 1
    frames.value = frame(2); // arrives while busy: skipped
    frames.value = frame(3); // newest while busy
    await pumpEventQueue();
    expect(detector.calls, [frame(1)]);

    detector.finish();
    await pumpEventQueue();
    expect(detector.calls, [frame(1), frame(3)]); // 2 never ran

    detector.finish();
    await pumpEventQueue();
    expect(detector.maxRunning, 1);
    expect(results.length, 2);
    loop.dispose();
  });

  test('keeps only alert classes and maps image side to wearer side', () {
    // Left of the rear image is the wearer's right.
    final car = parseDetection(yolo('car', const Rect.fromLTWH(0.05, 0.3, 0.2, 0.2))).single;
    expect(car.label, 'car');
    expect(car.side, WearerSide.right);

    final bike = parseDetection(yolo('Bicycle', const Rect.fromLTWH(0.7, 0.3, 0.2, 0.2))).single;
    expect(bike.label, 'bicycle');
    expect(bike.side, WearerSide.left);

    expect(parseDetection(yolo('chair', const Rect.fromLTWH(0.4, 0.4, 0.1, 0.1))), isEmpty);
    expect(alertClasses.length, 8);
  });
}
