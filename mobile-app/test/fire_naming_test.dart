// Naming reflex fires (Cam B, the FPGA) from Cam B's video.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/alerts/alert_engine.dart';
import 'package:omni_glasses/alerts/alert_service.dart';
import 'package:omni_glasses/net/glasses_link.dart';
import 'package:omni_glasses/net/protocol.dart';
import 'package:omni_glasses/screens/home_shell.dart';
import 'package:omni_glasses/vision/detector.dart';
import 'package:omni_glasses/vision/fire_namer.dart';
import 'package:omni_glasses/vision/rear_vision.dart';

import 'screens_test.dart' show FakeVoice, pumpApp;
import 'tracker_test.dart' show at;

Detection det(String label, double left, double width) =>
    Detection(label: label, confidence: 0.8, box: Rect.fromLTWH(left, 0.3, width, 0.4));

/// Names every fire [label] after the test calls [finish].
class FakeNamer implements FireNamer {
  FakeNamer(this.label);
  final String? label;
  final calls = <WearerSide>[];
  final _pending = <Completer<String?>>[];

  @override
  Future<String?> name(WearerSide side) {
    calls.add(side);
    final c = Completer<String?>();
    _pending.add(c);
    return c.future;
  }

  void finish() {
    for (final c in _pending) {
      c.complete(label);
    }
    _pending.clear();
  }
}

class _NoDetector implements ObjectDetector {
  @override
  Future<void> load() async {}
  @override
  Future<List<Detection>> detect(Uint8List jpeg) async => const [];
  @override
  void dispose() {}
}

void main() {
  group('pickFireObject', () {
    test('the biggest object on the fire side, or straight behind', () {
      // Image right (x > 0.65) is the wearer's left; the middle is behind.
      final ds = [det('person', 0.70, 0.10), det('car', 0.70, 0.25), det('bus', 0.05, 0.3)];
      expect(pickFireObject(ds, WearerSide.left), 'car');
      expect(pickFireObject(ds, WearerSide.right), 'bus');
      expect(pickFireObject([det('bicycle', 0.4, 0.2)], WearerSide.left), 'bicycle'); // straight behind
    });

    test('nothing on that side: no name', () {
      expect(pickFireObject([det('car', 0.05, 0.2)], WearerSide.left), isNull);
      expect(pickFireObject(const [], WearerSide.right), isNull);
    });
  });

  group('engine', () {
    test('a name from Cam B relabels the fire', () {
      final engine = AlertEngine();
      engine.addFire(at(0), WearerSide.left);
      expect(engine.fireIsNamed(WearerSide.left), isFalse);
      final events = engine.nameFire(at(0.1), WearerSide.left, 'car');
      expect(events.single, isA<AlertRaised>().having((e) => e.alert.label, 'label', 'car'));
      expect(engine.fireIsNamed(WearerSide.left), isTrue);
      // The name lasts as long as the fire.
      expect(engine.tick(at(1.7)).single, isA<AlertCleared>());
      expect(engine.fireIsNamed(WearerSide.left), isFalse);
    });

    test('a name that arrives after the fire is over is ignored', () {
      final engine = AlertEngine();
      engine.addFire(at(0), WearerSide.right);
      engine.tick(at(2));
      expect(engine.nameFire(at(2.1), WearerSide.right, 'car'), isEmpty);
    });
  });

  group('service', () {
    late GlassesLink link;
    late RearVision vision;
    setUp(() {
      link = GlassesLink(port: 0);
      vision = RearVision(link, _NoDetector());
    });
    tearDown(() {
      vision.dispose();
      link.dispose();
    });

    test('alerts at once, then names it, asking once for repeated fires', () async {
      final namer = FakeNamer('truck');
      final alerts = AlertService(link, vision, namer: namer);
      final events = <AlertEvent>[];
      alerts.events.listen(events.add);

      unawaited(alerts.onFire(WearerSide.left));
      unawaited(alerts.onFire(WearerSide.left)); // the reflex keeps firing
      await pumpEventQueue();
      expect(events.map((e) => (e as AlertRaised).alert.label), ['something']);
      expect(namer.calls, [WearerSide.left]);

      namer.finish();
      await pumpEventQueue();
      expect(events.map((e) => (e as AlertRaised).alert.label), ['something', 'truck']);
      expect(alerts.log.latest?.label, 'truck');
      alerts.dispose();
    });

    test('no name: the alert stays as it was', () async {
      final namer = FakeNamer(null);
      final alerts = AlertService(link, vision, namer: namer);
      unawaited(alerts.onFire(WearerSide.right));
      await pumpEventQueue();
      namer.finish();
      await pumpEventQueue();
      expect(alerts.current?.label, 'something');
      alerts.dispose();
    });
  });

  group('voice', () {
    testWidgets('speaks the name when Cam B names it quickly', (tester) async {
      final voice = FakeVoice();
      final namer = FakeNamer('car');
      final alerts = await pumpApp(tester, const HomeShell(), brightness: Brightness.light, voice: voice, namer: namer);
      unawaited(alerts.onFire(WearerSide.left));
      await tester.pump(const Duration(milliseconds: 100));
      namer.finish();
      await tester.pump(const Duration(milliseconds: 500));
      expect(voice.said, ['Car']);
    });

    testWidgets('says "Behind" when nothing names it', (tester) async {
      final voice = FakeVoice();
      final namer = FakeNamer(null);
      final alerts = await pumpApp(tester, const HomeShell(), brightness: Brightness.light, voice: voice, namer: namer);
      unawaited(alerts.onFire(WearerSide.left));
      await tester.pump(const Duration(milliseconds: 500));
      namer.finish();
      await tester.pump(const Duration(milliseconds: 100));
      expect(voice.said, ['Behind']);
    });
  });
}
