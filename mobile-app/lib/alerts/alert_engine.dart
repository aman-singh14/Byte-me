// Decides when to warn the wearer about something approaching from behind.
// Pure Dart: no Flutter, no I/O, no clock of its own (every input carries
// its time), so it can be tested frame by frame.
//
// Inputs: rear-camera detections, Cam B reflex fires, and the frame's
// sensor samples (head turn rate, light). Output: the one alert the wearer
// should feel right now, as AlertRaised / AlertCleared events.

import 'dart:math' as math;

import '../net/protocol.dart';
import 'tracker.dart';

enum AlertLevel {
  gentle(1),
  urgent(2);

  const AlertLevel(this.wire);

  /// "level" in the alert command.
  final int wire;
}

/// Seconds to contact at which each class raises a gentle and an urgent
/// alert, at normal sensitivity in daylight. People never get an urgent
/// camera alert: someone walking up to talk looks the same as a collision
/// until they slow down, and the social tap handles them.
///
/// People's gentle threshold is set so a walker (1.4 m/s) is caught at about
/// 4 m, while their feet are still in the picture: closer than that the
/// camera can only see their width, which leaning and arm swing change too
/// much to trust.
const approachThresholds = <String, ({double gentle, double? urgent})>{
  'car': (gentle: 6, urgent: 3),
  'bus': (gentle: 6, urgent: 3),
  'truck': (gentle: 6, urgent: 3),
  'motorcycle': (gentle: 6, urgent: 3),
  'bicycle': (gentle: 5, urgent: 2.5),
  'skateboard': (gentle: 4, urgent: 2),
  'dog': (gentle: 3, urgent: 1.5),
  'person': (gentle: 3, urgent: null),
};

/// Classes that only alert when straight behind ([WearerSide.behind]). A
/// person approaching off to one side is walking past, not at the wearer;
/// on a busy sidewalk that would be a buzz every few seconds.
const onlyStraightBehind = {'person'};

enum Sensitivity {
  low(0.7),
  normal(1.0),
  high(1.4);

  const Sensitivity(this.scale);

  /// Multiplies every time-to-contact threshold: higher warns earlier.
  final double scale;
}

/// Night mode warns earlier and accepts less certain detections, because
/// the camera sees less in the dark. Auto follows the frame's light sensor.
enum NightMode { auto, on, off }

class AlertSettings {
  const AlertSettings({
    this.sensitivity = Sensitivity.normal,
    this.nightMode = NightMode.auto,
    this.followAfter = const Duration(minutes: 3),
  });

  final Sensitivity sensitivity;
  final NightMode nightMode;

  /// Someone behind the wearer this long gets a "possibly following" notice.
  final Duration followAfter;

  AlertSettings copyWith({Sensitivity? sensitivity, NightMode? nightMode, Duration? followAfter}) => AlertSettings(
    sensitivity: sensitivity ?? this.sensitivity,
    nightMode: nightMode ?? this.nightMode,
    followAfter: followAfter ?? this.followAfter,
  );
}

/// What raised the alert: the phone's object detection, or Cam B's on-board
/// collision reflex.
enum AlertSource { camera, reflex }

class Alert {
  const Alert({
    required this.side,
    required this.level,
    required this.label,
    required this.source,
    this.secondsToContact,
    this.trackId,
  });

  final WearerSide side;
  final AlertLevel level;

  /// One word: the object class ("car"), or "something" for a reflex fire
  /// the camera can't name.
  final String label;
  final AlertSource source;
  final double? secondsToContact;
  final int? trackId;

  /// Same thing for the wearer: no need to buzz again.
  bool sameAs(Alert o) => side == o.side && level == o.level && label == o.label && source == o.source;

  @override
  String toString() =>
      'Alert(${level.name} ${side.name} $label, ${source.name}'
      '${secondsToContact == null ? '' : ', ${secondsToContact!.toStringAsFixed(1)} s'})';
}

sealed class AlertEvent {
  const AlertEvent();
}

/// A new alert, or the current one changed level, side or label. Replaces
/// any alert raised before.
class AlertRaised extends AlertEvent {
  const AlertRaised(this.alert);
  final Alert alert;
  @override
  String toString() => 'AlertRaised($alert)';
}

enum ClearReason {
  /// The object stopped approaching or left the view.
  gone,

  /// The wearer glanced back toward it.
  silenced,

  /// The wearer dismissed it in the app.
  dismissed,
}

class AlertCleared extends AlertEvent {
  const AlertCleared(this.alert, this.reason);
  final Alert alert;
  final ClearReason reason;
  @override
  String toString() => 'AlertCleared($alert, ${reason.name})';
}

