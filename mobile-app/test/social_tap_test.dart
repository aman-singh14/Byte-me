// Social taps: when someone counts as stopped close by, the Muse check and
// its fallbacks, cooldowns, and the "look up" nudge.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/alerts/alert_log.dart';
import 'package:omni_glasses/alerts/alert_service.dart';
import 'package:omni_glasses/alerts/social_tap.dart';
import 'package:omni_glasses/alerts/social_taps.dart';
import 'package:omni_glasses/alerts/tracker.dart';
import 'package:omni_glasses/assist/vlm.dart';
import 'package:omni_glasses/net/glasses_link.dart';
import 'package:omni_glasses/net/protocol.dart';
import 'package:omni_glasses/settings/feature_flags.dart';
import 'package:omni_glasses/vision/detector.dart';
import 'package:omni_glasses/vision/rear_vision.dart';

class RecordingLink extends GlassesLink {
  RecordingLink() : super(port: 0);
  final sent = <Map<String, Object>>[];
  @override
  void send(GlassesCommand cmd) => sent.add(cmd.toJson());
}

class _NoDetector implements ObjectDetector {
  @override
  Future<void> load() async {}
  @override
  Future<List<Detection>> detect(Uint8List jpeg) async => const [];
  @override
  void dispose() {}
}

final t0 = DateTime(2026, 10, 24, 12);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

/// A person box centered at [x] (image coordinates) with [height] of the
/// image, bottom cut off once it's close.
Sighting person(double x, double height) {
  final width = height * 0.32;
  final top = 1.0 - height;
  return Sighting(label: 'person', confidence: 0.9, box: Box(x - width / 2, top < 0 ? 0 : top, x + width / 2, 1));
}

/// Feeds a walk-up at a steady pace from 4 m to 1 m over [approachMs] (a box's
/// height goes as 1 / distance: 25% of the image at 4 m, 98% at 1 m), then
/// [stayMs] standing still.
List<SocialCandidate> walkUp(
  Tracker tracker,
  SocialTapDetector detector, {
  double x = 0.5,
  int startMs = 0,
  int approachMs = 2000,
  int stayMs = 1500,
  bool busy = false,
}) {
  final out = <SocialCandidate>[];
  for (var ms = 0; ms <= approachMs + stayMs; ms += 100) {
    final metres = ms >= approachMs ? 1.0 : 4 - 3 * ms / approachMs;
    final when = at(startMs + ms);
    tracker.update(when, [person(x, 0.98 / metres)]);
    out.addAll(detector.update(when, tracker.tracks, busy: busy));
  }
  return out;
}

