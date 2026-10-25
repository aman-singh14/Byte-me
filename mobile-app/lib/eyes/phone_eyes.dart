// Eye tracking, near-work, outside time and the rings, run on the phone from
// the camera boards: what the laptop backend did (backend/main.py _eye_step,
// _front_step), so the glasses work with just the phone.
//
//   EYE board   every frame -> pupil (worker isolate) -> blinks, squints,
//               low-blink stretches, gaze
//   FRONT board ~3 times a second -> YOLO near-work + distance -> close-up
//               sessions, heads-up; brightness + /sensor exposure -> outside
//
// The screens read it through BackendLink as if it were the laptop
// (PhoneApi). Without a frame ESP32 it also stands in for the frame's
// sensor samples (distance, blinks, light) so the social taps and side
// quests keep working. Only numbers are kept (EyeHistory); frames are
// dropped as soon as they're measured.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../net/backend_api.dart';
import '../net/backend_models.dart';
import '../net/glasses_link.dart';
import '../net/protocol.dart';
import '../vision/detector.dart';
import '../vision/mjpeg.dart';
import 'blinks.dart';
import 'eye_history.dart';
import 'gaze.dart';
import 'image_ops.dart';
import 'nearwork.dart';
import 'outdoor.dart';
import 'pupil.dart';

/// Turns one eye-camera JPEG into features. Null: it didn't decode.
typedef EyeExtractor = Future<EyeFeatures?> Function(Uint8List jpeg);

