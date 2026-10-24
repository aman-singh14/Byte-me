// Side quests: four daily goals the app measures on its own, always running.
// Each quest has three goals, and reaching one earns a star: up to 3 a quest
// and 12 a day. Stars add up Monday to Sunday for the friends leaderboard;
// only the day's star count leaves the phone. Progress starts over each day.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show IconData;
import 'package:flutter/foundation.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../net/protocol.dart';
import 'rings_source.dart';
import 'together_time.dart';

/// Nearer than this is phone (or book) distance. A plate on the table or
/// a friend across it is farther.
const phoneMaxCm = 45;

class SideQuest {
  const SideQuest({
    required this.id,
    required this.title,
    required this.blurb,
    required this.icon,
    required this.goals,
    required this.unit,
  });

  final String id;
  final String title;

  /// What counts.
  final String blurb;
  final IconData icon;

  /// One star at each, lowest first.
  final List<int> goals;

  /// "min"
  final String unit;

  int get maxStars => goals.length;

  /// Stars [progress] has earned.
  int starsFor(int progress) => goals.where((g) => progress >= g).length;

  /// The next goal after [progress], or null when every star is earned.
  int? nextGoal(int progress) {
    for (final g in goals) {
      if (progress < g) return g;
    }
    return null;
  }
}

const sideQuests = [
  SideQuest(
    id: 'look_up',
    title: 'Look up',
    blurb: 'Heads-up time today: looking farther than a screen.',
    icon: Symbols.eye_tracking_rounded,
    goals: [30, 60, 120],
    unit: 'min',
  ),
  SideQuest(
    id: 'golden_hour',
    title: 'Golden hour',
    blurb: 'Time outside between 5 and 8 pm.',
    icon: Symbols.wb_twilight_rounded,
    goals: [10, 20, 40],
    unit: 'min',
  ),
  SideQuest(
    id: 'phone_down_lunch',
    title: 'Phone-down lunch',
    blurb: 'Lunchtime, 11:30 to 2, with nothing held at phone distance.',
    icon: Symbols.restaurant_rounded,
    goals: [15, 30, 45],
    unit: 'min',
  ),
  SideQuest(
    id: 'hang_out',
    title: 'Hang out',
    blurb: 'Time with a friend nearby, counted by Together time.',
    icon: Symbols.diversity_3_rounded,
    goals: [15, 30, 60],
    unit: 'min',
  ),
];

/// The most stars a day can earn.
final maxStarsPerDay = sideQuests.fold(0, (n, q) => n + q.maxStars);

/// A side quest earned [gained] stars (usually one); [stars] is how many it
/// has now.
class StarEarned {
  const StarEarned(this.quest, this.stars, {this.gained = 1});
  final SideQuest quest;
  final int stars;
  final int gained;
}

class SideQuestStore extends ChangeNotifier {
  SideQuestStore({required this.rings, required Stream<SensMessage> sens, this.together, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _sens = sens.listen(_onSens);
    together?.addListener(_changed);
    rings.addListener(_changed);
  }

  final RingsSource rings;

  /// Minutes near friends, for Hang out.
  final TogetherTime? together;
  final DateTime Function() _clock;
  late final StreamSubscription<SensMessage> _sens;

  static const _key = 'side_quests_v2';

  /// Golden hour, local time: 5 pm to 8 pm.
  static const goldenFrom = 17, goldenTo = 20;

  /// Lunch, in minutes after midnight: 11:30 to 2 pm.
  static const lunchFrom = 11 * 60 + 30, lunchTo = 14 * 60;

  SharedPreferences? _prefs;

  // Today. Starts over when the day changes.
  String _day = '';
  Duration _golden = Duration.zero;
  Duration _lunch = Duration.zero;
  final _earned = <String, int>{}; // stars already announced, by quest
  DateTime? _lastSens;

  /// Stars per day ("2026-10-24"), for this week's total.
  final _byDay = <String, int>{};

  final _starred = StreamController<StarEarned>.broadcast();
  Stream<StarEarned> get starred => _starred.stream;

  Future<void> start() async {
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_key);
      if (saved != null) _load(jsonDecode(saved) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('SideQuestStore: could not load: $e');
    }
    _changed();
  }