/// The same person has stayed behind the wearer for [behindFor]. Reported
/// once per presence, then again as an [update] each further minute they
/// stay, so the notice and log keep the real time. Based only on how long
/// someone has been there, not on who they are.
class PossiblyFollowing extends AlertEvent {
  const PossiblyFollowing(this.side, this.behindFor, {this.presence, this.update = false});
  final WearerSide side;
  final Duration behindFor;

  /// Which presence this is about (a track id), to match updates.
  final int? presence;

  /// A later minute of a presence already reported: refresh, don't announce.
  final bool update;
  @override
  String toString() => 'PossiblyFollowing(${side.name}, ${behindFor.inSeconds} s${update ? ', update' : ''})';
}

/// Someone stopped close by on [side], probably to talk (a social tap). Not
/// a warning: it never uses the urgent color or pattern. [action] is what
/// Muse saw them doing ("waving"), when it was asked. [lookUp] means the
/// wearer was doing close-up work, so the tap also says "look up".
class SocialTapped extends AlertEvent {
  const SocialTapped(this.side, {this.action, this.lookUp = false});
  final WearerSide side;
  final String? action;
  final bool lookUp;
  @override
  String toString() => 'SocialTapped(${side.name}${action == null ? '' : ', $action'}${lookUp ? ', look up' : ''})';
}

class AlertEngine {
  AlertEngine({this.settings = const AlertSettings()});

  AlertSettings settings;

  /// Above this head turn rate (degrees per second) the image is smeared and
  /// jumping, so camera alerts are frozen.
  static const turnRate = 60.0;

  /// Camera alerts stay frozen this long after the turn slows down.
  static const turnSettle = Duration(milliseconds: 300);

  /// Turning the head this far toward the alert's side within [glanceWindow]
  /// counts as looking back at it, and silences it. For something straight
  /// behind, either way counts.
  static const glanceDegrees = 45.0;
  static const glanceWindow = Duration(milliseconds: 1500);

  /// An alert stays at its highest level this long after it last qualified,
  /// so it doesn't flicker on noisy frames.
  static const hold = Duration(seconds: 1);

  /// A camera alert must qualify on every frame for this long before it is
  /// raised, so one or two odd boxes never buzz the wearer. Reflex fires
  /// don't wait.
  static const confirmFor = Duration(milliseconds: 300);

  /// A box must move this far (share of image width) past the edge of the
  /// "behind" zone before its alert changes side, so it doesn't flip back
  /// and forth at the boundary.
  static const sideMargin = 0.05;

  /// A reflex alert lasts this long after the last fire on that side, and a
  /// glance silences reflex fires on that side for [reflexSilence].
  static const reflexHold = Duration(milliseconds: 1500);
  static const reflexSilence = Duration(seconds: 3);

  /// Night mode (auto) turns on below [nightBelowLux] and off above
  /// [dayAboveLux].
  static const nightBelowLux = 15.0;
  static const dayAboveLux = 30.0;
  static const nightScale = 1.25;
  static const minConfidenceDay = 0.45;
  static const minConfidenceNight = 0.35;

  final tracker = Tracker();

  Alert? _current;

  /// The alert the wearer should feel now, if any.
  Alert? get current => _current;

  double? _lux;
  bool _darkOutside = false;

  bool get isNight => switch (settings.nightMode) {
    NightMode.on => true,
    NightMode.off => false,
    NightMode.auto => _darkOutside,
  };

  DateTime? _turningUntil;
  bool isTurning(DateTime at) => _turningUntil != null && at.isBefore(_turningUntil!);

  final _yaw = <(DateTime, double)>[]; // recent (time, yaw rate)
  final _trackAlerts = <int, _TrackAlert>{};
  final _trackSides = <int, WearerSide>{};
  final _silencedTracks = <int, AlertLevel>{}; // track id -> highest level the wearer has seen
  final _fires = <WearerSide, DateTime>{};
  final _fireNames = <WearerSide, String>{}; // what Cam B saw, per active fire
  final _reflexSilencedUntil = <WearerSide, DateTime>{};

  /// The alert level for [label] at [secondsToContact] with the current
  /// settings, or null for no alert.
  AlertLevel? levelFor(String label, double secondsToContact) {
    final t = approachThresholds[label];
    if (t == null) return null;
    final scale = settings.sensitivity.scale * (isNight ? nightScale : 1);
    final urgent = t.urgent;
    if (urgent != null && secondsToContact <= urgent * scale) return AlertLevel.urgent;
    if (secondsToContact <= t.gentle * scale) return AlertLevel.gentle;
    return null;
  }

