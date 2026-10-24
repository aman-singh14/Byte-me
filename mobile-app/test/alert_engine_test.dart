import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/alerts/alert_engine.dart';
import 'package:omni_glasses/alerts/tracker.dart';
import 'package:omni_glasses/net/protocol.dart';

import 'tracker_test.dart' show at, boxAt, walkerAt;

/// An event and when it happened, in seconds.
typedef Timed = (double, AlertEvent);

/// Plays one object behind the wearer at 10 frames and sensor samples per
/// second. [distance] in meters and [yawRate] in degrees per second, as
/// functions of time. [imageX] 0.75 is the wearer's left.
List<Timed> play(
  AlertEngine engine,
  String label, {
  required double from,
  required double to,
  required double Function(double t) distance,
  double imageX = 0.75,
  double aspect = 1.5,
  double Function(double t)? yawRate,
  double lux = 400,
  double confidence = 0.9,
}) {
  final events = <Timed>[];
  for (var t = from; t <= to + 1e-9; t += 0.1) {
    events.addAll([
      for (final e in engine.addSens(at(t), yawRate: yawRate?.call(t) ?? 0, lux: lux)) (t, e),
      for (final e in engine.addDetections(at(t), [
        Sighting(
          label: label,
          confidence: confidence,
          box: boxAt(distance(t), imageX: imageX, aspect: aspect),
        ),
      ]))
        (t, e),
    ]);
  }
  return events;
}

/// Sensor samples and ticks only (nothing in view).
List<Timed> wait(AlertEngine engine, {required double from, required double to, double yawRate = 0}) {
  final events = <Timed>[];
  for (var t = from; t <= to + 1e-9; t += 0.1) {
    events.addAll([for (final e in engine.addSens(at(t), yawRate: yawRate, lux: 400)) (t, e)]);
    events.addAll([for (final e in engine.tick(at(t))) (t, e)]);
  }
  return events;
}

List<AlertEvent> only(List<Timed> events) => [for (final (_, e) in events) e];

Matcher raised(AlertLevel level, WearerSide side, String label, [AlertSource source = AlertSource.camera]) =>
    isA<AlertRaised>().having((e) => (e.alert.level, e.alert.side, e.alert.label, e.alert.source), 'alert', (
      level,
      side,
      label,
      source,
    ));

Matcher cleared(ClearReason reason) => isA<AlertCleared>().having((e) => e.reason, 'reason', reason);