  /// Today's progress, in the quest's unit.
  int progress(SideQuest q) {
    _rollDay();
    return switch (q.id) {
      'look_up' => rings.today.headsUpMinutes,
      'golden_hour' => _golden.inMinutes,
      'phone_down_lunch' => _lunch.inMinutes,
      'hang_out' => together?.minutesToday ?? 0,
      _ => 0,
    };
  }

  /// Stars earned today. Never goes down during the day, even if a source
  /// starts counting over (the app restarted).
  int stars(SideQuest q) {
    final s = q.starsFor(progress(q));
    final earned = _earned[q.id] ?? 0;
    return s > earned ? s : earned;
  }

  int get starsToday => sideQuests.fold(0, (n, q) => n + stars(q));

  /// Today's stars by quest id, for the server.
  Map<String, int> get starsByQuest => {for (final q in sideQuests) q.id: stars(q)};

  /// Stars from Monday through today.
  int get starsThisWeek {
    _rollDay();
    final now = _clock();
    final monday = _dayKey(DateTime(now.year, now.month, now.day - (now.weekday - 1)));
    var total = 0;
    for (final MapEntry(:key, :value) in _byDay.entries) {
      if (key.compareTo(monday) >= 0 && key != _day) total += value;
    }
    return total + starsToday;
  }

  void _onSens(SensMessage s) {
    final now = _clock();
    _rollDay();
    final last = _lastSens;
    _lastSens = now;
    if (last == null) return;
    var dt = now.difference(last);
    if (dt > const Duration(seconds: 1)) dt = const Duration(seconds: 1); // glasses were off
    final minute = now.hour * 60 + now.minute;
    final before = (_golden.inMinutes, _lunch.inMinutes);
    if (now.hour >= goldenFrom && now.hour < goldenTo && s.lux > outsideMinLux) _golden += dt;
    if (minute >= lunchFrom && minute < lunchTo && s.distCm > phoneMaxCm) _lunch += dt;
    if ((_golden.inMinutes, _lunch.inMinutes) != before) _changed();
  }

  void _changed() {
    _rollDay();
    for (final q in sideQuests) {
      final s = stars(q), before = _earned[q.id] ?? 0;
      if (s <= before) continue;
      _earned[q.id] = s;
      _starred.add(StarEarned(q, s, gained: s - before));
    }
    _byDay[_day] = starsToday;
    _save();
    notifyListeners();
  }

  void _rollDay() {
    final now = _clock();
    final day = _dayKey(now);
    if (day == _day) return;
    _day = day;
    _golden = _lunch = Duration.zero;
    _earned.clear();
    _lastSens = null;
    // Two weeks is plenty for "this week".
    final cutoff = _dayKey(now.subtract(const Duration(days: 14)));
    _byDay.removeWhere((d, _) => d.compareTo(cutoff) < 0);
  }

  static String _dayKey(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  void _load(Map<String, dynamic> j) {
    _day = j['day'] as String? ?? '';
    _golden = Duration(seconds: j['golden_s'] as int? ?? 0);
    _lunch = Duration(seconds: j['lunch_s'] as int? ?? 0);
    for (final MapEntry(:key, :value) in (j['earned'] as Map? ?? const {}).entries) {
      _earned[key as String] = value as int;
    }
    for (final MapEntry(:key, :value) in (j['by_day'] as Map? ?? const {}).entries) {
      _byDay[key as String] = value as int;
    }
  }

  void _save() => _prefs?.setString(
    _key,
    jsonEncode({
      'day': _day,
      'golden_s': _golden.inSeconds,
      'lunch_s': _lunch.inSeconds,
      'earned': _earned,
      'by_day': _byDay,
    }),
  );

  @override
  void dispose() {
    _sens.cancel();
    together?.removeListener(_changed);
    rings.removeListener(_changed);
    _starred.close();
    super.dispose();
  }
}