  /// Detections from one rear-camera frame taken at [at].
  List<AlertEvent> addDetections(DateTime at, List<Sighting> sightings) {
    if (isTurning(at)) return _evaluate(at); // skip smeared frames

    tracker.update(at, [
      for (final s in sightings)
        if (s.confidence >= minConfidence && approachThresholds.containsKey(s.label)) s,
    ]);

    final events = <AlertEvent>[];
    for (final t in tracker.tracks) {
      if (t.lastSeen != at) continue;

      final ttc = t.secondsToContact;
      final passingBy = onlyStraightBehind.contains(t.label) && _stableSide(t) != WearerSide.behind;
      final level = ttc == null || passingBy ? null : levelFor(t.label, ttc);
      if (level != null) {
        (_trackAlerts[t.id] ??= _TrackAlert()).update(level, at, ttc);
      } else {
        _trackAlerts[t.id]?.update(null, at, ttc); // breaks a streak that isn't confirmed yet
      }

      final behindFor = at.difference(t.behindSince);
      if (t.label == 'person' && behindFor >= settings.followAfter) {
        final minutes = behindFor.inMinutes;
        if (!t.followingReported) {
          t.followingReported = true;
          t.followingMinutes = minutes;
          events.add(PossiblyFollowing(t.side, behindFor, presence: t.presence));
        } else if (minutes > t.followingMinutes) {
          t.followingMinutes = minutes;
          events.add(PossiblyFollowing(t.side, behindFor, presence: t.presence, update: true));
        }
      }
    }
    return events..addAll(_evaluate(at));
  }

  /// Cam B's reflex fired on [side] (already the wearer's side).
  List<AlertEvent> addFire(DateTime at, WearerSide side) {
    _fires[side] = at;
    return _evaluate(at);
  }

  /// Cam B's video says the fire on [side] is a [label]. Ignored if that
  /// fire is already over.
  List<AlertEvent> nameFire(DateTime at, WearerSide side, String label) {
    if (!_fires.containsKey(side)) return [];
    _fireNames[side] = label;
    return _evaluate(at);
  }

  /// The active fire on [side] already has a name from Cam B.
  bool fireIsNamed(WearerSide side) => _fireNames.containsKey(side);

  /// One sensor sample. [yawRate] is degrees per second, positive when the
  /// head turns toward the wearer's left.
  List<AlertEvent> addSens(DateTime at, {required num yawRate, required num lux}) {
    _updateLight(lux.toDouble());

    if (yawRate.abs() >= turnRate) {
      if (!isTurning(at)) tracker.resetMotion(); // sizes from before the turn don't compare
      _turningUntil = at.add(turnSettle);
    }
    _yaw.add((at, yawRate.toDouble()));
    _yaw.removeWhere((s) => at.difference(s.$1) > glanceWindow);

    final events = <AlertEvent>[];
    final current = _current;
    if (current != null && _degreesTurnedToward(current.side) >= glanceDegrees) {
      _silence(current, at);
      _yaw.clear(); // one glance silences one alert
      _current = null;
      events.add(AlertCleared(current, ClearReason.silenced));
    }
    return events..addAll(_evaluate(at));
  }

  /// The wearer dismissed the current alert in the app. Like a glance, it
  /// stays quiet until it gets worse.
  List<AlertEvent> dismiss(DateTime at) {
    final current = _current;
    if (current == null) return [];
    _silence(current, at);
    _current = null;
    return [AlertCleared(current, ClearReason.dismissed), ..._evaluate(at)];
  }

  /// Detections below this confidence are ignored.
  double get minConfidence => isNight ? minConfidenceNight : minConfidenceDay;

  /// Call regularly (every 100 ms) so alerts end even if no input arrives,
  /// for example when the camera stream drops.
  List<AlertEvent> tick(DateTime at) {
    if (!isTurning(at)) tracker.prune(at);
    return _evaluate(at);
  }

  List<AlertEvent> _evaluate(DateTime at) {
    if (!isTurning(at)) {
      final alive = {for (final t in tracker.tracks) t.id};
      _trackAlerts.removeWhere((id, a) => !alive.contains(id) || a.staleAt(at));
      _trackSides.removeWhere((id, _) => !alive.contains(id));
      _silencedTracks.removeWhere((id, _) => !alive.contains(id));
    }
    _fires.removeWhere((_, firedAt) => at.difference(firedAt) > reflexHold);
    _fireNames.removeWhere((side, _) => !_fires.containsKey(side));

    final candidates = <Alert>[
      for (final side in _fires.keys)
        if (!(_reflexSilencedUntil[side]?.isAfter(at) ?? false))
          Alert(
            side: side,
            level: AlertLevel.urgent,
            label: _fireNames[side] ?? _labelOn(side, at), // Cam B saw it up close; Cam A is a guess
            source: AlertSource.reflex,
          ),
      for (final t in tracker.tracks)
        if (_trackAlerts[t.id] case final a?)
          if (a.levelAt(at) case final level? when level.index > (_silencedTracks[t.id]?.index ?? -1))
            Alert(
              side: _stableSide(t),
              level: level,
              label: t.label,
              source: AlertSource.camera,
              secondsToContact: a.secondsToContact,
              trackId: t.id,
            ),
    ]..sort(_mostUrgentFirst);

    final previous = _current;
    final next = candidates.firstOrNull;
    _current = next;
    if (next == null) return [if (previous != null) AlertCleared(previous, ClearReason.gone)];
    if (previous != null && next.sameAs(previous)) return [];
    return [AlertRaised(next)];
  }