void main() {
  test('a car closing in goes gentle, then urgent', () {
    // 40 m away at 8 m/s: 5 s to contact at t = 0, 3 s at t = 2.
    final events = play(AlertEngine(), 'car', from: 0, to: 3, distance: (t) => 40 - 8 * t);
    expect(only(events), [
      raised(AlertLevel.gentle, WearerSide.left, 'car'),
      raised(AlertLevel.urgent, WearerSide.left, 'car'),
    ]);
    expect(events[0].$1, lessThan(1.0)); // 0.4 s of history + 0.3 s to confirm
    expect(events[1].$1, inInclusiveRange(1.8, 2.4));
  });

  test('sides are the wearer\'s', () {
    final events = play(AlertEngine(), 'bicycle', from: 0, to: 1, distance: (t) => 20 - 4 * t, imageX: 0.2);
    expect(only(events), [raised(AlertLevel.gentle, WearerSide.right, 'bicycle')]);
  });

  test('clears once the car stops coming', () {
    final engine = AlertEngine();
    play(engine, 'car', from: 0, to: 1, distance: (t) => 40 - 8 * t);
    expect(engine.current?.level, AlertLevel.gentle);
    final events = play(engine, 'car', from: 1.1, to: 5, distance: (t) => 32);
    expect(only(events), [cleared(ClearReason.gone)]);
    expect(events.single.$1, lessThan(3.5));
  });

  test('clears when the camera stops sending frames', () {
    final engine = AlertEngine();
    play(engine, 'car', from: 0, to: 1, distance: (t) => 40 - 8 * t);
    final events = wait(engine, from: 1.1, to: 3);
    expect(only(events), [cleared(ClearReason.gone)]);
    expect(events.single.$1, lessThan(2.3));
  });

  test('someone walking straight up gets a gentle alert, never urgent', () {
    // 7 m away at 1.4 m/s, down to 1 m (feet leave the picture at about 2 m).
    final events = play(
      AlertEngine(),
      'person',
      from: 0,
      to: 4.3,
      distance: (t) => 7 - 1.4 * t,
      imageX: 0.5,
      aspect: 0.4,
    );
    expect(only(events), [raised(AlertLevel.gentle, WearerSide.behind, 'person')]);
    expect(events.single.$1, lessThan(2.6)); // about 3.5 m away
  });

  test('someone walking past to one side does not alert', () {
    final events = play(
      AlertEngine(),
      'person',
      from: 0,
      to: 4.3,
      distance: (t) => 7 - 1.4 * t,
      imageX: 0.8,
      aspect: 0.4,
    );
    expect(events, isEmpty);
  });

  test('someone walking across the view never alerts', () {
    final engine = AlertEngine();
    final events = <AlertEvent>[];
    for (var t = 0.0; t <= 4; t += 0.1) {
      events.addAll(engine.addSens(at(t), yawRate: 0, lux: 400));
      events.addAll(engine.addDetections(at(t), [Sighting(label: 'person', confidence: 0.8, box: walkerAt(t))]));
    }
    expect(events, isEmpty);
  });

  test('someone sitting close and leaning in and out never alerts', () {
    // Fills the frame, bottom cut off: only width changes as they lean.
    final engine = AlertEngine();
    final events = <AlertEvent>[];
    for (var t = 0.0; t <= 10; t += 0.1) {
      final w = 0.55 * (1 + 0.2 * math.sin(t * 2.5));
      final box = Box(0.5 - w / 2, 0.15, 0.5 + w / 2, 1.0);
      events.addAll(engine.addDetections(at(t), [Sighting(label: 'person', confidence: 0.9, box: box)]));
    }
    expect(events, isEmpty);
  });

  test('one odd frame never alerts', () {
    // A steady car whose box jumps for a single frame.
    final engine = AlertEngine();
    final events = play(engine, 'car', from: 0, to: 3, distance: (t) => (t - 1.5).abs() < 0.05 ? 6 : 10);
    expect(events, isEmpty);
  });

  test('tiny far-away boxes never alert', () {
    final events = play(AlertEngine(), 'person', from: 0, to: 5, distance: (t) => 40 * (1 + 0.1 * math.sin(t * 9)));
    expect(events, isEmpty);
  });

  test('straight behind is its own side', () {
    final events = play(AlertEngine(), 'car', from: 0, to: 1.2, distance: (t) => 25 - 4 * t, imageX: 0.5);
    expect(only(events), [raised(AlertLevel.gentle, WearerSide.behind, 'car')]);
  });

  test('a glance either way silences something straight behind', () {
    for (final rate in [120.0, -120.0]) {
      final engine = AlertEngine();
      play(engine, 'car', from: 0, to: 1.2, distance: (t) => 25 - 4 * t, imageX: 0.5);
      final events = wait(engine, from: 1.3, to: 1.9, yawRate: rate);
      expect(only(events), [cleared(ClearReason.silenced)], reason: 'yaw $rate');
    }
  });

  test('a fire takes the label of what is straight behind', () {
    final engine = AlertEngine();
    play(engine, 'bus', from: 0, to: 0.3, distance: (t) => 12, imageX: 0.5);
    expect(engine.addFire(at(0.35), WearerSide.left), [
      raised(AlertLevel.urgent, WearerSide.left, 'bus', AlertSource.reflex),
    ]);
  });

  test('a parked car with jittery boxes never alerts', () {
    final events = play(AlertEngine(), 'car', from: 0, to: 10, distance: (t) => t * 37 % 1 < 0.5 ? 8 : 8.3);
    expect(events, isEmpty);
  });

  test('ignores low-confidence detections in daylight', () {
    final events = play(AlertEngine(), 'car', from: 0, to: 2, distance: (t) => 40 - 8 * t, confidence: 0.4);
    expect(events, isEmpty);
  });

  group('head turns', () {
    test('no camera alerts while the head is turning', () {
      final engine = AlertEngine();
      final turning = play(engine, 'car', from: 0, to: 1.5, distance: (t) => 30 - 4 * t, yawRate: (t) => -90);
      expect(turning, isEmpty);
      // The turn ends: alerts come back once there's fresh history.
      final after = play(engine, 'car', from: 1.6, to: 2.8, distance: (t) => 30 - 4 * t);
      expect(only(after), [raised(AlertLevel.gentle, WearerSide.left, 'car')]);
      expect(after.single.$1, lessThan(2.8));
    });

    test('glancing back toward the alert silences it until it gets worse', () {
      final engine = AlertEngine();
      // Gentle by t = 0.5; glance left (toward the car) at t = 1..1.5; urgent at t = 2.
      final events = play(
        engine,
        'car',
        from: 0,
        to: 3,
        distance: (t) => 40 - 8 * t,
        yawRate: (t) => t >= 1 && t < 1.5 ? 120 : 0,
      );
      expect(only(events), [
        raised(AlertLevel.gentle, WearerSide.left, 'car'),
        cleared(ClearReason.silenced),
        raised(AlertLevel.urgent, WearerSide.left, 'car'),
      ]);
      expect(events[1].$1, inInclusiveRange(1.3, 1.5));
    });

    test('dismissing in the app works like a glance', () {
      final engine = AlertEngine();
      play(engine, 'car', from: 0, to: 1, distance: (t) => 40 - 8 * t);
      expect(engine.dismiss(at(1.05)), [cleared(ClearReason.dismissed)]);
      final events = play(engine, 'car', from: 1.1, to: 3, distance: (t) => 40 - 8 * t);
      expect(only(events), [raised(AlertLevel.urgent, WearerSide.left, 'car')]);
      expect(engine.dismiss(at(3.1)), [cleared(ClearReason.dismissed)]);
      expect(engine.dismiss(at(3.2)), isEmpty);
    });

    test('turning the other way does not silence it', () {
      final events = play(
        AlertEngine(),
        'car',
        from: 0,
        to: 1.5,
        distance: (t) => 40 - 8 * t,
        yawRate: (t) => t >= 0.8 && t < 1.3 ? -120 : 0,
      );
      expect(only(events), [raised(AlertLevel.gentle, WearerSide.left, 'car')]);
    });
  });

  group('reflex fires', () {
    test('a fire is urgent at once and ends on its own', () {
      final engine = AlertEngine();
      expect(engine.addFire(at(0), WearerSide.right), [
        raised(AlertLevel.urgent, WearerSide.right, 'something', AlertSource.reflex),
      ]);
      expect(engine.tick(at(1)), isEmpty);
      expect(engine.tick(at(1.6)), [cleared(ClearReason.gone)]);
    });

    test('a fire takes its label from what the camera sees on that side', () {
      final engine = AlertEngine();
      play(engine, 'bicycle', from: 0, to: 0.3, distance: (t) => 10, imageX: 0.2);
      expect(engine.addFire(at(0.35), WearerSide.right), [
        raised(AlertLevel.urgent, WearerSide.right, 'bicycle', AlertSource.reflex),
      ]);
    });

    test('a fire beats a gentle camera alert, which comes back after', () {
      final engine = AlertEngine();
      play(engine, 'car', from: 0, to: 1, distance: (t) => 25 - 4 * t, imageX: 0.2);
      expect(engine.current?.side, WearerSide.right);
      expect(engine.addFire(at(1.05), WearerSide.left), [
        raised(AlertLevel.urgent, WearerSide.left, 'something', AlertSource.reflex),
      ]);
      final after = play(engine, 'car', from: 1.1, to: 2.8, distance: (t) => 25 - 4 * t, imageX: 0.2);
      expect(only(after).first, raised(AlertLevel.gentle, WearerSide.right, 'car'));
    });

    test('glancing at a fire silences that side for a few seconds', () {
      final engine = AlertEngine();
      engine.addFire(at(0), WearerSide.left);
      final events = wait(engine, from: 0, to: 0.6, yawRate: 120);
      expect(only(events), [cleared(ClearReason.silenced)]);
      expect(engine.addFire(at(1), WearerSide.left), isEmpty);
      expect(engine.addFire(at(4), WearerSide.left), [
        raised(AlertLevel.urgent, WearerSide.left, 'something', AlertSource.reflex),
      ]);
    });
  });

  group('modes', () {
    test('high sensitivity warns earlier, low later', () {
      // 7 s to contact: beyond the 6 s normal threshold for cars.
      AlertLevel? levelAt(Sensitivity s) => AlertEngine(settings: AlertSettings(sensitivity: s)).levelFor('car', 7);
      expect(levelAt(Sensitivity.normal), isNull);
      expect(levelAt(Sensitivity.high), AlertLevel.gentle);
      expect(AlertEngine(settings: const AlertSettings(sensitivity: Sensitivity.low)).levelFor('car', 4.5), isNull);

      final events = play(
        AlertEngine(settings: const AlertSettings(sensitivity: Sensitivity.high)),
        'car',
        from: 0,
        to: 1.2,
        distance: (t) => 21 - 3 * t, // 7 s to contact at t = 0
      );
      expect(only(events), [raised(AlertLevel.gentle, WearerSide.left, 'car')]);
    });

    test('night mode follows the light sensor and warns earlier', () {
      final engine = AlertEngine();
      expect(engine.isNight, isFalse);
      for (var t = 0.0; t < 2; t += 0.1) {
        engine.addSens(at(t), yawRate: 0, lux: 5);
      }
      expect(engine.isNight, isTrue);
      expect(engine.levelFor('car', 7), AlertLevel.gentle);

      engine.settings = engine.settings.copyWith(nightMode: NightMode.off);
      expect(engine.isNight, isFalse);
      expect(engine.levelFor('car', 7), isNull);

      for (var t = 2.0; t < 4; t += 0.1) {
        engine.addSens(at(t), yawRate: 0, lux: 400);
      }
      engine.settings = engine.settings.copyWith(nightMode: NightMode.auto);
      expect(engine.isNight, isFalse);
    });

    test('night mode accepts less certain detections', () {
      final engine = AlertEngine(settings: const AlertSettings(nightMode: NightMode.on));
      final events = play(engine, 'car', from: 0, to: 1, distance: (t) => 40 - 8 * t, confidence: 0.4, lux: 5);
      expect(only(events), [raised(AlertLevel.gentle, WearerSide.left, 'car')]);
    });
  });

  group('possibly following', () {
    List<Timed> stayBehind(AlertEngine engine, {required double from, required double to}) {
      final events = <Timed>[];
      for (var t = from; t <= to + 1e-9; t += 0.5) {
        final s = Sighting(label: 'person', confidence: 0.8, box: boxAt(5, imageX: 0.3));
        events.addAll([
          for (final e in engine.addDetections(at(t), [s])) (t, e),
        ]);
      }
      return events;
    }

    test('someone behind for 3 minutes is reported once, despite short gaps', () {
      final engine = AlertEngine();
      final events = [
        ...stayBehind(engine, from: 0, to: 60),
        ...wait(engine, from: 60.1, to: 65), // lost for 5 s
        ...stayBehind(engine, from: 65, to: 240),
      ];
      expect(only(events), [isA<PossiblyFollowing>().having((e) => e.side, 'side', WearerSide.right)]);
      expect(events.single.$1, closeTo(180, 0.5));
    });

    test('a new presence after a long gap starts over', () {
      final engine = AlertEngine();
      stayBehind(engine, from: 0, to: 120);
      wait(engine, from: 120.1, to: 140);
      expect(stayBehind(engine, from: 140, to: 250), isEmpty);
    });

    test('vehicles are never "following"', () {
      final engine = AlertEngine(settings: const AlertSettings(followAfter: Duration(seconds: 10)));
      final events = play(engine, 'car', from: 0, to: 20, distance: (t) => 8);
      expect(events, isEmpty);
    });
  });
}