/// A grey frame from a JPEG (the eye camera sends grey; colour is converted like cv2).
/// Null for a broken one (a frame mangled on the way).
Grey? decodeGrey(Uint8List jpeg) {
  final img.Image? im;
  try {
    im = img.decodeJpg(jpeg);
  } on Object {
    return null;
  }
  if (im == null) return null;
  final px = Uint8List(im.width * im.height);
  var i = 0;
  for (final p in im) {
    px[i++] = im.numChannels == 1 ? p.r.toInt() : (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
  }
  return Grey(im.width, im.height, px);
}

/// Pupil tracking on its own isolate, keeping CloseupEye's memory between frames.
class EyeWorker {
  SendPort? _to;
  final _from = ReceivePort();
  Completer<EyeFeatures?>? _pending;
  Future<void>? _starting;

  Future<void> _start() async {
    final ready = Completer<SendPort>();
    _from.listen((m) {
      if (m is SendPort) return ready.complete(m);
      final p = _pending;
      _pending = null;
      p?.complete(
        m is List
            ? EyeFeatures(
                m[0] as double,
                m[1] == null ? null : (m[1] as double, m[2] as double),
                (m[3] as List?)?.cast<double>(),
              )
            : null,
      );
    });
    await Isolate.spawn(_run, _from.sendPort);
    _to = await ready.future;
  }

  static void _run(SendPort out) {
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    final eye = CloseupEye();
    inbox.listen((m) {
      final g = decodeGrey(m as Uint8List);
      if (g == null) return out.send(null);
      final f = eye.extract(g);
      out.send([f.openness, f.pupil?.$1, f.pupil?.$2, f.vector]);
    });
  }

  Future<EyeFeatures?> call(Uint8List jpeg) async {
    await (_starting ??= _start());
    final p = _pending = Completer<EyeFeatures?>();
    _to!.send(jpeg);
    return p.future;
  }

  void dispose() => _from.close();
}

/// The distance reported with nothing near in view: well past heads-up distance (100 cm).
const farCm = 300;

double _nowSeconds() => DateTime.now().millisecondsSinceEpoch / 1000;

class PhoneEyes extends ChangeNotifier {
  PhoneEyes(
    this.link, {
    ObjectDetector? frontDetector,
    EyeExtractor? extractor,
    this.say,
    http.Client? client,
    this.clock = _nowSeconds,
    this.frontEvery = const Duration(milliseconds: 333),
    this.persist = true,
  }) : frontDetector = frontDetector ?? YoloDetector(classes: nearClasses.keys.toSet()),
       _extract = extractor,
       _http = client ?? http.Client();

  final GlassesLink link;
  final ObjectDetector frontDetector;
  final void Function(String)? say;
  final double Function() clock;
  final Duration frontEvery;
  final bool persist;
  final http.Client _http;
  EyeExtractor? _extract;
  EyeWorker? _worker;

  static const _historyKey = 'phone_eyes_history', _calibrationKey = 'phone_eyes_calibration';

  final eye = EyeTracker();
  final lowBlink = LowBlinkMonitor();
  late GazeTracker gaze = GazeTracker(say: say, onSaved: (_) => _saveCalibration());
  final nearwork = NearWorkEstimator();
  final closeup = CloseupTracker();
  final headsUp = HeadsUpTracker();
  final outdoor = OutdoorDetector();
  EyeHistory history = EyeHistory();

  CameraFeed? _eyeCam, _frontCam;
  CameraBoard? _eyeBoard, _frontBoard;
  double? _lastEyeFrame, _lastFrontFrame;
  bool _eyeBusy = false, _frontBusy = false;
  Uint8List? _eyeQueued, _frontSeen;
  Timer? _front, _tick, _sensor;
  bool _detectorReady = false;
  (double, double)? _sensorReading;
  double? _sensorAt;
  double? _luma;
  bool _blinkSinceSens = false;
  bool _disposed = false;

  bool get eyeOnline => _lastEyeFrame != null && clock() - _lastEyeFrame! < 2;
  bool get frontOnline => _lastFrontFrame != null && clock() - _lastFrontFrame! < 2;

  /// Where the wearer is looking (left / center / right), while the eye is in view and gaze is
  /// calibrated (the default centres are too rough to crop Ask's photo by).
  String? get gazeRegion => eye.state.eyeDetected && gaze.calibrated && !gaze.calibrating ? gaze.smoothed : null;

  /// Glasses on: the eye camera sees an eye. Without an eye camera there's no telling, so yes.
  bool get worn => _eyeBoard == null || eye.state.eyeDetected;

  Future<void> start() async {
    if (persist) await _load();
    link.addListener(_boardsChanged);
    _boardsChanged();
    _front = Timer.periodic(frontEvery, (_) => _frontStep());
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) => _everyHalfSecond());
    _sensor = Timer.periodic(const Duration(seconds: 1), (_) => _pollSensor());
    unawaited(_loadDetector());
  }

  Future<void> _loadDetector() async {
    try {
      await frontDetector.load();
      _detectorReady = true;
    } catch (e) {
      debugPrint('PhoneEyes: YOLO for near-work did not load: $e');
    }
  }

  // -- the camera boards ---------------------------------------------------------

  void _boardsChanged() {
    if (link.eyeCam != _eyeBoard) {
      _eyeBoard = link.eyeCam;
      _eyeCam?.frame.removeListener(_onEyeFrame);
      _eyeCam?.dispose();
      _eyeCam = _eyeBoard == null ? null : (_eyeBoard!.open()..start());
      _eyeCam?.frame.addListener(_onEyeFrame);
    }
    if (link.frontCam != _frontBoard) {
      _frontBoard = link.frontCam;
      _frontCam?.dispose();
      _frontCam = _frontBoard == null ? null : (_frontBoard!.open()..start());
    }
  }

  // -- EYE -------------------------------------------------------------------------

  void _onEyeFrame() {
    final jpeg = _eyeCam?.frame.value;
    if (jpeg == null) return;
    if (_eyeBusy) {
      _eyeQueued = jpeg; // keep only the newest while the worker is busy
      return;
    }
    unawaited(_eyeStep(jpeg));
  }

  Future<void> _eyeStep(Uint8List jpeg) async {
    _eyeBusy = true;
    final t = clock();
    try {
      final f = await (_extract ??= (_worker = EyeWorker()).call)(jpeg);
      if (_disposed) return;
      if (f != null) {
        _lastEyeFrame = t;
        _eyeFeatures(f, t);
      }
    } catch (e) {
      debugPrint('PhoneEyes: eye frame: $e');
    } finally {
      _eyeBusy = false;
      final next = _eyeQueued;
      _eyeQueued = null;
      if (next != null && !_disposed) unawaited(_eyeStep(next));
    }
  }

  void _eyeFeatures(EyeFeatures? f, double t) {
    for (final e in eye.process(f, t)) {
      switch (e) {
        case Blink():
          history.blink(t);
          _blinkSinceSens = true;
        case PartialBlink():
          history.partialBlink(t);
        case SquintStart():
          history.squint(t);
        case Calibrated() || SquintEnd():
          break;
      }
    }
    final s = eye.state;
    final low = lowBlink.update(t, s.blinkRate, s.eyeDetected);
    if (low != null) history.lowBlink(low.$1, low.$2);
    final reading = s.vector ?? (s.pupil == null ? null : [s.pupil!.$1, s.pupil!.$2]);
    final wasCalibrating = gaze.calibrating;
    gaze.update(reading, t);
    if (wasCalibrating != gaze.calibrating) notifyListeners();
  }

  /// "Look left / straight ahead / right", spoken; needs the eye camera.
  void calibrateGaze() {
    gaze.startCalibration();
    notifyListeners();
  }

  // -- FRONT ----------------------------------------------------------------------

  Future<void> _frontStep() async {
    final jpeg = _frontCam?.frame.value;
    if (_frontBusy || jpeg == null || identical(jpeg, _frontSeen)) return;
    _frontSeen = jpeg;
    _frontBusy = true;
    final t = clock();
    try {
      final results = await Future.wait([
        _detectorReady ? frontDetector.detect(jpeg) : Future.value(const <Detection>[]),
        Isolate.run(() => frontFrameStats(jpeg)),
      ]);
      if (_disposed) return;
      _lastFrontFrame = t;
      _frontResults(t, results[0] as List<Detection>, results[1] as (double, double)?);
    } catch (e) {
      debugPrint('PhoneEyes: front frame: $e');
    } finally {
      _frontBusy = false;
    }
  }

  @visibleForTesting
  void frontResults(double t, List<Detection> dets, (double, double)? stats) {
    _lastFrontFrame = t;
    _frontResults(t, dets, stats);
  }

  void _frontResults(double t, List<Detection> dets, (double, double)? stats) {
    final objs = nearwork.measure(dets);
    final nearest = objs.firstOrNull;
    final (done, _) = closeup.update(t, nearest);
    done.forEach(history.closeupSession);

    final wasUp = headsUp.activeSince != null;
    final hu = headsUp.update(t, objs.isNotEmpty, worn);
    if (hu != null) history.stretchEnded('heads_up', hu.$1, hu.$2);
    if (!wasUp && headsUp.activeSince != null) history.stretchStarted('heads_up', headsUp.activeSince!);

    _luma = stats?.$1;
    Object? ev;
    if (worn || outdoor.manual != null) {
      final fresh = _sensorAt != null && t - _sensorAt! <= 5 ? _sensorReading : null;
      ev = outdoor.update(t, luma: stats?.$1, sky: stats?.$2 ?? 0, exposureLines: fresh?.$1, gain: fresh?.$2);
    } else {
      final out = outdoor.flush(t); // glasses off: outside time stops counting
      if (out != null) ev = ('end', out);
    }
    if (ev case ('start', final double start)) history.stretchStarted('outside', start);
    if (ev case ('end', (final double s, final double e))) history.stretchEnded('outside', s, e);
    history.checkGoals(t);
  }

  Future<void> _pollSensor() async {
    final url = _frontBoard?.sensor;
    if (url == null) return; // no board, or one through a relay: no outside time
    try {
      final r = await _http.get(url).timeout(const Duration(seconds: 1));
      final j = jsonDecode(r.body);
      if (j is Map<String, dynamic>) {
        final (exp, gain) = parseSensor(j);
        if (exp != null && gain != null) {
          _sensorReading = (exp, gain);
          _sensorAt = clock();
        }
      }
    } catch (_) {
      // the board is busy or gone: the reading goes stale and outside isn't called
    }
  }

  // -- twice a second ----------------------------------------------------------------

  int _ticks = 0;

  void _everyHalfSecond() {
    final t = clock();
    // The eye camera stopped sending: say so to the tracker (no eye, no blinks).
    if (_lastEyeFrame != null && t - _lastEyeFrame! > 0.5 && !_eyeBusy) _eyeFeatures(null, t);
    if (_lastFrontFrame != null && t - _lastFrontFrame! > 2) _frontGone(t);
    if (_lastFrontFrame != null && frontOnline) {
      // Stands in for the frame's sensor samples: distance, blinks and light (as the laptop's bridge did).
      link.addPhoneSens(
        SensMessage(
          // the nearest screen or book in view; nothing near means looking at something far
          distCm: nearwork.last.firstOrNull?.distanceCm.round() ?? farCm,
          blink: _blinkSinceSens,
          yawRate: 0,
          lux: ((_luma ?? 0) * 4).round(),
        ),
      );
      _blinkSinceSens = false;
    }
    if (++_ticks % 2 == 0) history.sample(t, eye.state.eyeDetected ? eye.state.blinkRate : null);
    if (_ticks % 60 == 0) unawaited(_saveHistory());
    notifyListeners();
  }

  /// The front camera went away: close what was open.
  void _frontGone(double t) {
    closeup.flush(t).forEach(history.closeupSession);
    final hu = headsUp.flush(t);
    if (hu != null) history.stretchEnded('heads_up', hu.$1, hu.$2);
    final out = outdoor.flush(t);
    if (out != null) history.stretchEnded('outside', out.$1, out.$2);
    _lastFrontFrame = null;
  }

  // -- what BackendLink shows ----------------------------------------------------------

  EyesLive live() {
    final s = eye.state;
    final nearest = nearwork.last.firstOrNull;
    final session = closeup.open;
    DateTime at(double v) => DateTime.fromMillisecondsSinceEpoch((v * 1000).round());
    final front = frontOnline;
    return EyesLive(
      blinkRate: s.blinkRate == null ? null : (s.blinkRate! * 10).round() / 10,
      blinksTotal: s.blinksTotal,
      partialBlinks: s.partialBlinks,
      squinting: s.squinting,
      lowBlink: lowBlink.active,
      lowBlinkSince: lowBlink.active ? at(lowBlink.since!) : null,
      eyeDetected: s.eyeDetected && eyeOnline,
      calibrating: s.calibrating,
      nearwork: front && nearest != null,
      nearworkObject: front ? nearest?.kind : null,
      nearworkDistanceCm: front && nearest != null ? (nearest.distanceCm * 10).round() / 10 : null,
      nearworkClose: front && (nearest?.close ?? false),
      nearworkThresholdCm: front ? nearest?.thresholdCm : null,
      sessionStart: session == null ? null : at(session.$1),
      sessionObject: session?.$2,
      headsUpSince: headsUp.activeSince == null ? null : at(headsUp.activeSince!),
      eyeCameraOnline: eyeOnline,
      frontCameraOnline: front,
    );
  }

  EyesHistory eyesHistory() => history.eyes(clock(), openLowBlink: lowBlink.active ? lowBlink.since : null);
  CloseupDay closeupToday() => history.closeupToday(clock(), closeup.open);
  RingsDay ringsToday() => history.today(clock());
  List<RingsDay> ringsHistory({int days = 7}) => history.history(clock(), days: days);

  /// Calibrate one object type held [knownCm] away. Throws [StateError] with a readable message.
  void calibrateCloseup(String object, double knownCm) {
    if (knownCm < 5 || knownCm > 500) throw StateError('The distance must be between 5 and 500 cm.');
    nearwork.calibrate(object, knownCm);
    unawaited(_saveCalibration());
  }

  /// Debug: force outside on or off, or null for automatic.
  void setOutside(bool? on) => outdoor.manual = on;

  // -- keeping it ---------------------------------------------------------------------

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    try {
      final h = p.getString(_historyKey);
      if (h != null) history = EyeHistory(saved: jsonDecode(h) as Map<String, dynamic>);
      final c = p.getString(_calibrationKey);
      if (c != null) {
        final j = jsonDecode(c) as Map<String, dynamic>;
        gaze = GazeTracker(saved: j['gaze'] as Map<String, dynamic>?, say: say, onSaved: (_) => _saveCalibration());
        for (final e in (j['nearwork_k'] as Map<String, dynamic>? ?? {}).entries) {
          nearwork.k[e.key] = (e.value as num).toDouble();
        }
      }
    } on Object catch (e) {
      debugPrint('PhoneEyes: saved data unreadable, starting fresh: $e');
    }
  }

  Future<void> _saveHistory() async {
    if (!persist) return;
    history.prune(clock());
    await (await SharedPreferences.getInstance()).setString(_historyKey, jsonEncode(history.toJson()));
  }

  Future<void> _saveCalibration() async {
    if (!persist) return;
    await (await SharedPreferences.getInstance()).setString(
      _calibrationKey,
      jsonEncode({
        'gaze': gaze.calibrated ? {for (final e in gaze.centroids.entries) e.key: e.value, 'scale': ?gaze.scale} : null,
        'nearwork_k': nearwork.k,
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    final t = clock();
    _frontGone(t);
    unawaited(_saveHistory());
    link.removeListener(_boardsChanged);
    _front?.cancel();
    _tick?.cancel();
    _sensor?.cancel();
    _eyeCam?.frame.removeListener(_onEyeFrame);
    _eyeCam?.dispose();
    _frontCam?.dispose();
    _worker?.dispose();
    frontDetector.dispose();
    super.dispose();
  }
}

/// The phone answering BackendLink's questions, in place of the laptop.
class PhoneApi extends BackendApi {
  PhoneApi(this.eyes) : super(Uri(scheme: 'phone', host: 'this'));
  final PhoneEyes eyes;

  @override
  Future<EyesLive> eyesLive() async => eyes.live();

  @override
  Future<EyesHistory> eyesHistory({String range = 'day'}) async => eyes.eyesHistory();

  @override
  Future<CloseupDay> closeupToday() async => eyes.closeupToday();

  @override
  Future<RingsDay> ringsToday() async => eyes.ringsToday();

  @override
  Future<List<RingsDay>> ringsHistory({int days = 7}) async => eyes.ringsHistory(days: days);

  @override
  Future<void> calibrateCloseup(String object, double knownCm) async {
    try {
      eyes.calibrateCloseup(object, knownCm);
    } on StateError catch (e) {
      throw BackendException(e.message);
    }
  }

  @override
  Future<void> setOutside(bool? on) async => eyes.setOutside(on);

  @override
  Future<LookResult> look({String? question, String? region, bool requireGaze = false}) =>
      throw const BackendException('Ask runs through the cloud server on the phone.');

  @override
  Future<Map<String, dynamic>> vlm(
    String feature, {
    List<(String, List<int>)> images = const [],
    bool useFront = false,
    String? question,
    Duration? timeout,
  }) => throw const BackendException('Muse needs the cloud server: build the app with CLOUD_URL.');
}
