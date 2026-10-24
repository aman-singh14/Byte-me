// JSON from the laptop backend (backend/api.py), parsed leniently: a missing or
// null field never throws, it just becomes null / 0 / empty.

DateTime? _time(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch((v * 1000).round()) : null;
double? _dbl(Object? v) => v is num ? v.toDouble() : null;
int _int(Object? v) => v is num ? v.round() : 0;
bool _bool(Object? v) => v == true;
String? _str(Object? v) => v is String ? v : null;
Map<String, dynamic> _map(Object? v) => v is Map<String, dynamic> ? v : const {};
List<Object?> _list(Object? v) => v is List ? v : const [];

/// POST /assist/look: what the wearer is looking at.
class LookResult {
  const LookResult({
    this.region = 'center',
    this.regionSource = '',
    this.localAnswer,
    this.museAnswer,
    this.museError,
    this.objects = const [],
    this.seconds,
  });

  final String region; // left | center | right | all
  final String regionSource; // override | question | gaze | default
  final String? localAnswer; // instant, from YOLO on the laptop
  final String? museAnswer; // fuller description from Muse
  final String? museError; // why Muse didn't answer (no key, budget, offline)
  final List<String> objects; // YOLO labels, e.g. "laptop"
  final double? seconds;

  /// The best thing to say out loud.
  String get spoken => museAnswer ?? localAnswer ?? "I couldn't tell.";

  factory LookResult.fromJson(Map<String, dynamic> j) => LookResult(
    region: _str(j['region']) ?? 'center',
    regionSource: _str(j['region_source']) ?? '',
    localAnswer: _str(j['local_answer']),
    museAnswer: _str(j['muse_answer']),
    museError: _str(j['muse_error']),
    objects: [for (final d in _list(j['detections']).whereType<Map<String, dynamic>>()) ?_str(d['label'])],
    seconds: _dbl(_map(j['timing_s'])['total']),
  );
}

/// GET /eyes/live: blinks from the EYE camera, near-work from the FRONT camera.
class EyesLive {
  const EyesLive({
    this.blinkRate,
    this.blinksTotal = 0,
    this.partialBlinks = 0,
    this.squinting = false,
    this.lowBlink = false,
    this.lowBlinkSince,
    this.eyeDetected = false,
    this.calibrating = false,
    this.nearwork = false,
    this.nearworkObject,
    this.nearworkDistanceCm,
    this.nearworkClose = false,
    this.nearworkThresholdCm,
    this.sessionStart,
    this.sessionObject,
    this.headsUpSince,
    this.eyeCameraOnline,
    this.frontCameraOnline,
  });

  final double? blinkRate; // blinks per minute (null until there is enough data)
  final int blinksTotal;
  final int partialBlinks;
  final bool squinting;
  final bool lowBlink; // under 10 blinks/min for more than 5 minutes
  final DateTime? lowBlinkSince;
  final bool eyeDetected;
  final bool calibrating;
  final bool nearwork; // a phone, laptop, tv, keyboard or book is in view
  final String? nearworkObject; // "phone" | "laptop" | "tv" | "keyboard" | "book"
  final double? nearworkDistanceCm;
  final bool nearworkClose;
  final double? nearworkThresholdCm;
  final DateTime? sessionStart; // open close-up session
  final String? sessionObject;
  final DateTime? headsUpSince; // open heads-up stretch
  final bool? eyeCameraOnline;
  final bool? frontCameraOnline;

  factory EyesLive.fromJson(Map<String, dynamic> j) {
    final session = _map(j['closeup_session']);
    final headsUp = _map(j['heads_up']);
    final cams = _map(j['cameras']);
    bool? online(String c) => cams[c] == null ? null : cams[c] == 'online';
    return EyesLive(
      blinkRate: _dbl(j['blink_rate']),
      blinksTotal: _int(j['blinks_total']),
      partialBlinks: _int(j['partial_blinks']),
      squinting: _bool(j['squinting']),
      lowBlink: _bool(j['low_blink']),
      lowBlinkSince: _time(j['low_blink_since']),
      eyeDetected: _bool(j['eye_detected']),
      calibrating: _bool(j['calibrating']),
      nearwork: _bool(j['nearwork']),
      nearworkObject: _str(j['nearwork_object']),
      nearworkDistanceCm: _dbl(j['nearwork_distance_cm']),
      nearworkClose: _bool(j['nearwork_close']),
      nearworkThresholdCm: _dbl(j['nearwork_threshold_cm']),
      sessionStart: _time(session['start']),
      sessionObject: _str(session['object']),
      headsUpSince: _time(headsUp['start']),
      eyeCameraOnline: online('eye'),
      frontCameraOnline: online('front'),
    );
  }
}

class BlinkPoint {
  const BlinkPoint(this.time, this.blinkRate, this.partialBlinks);
  final DateTime time;
  final double? blinkRate;
  final int partialBlinks;
}

class TimeSpan {
  const TimeSpan(this.start, this.end, {this.open = false});
  final DateTime start;
  final DateTime end;
  final bool open;
  Duration get duration => end.difference(start);
}

/// GET /eyes/history: blink rate over time, squints, low-blink stretches.
class EyesHistory {
  const EyesHistory({this.points = const [], this.squints = const [], this.lowBlink = const []});

  final List<BlinkPoint> points;
  final List<DateTime> squints;
  final List<TimeSpan> lowBlink;

  int get partialBlinks => points.fold(0, (a, p) => a + p.partialBlinks);

  factory EyesHistory.fromJson(Map<String, dynamic> j) => EyesHistory(
    points: [
      for (final p in _list(j['points']).whereType<Map<String, dynamic>>())
        if (_time(p['t']) != null) BlinkPoint(_time(p['t'])!, _dbl(p['blink_rate']), _int(p['partial_blinks'])),
    ],
    squints: [for (final t in _list(j['squints'])) ?_time(t)],
    lowBlink: [
      for (final s in _list(j['low_blink']).whereType<Map<String, dynamic>>())
        if (_time(s['start']) != null && _time(s['end']) != null)
          TimeSpan(_time(s['start'])!, _time(s['end'])!, open: _bool(s['open'])),
    ],
  );
}

class CloseupSession {
  const CloseupSession({
    required this.start,
    required this.end,
    required this.object,
    this.minCm,
    this.avgCm,
    this.minutes = 0,
    this.open = false,
  });

  final DateTime start;
  final DateTime end;
  final String object;
  final double? minCm;
  final double? avgCm;
  final double minutes;
  final bool open;
}

/// GET /closeup/sessions: close-up time today, by object, and each session.
class CloseupDay {
  const CloseupDay({
    this.totalMinutes = 0,
    this.byObject = const {},
    this.sessions = const [],
    this.longestMinutes = 0,
  });

  final double totalMinutes;
  final Map<String, double> byObject;
  final List<CloseupSession> sessions;
  final double longestMinutes;

  factory CloseupDay.fromJson(Map<String, dynamic> j) => CloseupDay(
    totalMinutes: _dbl(j['total_min']) ?? 0,
    byObject: {for (final e in _map(j['by_object']).entries) e.key: _dbl(e.value) ?? 0},
    longestMinutes: _dbl(j['longest_min']) ?? 0,
    sessions: [
      for (final s in _list(j['sessions']).whereType<Map<String, dynamic>>())
        if (_time(s['start']) != null && _time(s['end']) != null)
          CloseupSession(
            start: _time(s['start'])!,
            end: _time(s['end'])!,
            object: _str(s['object']) ?? 'screen',
            minCm: _dbl(s['min_cm']),
            avgCm: _dbl(s['avg_cm']),
            minutes: _dbl(s['duration_min']) ?? 0,
            open: _bool(s['open']),
          ),
    ],
  );
}

class RingProgress {
  const RingProgress({this.minutes = 0, this.goalMinutes = 0, this.active = false});
  final double minutes;
  final int goalMinutes;
  final bool active;

  factory RingProgress.fromJson(Object? v) {
    final j = _map(v);
    return RingProgress(minutes: _dbl(j['minutes']) ?? 0, goalMinutes: _int(j['goal_min']), active: _bool(j['active']));
  }
}

/// GET /rings/today (and each entry of /rings/history).
class RingsDay {
  const RingsDay({
    this.date = '',
    this.headsUp = const RingProgress(),
    this.outside = const RingProgress(),
    this.headsUpBreaks = 0,
    this.points = 0,
  });

  final String date; // YYYY-MM-DD
  final RingProgress headsUp;
  final RingProgress outside;
  final int headsUpBreaks;
  final int points;

  factory RingsDay.fromJson(Map<String, dynamic> j) => RingsDay(
    date: _str(j['date']) ?? '',
    headsUp: RingProgress.fromJson(j['heads_up']),
    outside: RingProgress.fromJson(j['outside']),
    headsUpBreaks: _int(_map(j['heads_up'])['breaks']),
    points: _int(j['points']),
  );
}
