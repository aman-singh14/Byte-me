// Feeds the alert engine from the glasses and the rear camera, sends its
// decisions to the frame's vibration motors, and keeps the event log.
//
// Close range is the reflex's (Cam B, the FPGA): a fire is an urgent alert at
// once, and [namer] then says what it is from Cam B's video. Cam A's YOLO
// tracking warns earlier, at range.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/glasses_link.dart';
import '../net/protocol.dart';
import '../vision/fire_namer.dart';
import '../vision/rear_vision.dart';
import 'alert_engine.dart';
import 'alert_log.dart';
import 'tracker.dart';

class AlertService extends ChangeNotifier {
  AlertService(this.link, this.vision, {AlertEngine? engine, this.namer}) : engine = engine ?? AlertEngine() {
    _subs.add(link.sens.listen((s) => _handle(this.engine.addSens(DateTime.now(), yawRate: s.yawRate, lux: s.lux))));
    _subs.add(link.fires.listen((f) => onFire(f.side)));
    vision.addListener(_onVision);
    _onVision();
  }

  final GlassesLink link;
  final RearVision vision;
  final AlertEngine engine;
  final FireNamer? namer;
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

  /// The last social tap, until dismissed.
  SocialTapped? _socialTap;
  SocialTapped? get socialTap => _socialTap;

  final _tracked = StreamController<DateTime>.broadcast(sync: true);

  /// The time of each rear-camera frame, right after the tracker took it in
  /// (for the social tap detector, which reads [engine]'s tracks).
  Stream<DateTime> get tracked => _tracked.stream;

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

  final _naming = <WearerSide>{};
  bool _disposed = false;

  /// A reflex fire: alert now, then name it from Cam B's video. The reflex
  /// fires repeatedly while something looms, so each side is named once
  /// per alert.
  @visibleForTesting
  Future<void> onFire(WearerSide side) async {
    _handle(engine.addFire(DateTime.now(), side));
    final namer = this.namer;
    if (namer == null || engine.fireIsNamed(side) || !_naming.add(side)) return;
    try {
      final label = await namer.name(side);
      if (label != null && !_disposed) _handle(engine.nameFire(DateTime.now(), side, label));
    } finally {
      _naming.remove(side);
    }
  }

  /// The wearer dismissed the alert in the app: same as glancing back.
  void dismiss() => _handle(engine.dismiss(DateTime.now()));

  void dismissFollowing() {
    _following = null;
    notifyListeners();
  }

  /// Someone stopped close by: tap the glasses on that side, unless a safety
  /// alert is going on (it always wins).
  bool raiseSocialTap(SocialTapped tap) {
    if (current != null) return false;
    _handle([tap]);
    return true;
  }

  void dismissSocialTap() {
    _socialTap = null;
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
    _detections = loop?.results.listen((frame) {
      _handle(
        engine.addDetections(frame.at, [
          for (final d in frame.detections)
            Sighting(
              label: d.label,
              confidence: d.confidence,
              box: Box(d.box.left, d.box.top, d.box.right, d.box.bottom),
            ),
        ]),
      );
      if (!_disposed) _tracked.add(frame.at);
    });
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
        case PossiblyFollowing(:final update, :final presence):
          // Shown and spoken, no buzz. An update only refreshes a notice
          // that's still up; a dismissed one stays dismissed.
          if (!update) {
            _following = e;
          } else if (_following?.presence == presence) {
            _following = e;
          }
        case SocialTapped(:final side, :final lookUp):
          link.send(TapCommand(side: side, kind: lookUp ? 'lookup' : 'social'));
          _socialTap = e;
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
    _disposed = true;
    _ticker?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _detections?.cancel();
    vision.removeListener(_onVision);
    _events.close();
    _tracked.close();
    super.dispose();
  }
}
