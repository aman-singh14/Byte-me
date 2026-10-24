// Follows objects across rear-camera frames and estimates how soon each one
// would reach the wearer. Pure Dart: no Flutter, no I/O, no identities.
//
// Time to contact comes from how fast a box grows. For something coming at
// the camera, its apparent size is proportional to 1 / distance, so
// d(ln size)/dt = speed / distance = 1 / time-to-contact. No calibration of
// distance or speed is needed.
//
// Size is the box's height, not its width or area: a walking person's width
// swings with every stride and arm swing, their height hardly changes. A box
// cut off by the image edge isn't measured on that axis, since it "grows" as
// more of the object comes into view. When the top or bottom is cut off,
// width is used instead, but only for rigid things like vehicles: a person
// or dog that fills the frame has no reliable size (leaning, turning), so
// they get no camera estimate up close (the reflex and social tap cover
// that range). Tiny boxes aren't measured either: at a few pixels, one pixel
// of jitter looks like fast growth.

import 'dart:math' as math;

import '../net/protocol.dart';

/// A box in the rear camera's image, normalized 0..1 (image coordinates, not
/// mirrored).
class Box {
  const Box(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;

  double get width => right - left;
  double get height => bottom - top;
  double get area => math.max(0.0, width) * math.max(0.0, height);
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  /// Apparent size. Grows as 1 / distance.
  double get size => math.sqrt(area);

  /// Within [margin] of the image's top or bottom edge, so its height is cut.
  bool cutVertically([double margin = 0.01]) => top <= margin || bottom >= 1 - margin;
  bool cutHorizontally([double margin = 0.01]) => left <= margin || right >= 1 - margin;

  /// Overlap divided by union, 0..1.
  double iou(Box o) {
    final w = math.min(right, o.right) - math.max(left, o.left);
    final h = math.min(bottom, o.bottom) - math.max(top, o.top);
    if (w <= 0 || h <= 0) return 0;
    final overlap = w * h;
    return overlap / (area + o.area - overlap);
  }

  double centerDistance(Box o) {
    final dx = centerX - o.centerX, dy = centerY - o.centerY;
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  String toString() =>
      'Box(${left.toStringAsFixed(2)}, ${top.toStringAsFixed(2)}, '
      '${right.toStringAsFixed(2)}, ${bottom.toStringAsFixed(2)})';
}

/// One detection in one frame.
class Sighting {
  const Sighting({required this.label, required this.confidence, required this.box});
  final String label;
  final double confidence;
  final Box box;
}

/// One object followed across frames.
class Track {
  Track._(this.id, this.label, this.box, this.confidence, DateTime at, {required this.behindSince})
    : lastSeen = at,
      presence = id {
    _measure(at);
  }

  final int id;
  final String label;
  Box box;
  double confidence;
  DateTime lastSeen;

  /// When this track, or one it continues, was first seen. A new track
  /// continues a lost one of the same class and about the same size that
  /// vanished a few seconds earlier (a missed detection, a head turn). Used
  /// for "possibly following". It describes presence, never identity.
  DateTime behindSince;

  /// The id of the first track in this presence (this track, or the
  /// earliest one it continues).
  int presence;

  /// Set once "possibly following" has been reported for this presence.
  bool followingReported = false;

  /// Whole minutes behind when it was last reported, for the per-minute
  /// updates.
  int followingMinutes = 0;

  final _heights = _SizeHistory();
  final _widths = _SizeHistory();

  /// Which side of the wearer this is on.
  WearerSide get side => wearerSideFromRearImageX(box.centerX);

  /// Seconds until it reaches the wearer at its current approach speed, or
  /// null if it is not approaching (or not seen long enough to tell).
  /// Height decides when it can; width only when the height is cut off, and
  /// only for rigid objects.
  double? get secondsToContact {
    if (_heights.ready) return _heights.secondsToContact;
    if (_widths.ready && !Tracker.flexible.contains(label)) return _widths.secondsToContact;
    return null;
  }

  /// What the estimate is, or why there isn't one, for the debug readout:
  /// "3.2 s", "not closing", "cut off" (a person or dog filling the frame),
  /// "too small", or "measuring" (not enough history yet).
  String get debugReason {
    final s = secondsToContact;
    if (s != null) return '${s.toStringAsFixed(1)} s';
    final flexible = Tracker.flexible.contains(label);
    if (_heights.ready || (_widths.ready && !flexible)) return 'not closing';
    if (box.cutVertically() && flexible) return 'cut off';
    if (box.height < Tracker.minSize) return 'too small';
    return 'measuring';
  }

  void _see(DateTime at, Sighting s) {
    box = s.box;
    confidence = s.confidence;
    lastSeen = at;
    _measure(at);
  }

  // A cut-off or tiny axis starts over, so a history never mixes good and
  // bad measurements.
  void _measure(DateTime at) {
    box.cutVertically() || box.height < Tracker.minSize ? _heights.clear() : _heights.add(at, box.height);
    box.cutHorizontally() || box.width < Tracker.minSize ? _widths.clear() : _widths.add(at, box.width);
  }

  void _resetMotion() {
    _heights.clear();
    _widths.clear();
  }
}

/// Recent sizes of a box along one axis, for fitting time to contact.
class _SizeHistory {
  final _samples = <(DateTime, double)>[]; // (time, ln size)

  void add(DateTime at, double size) {
    _samples.add((at, math.log(math.max(size, 1e-4))));
    _samples.removeWhere((s) => at.difference(s.$1) > Tracker.sampleWindow);
  }

  void clear() => _samples.clear();

  /// Enough history to say whether it is approaching.
  bool get ready =>
      _samples.length >= Tracker.minSamples && _samples.last.$1.difference(_samples.first.$1) >= Tracker.minSpan;

  double? get secondsToContact {
    if (!ready) return null;

    // Least-squares line through ln(size) over time.
    final first = _samples.first.$1;
    final ts = [for (final (t, _) in _samples) t.difference(first).inMicroseconds / 1e6];
    final ys = [for (final (_, y) in _samples) y];
    final tMean = ts.reduce((a, b) => a + b) / ts.length;
    final yMean = ys.reduce((a, b) => a + b) / ys.length;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < ts.length; i++) {
      num += (ts[i] - tMean) * (ys[i] - yMean);
      den += (ts[i] - tMean) * (ts[i] - tMean);
    }
    final growthPerSecond = num / den;
    if (growthPerSecond <= 1 / Tracker.maxSecondsToContact) return null;

    // Steady growth fits a line well; a box wobbling (stride, jitter) doesn't.
    var residual = 0.0, total = 0.0;
    for (var i = 0; i < ts.length; i++) {
      final predicted = yMean + growthPerSecond * (ts[i] - tMean);
      residual += (ys[i] - predicted) * (ys[i] - predicted);
      total += (ys[i] - yMean) * (ys[i] - yMean);
    }
    if (1 - residual / total < Tracker.minFit) return null;

    // The fit gives the time to contact at the middle of the window; it is
    // that much less by the newest sample.
    return math.max(0.0, 1 / growthPerSecond - (ts.last - tMean));
  }
}

/// Matches each frame's sightings to the objects seen in earlier frames.
class Tracker {
  /// A sighting continues a track of the same class if their boxes overlap
  /// this much, or their centers are this close (fast or small objects).
  static const matchIou = 0.2;
  static const matchCenter = 0.1;

