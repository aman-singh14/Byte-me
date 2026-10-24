import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/alerts/alert_engine.dart';
import 'package:omni_glasses/alerts/alert_log.dart';
import 'package:omni_glasses/net/protocol.dart';

import 'tracker_test.dart' show at;

Alert camera(WearerSide side, AlertLevel level, String label, int track, double seconds) => Alert(
  side: side,
  level: level,
  label: label,
  source: AlertSource.camera,
  secondsToContact: seconds,
  trackId: track,
);

Alert reflex(WearerSide side) =>
    Alert(side: side, level: AlertLevel.urgent, label: 'something', source: AlertSource.reflex);

void main() {
  test('one entry per alert, at its highest level and closest approach', () {
    final log = AlertLog();
    final gentle = camera(WearerSide.left, AlertLevel.gentle, 'car', 1, 5.2);
    log.record(at(0), AlertRaised(gentle));
    log.record(at(1), AlertRaised(camera(WearerSide.left, AlertLevel.urgent, 'car', 1, 2.4)));
    log.record(at(2), AlertCleared(gentle, ClearReason.silenced));

    final e = log.entries.single;
    expect(e.label, 'car');
    expect(e.level, AlertLevel.urgent);
    expect(e.nearMiss, isTrue);
    expect(e.closestSeconds, 2.4);
    expect(e.ended, ClearReason.silenced);
    expect(e.at, at(0));
  });

  test('a reflex fire on the same side joins the camera alert', () {
    final log = AlertLog();
    log.record(at(0), AlertRaised(camera(WearerSide.right, AlertLevel.gentle, 'bicycle', 4, 4)));
    log.record(at(1), AlertRaised(reflex(WearerSide.right)));
    final e = log.entries.single;
    expect((e.label, e.level, e.reflex), ('bicycle', AlertLevel.urgent, true));
  });

  test('a different object starts a new entry, newest first', () {
    final log = AlertLog();
    log.record(at(0), AlertRaised(camera(WearerSide.left, AlertLevel.gentle, 'car', 1, 5)));
    log.record(at(1), AlertRaised(camera(WearerSide.right, AlertLevel.urgent, 'bicycle', 2, 2)));
    log.record(at(2), AlertRaised(reflex(WearerSide.left)));
    expect(log.entries.map((e) => e.label), ['something', 'bicycle', 'car']);
  });

  test('records "possibly following" notices', () {
    final log = AlertLog();
    log.record(at(0), const PossiblyFollowing(WearerSide.left, Duration(minutes: 3)));
    final e = log.latest!;
    expect((e.kind, e.side, e.behindFor), (LogKind.following, WearerSide.left, const Duration(minutes: 3)));
    expect(e.nearMiss, isFalse);
  });

  test('keeps 7 days and at most maxEntries', () {
    final log = AlertLog(maxEntries: 3);
    for (var i = 0; i < 5; i++) {
      log.record(at(i * 10.0), AlertRaised(reflex(i.isEven ? WearerSide.left : WearerSide.right)));
    }
    expect(log.entries.length, 3);

    final week = AlertLog();
    week.record(at(0), AlertRaised(reflex(WearerSide.left)));
    week.record(at(8 * 24 * 3600), AlertRaised(reflex(WearerSide.right)));
    expect(week.entries.single.side, WearerSide.right);
  });

  test('saves and loads, skipping damaged entries', () {
    final log = AlertLog();
    log.record(at(0), AlertRaised(camera(WearerSide.left, AlertLevel.urgent, 'car', 1, 1.9)));
    log.record(at(1), AlertCleared(reflex(WearerSide.left), ClearReason.dismissed));
    log.record(at(5), const PossiblyFollowing(WearerSide.right, Duration(minutes: 4)));

    final saved = jsonDecode(
      jsonEncode([
        ...log.toJson(),
        'junk',
        {'kind': 'alert'},
      ]),
    );
    final loaded = AlertLog()..load(saved, at(10));
    expect(loaded.entries.length, 2);
    final car = loaded.entries.last;
    expect(
      (car.label, car.level, car.closestSeconds, car.ended),
      ('car', AlertLevel.urgent, 1.9, ClearReason.dismissed),
    );
    expect(loaded.latest!.behindFor, const Duration(minutes: 4));
  });
}
