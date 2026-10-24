import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/alerts/tracker.dart';
import 'package:omni_glasses/net/protocol.dart';

final t0 = DateTime(2026, 10, 24, 12);
DateTime at(double seconds) => t0.add(Duration(microseconds: (seconds * 1e6).round()));

/// The box of something [distance] meters behind the camera, 1.5 m tall and
/// [aspect] times as wide, centered at [imageX] in the rear image. Cut off at
/// the image edges, like YOLO's boxes.
Box boxAt(double distance, {double imageX = 0.75, double aspect = 1.5}) {
  final h = 1.5 / distance, w = h * aspect;
  return clipped(imageX - w / 2, 0.6 - h / 2, imageX + w / 2, 0.6 + h / 2);
}

Box clipped(double l, double t, double r, double b) =>
    Box(l.clamp(0.0, 1.0), t.clamp(0.0, 1.0), r.clamp(0.0, 1.0), b.clamp(0.0, 1.0));

/// Someone walking across the view [distance] meters behind, entering at the
/// image's left edge. Their stride makes the box 30% wider and narrower twice
/// a second; their height barely changes.
Box walkerAt(double t, {double distance = 3}) {
  final h = 1.7 / distance * (1 + 0.02 * math.sin(t * 23));
  final w = 0.35 * h * (1 + 0.3 * math.sin(2 * math.pi * 2 * t));
  final x = 0.25 * t; // a quarter of the image width per second
  return clipped(x - w / 2, 0.6 - h / 2, x + w / 2, 0.6 + h / 2);
}

Sighting seen(String label, Box box) => Sighting(label: label, confidence: 0.9, box: box);

/// Feeds [label] at [distance] (meters, over time) at 10 frames per second.
Tracker follow(String label, double Function(double t) distance, {double seconds = 1.5, double imageX = 0.75}) {
  final tracker = Tracker();
  for (var t = 0.0; t <= seconds + 1e-9; t += 0.1) {
    tracker.update(at(t), [seen(label, boxAt(distance(t), imageX: imageX))]);
  }
  return tracker;
}

void main() {
  test('Box overlap', () {
    const a = Box(0, 0, 0.5, 0.5);
    expect(a.iou(a), 1);
    expect(a.iou(const Box(0.5, 0.5, 1, 1)), 0);
    expect(a.iou(const Box(0.25, 0, 0.75, 0.5)), closeTo(1 / 3, 1e-9));
  });

  test('estimates time to contact from box growth', () {
    // 30 m away at 6 m/s: 5 s to contact at t = 0, 3.5 s at t = 1.5.
    final track = follow('car', (t) => 30 - 6 * t).tracks.single;
    expect(track.secondsToContact, closeTo(3.5, 0.35));
    expect(track.side, WearerSide.left); // right of the rear image
  });

  test('no time to contact when standing still, moving away, or jittering', () {
    expect(follow('car', (t) => 10).tracks.single.secondsToContact, isNull);
    expect(follow('car', (t) => 10 + 4 * t).tracks.single.secondsToContact, isNull);
    // +-3% box noise, like YOLO on a parked car
    expect(follow('car', (t) => 10 * (1 + 0.03 * math.sin(t * 37))).tracks.single.secondsToContact, isNull);
  });

  test('walking across the view is not an approach', () {
    final tracker = Tracker();
    for (var t = 0.0; t <= 4; t += 0.1) {
      tracker.update(at(t), [seen('person', walkerAt(t))]);
      expect(tracker.tracks.single.secondsToContact, isNull, reason: 'at ${t.toStringAsFixed(1)} s');
    }
  });

  test('with the bottom cut off, uses width for vehicles but not people', () {
    // Close enough that the bottom is below the image.
    Tracker cutOff(String label) {
      final tracker = Tracker();
      for (var t = 0.0; t <= 1.5; t += 0.1) {
        final d = 2.0 - 0.5 * t; // 4 s to contact at t = 0
        final h = 1.7 / d, w = 0.5 / d;
        tracker.update(at(t), [seen(label, clipped(0.5 - w / 2, 0.35, 0.5 + w / 2, 0.35 + h))]);
      }
      return tracker;
    }

    expect(cutOff('car').tracks.single.secondsToContact, closeTo(2.5, 0.3));
    expect(cutOff('person').tracks.single.secondsToContact, isNull); // leaning looks like this too
  });

  test('tiny boxes are not measured', () {
    // A car 100 m away closing fast: only a few pixels, so no estimate.
    final tracker = follow('car', (t) => 120 - 20 * t);
    expect(tracker.tracks.single.secondsToContact, isNull);
  });

  test('needs enough history before estimating', () {
    final tracker = Tracker();
    for (var t = 0.0; t < 0.25; t += 0.1) {
      tracker.update(at(t), [seen('car', boxAt(20 - 10 * t))]);
    }
    expect(tracker.tracks.single.secondsToContact, isNull);
  });

  test('keeps separate objects separate', () {
    final tracker = Tracker();
    for (var t = 0.0; t <= 1; t += 0.1) {
      tracker.update(at(t), [
        seen('car', boxAt(20 - 5 * t, imageX: 0.8)),
        seen('bicycle', boxAt(8, imageX: 0.2)),
        seen('person', boxAt(8, imageX: 0.22)), // overlaps the bicycle, different class
      ]);
    }
    expect(tracker.tracks.map((t) => t.label), unorderedEquals(['car', 'bicycle', 'person']));
    expect(tracker.tracks.map((t) => t.id).toSet().length, 3);
  });

  test('drops lost tracks, and a reappearance continues the presence', () {
    final tracker = Tracker();
    tracker.update(at(0), [seen('person', boxAt(4))]);
    tracker.update(at(30), [seen('person', boxAt(4))]); // 30 s gap: a new presence
    final first = tracker.tracks.single;
    expect(first.behindSince, at(30));

    tracker.update(at(30.5), []);
    tracker.update(at(32), []); // lost after 1 s
    expect(tracker.tracks, isEmpty);

    tracker.update(at(36), [seen('person', boxAt(4.5))]); // back within 10 s
    final again = tracker.tracks.single;
    expect(again.id, isNot(first.id));
    expect(again.behindSince, at(30));

    tracker.update(at(38), []);
    tracker.update(at(60), [seen('person', boxAt(4))]); // gone too long
    expect(tracker.tracks.single.behindSince, at(60));
  });

  test('resetMotion forgets approach history', () {
    final tracker = follow('car', (t) => 30 - 6 * t);
    tracker.resetMotion();
    expect(tracker.tracks.single.secondsToContact, isNull);
  });
}