  static int _mostUrgentFirst(Alert a, Alert b) {
    if (a.level != b.level) return b.level.index - a.level.index;
    if (a.source != b.source) return a.source == AlertSource.reflex ? -1 : 1;
    return (a.secondsToContact ?? double.infinity).compareTo(b.secondsToContact ?? double.infinity);
  }

  /// The side of [t], kept until its box is clearly past a zone boundary.
  WearerSide _stableSide(Track t) {
    final a = wearerSideFromRearImageX(t.box.centerX - sideMargin);
    final b = wearerSideFromRearImageX(t.box.centerX + sideMargin);
    final side = a == b ? a : (_trackSides[t.id] ?? t.side);
    return _trackSides[t.id] = side;
  }

  /// The largest object the camera saw on [side] (or straight behind) in
  /// the last second.
  String _labelOn(WearerSide side, DateTime at) {
    Track? biggest;
    for (final t in tracker.tracks) {
      final near = t.side == side || t.side == WearerSide.behind;
      if (!near || at.difference(t.lastSeen) > const Duration(seconds: 1)) continue;
      if (biggest == null || t.box.area > biggest.box.area) biggest = t;
    }
    return biggest?.label ?? 'something';
  }

  void _silence(Alert alert, DateTime at) {
    switch (alert.source) {
      case AlertSource.camera:
        _silencedTracks[alert.trackId!] = alert.level;
      case AlertSource.reflex:
        _reflexSilencedUntil[alert.side] = at.add(reflexSilence);
    }
  }

  double _degreesTurnedToward(WearerSide side) {
    var towardLeft = 0.0;
    for (var i = 1; i < _yaw.length; i++) {
      final dt = _yaw[i].$1.difference(_yaw[i - 1].$1).inMicroseconds / 1e6;
      towardLeft += _yaw[i].$2 * math.min(dt, 0.2); // cap gaps from dropped samples
    }
    return switch (side) {
      WearerSide.left => towardLeft,
      WearerSide.right => -towardLeft,
      WearerSide.behind => towardLeft.abs(),
    };
  }

  void _updateLight(double lux) {
    final smoothed = _lux = _lux == null ? lux : _lux! + (lux - _lux!) * 0.2;
    if (smoothed < nightBelowLux) _darkOutside = true;
    if (smoothed > dayAboveLux) _darkOutside = false;
  }
}

/// One track's alert levels over time. A level is confirmed once the track
/// has qualified for it on every frame for [AlertEngine.confirmFor], and then
/// held for [AlertEngine.hold] after it last qualified, so noisy frames
/// neither start an alert nor make it flicker.
class _TrackAlert {
  final _streakStart = <AlertLevel, DateTime>{};
  final _lastQualified = <AlertLevel, DateTime>{};
  final _confirmed = <AlertLevel>{};
  double secondsToContact = double.infinity;

  /// One frame's verdict: [level], or null if it doesn't qualify for any.
  void update(AlertLevel? level, DateTime at, double? ttc) {
    for (final l in AlertLevel.values) {
      final qualifies = level != null && l.index <= level.index; // urgent also counts as gentle
      if (!qualifies) {
        _streakStart.remove(l);
        continue;
      }
      final start = _streakStart[l] ??= at;
      _lastQualified[l] = at;
      if (at.difference(start) >= AlertEngine.confirmFor) _confirmed.add(l);
    }
    if (ttc != null) secondsToContact = ttc;
  }

  AlertLevel? levelAt(DateTime at) {
    for (final l in AlertLevel.values.reversed) {
      final last = _lastQualified[l];
      if (last == null || at.difference(last) > AlertEngine.hold) {
        _confirmed.remove(l); // held long enough: must confirm again
        continue;
      }
      if (_confirmed.contains(l)) return l;
    }
    return null;
  }

  /// Nothing qualified for [AlertEngine.hold]: safe to forget.
  bool staleAt(DateTime at) => _lastQualified.values.every((last) => at.difference(last) > AlertEngine.hold);
}
