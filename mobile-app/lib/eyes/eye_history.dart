// What the phone keeps of the eye and near-work data, and the daily rings
// and points: backend/db.py's tables and backend/rings.py in one small JSON
// document (kept in SharedPreferences by PhoneEyes). Numbers only: no frames,
// nothing anyone said. The last 8 days.
//
//   heads-up ring  minutes with no near-work in view (glasses on), goal 180
//   outside ring   minutes outdoors, goal 120
//   points         +5 per heads-up break of a minute or more, +1 per 5 outside
//                  minutes, +20 per ring completed (once a day)

import '../net/backend_models.dart';
import 'nearwork.dart';

const _day = 86400.0;
const _bucket = 900.0; // blink history in 15-minute buckets, like the laptop's "day" range
const _keepDays = 8;

double dayStart(double t) {
  final d = DateTime.fromMillisecondsSinceEpoch((t * 1000).round());
  return DateTime(d.year, d.month, d.day).millisecondsSinceEpoch / 1000;
}

String _date(double d0) {
  final d = DateTime.fromMillisecondsSinceEpoch((d0 * 1000).round());
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

DateTime _time(double t) => DateTime.fromMillisecondsSinceEpoch((t * 1000).round());

/// Seconds of [spans] inside since..until.
double _clipped(Iterable<(double, double)> spans, double since, double until) => spans.fold(0.0, (a, s) {
  final v = (s.$2 < until ? s.$2 : until) - (s.$1 > since ? s.$1 : since);
  return a + (v > 0 ? v : 0);
});

class _Bucket {
  _Bucket(this.t);
  final double t;
  double rateSum = 0;
  int rateN = 0, blinks = 0, partial = 0;

  Map<String, dynamic> toJson() => {'t': t, 'rs': rateSum, 'rn': rateN, 'b': blinks, 'p': partial};
  static _Bucket fromJson(Map<String, dynamic> j) => _Bucket((j['t'] as num).toDouble())
    ..rateSum = (j['rs'] as num).toDouble()
    ..rateN = j['rn'] as int
    ..blinks = j['b'] as int
    ..partial = j['p'] as int;
}

class EyeHistory {
  EyeHistory({Map<String, dynamic>? saved, this.headsUpGoal = 180, this.outsideGoal = 120}) {
    if (saved != null) _load(saved);
  }

  final int headsUpGoal, outsideGoal;
  final _intervals = <String, List<(double, double)>>{'heads_up': [], 'outside': [], 'low_blink': []};
  final _sessions = <CloseupSessionRecord>[];
  final _points = <(double, String, int)>[]; // (ts, kind, points)
  final _buckets = <_Bucket>[];
  final _squints = <double>[];

  /// Stretches still going (heads-up or outside right now): kind -> start.
  final open = <String, double?>{'heads_up': null, 'outside': null};

  // -- recording -------------------------------------------------------------

  _Bucket _bucketAt(double t) {
    final start = (t / _bucket).floor() * _bucket;
    if (_buckets.isEmpty || _buckets.last.t != start) _buckets.add(_Bucket(start));
    return _buckets.last;
  }

  /// Once a second: the blink rate now (null until known).
  void sample(double t, double? blinkRate) {
    final b = _bucketAt(t);
    if (blinkRate != null) {
      b.rateSum += blinkRate;
      b.rateN++;
    }
  }

  void blink(double t) => _bucketAt(t).blinks++;
  void partialBlink(double t) => _bucketAt(t).partial++;
  void squint(double t) => _squints.add(t);
  void lowBlink(double start, double end) => _intervals['low_blink']!.add((start, end));
  void closeupSession(CloseupSessionRecord s) => _sessions.add(s);

  void stretchStarted(String kind, double start) => open[kind] = start;

  void stretchEnded(String kind, double start, double end) {
    open[kind] = null;
    if (end - start <= 0) return;
    _intervals[kind]!.add((start, end));
    if (kind == 'heads_up' && end - start >= 60) {
      _points.add((end, 'heads_up_break', 5));
    } else if (kind == 'outside' && (end - start) ~/ 300 > 0) {
      _points.add((end, 'outside', (end - start) ~/ 300));
    }
    checkGoals(end);
  }

  /// The ring-complete bonus, the first time a ring fills today.
  void checkGoals(double now) {
    final d0 = dayStart(now);
    for (final (kind, goal) in [('heads_up', headsUpGoal), ('outside', outsideGoal)]) {
      if (_points.any((p) => p.$2 == '${kind}_ring' && p.$1 >= d0 && p.$1 < d0 + _day)) continue;
      if (minutes(kind, d0, now, now) >= goal) _points.add((now, '${kind}_ring', 20));
    }
  }

  /// Forget everything older than [_keepDays].
  void prune(double now) {
    final cutoff = dayStart(now) - (_keepDays - 1) * _day;
    for (final list in _intervals.values) {
      list.removeWhere((s) => s.$2 < cutoff);
    }
    _sessions.removeWhere((s) => s.end < cutoff);
    _points.removeWhere((p) => p.$1 < cutoff);
    _buckets.removeWhere((b) => b.t < cutoff);
    _squints.removeWhere((t) => t < cutoff);
  }

  // -- what the screens show ----------------------------------------------------

  double minutes(String kind, double since, double until, double now) {
    final spans = [..._intervals[kind]!, if (open[kind] != null) (open[kind]!, now < until ? now : until)];
    return _clipped(spans, since, until) / 60;
  }

  RingsDay day(double d0, double now) {
    final until = now < d0 + _day ? now : d0 + _day;
    final today = d0 <= now && now < d0 + _day;
    RingProgress ring(String kind, int goal) => RingProgress(
      minutes: _round1(minutes(kind, d0, until, now)),
      goalMinutes: goal,
      active: today && open[kind] != null,
    );
    return RingsDay(
      date: _date(d0),
      headsUp: ring('heads_up', headsUpGoal),
      outside: ring('outside', outsideGoal),
      headsUpBreaks:
          _intervals['heads_up']!.where((s) => s.$1 < until && s.$2 > d0).length +
          (today && open['heads_up'] != null ? 1 : 0),
      points: _points.where((p) => p.$1 >= d0 && p.$1 < d0 + _day).fold(0, (a, p) => a + p.$3),
    );
  }

  RingsDay today(double now) => day(dayStart(now), now);

  List<RingsDay> history(double now, {int days = 7}) => [
    for (var i = days - 1; i >= 0; i--) day(dayStart(now) - i * _day, now),
  ];

  /// Today's close-up sessions, with the one going on now ([openSession]: start, object).
  CloseupDay closeupToday(double now, (double, String)? openSession) {
    final d0 = dayStart(now), until = now < d0 + _day ? now : d0 + _day;
    double mins(double s, double e) => _round1(((e < until ? e : until) - (s > d0 ? s : d0)) / 60);
    final rows = [
      for (final s in _sessions)
        if (s.start < d0 + _day && s.end > d0)
          CloseupSession(
            start: _time(s.start),
            end: _time(s.end),
            object: s.object,
            minCm: s.minCm,
            avgCm: s.avgCm,
            minutes: mins(s.start, s.end),
          ),
      if (openSession != null && openSession.$1 >= d0)
        CloseupSession(
          start: _time(openSession.$1),
          end: _time(now),
          object: openSession.$2,
          open: true,
          minutes: mins(openSession.$1, now),
        ),
    ];
    final byObject = <String, double>{};
    for (final r in rows) {
      byObject[r.object] = _round1((byObject[r.object] ?? 0) + r.minutes);
    }
    return CloseupDay(
      totalMinutes: _round1(rows.fold(0.0, (a, r) => a + r.minutes)),
      byObject: byObject,
      sessions: rows,
      longestMinutes: rows.fold(0.0, (a, r) => r.minutes > a ? r.minutes : a),
    );
  }

  /// The last 24 hours of blinking ([openLowBlink]: a low-blink stretch going on now).
  EyesHistory eyes(double now, {double? openLowBlink}) {
    final since = now - _day;
    return EyesHistory(
      points: [
        for (final b in _buckets)
          if (b.t >= since) BlinkPoint(_time(b.t), b.rateN == 0 ? null : _round1(b.rateSum / b.rateN), b.partial),
      ],
      squints: [
        for (final t in _squints)
          if (t >= since) _time(t),
      ],
      lowBlink: [
        for (final (s, e) in _intervals['low_blink']!)
          if (e >= since) TimeSpan(_time(s), _time(e)),
        if (openLowBlink != null) TimeSpan(_time(openLowBlink), _time(now), open: true),
      ],
    );
  }

  // -- keeping it ---------------------------------------------------------------

  Map<String, dynamic> toJson() => {
    'intervals': {
      for (final e in _intervals.entries)
        e.key: [
          for (final (s, en) in e.value) [s, en],
        ],
    },
    'sessions': [for (final s in _sessions) s.toJson()],
    'points': [
      for (final (t, k, p) in _points) [t, k, p],
    ],
    'buckets': [for (final b in _buckets) b.toJson()],
    'squints': _squints,
  };

  void _load(Map<String, dynamic> j) {
    double n(Object? v) => (v as num).toDouble();
    try {
      for (final e in (j['intervals'] as Map<String, dynamic>? ?? {}).entries) {
        _intervals[e.key] = [for (final s in e.value as List) (n((s as List)[0]), n(s[1]))];
      }
      _sessions.addAll([
        for (final s in j['sessions'] as List? ?? []) CloseupSessionRecord.fromJson(s as Map<String, dynamic>),
      ]);
      _points.addAll([for (final p in j['points'] as List? ?? []) (n((p as List)[0]), p[1] as String, p[2] as int)]);
      _buckets.addAll([for (final b in j['buckets'] as List? ?? []) _Bucket.fromJson(b as Map<String, dynamic>)]);
      _squints.addAll([for (final t in j['squints'] as List? ?? []) n(t)]);
    } on Object {
      // A document from an older version: start over rather than crash.
      for (final l in _intervals.values) {
        l.clear();
      }
      _sessions.clear();
      _points.clear();
      _buckets.clear();
      _squints.clear();
    }
  }
}

double _round1(double v) => (v * 10).round() / 10;
