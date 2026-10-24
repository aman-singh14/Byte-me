// Feeds the alert engine from the glasses and the rear camera, sends its
// decisions to the frame's vibration motors, and keeps the event log.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/glasses_link.dart';
import '../net/protocol.dart';
import '../vision/rear_vision.dart';
import 'alert_engine.dart';
import 'alert_log.dart';
import 'tracker.dart';

class AlertService extends ChangeNotifier {
  AlertService(this.link, this.vision, {AlertEngine? engine}) : engine = engine ?? AlertEngine() {
    _subs.add(link.sens.listen((s) => _handle(this.engine.addSens(DateTime.now(), yawRate: s.yawRate, lux: s.lux))));
    _subs.add(link.fires.listen((f) => _handle(this.engine.addFire(DateTime.now(), f.side))));
    vision.addListener(_onVision);
    _onVision();
  }

  final GlassesLink link;
  final RearVision vision;
  final AlertEngine engine;
  final log = AlertLog();

  static const _logKey = 'alert_log_v1';

  final _subs = <StreamSubscription<Object?>>[];
  StreamSubscription<DetectionFrame>? _detections;
  DetectionLoop? _loop;
  Timer? _ticker;
  SharedPreferences? _prefs;

  final _events = StreamController<AlertEvent>.broadcast();

  /// Everything the engine decides, for the voice and announcements.
  Stream<AlertEvent> get events => _events.stream;

  /// The alert the wearer should feel now, if any.
  Alert? get current => engine.current;

  PossiblyFollowing? _following;

  /// The last "possibly following" notice, until dismissed.
  PossiblyFollowing? get following => _following;

  AlertSettings get settings => engine.settings;
  set settings(AlertSettings s) {
    engine.settings = s;
    notifyListeners();
  }

  /// Starts the 100 ms tick (so alerts end when inputs stop) and loads the
  /// saved event log.
  Future<void> start() async {
    _ticker ??= Timer.periodic(const Duration(milliseconds: 100), (_) => _handle(engine.tick(DateTime.now())));
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_logKey);
      if (saved != null) log.load(jsonDecode(saved), DateTime.now());
      notifyListeners();
    } catch (e) {
      debugPrint('AlertService: could not load the event log: $e');
    }
  }

  /// The wearer dismissed the alert in the app: same as glancing back.
  void dismiss() => _handle(engine.dismiss(DateTime.now()));

  void dismissFollowing() {
    _following = null;
    notifyListeners();
  }

  void clearLog() {
    log.clear();
    _save();
    notifyListeners();
  }

  // RearVision replaces its detection loop when the camera or model changes.
  void _onVision() {
    final loop = vision.loop;
    if (identical(loop, _loop)) return;
    _loop = loop;
    _detections?.cancel();
    _detections = loop?.results.listen(
      (frame) => _handle(
        engine.addDetections(frame.at, [
          for (final d in frame.detections)
            Sighting(
              label: d.label,
              confidence: d.confidence,
              box: Box(d.box.left, d.box.top, d.box.right, d.box.bottom),
            ),
        ]),
      ),
    );
  }

  /// Acts on engine events. Public for tests.
  @visibleForTesting
  void handle(List<AlertEvent> events) => _handle(events);

  void _handle(List<AlertEvent> events) {
    if (events.isEmpty) return;
    final now = DateTime.now();
    for (final e in events) {
      switch (e) {
        case AlertRaised(:final alert):
          // Reflex alerts go back too: the frame can't tell otherwise whether
          // the phone agrees, and a missed buzz is worse than a double one.
          link.send(AlertCommand(side: alert.side, level: alert.level.wire, label: alert.label));
        case AlertCleared():
          link.send(const StopCommand());
        case PossiblyFollowing():
          _following = e; // shown and spoken, no buzz
      }
      debugPrint('AlertService: $e');
      log.record(now, e);
      _events.add(e);
    }
    _save();
    notifyListeners();
  }

  void _save() => _prefs?.setString(_logKey, jsonEncode(log.toJson()));

  @override
  void dispose() {
    _ticker?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _detections?.cancel();
    vision.removeListener(_onVision);
    _events.close();
    super.dispose();
  }
}
