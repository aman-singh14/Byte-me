// Social taps, end to end: the detector notices someone who stopped close
// behind or beside the wearer; one rear snapshot asks Muse whether they're
// trying to get the wearer's attention; then AlertService taps the glasses
// on that side, logs it and tells the announcer.
//
// If Muse doesn't answer in time, or can't be asked, the tap goes out
// anyway: better to tap than to miss someone. During close-up work the tap
// is a "look up" tap, and turning toward that side within 10 s counts
// toward the Look up quest: the frame's gyro (which way), the back camera
// FPGA's gyro (how fast, not which way: any real turn counts), or the eye
// camera's gaze moving to that side.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../assist/vlm.dart';
import '../net/protocol.dart';
import '../settings/feature_flags.dart';
import '../social/side_quests.dart' show phoneMaxCm;
import 'alert_engine.dart';
import 'alert_service.dart';
import 'social_tap.dart';

class SocialTapService {
  SocialTapService({
    required this.alerts,
    required this.rearSnapshot,
    required this.vlm,
    required this.flags,
    required Stream<SensMessage> sens,
    Stream<double>? turns,
    this.gazeSide,
    this.backendCloseUp,
    this.onLookedUp,
    DateTime Function()? clock,
    SocialTapDetector? detector,
  }) : _clock = clock ?? DateTime.now,
       detector = detector ?? SocialTapDetector() {
    _frames = alerts.tracked.listen(_onFrame);
    _sens = sens.listen(_onSens);
    _turns = turns?.listen(_onTurn);
  }

  final AlertService alerts;

  /// The rear camera's newest JPEG, if any.
  final Uint8List? Function() rearSnapshot;
  final VlmService vlm;
  final FeatureFlags flags;

  /// Where the eye camera says the wearer looks: "left", "center", "right", or null.
  final String? Function()? gazeSide;

  /// True while the laptop backend has a close-up session open.
  final bool Function()? backendCloseUp;

  /// The wearer looked up after a "look up" tap.
  final VoidCallback? onLookedUp;
  final DateTime Function() _clock;
  final SocialTapDetector detector;

  /// Close-up work, from the frame's distance sensor alone: nearer than
  /// phone distance for this long.
  static const closeUpAfter = Duration(seconds: 10);

  /// A "look up" tap counts if the wearer turns toward it this soon.
  static const lookUpWithin = Duration(seconds: 10);

  late final StreamSubscription<DateTime> _frames;
  late final StreamSubscription<SensMessage> _sens;
  StreamSubscription<double>? _turns;
  bool _disposed = false;

  DateTime? _nearSince;
  DateTime? _lastSens;
  WearerSide? _lookUpSide;
  DateTime? _lookUpUntil;
  double _turnedLeft = 0;
  double _turnedAny = 0; // the FPGA's gyro: degrees turned, either way
  DateTime? _lastTurn;

  /// Close-up work right now (laptop backend or the frame's distance sensor).
  bool get closeUp {
    if (backendCloseUp?.call() == true) return true;
    final since = _nearSince;
    return since != null && _clock().difference(since) >= closeUpAfter;
  }

  void _onFrame(DateTime at) {
    if (!flags[Feature.socialTaps]) return;
    final busy = alerts.current != null || alerts.engine.isTurning(at);
    for (final c in detector.update(at, alerts.engine.tracker.tracks, busy: busy)) {
      unawaited(confirmAndTap(c.side));
    }
  }

  /// Asks Muse (if that's on), then taps. Public for tests and the mock.
  Future<void> confirmAndTap(WearerSide side) async {
    final lookUp = flags[Feature.lookUpNudge] && closeUp;
    String? action;
    final snapshot = flags[Feature.socialTapCheck] ? rearSnapshot() : null;
    if (snapshot != null) {
      try {
        final answer = await vlm.ask(VlmFeature.socialConfirm, images: [VlmImage.rear(snapshot)]);
        if (answer['engaging'] == false) {
          debugPrint('SocialTaps: not engaging (${answer['action']}), no tap');
          return;
        }
        if (answer['action'] is String) action = answer['action'] as String;
      } on VlmUnavailable catch (e) {
        debugPrint('SocialTaps: no Muse answer (${e.message}), tapping anyway');
      }
    }
    if (_disposed) return;
    final tapped = alerts.raiseSocialTap(SocialTapped(side, action: action, lookUp: lookUp));
    if (tapped && lookUp) {
      _lookUpSide = side;
      _lookUpUntil = _clock().add(lookUpWithin);
      _turnedLeft = _turnedAny = 0;
    }
  }

  void _onSens(SensMessage s) {
    final now = _clock();
    if (s.distCm < phoneMaxCm) {
      _nearSince ??= now;
    } else {
      _nearSince = null;
    }

    final last = _lastSens;
    _lastSens = now;
    final side = _lookUpPending(now);
    if (side == null || last == null) return;
    if (gazeSide?.call() == side.name) return _lookedUp(); // eyes moved to that side
    final dt = math.min(now.difference(last).inMicroseconds / 1e6, 0.2); // cap gaps from dropped samples
    _turnedLeft += s.yawRate * dt;
    final toward = switch (side) {
      WearerSide.left => _turnedLeft,
      WearerSide.right => -_turnedLeft,
      WearerSide.behind => _turnedLeft.abs(),
    };
    if (toward >= AlertEngine.glanceDegrees) _lookedUp();
  }

  /// The back camera FPGA's turn rate (deg/s, which way unknown).
  void _onTurn(double rate) {
    final now = _clock();
    final last = _lastTurn;
    _lastTurn = now;
    if (_lookUpPending(now) == null || last == null) return;
    _turnedAny += rate.abs() * math.min(now.difference(last).inMicroseconds / 1e6, 0.5);
    if (_turnedAny >= AlertEngine.glanceDegrees) _lookedUp();
  }

  /// The side of a "look up" tap still waiting for the wearer to turn, if any.
  WearerSide? _lookUpPending(DateTime now) {
    final until = _lookUpUntil;
    if (until != null && now.isAfter(until)) _lookUpSide = null;
    return _lookUpSide;
  }

  void _lookedUp() {
    _lookUpSide = null;
    debugPrint('SocialTaps: looked up');
    onLookedUp?.call();
  }

  void dispose() {
    _disposed = true;
    _frames.cancel();
    _sens.cancel();
    _turns?.cancel();
  }
}