void main() {
  group('SocialTapDetector', () {
    test('someone who walks up and stays a second gets one tap, on the right side', () {
      final tracker = Tracker(), detector = SocialTapDetector();
      // Image right is the wearer's LEFT (the rear camera faces backward).
      final taps = walkUp(tracker, detector, x: 0.8);
      expect(taps, hasLength(1));
      expect(taps.single.side, WearerSide.left);
      expect(walkUp(Tracker(), SocialTapDetector(), x: 0.5).single.side, WearerSide.behind);
    });

    test('not before a full second of standing still', () {
      expect(walkUp(Tracker(), SocialTapDetector(), stayMs: 800), isEmpty);
    });

    test('nobody already standing there, nobody far away, nothing during an alert', () {
      final tracker = Tracker(), detector = SocialTapDetector();
      for (var ms = 0; ms <= 3000; ms += 100) {
        tracker.update(at(ms), [person(0.5, 0.98)]); // was close from the start: no approach
        expect(detector.update(at(ms), tracker.tracks), isEmpty);
      }
      final far = Tracker(), farDetector = SocialTapDetector();
      for (var ms = 0; ms <= 3000; ms += 100) {
        far.update(at(ms), [person(0.5, 0.2 + 0.4 * (ms / 3000))]); // came closer, still ~3 m away
        expect(farDetector.update(at(ms), far.tracks), isEmpty);
      }
      expect(walkUp(Tracker(), SocialTapDetector(), busy: true), isEmpty);
    });

    test('one tap per person a minute', () {
      final tracker = Tracker(), detector = SocialTapDetector();
      expect(walkUp(tracker, detector), hasLength(1));
      // Same presence keeps standing there for 50 s: no second tap.
      for (var ms = 3600; ms <= 53600; ms += 100) {
        tracker.update(at(ms), [person(0.5, 0.98)]);
        expect(detector.update(at(ms), tracker.tracks), isEmpty);
      }
      // Over a minute later they're still there and still steady: tapped again.
      final later = <SocialCandidate>[];
      for (var ms = 53700; ms <= 66000; ms += 100) {
        tracker.update(at(ms), [person(0.5, 0.98)]);
        later.addAll(detector.update(at(ms), tracker.tracks));
      }
      expect(later, hasLength(1));
    });
  });

  group('SocialTapService', () {
    late RecordingLink link;
    late RearVision vision;
    late AlertService alerts;
    late StreamController<SensMessage> sens;
    late FeatureFlags flags;
    late Map<String, dynamic> Function() answer;
    late Completer<void>? hang;
    late int vlmCalls, lookedUp;
    late DateTime now;
    late SocialTapService taps;

    setUp(() {
      link = RecordingLink();
      vision = RearVision(link, _NoDetector());
      alerts = AlertService(link, vision);
      sens = StreamController<SensMessage>.broadcast(sync: true);
      flags = FeatureFlags();
      answer = () => {'engaging': true, 'action': 'waving'};
      hang = null;
      vlmCalls = lookedUp = 0;
      now = t0;
      final vlm = VlmService(
        flags: flags,
        minInterval: Duration.zero,
        call: (feature, {images = const [], useFront = false, timeout}) async {
          vlmCalls++;
          expect((feature, images.single.$1), ('social_confirm', 'rear'));
          if (hang != null) await hang!.future;
          return answer();
        },
      );
      taps = SocialTapService(
        alerts: alerts,
        rearSnapshot: () => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
        vlm: vlm,
        flags: flags,
        sens: sens.stream,
        onLookedUp: () => lookedUp++,
        clock: () => now,
      );
    });

    tearDown(() {
      taps.dispose();
      alerts.dispose();
      vision.dispose();
      link.dispose();
      sens.close();
    });

    test('Muse says they want attention: tap on that side, card, log, with the action', () async {
      await taps.confirmAndTap(WearerSide.left);
      expect(link.sent, [
        {'t': 'tap', 'side': 'L', 'kind': 'social'},
      ]);
      expect(alerts.socialTap?.action, 'waving');
      final logged = alerts.log.latest!;
      expect((logged.kind, logged.side, logged.label), (LogKind.social, WearerSide.left, 'waving'));
    });

    test("Muse says they're not engaging: no tap", () async {
      answer = () => {'engaging': false, 'action': 'walking past'};
      await taps.confirmAndTap(WearerSide.right);
      expect(link.sent, isEmpty);
      expect(alerts.socialTap, isNull);
    });

    testWidgets('Muse too slow or unreachable: tap anyway', (tester) async {
      hang = Completer<void>();
      final done = taps.confirmAndTap(WearerSide.behind);
      await tester.pump(const Duration(seconds: 5)); // past the 4 s timeout
      await done;
      expect(link.sent.single, {'t': 'tap', 'side': 'B', 'kind': 'social'});
      expect(alerts.socialTap?.action, isNull);
    });

    test('with the check switched off, no snapshot leaves the phone', () async {
      flags.set(Feature.socialTapCheck, false);
      await taps.confirmAndTap(WearerSide.left);
      expect(vlmCalls, 0);
      expect(link.sent, hasLength(1));
    });

    test('a safety alert wins: no tap while one is up', () async {
      alerts.handle(
        alerts.engine.addFire(DateTime.now(), WearerSide.left), // reflex fire: urgent alert
      );
      link.sent.clear();
      await taps.confirmAndTap(WearerSide.left);
      expect(link.sent.where((m) => m['t'] == 'tap'), isEmpty);
    });

    test('during close-up work: a "look up" tap, and turning toward it counts', () async {
      for (var s = 0; s <= 11; s++) {
        now = t0.add(Duration(seconds: s));
        sens.add(const SensMessage(distCm: 30, blink: false, yawRate: 0, lux: 400));
      }
      expect(taps.closeUp, isTrue);
      await taps.confirmAndTap(WearerSide.left);
      expect(link.sent.single, {'t': 'tap', 'side': 'L', 'kind': 'lookup'});
      expect(alerts.socialTap?.lookUp, isTrue);
      // Head turns left at 100 deg/s for 0.6 s: 60 degrees toward the tap.
      for (var i = 1; i <= 6; i++) {
        now = now.add(const Duration(milliseconds: 100));
        sens.add(const SensMessage(distCm: 200, blink: false, yawRate: 100, lux: 400));
      }
      expect(lookedUp, 1);
    });

    test('turning the other way, or too late, does not count', () async {
      for (var s = 0; s <= 11; s++) {
        now = t0.add(Duration(seconds: s));
        sens.add(const SensMessage(distCm: 30, blink: false, yawRate: 0, lux: 400));
      }
      await taps.confirmAndTap(WearerSide.left);
      for (var i = 1; i <= 6; i++) {
        now = now.add(const Duration(milliseconds: 100));
        sens.add(const SensMessage(distCm: 200, blink: false, yawRate: -100, lux: 400)); // toward the right
      }
      now = now.add(const Duration(seconds: 11));
      for (var i = 1; i <= 6; i++) {
        now = now.add(const Duration(milliseconds: 100));
        sens.add(const SensMessage(distCm: 200, blink: false, yawRate: 100, lux: 400));
      }
      expect(lookedUp, 0);
    });

    test('the "look up" nudge can be switched off', () async {
      flags.set(Feature.lookUpNudge, false);
      for (var s = 0; s <= 11; s++) {
        now = t0.add(Duration(seconds: s));
        sens.add(const SensMessage(distCm: 30, blink: false, yawRate: 0, lux: 400));
      }
      await taps.confirmAndTap(WearerSide.left);
      expect(link.sent.single['kind'], 'social');
    });
  });
}
