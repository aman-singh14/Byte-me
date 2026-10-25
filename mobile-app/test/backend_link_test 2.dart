// BackendLink and the backend JSON models, with a fake transport (no network),
// plus address discovery from a real UDP hello like glasses_link_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/net/backend_api.dart';
import 'package:omni_glasses/net/backend_link.dart';
import 'package:omni_glasses/net/backend_models.dart';
import 'package:omni_glasses/net/backend_rings.dart';
import 'package:omni_glasses/net/glasses_link.dart';

import 'backend_fakes.dart';
import 'social_test.dart' show FixedRings;

BackendLink makeLink(FakeTransport t, {String? saved}) => BackendLink(
  store: MemorySettingsStore(saved),
  apiFactory: (base) => BackendApi(base, transport: t),
  liveEvery: const Duration(hours: 1),
  slowEvery: const Duration(hours: 1),
);

void main() {
  group('models', () {
    test('eyes live', () {
      final e = EyesLive.fromJson(eyesLiveJson());
      expect(e.blinkRate, 7.4);
      expect(e.partialBlinks, 9);
      expect(e.lowBlink, isTrue);
      expect(e.nearworkObject, 'phone');
      expect(e.nearworkClose, isTrue);
      expect(e.sessionObject, 'phone');
      expect(e.eyeCameraOnline, isTrue);
      expect(e.headsUpSince, isNull);
    });

    test('missing and null fields never throw', () {
      final e = EyesLive.fromJson({'blink_rate': null, 'cameras': null});
      expect(e.blinkRate, isNull);
      expect(e.nearwork, isFalse);
      expect(e.eyeCameraOnline, isNull);
      expect(RingsDay.fromJson({}).headsUp.minutes, 0);
      expect(
        CloseupDay.fromJson({
          'sessions': [
            {'object': 'phone'},
          ],
        }).sessions,
        isEmpty,
      );
      expect(EyesHistory.fromJson({'points': 'nope'}).points, isEmpty);
    });

    test('rings and close-up', () {
      final r = RingsDay.fromJson(ringsTodayJson());
      expect(r.headsUp.minutes, 96.4);
      expect(r.headsUpBreaks, 7);
      expect(r.outside.active, isTrue);
      expect(r.points, 48);
      final c = CloseupDay.fromJson(closeupJson());
      expect(c.totalMinutes, 132.5);
      expect(c.byObject['laptop'], 98.0);
      expect(c.sessions.last.open, isTrue);
      final h = EyesHistory.fromJson(eyesHistoryJson());
      expect(h.points.length, 13);
      expect(h.squints.length, 2);
      expect(h.lowBlink.single.duration.inMinutes, 10);
    });
  });

  group('addresses', () {
    test('parseBackendUrl', () {
      expect(parseBackendUrl('172.20.10.2').toString(), 'http://172.20.10.2:8001');
      expect(parseBackendUrl(' 172.20.10.2:8765 ').toString(), 'http://172.20.10.2:8765');
      expect(parseBackendUrl('http://laptop.local').toString(), 'http://laptop.local:8001');
      expect(parseBackendUrl(''), isNull);
      expect(parseBackendUrl('ftp://x'), isNull);
    });
  });

  group('BackendLink', () {
    test('saved address: connects and fills everything', () async {
      final t = FakeTransport();
      final link = makeLink(t, saved: 'http://172.20.10.2:8000');
      await link.start();
      await link.refreshAll();
      expect(link.status, BackendStatus.connected);
      expect(link.baseUrl.toString(), 'http://172.20.10.2:8000');
      expect(link.eyes?.blinkRate, 7.4);
      expect(link.rings?.headsUpBreaks, 7);
      expect(link.closeup?.byObject.length, 3);
      expect(link.ringsHistory.length, 7);
      expect(t.requests, contains('GET /eyes/history?range=day'));
      link.dispose();
    });

    test('no address: not configured, no requests', () async {
      final t = FakeTransport();
      final link = makeLink(t);
      await link.start();
      expect(link.status, BackendStatus.notConfigured);
      expect(t.requests, isEmpty);
      link.dispose();
    });

    test('unreachable keeps the reason', () async {
      final t = FakeTransport(fail: const BackendException("Can't reach the backend (refused)."));
      final link = makeLink(t, saved: '172.20.10.2');
      await link.start();
      await link.refreshAll();
      expect(link.status, BackendStatus.unreachable);
      expect(link.lastError, contains("Can't reach"));
      t.fail = null;
      await link.refreshLive();
      expect(link.status, BackendStatus.connected);
      link.dispose();
    });

    test('typed address is validated and remembered', () async {
      final store = MemorySettingsStore();
      final link = BackendLink(
        store: store,
        apiFactory: (b) => BackendApi(b, transport: FakeTransport()),
      );
      expect(await link.setManualUrl('not a url ::'), isFalse);
      expect(await link.setManualUrl('172.20.10.5'), isTrue);
      expect(store.url, 'http://172.20.10.5:8001');
      expect(await link.setManualUrl(''), isTrue);
      expect(store.url, isNull);
      link.dispose();
    });

    test('calibration and dev toggle post to the backend', () async {
      final t = FakeTransport();
      final link = makeLink(t, saved: '172.20.10.2');
      await link.start();
      expect(await link.calibrateCloseup('laptop', 50), isNull);
      expect(t.bodies[t.requests.indexOf('POST /closeup/calibrate')], {'object': 'laptop', 'known_cm': 50.0});
      expect(await link.setOutside(true), isNull);
      t.fail = const BackendException('no laptop in view right now', statusCode: 409);
      expect(await link.calibrateCloseup('laptop', 50), 'no laptop in view right now');
      link.dispose();
    });

    test('BackendRings feeds the social features, with the stand-in as fallback', () async {
      final t = FakeTransport(fail: const BackendException('down'));
      final link = makeLink(t, saved: '172.20.10.2');
      final fallback = FixedRings()..set(12, 3);
      final rings = BackendRings(link, fallback);
      var notified = 0;
      rings.addListener(() => notified++);
      await link.start();
      await link.refreshAll();
      expect(rings.fromBackend, isFalse); // backend down: stand-in numbers
      expect(rings.today.headsUpMinutes, 12);
      t.fail = null;
      await link.refreshLive();
      expect(rings.fromBackend, isTrue); // backend up: real rings
      expect(rings.today.headsUpMinutes, 96);
      expect(rings.today.outsideMinutes, 41);
      expect(rings.today.headsUpGoal, 180);
      final before = notified;
      await link.refreshLive(); // same numbers: no extra notification
      expect(notified, before);
      rings.dispose();
      link.dispose();
    });

    test('look sends the question and side, and parses both answers', () async {
      final t = FakeTransport();
      final link = makeLink(t, saved: '172.20.10.2');
      await link.start();
      final r = await link.look(question: "what's on my left?", region: 'left');
      expect(t.bodies[t.requests.indexOf('POST /assist/look')], {
        'question': "what's on my left?",
        'region_override': 'left',
      });
      expect(r.region, 'left');
      expect(r.localAnswer, startsWith('Ahead: a laptop'));
      expect(r.museAnswer, contains('laptop'));
      expect(r.spoken, r.museAnswer);
      expect(r.objects, ['laptop', 'cup']);
      expect(LookResult.fromJson({'local_answer': 'A cup.', 'muse_error': 'no key'}).spoken, 'A cup.');
      link.dispose();
    });

    test('finds the laptop from the glasses link hello', () async {
      final glasses = GlassesLink(port: 0, heartbeatInterval: const Duration(seconds: 10));
      await glasses.start();
      final laptop = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final t = FakeTransport();
      final link = makeLink(t);
      await link.start(glasses: glasses);
      expect(link.status, BackendStatus.notConfigured);

      laptop.send(utf8.encode('{"t":"hello","id":"frame"}'), InternetAddress.loopbackIPv4, glasses.boundPort!);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(link.discoveredUrl.toString(), 'http://127.0.0.1:8001');
      expect(link.baseUrl, link.discoveredUrl);
      await link.refreshLive();
      expect(link.status, BackendStatus.connected);

      await link.setManualUrl('172.20.10.7'); // typed address wins
      expect(link.baseUrl.toString(), 'http://172.20.10.7:8001');
      link.dispose();
      glasses.dispose();
      laptop.close();
    });
  });
}
