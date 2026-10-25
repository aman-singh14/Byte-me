// Near-work from the FRONT camera: which screen or book is in front of the
// wearer, how close, close-up sessions and heads-up stretches. A port of
// backend/nearwork.py with the product's settings.
//
//   YOLO (laptop, cell phone, tv, keyboard, book) -> distance from apparent size
//   -> CloseupTracker: sessions closer than a per-object threshold
//   -> HeadsUpTracker: stretches with no near-work looked at, glasses on: only
//      objects within [nearWorkMaxCm] where the eye camera says the wearer is
//      looking (left / center / right) count; without gaze, any within reach
//
// distance_cm = k / (longest side / frame width), with k from the lens
// (0.5 / tan(hfov / 2) x the object's real longest side) until calibrated
// at a known distance.

import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../vision/detector.dart';

/// COCO label -> (kind, real longest side in cm, too-close threshold in cm).
const nearClasses = {
  'cell phone': ('phone', 15.0, 30.0),
  'book': ('book', 24.0, 30.0),
  'laptop': ('laptop', 32.0, 50.0),
  'tv': ('tv', 100.0, 50.0),
  'keyboard': ('keyboard', 44.0, 50.0),
};

/// Near-work further away than this (a TV across the room) doesn't stop heads-up time.
const nearWorkMaxCm = 100.0;

class NearObject {
  const NearObject(this.label, this.distanceCm, this.frac, [this.box = const Rect.fromLTRB(0, 0, 1, 1)]);
  final String label;
  final double distanceCm;
  final double frac; // longest side / frame width
  final Rect box; // where in the front picture, 0..1
  String get kind => nearClasses[label]!.$1;
  double get thresholdCm => nearClasses[label]!.$3;
  bool get close => distanceCm < thresholdCm;
}

class NearWorkEstimator {
  NearWorkEstimator({Map<String, double>? k, this.hfovDeg = 65}) : k = {...?k};

  /// Calibrated k per COCO label.
  final Map<String, double> k;
  final double hfovDeg;

  /// The last frame's near-work objects, nearest first.
  List<NearObject> last = const [];

  double _k(String label) => k[label] ?? 0.5 / math.tan(hfovDeg * math.pi / 360) * nearClasses[label]!.$2;

  /// [aspect]: the frame's height / width (boxes are 0..1 of each side).
  List<NearObject> measure(List<Detection> dets, {double aspect = 0.75}) {
    final out = <NearObject>[
      for (final d in dets)
        if (nearClasses.containsKey(d.label) && d.box.width > 0)
          NearObject(
            d.label,
            _k(d.label) / math.max(d.box.width, d.box.height * aspect),
            math.max(d.box.width, d.box.height * aspect),
            d.box,
          ),
    ]..sort((a, b) => a.distanceCm.compareTo(b.distanceCm));
    return last = out;
  }

  /// Calibrate one object type with what is in view now, held [knownCm] away.
  /// Returns the new k, or throws [StateError] with a readable message.
  double calibrate(String kindOrLabel, double knownCm) {
    final label = nearClasses.entries.where((e) => e.key == kindOrLabel || e.value.$1 == kindOrLabel).firstOrNull?.key;
    if (label == null) throw StateError('Unknown object $kindOrLabel.');
    final seen = last.where((o) => o.label == label);
    if (seen.isEmpty) throw StateError('No ${nearClasses[label]!.$1} in view right now.');
    final biggest = seen.reduce((a, b) => b.frac > a.frac ? b : a);
    return k[label] = biggest.frac * knownCm;
  }
}

/// The near-work the wearer is looking at: within [maxCm], and overlapping [columns],
/// the gaze region's left..right in the front picture (0..1). Without gaze ([columns]
/// null) everything within reach counts.
List<NearObject> lookedAt(List<NearObject> objs, (double, double)? columns, {double maxCm = nearWorkMaxCm}) => [
  for (final o in objs)
    if (o.distanceCm <= maxCm && (columns == null || (o.box.right > columns.$1 && o.box.left < columns.$2))) o,
];

