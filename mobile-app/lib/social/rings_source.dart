// Today's rings, as the social features need them.
//
// The rings themselves (Heads-up and Outside, Phase 3 step 10) are built
// separately. That code implements [RingsSource]; until it lands,
// [StandInRings] counts minutes from the frame's sensor samples so the
// social features work end to end. Only the percentages ever leave the
// phone.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/protocol.dart';

/// Heads-up: looking at something farther than this (not a screen).
const headsUpMinCm = 100;

/// Outside: brighter than indoor light. Shade outdoors is ~1,000+ lux,
/// a bright office ~500.
const outsideMinLux = 1000;

class RingsToday {
  const RingsToday({
    required this.headsUpMinutes,
    required this.outsideMinutes,
    this.headsUpGoal = 180,
    this.outsideGoal = 120,
  });

  final int headsUpMinutes;
  final int outsideMinutes;
  final int headsUpGoal;
  final int outsideGoal;

  int get headsUpPercent => _percent(headsUpMinutes, headsUpGoal);
  int get outsidePercent => _percent(outsideMinutes, outsideGoal);

  static int _percent(int minutes, int goal) => goal <= 0 ? 0 : (minutes * 100 / goal).round().clamp(0, 100);
}

abstract class RingsSource implements Listenable {
  RingsToday get today;
}

/// Counts heads-up and outside time from sensor samples, in memory, for
/// today only. A stand-in until the real rings code replaces it.
class StandInRings extends ChangeNotifier implements RingsSource {
  StandInRings(Stream<SensMessage> sens, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    _sub = sens.listen(add);
  }

  final DateTime Function() _clock;
  late final StreamSubscription<SensMessage> _sub;

  DateTime? _day;
  DateTime? _last;
  Duration _headsUp = Duration.zero;
  Duration _outside = Duration.zero;

  @override
  RingsToday get today => RingsToday(headsUpMinutes: _headsUp.inMinutes, outsideMinutes: _outside.inMinutes);

  @visibleForTesting
  void add(SensMessage s) {
    final now = _clock();
    final day = DateTime(now.year, now.month, now.day);
    if (day != _day) {
      _day = day;
      _headsUp = _outside = Duration.zero;
      _last = null;
    }
    final last = _last;
    _last = now;
    if (last == null) return;
    // Count the time since the previous sample, capped so a gap (glasses
    // off) doesn't count.
    var dt = now.difference(last);
    if (dt > const Duration(seconds: 1)) dt = const Duration(seconds: 1);
    final before = today;
    if (s.distCm > headsUpMinCm) _headsUp += dt;
    if (s.lux > outsideMinLux) _outside += dt;
    final after = today;
    if (after.headsUpMinutes != before.headsUpMinutes || after.outsideMinutes != before.outsideMinutes) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
