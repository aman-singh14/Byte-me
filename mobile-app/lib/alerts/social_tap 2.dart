// Decides when someone has stopped close behind or beside the wearer, the
// moment for a social tap. Pure Dart, like the alert engine: every input
// carries its time.
//
// A social tap needs a person who came closer (their box grew), is now
// within about 1.5 m, and has stayed there, steady, for a whole second: their
// box's size hardly changed over that second. Someone
// rushing in stays the alert engine's business: no tap while any safety
// alert is up or the head is turning. One tap per person (presence) a minute.
//
// "Within 1.5 m" comes from the box: the rear camera sees about 1.3 m of
// height at 1.5 m, so an adult's box fills most of the image's height, or
// is cut off, and is at least a fifth of its width (shoulders and arms).

import 'dart:math' as math;

import '../net/protocol.dart';
import 'tracker.dart';

/// Someone stopped on [side]; [presence] is the track presence (no identity).
class SocialCandidate {
  const SocialCandidate({required this.side, required this.presence});
  final WearerSide side;
  final int presence;

  @override
  String toString() => 'SocialCandidate(${side.name}, presence $presence)';
}

class SocialTapDetector {
  /// Close: the box is at least this tall, or cut at the top or bottom...
  static const nearHeight = 0.75;

  /// ...and at least this wide (shares of the image).
  static const nearWidth = 0.2;

  /// It must have grown by this much since it was first seen (came closer).
  static const approachGrowth = 1.25;

  /// And stayed close and steady this long.
  static const dwell = Duration(seconds: 1);

  /// Steady: over [dwell], the largest size is at most this much more than
  /// the smallest (arm swing moves a cut-off box's width by about 10%).
  static const steadyChange = 0.2;

  /// One tap per presence this often.
  static const cooldown = Duration(seconds: 60);

  final _states = <int, _PersonState>{}; // by presence, so a re-found track keeps its history
  final _lastTap = <int, DateTime>{};

  /// The tracker's [tracks] after a detection frame at [at]. [busy] is true
  /// while a safety alert is up or the head is turning.
  List<SocialCandidate> update(DateTime at, List<Track> tracks, {bool busy = false}) {
    final out = <SocialCandidate>[];
    for (final t in tracks) {
      if (t.label != 'person' || t.lastSeen != at) continue;
      final size = t.box.size;
      final s = _states[t.presence] ??= _PersonState(size);
      s.lastSeen = at;
      final near = (t.box.height >= nearHeight || t.box.cutVertically()) && t.box.width >= nearWidth;
      final approached = size >= s.firstSize * approachGrowth;
      if (busy || !near || !approached) {
        s.recent.clear(); // the dwell starts over
        continue;
      }
      s.recent.add((at, size));
      s.recent.removeWhere((r) => at.difference(r.$1) > dwell);
      // The samples must cover the whole second (frames come about every 100 ms).
      if (at.difference(s.recent.first.$1) < dwell - const Duration(milliseconds: 150)) continue;
      final sizes = s.recent.map((r) => r.$2);
      if (sizes.reduce(math.max) > sizes.reduce(math.min) * (1 + steadyChange)) continue;
      final last = _lastTap[t.presence];
      if (last != null && at.difference(last) < cooldown) continue;
      _lastTap[t.presence] = at;
      s.recent.clear();
      out.add(SocialCandidate(side: t.side, presence: t.presence));
    }
    _states.removeWhere((_, s) => at.difference(s.lastSeen) > Tracker.continueWithin);
    _lastTap.removeWhere((_, when) => at.difference(when) > cooldown * 2);
    return out;
  }
}

class _PersonState {
  _PersonState(double size) : firstSize = math.max(size, 1e-4);
  final double firstSize;
  DateTime lastSeen = DateTime.fromMillisecondsSinceEpoch(0);

  /// (time, size) while close, over the last [SocialTapDetector.dwell].
  final recent = <(DateTime, double)>[];
}
