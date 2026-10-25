// Eye tracking, near-work, outside time and the rings on the phone
// (lib/eyes/): the same behaviour the laptop's tests check
// (backend/tests/test_closeup_eye.py, test_frontwork.py, ...), then the
// whole thing over real UDP from a fake eye camera to what BackendLink shows.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:omni_glasses/eyes/blinks.dart';
import 'package:omni_glasses/eyes/eye_history.dart';
import 'package:omni_glasses/eyes/gaze.dart';
import 'package:omni_glasses/eyes/nearwork.dart';
import 'package:omni_glasses/eyes/outdoor.dart';
import 'package:omni_glasses/eyes/phone_eyes.dart';
import 'package:omni_glasses/eyes/pupil.dart';
import 'package:omni_glasses/net/backend_link.dart';
import 'package:omni_glasses/net/glasses_link.dart';
import 'package:omni_glasses/net/protocol.dart';
import 'package:omni_glasses/vision/detector.dart';

const fps = 15.0;

/// Feeds openness values one frame apart; returns every event.
List<EyeEvent> feed(BlinkSquintDetector d, List<double?> values, {double start = 0}) => [
  for (final (i, v) in values.indexed) ...d.update(v, start + i / fps),
];

Detection det(String label, double w, double h) =>
    Detection(label: label, confidence: 0.9, box: Rect.fromLTWH(0.1, 0.1, w, h));

class NoDetector implements ObjectDetector {
  @override
  Future<void> load() async {}
  @override
  Future<List<Detection>> detect(Uint8List jpeg) async => const [];
  @override
  void dispose() {}
}

/// A frame of the eye fixtures (make_eye_fixtures.py) as the eye camera's JPEG.
Uint8List fixtureJpeg(String name) {
  final expected = jsonDecode(File('test/fixtures/eye/expected.json').readAsStringSync()) as Map<String, dynamic>;
  final raw = gzip.decode(File('test/fixtures/eye/frames.gray.gz').readAsBytesSync());
  final i = [for (final r in expected['frames'] as List) (r as Map)['name'] as String].indexOf(name);
  final im = img.Image.fromBytes(
    width: 320,
    height: 240,
    numChannels: 1,
    bytes: Uint8List.fromList(raw.sublist(i * 76800, (i + 1) * 76800)).buffer,
  );
  return img.encodeJpg(im, quality: 90);
}

