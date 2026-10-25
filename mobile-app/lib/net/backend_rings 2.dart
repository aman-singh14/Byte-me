// Today's rings for the social features (RingsSource), from the laptop backend.
//
// The backend measures Heads-up (no phone/screen/book in view, glasses on) and
// Outside (exposure-aware brightness) from the FRONT camera. While the backend
// isn't answering, the sensor-based stand-in keeps the social features working.

import 'package:flutter/foundation.dart';

import '../social/rings_source.dart';
import 'backend_link.dart';

class BackendRings extends ChangeNotifier implements RingsSource {
  BackendRings(this.backend, this.fallback) {
    backend.addListener(_changed);
    fallback.addListener(_changed);
    _last = today;
  }

  final BackendLink backend;
  final RingsSource fallback;
  late RingsToday _last;

  /// True while the numbers come from the backend (not the stand-in).
  bool get fromBackend => backend.status == BackendStatus.connected && backend.rings != null;

  @override
  RingsToday get today {
    final r = backend.rings;
    if (!fromBackend || r == null) return fallback.today;
    return RingsToday(
      headsUpMinutes: r.headsUp.minutes.round(),
      outsideMinutes: r.outside.minutes.round(),
      headsUpGoal: r.headsUp.goalMinutes > 0 ? r.headsUp.goalMinutes : 180,
      outsideGoal: r.outside.goalMinutes > 0 ? r.outside.goalMinutes : 120,
    );
  }

  // The backend link notifies on every poll; pass it on only when the rings change.
  void _changed() {
    final now = today;
    if (now.headsUpMinutes == _last.headsUpMinutes &&
        now.outsideMinutes == _last.outsideMinutes &&
        now.headsUpGoal == _last.headsUpGoal &&
        now.outsideGoal == _last.outsideGoal) {
      return;
    }
    _last = now;
    notifyListeners();
  }

  @override
  void dispose() {
    backend.removeListener(_changed);
    fallback.removeListener(_changed);
    super.dispose();
  }
}