  /// A track not seen for this long is gone.
  static const lostAfter = Duration(seconds: 1);

  /// A new track continues a lost one ([Track.behindSince]) within this time.
  static const continueWithin = Duration(seconds: 10);

  /// Time to contact is fitted over this much recent history.
  static const sampleWindow = Duration(seconds: 1);
  static const minSamples = 4;
  static const minSpan = Duration(milliseconds: 400);

  /// Slower approaches than this are treated as not approaching (box jitter).
  static const maxSecondsToContact = 15.0;

  /// How well the growth must fit a straight line (R², 0..1) to count.
  static const minFit = 0.75;

  /// Sides smaller than this (share of the image, about 12 px of 240) aren't
  /// measured: too few pixels to tell growth from jitter.
  static const minSize = 0.05;

  /// Classes whose width changes with pose, so only height measures them.
  static const flexible = {'person', 'dog'};

  final _tracks = <Track>[];
  final _lost = <Track>[];
  int _nextId = 1;

  List<Track> get tracks => List.unmodifiable(_tracks);

  void update(DateTime at, List<Sighting> sightings) {
    prune(at);

    // Greedy matching, best pairs first.
    final pairs = <(double, int, int)>[];
    for (var ti = 0; ti < _tracks.length; ti++) {
      for (var si = 0; si < sightings.length; si++) {
        final track = _tracks[ti], s = sightings[si];
        if (track.label != s.label) continue;
        final iou = track.box.iou(s.box), dist = track.box.centerDistance(s.box);
        if (iou >= matchIou || dist <= matchCenter) pairs.add((iou - dist, ti, si));
      }
    }
    pairs.sort((a, b) => b.$1.compareTo(a.$1));

    final matchedTracks = <int>{}, matchedSightings = <int>{};
    for (final (_, ti, si) in pairs) {
      if (matchedTracks.contains(ti) || matchedSightings.contains(si)) continue;
      _tracks[ti]._see(at, sightings[si]);
      matchedTracks.add(ti);
      matchedSightings.add(si);
    }
    for (var si = 0; si < sightings.length; si++) {
      if (!matchedSightings.contains(si)) _tracks.add(_newTrack(at, sightings[si]));
    }
  }

  /// Drops tracks that have not been seen for [lostAfter].
  void prune(DateTime at) {
    for (final t in _tracks.where((t) => at.difference(t.lastSeen) > lostAfter).toList()) {
      _tracks.remove(t);
      _lost.add(t);
    }
    _lost.removeWhere((t) => at.difference(t.lastSeen) > continueWithin);
  }

  /// Forgets approach history, keeping the tracks. Call when the image has
  /// jumped (head turn), so box sizes from before don't fake an approach.
  void resetMotion() {
    for (final t in _tracks) {
      t._resetMotion();
    }
  }

  Track _newTrack(DateTime at, Sighting s) {
    final track = Track._(_nextId++, s.label, s.box, s.confidence, at, behindSince: at);
    // Continue the earliest similar track that was lost recently.
    Track? continues;
    for (final lost in _lost) {
      final ratio = s.box.size / math.max(lost.box.size, 1e-4);
      if (lost.label != s.label || ratio < 0.5 || ratio > 2) continue;
      if (continues == null || lost.behindSince.isBefore(continues.behindSince)) continues = lost;
    }
    if (continues != null) {
      _lost.remove(continues);
      track.behindSince = continues.behindSince;
      track.presence = continues.presence;
      track.followingReported = continues.followingReported;
      track.followingMinutes = continues.followingMinutes;
    }
    return track;
  }
}