class CloseupSessionRecord {
  const CloseupSessionRecord(this.start, this.end, this.object, this.minCm, this.avgCm);
  final double start, end;
  final String object;
  final double? minCm, avgCm;

  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'object': object, 'min_cm': minCm, 'avg_cm': avgCm};
  static CloseupSessionRecord fromJson(Map<String, dynamic> j) => CloseupSessionRecord(
    (j['start'] as num).toDouble(),
    (j['end'] as num).toDouble(),
    j['object'] as String,
    (j['min_cm'] as num?)?.toDouble(),
    (j['avg_cm'] as num?)?.toDouble(),
  );
}

class _Open {
  _Open(this.start, this.object) : last = start;
  final double start;
  final String object;
  double last;
  final dists = <double>[];
  (String, double)? other;
}

/// Close-up sessions: near-work closer than its threshold. A session ends
/// [gapS] after the last close sighting (missed detections don't split it), a
/// different object close for [switchS] splits it, and sessions shorter than
/// [minS] are glances and dropped.
class CloseupTracker {
  CloseupTracker({this.gapS = 5, this.switchS = 5, this.minS = 10});
  final double gapS, switchS, minS;
  _Open? _cur;

  /// One front sample: the nearest near-work object, if any. Returns finished
  /// sessions and whether one started.
  (List<CloseupSessionRecord>, bool) update(double t, NearObject? nearest) {
    final done = <CloseupSessionRecord>[];
    var started = false;
    var cur = _cur;
    if (cur != null && t - cur.last > gapS) {
      done.addAll(_close(cur.last));
      cur = null;
    }
    if (nearest != null && nearest.close) {
      final obj = nearest.kind;
      if (cur == null) {
        cur = _cur = _Open(t, obj);
        started = true;
      } else if (obj != cur.object) {
        final other = cur.other;
        if (other == null || other.$1 != obj) {
          cur.other = (obj, t);
        } else if (t - other.$2 >= switchS) {
          done.addAll(_close(other.$2));
          cur = _cur = _Open(other.$2, obj);
          started = true;
        }
      } else {
        cur.other = null;
      }
      cur.last = t;
      if (obj == cur.object) cur.dists.add(nearest.distanceCm);
    }
    return (done, started);
  }

  List<CloseupSessionRecord> _close(double end) {
    final cur = _cur;
    _cur = null;
    if (cur == null || end - cur.start < minS) return const [];
    final d = cur.dists;
    return [
      CloseupSessionRecord(
        cur.start,
        end,
        cur.object,
        d.isEmpty ? null : _round1(d.reduce(math.min)),
        d.isEmpty ? null : _round1(d.reduce((a, b) => a + b) / d.length),
      ),
    ];
  }

  /// The front camera went away: end the open session.
  List<CloseupSessionRecord> flush(double t) => _cur == null ? const [] : _close(math.min(t, _cur!.last));

  /// The open session's start and object.
  (double, String)? get open => _cur == null ? null : (_cur!.start, _cur!.object);
}

/// Heads-up = no near-work in view for at least [minS] while the glasses are
/// worn. The whole stretch counts once it gets there (from the last near-work
/// sighting); it ends at the next sighting or when the glasses come off.
class HeadsUpTracker {
  HeadsUpTracker({this.minS = 20});
  final double minS;
  double? _lastNearwork;
  double? activeSince;

  /// A finished stretch (start, end), when one just ended.
  (double, double)? update(double t, bool nearwork, bool worn) {
    if (!worn) {
      final f = _end(t);
      _lastNearwork = null;
      return f;
    }
    _lastNearwork ??= t; // just put on: count from now
    if (nearwork) {
      final f = _end(t);
      _lastNearwork = t;
      return f;
    }
    if (activeSince == null && t - _lastNearwork! >= minS) activeSince = _lastNearwork;
    return null;
  }

  (double, double)? _end(double t) {
    final s = activeSince;
    activeSince = null;
    return s == null ? null : (s, t);
  }

  (double, double)? flush(double t) => _end(t);
}

double _round1(double v) => (v * 10).round() / 10;