void main() {
  group('Blinks and squints', () {
    BlinkSquintDetector calibrated() {
      final d = BlinkSquintDetector();
      feed(d, List.filled((6 * fps).round(), 1.0));
      expect(d.calibrated, isTrue);
      return d;
    }

    test('2 to 6 closed frames are a blink; 1, or 8, are not', () {
      for (final (closed, blink) in [(1, false), (2, true), (6, true), (8, false)]) {
        final d = calibrated();
        final events = feed(d, [...List.filled(closed, 0.0), 1.0], start: 10);
        expect(events.whereType<Blink>().length, blink ? 1 : 0, reason: '$closed frames');
      }
    });

    test('a lid held low for 1.5 s is a squint, and a blink inside it does not end it', () {
      final d = calibrated();
      final events = feed(d, [...List.filled(30, 0.75), 0.0, 0.0, ...List.filled(10, 0.75), 1.0], start: 10);
      expect(events.whereType<SquintStart>().length, 1);
      expect(events.whereType<SquintEnd>().length, 1);
      expect(events.whereType<Blink>().length, 1);
    });

    test('a dip that never closes is a partial blink', () {
      final d = calibrated();
      final events = feed(d, [0.75, 0.75, 1.0], start: 10);
      expect(events.whereType<PartialBlink>().length, 1);
    });

    test('the eye out of view is not a closure, and glasses back on is no fake blink', () {
      final t = EyeTracker();
      final events = <EyeEvent>[];
      for (var i = 0; i < 60; i++) {
        events.addAll(t.process(const EyeFeatures(1.0, (0, 0)), i / fps));
      }
      for (var i = 60; i < 120; i++) {
        events.addAll(t.process(const EyeFeatures(0), i / fps)); // no pupil for 4 s
      }
      expect(t.state.eyeDetected, isFalse);
      for (var i = 120; i < 140; i++) {
        events.addAll(t.process(const EyeFeatures(1.0, (0, 0)), i / fps));
      }
      expect(events.whereType<Blink>(), isEmpty);
    });

    test('low blinking for 5 minutes is flagged, and ends when it picks up', () {
      final m = LowBlinkMonitor();
      expect(m.update(0, 6, true), isNull);
      m.update(299, 6, true);
      expect(m.active, isFalse);
      m.update(301, 6, true);
      expect(m.active, isTrue);
      expect(m.update(400, 14, true), (0, 400));
    });
  });

  group('Gaze', () {
    test('calibrates from three looks, says the prompts and keeps the result', () {
      final said = <String>[];
      Map<String, dynamic>? saved;
      final g = GazeTracker(say: said.add, onSaved: (m) => saved = m)..startCalibration();
      var t = 0.0;
      for (final x in [-0.4, 0.0, 0.4]) {
        for (var i = 0; i < 50; i++, t += 0.07) {
          g.update([x + (i % 3) * 0.01, 0.0], t);
        }
      }
      g.update([0, 0], t);
      expect(said, ['Look left', 'Look straight ahead', 'Look right', 'Gaze calibrated']);
      expect(g.calibrated, isTrue);
      expect(g.centroids['left']![0], closeTo(-0.39, 0.02));
      expect(GazeTracker(saved: saved).centroids['right']![0], closeTo(0.41, 0.02));
    });

    test('classifies with hysteresis and a majority over half a second', () {
      final g = GazeTracker();
      expect(g.update([-0.3, 0], 0), 'left');
      expect(g.classify([-0.1, 0]), 'left'); // nearer center, but not clearly: stays
      for (var i = 1; i < 10; i++) {
        g.update([0.3, 0], i * 0.1);
      }
      expect(g.smoothed, 'right');
    });
  });

  group('Near-work', () {
    test('distance from the apparent size, too close per object, and calibration', () {
      final n = NearWorkEstimator();
      final phone = n.measure([det('cell phone', 0.5, 0.3), det('person', 0.5, 0.5)]).single;
      expect(phone.kind, 'phone');
      expect(phone.distanceCm, closeTo(23.6, 0.3)); // 0.5 / tan(32.5 deg) x 15 cm / 0.5
      expect(phone.close, isTrue);
      n.calibrate('phone', 40);
      expect(n.measure([det('cell phone', 0.5, 0.3)]).single.distanceCm, closeTo(40, 0.01));
      expect(() => n.calibrate('laptop', 50), throwsStateError);
    });

    test('close-up sessions: glances are dropped, short gaps bridged, another object splits', () {
      final c = CloseupTracker();
      final phone = NearObject('cell phone', 20, 0.5), laptop = NearObject('laptop', 30, 0.5);
      for (var t = 0.0; t < 5; t++) {
        c.update(t, phone);
      }
      expect(c.update(20, null).$1, isEmpty); // a 4 s glance
      final done = <CloseupSessionRecord>[];
      for (var t = 30.0; t <= 50; t++) {
        if (t == 40 || t == 41) continue; // two missed detections
        done.addAll(c.update(t, phone).$1);
      }
      for (var t = 51.0; t <= 70; t++) {
        done.addAll(c.update(t, laptop).$1);
      }
      expect(done.single.object, 'phone');
      expect((done.single.start, done.single.end), (30, 51));
      expect(c.open, (51, 'laptop'));
    });

    test('heads-up counts from the last near-work once it lasts 20 s, while worn', () {
      final h = HeadsUpTracker();
      h.update(0, true, true);
      h.update(10, false, true);
      expect(h.activeSince, isNull);
      h.update(21, false, true);
      expect(h.activeSince, 0);
      expect(h.update(30, false, false), (0, 30)); // glasses off
    });
  });

  group('Outside', () {
    test('needs a minute of bright exposure-normalised light, and the sensor', () {
      final o = OutdoorDetector();
      expect(o.update(0, luma: 120, exposureLines: null, gain: null), isNull);
      expect(o.update(1, luma: 120, exposureLines: 20, gain: 1), isNull); // log10(6) = 0.78: bright
      expect(o.update(61, luma: 120, exposureLines: 20, gain: 1), ('start', 1.0));
      expect(o.update(70, luma: 120, exposureLines: 1000, gain: 4), isNull);
      expect(o.update(131, luma: 120, exposureLines: 1000, gain: 4), ('end', (1.0, 70.0)));
    });

    test("reads the board's /sensor, including the raw gain register", () {
      expect(gainFromOv2640(0x00), 1.0);
      expect(gainFromOv2640(0x18), 2 * 1.5);
      expect(parseSensor({'aec_lines': 600, 'gain_reg': 0x30}), (600.0, 4.0));
    });
  });

  group('History and rings', () {
    test('rings, breaks and points from the stretches, and they survive a restart', () {
      final now = dayStart(DateTime(2026, 10, 25, 18).millisecondsSinceEpoch / 1000) + 18 * 3600;
      final h = EyeHistory()
        ..stretchEnded('heads_up', now - 7200, now - 7200 + 600) // 10 min: +5
        ..stretchEnded('outside', now - 3600, now - 3600 + 1500) // 25 min: +5
        ..stretchStarted('heads_up', now - 300);
      final day = h.today(now);
      expect(day.headsUp.minutes, 15);
      expect(day.headsUp.active, isTrue);
      expect(day.headsUpBreaks, 2);
      expect(day.outside.minutes, 25);
      expect(day.points, 10);
      final again = EyeHistory(saved: jsonDecode(jsonEncode(h.toJson())) as Map<String, dynamic>);
      expect(again.today(now).outside.minutes, 25);
      expect(again.history(now).length, 7);
    });

    test('filling a ring gives its bonus once', () {
      final now = dayStart(DateTime(2026, 10, 25).millisecondsSinceEpoch / 1000) + 20 * 3600;
      final h = EyeHistory()..stretchEnded('outside', now - 7300, now - 100);
      h.checkGoals(now);
      expect(h.today(now).points, 24 + 20);
    });
  });

  test('the eye worker isolate finds the pupil in a JPEG from the eye camera', () async {
    final raw = gzip.decode(File('test/fixtures/eye/frames.gray.gz').readAsBytesSync());
    final im = img.Image.fromBytes(
      width: 320,
      height: 240,
      numChannels: 1,
      bytes: Uint8List.fromList(raw.sublist(0, 76800)).buffer,
    );
    final worker = EyeWorker();
    final f = await worker(img.encodeJpg(im, quality: 90));
    expect(f!.openness, closeTo(1, 0.05));
    expect(f.pupil!.$1, closeTo(0, 0.02));
    expect(f.vector, hasLength(8));
    expect(await worker(Uint8List.fromList([1, 2, 3])), isNull);
    worker.dispose();
  });

  group('On the phone, over UDP', () {
    late GlassesLink link;
    late RawDatagramSocket board;
    late PhoneEyes eyes;
    final sent = <(InternetAddress, int)>[];
    double? frozen; // the engine's clock, when a test sets it; real time otherwise

    setUp(() async {
      link = GlassesLink(port: 0);
      await link.start();
      board = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      sent.clear();
      board.listen((e) {
        final d = e == RawSocketEvent.read ? board.receive() : null;
        if (d != null && utf8.decode(d.data, allowMalformed: true) == videoWant) sent.add((d.address, d.port));
      });
      final pupil = CloseupEye();
      eyes = PhoneEyes(
        link,
        frontDetector: NoDetector(),
        extractor: (jpeg) async {
          final g = decodeGrey(jpeg);
          return g == null ? null : pupil.extract(g);
        },
        persist: false,
        clock: () => frozen ?? DateTime.now().millisecondsSinceEpoch / 1000,
      );
      frozen = null;
      await eyes.start();
    });

    tearDown(() {
      eyes.dispose();
      board.close();
      link.dispose();
    });

    test('a fake eye camera blinks, and BackendLink shows it as if it were the laptop', () async {
      final open = fixtureJpeg('settle 0'), closed = fixtureJpeg('open 0.0');
      board.send(
        utf8.encode('{"t":"cam_hello","role":"eye","ip":"x","stream":"udp","stream_port":${board.port},"http_port":1}'),
        InternetAddress.loopbackIPv4,
        link.boundHelloPort!,
      );
      while (sent.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final (to, port) = sent.first;
      var id = 0;
      Future<void> show(Uint8List frame, int frames) async {
        final n = (frame.length + 1399) ~/ 1400;
        for (var i = 0; i < frames; i++) {
          id++;
          for (var c = 0; c < n; c++) {
            final part = frame.sublist(c * 1400, ((c + 1) * 1400).clamp(0, frame.length));
            board.send(chunkDatagram(eyeFrontMagic, id, c, n, frame, part), to, port);
          }
          await Future<void>.delayed(const Duration(milliseconds: 40)); // 25 fps
        }
      }

      await show(open, 20);
      await show(closed, 4); // ~160 ms with the lid down
      await show(open, 10);
      expect(eyes.eye.state.blinksTotal, 1);

      final backend = BackendLink(store: MemorySettingsStore(), phone: eyes);
      await backend.start();
      await backend.refreshAll();
      expect(backend.onPhone, isTrue);
      expect(backend.status, BackendStatus.connected);
      expect((backend.eyes!.blinksTotal, backend.eyes!.eyeDetected, backend.eyes!.eyeCameraOnline), (1, true, true));
      expect(backend.rings, isNotNull);
      backend.dispose();
    });

    test('an eye camera on another network blinks through the relay', () async {
      final open = fixtureJpeg('settle 0'), closed = fixtureJpeg('open 0.0');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final asked = <String>[];
      var done = false;
      server.listen((req) async {
        final first = !asked.contains(req.uri.path);
        asked.add(req.uri.path);
        if (req.uri.path != '/relay/k3y/eye/stream' || !first) {
          req.response.statusCode = 404;
          return req.response.close();
        }
        req.response.headers.contentType = ContentType.parse('multipart/x-mixed-replace; boundary=frame');
        for (final f in [...List.filled(20, open), ...List.filled(4, closed), ...List.filled(10, open)]) {
          req.response.add([...utf8.encode('--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${f.length}\r\n\r\n'), ...f, 13, 10]);
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 40)); // 25 fps
        }
        done = true;
        await req.response.close();
      });
      link.relay = parseRelay('http://127.0.0.1:${server.port}/relay/k3y');
      while (!done) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(asked, containsAll(['/relay/k3y/eye/stream', '/relay/k3y/front/stream']));
      expect(eyes.eye.state.blinksTotal, 1);
      expect(eyes.live().eyeCameraOnline, isTrue);
      link.relay = null;
      await server.close(force: true);
    });

    test('front camera near-work becomes a close-up session, heads-up and the frame sensor stand-in', () async {
      final sens = <SensMessage>[];
      link.sens.listen(sens.add);
      final t0 = DateTime.now().millisecondsSinceEpoch / 1000;
      for (var t = t0; t < t0 + 15; t += 0.33) {
        eyes.frontResults(frozen = t, [det('cell phone', 0.5, 0.3)], (100.0, 0.0));
      }
      expect(eyes.live().nearworkObject, 'phone');
      expect(eyes.live().sessionStart, isNotNull);
      for (var t = t0 + 15; t < t0 + 40; t += 0.33) {
        eyes.frontResults(frozen = t, const [], (100.0, 0.0));
      }
      expect(eyes.closeupToday().sessions.single.object, 'phone');
      expect(eyes.live().headsUpSince, isNotNull); // no eye camera: worn is assumed
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(sens.last.distCm, farCm); // the phone is gone: looking at something far
      expect(sens.last.lux, 400);
      eyes.frontResults(frozen = t0 + 40, [det('cell phone', 0.5, 0.3)], (100.0, 0.0));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(sens.last.distCm, 24);
    });
  });
}
