// Openness over time -> blinks, blink rate, partial blinks, squints and
// low-blink stretches: backend/eye_tracking.py BlinkSquintDetector,
// LowBlinkMonitor and EyeTracker, with the product's settings
// (backend/config.yaml eye:). Times are seconds since the epoch, as there.

import 'dart:math' as math;

import 'image_ops.dart';
import 'pupil.dart';

sealed class EyeEvent {
  const EyeEvent();
}

class Calibrated extends EyeEvent {
  const Calibrated(this.baseline);
  final double baseline;
}

class Blink extends EyeEvent {
  const Blink(this.seconds);
  final double seconds;
}

class PartialBlink extends EyeEvent {
  const PartialBlink(this.seconds);
  final double seconds;
}

class SquintStart extends EyeEvent {
  const SquintStart();
}

class SquintEnd extends EyeEvent {
  const SquintEnd(this.seconds);
  final double seconds;
}

class BlinkSquintDetector {
  BlinkSquintDetector({
    this.calibrationS = 5.0,
    this.defaultBaseline = 1.0,
    this.blinkRatio = 0.65,
    this.blinkMinS = 0.08,
    this.blinkMaxS = 0.45,
    this.squintLow = 0.65,
    this.squintHigh = 0.85,
    this.squintMinS = 1.5,
    this.rateWindowS = 60,
    this.partialRatio = 0.85,
  }) : baseline = defaultBaseline;

  final double calibrationS, defaultBaseline, blinkRatio, blinkMinS, blinkMaxS;
  final double squintLow, squintHigh, squintMinS, rateWindowS, partialRatio;

  double baseline;
  bool calibrated = false;
  final _calib = <double>[];
  double? _calibUntil;
  bool _calibPending = true; // calibrate as soon as an eye shows up
  double? _closedSince;
  double? _squintSince;
  bool squinting = false;
  double? _dipSince, _dipMin;
  int partialBlinks = 0;
  final _blinks = <double>[];
  int totalBlinks = 0;
  double? _tStart;
  double? ratio;

  /// The calibration window starts at the next sample with an eye in view.
  void startCalibration() {
    _calib.clear();
    _calibUntil = null;
    _calibPending = true;
  }

  bool get calibrating => _calibPending || _calibUntil != null;

  /// One sample (openness null = no eye in view).
  List<EyeEvent> update(double? openness, double t) {
    _tStart ??= t;
    final events = <EyeEvent>[];
    if (openness == null) {
      _closedSince = null; // a lost eye is not a blink
      ratio = null;
      return _endSquint(t, events);
    }
    if (_calibPending) {
      _calibPending = false;
      _calibUntil = t + calibrationS;
    }
    if (_calibUntil != null && openness > 0) {
      _calib.add(openness);
      if (t >= _calibUntil!) {
        _calibUntil = null;
        if (_calib.length >= 10) {
          // Drop the lowest quarter: blinks during calibration should not lower the baseline.
          final vals = [..._calib]..sort();
          baseline = median(vals.sublist(vals.length ~/ 4));
          calibrated = true;
          events.add(Calibrated(baseline));
        } else {
          startCalibration(); // the eye was mostly out of view: try again
        }
      }
    }

    final r = ratio = openness / math.max(baseline, 1e-6);
    final closed = r < blinkRatio;
    if (closed) {
      _closedSince ??= t;
    } else if (_closedSince != null) {
      final dur = t - _closedSince!;
      _closedSince = null;
      if (dur >= blinkMinS && dur <= blinkMaxS) {
        _blinks.add(t);
        totalBlinks++;
        events.add(Blink(dur));
      }
    }

    if (r < partialRatio) {
      _dipSince ??= t;
      _dipMin = math.min(_dipMin ?? r, r);
    } else if (_dipSince != null) {
      final dur = t - _dipSince!, low = _dipMin!;
      _dipSince = _dipMin = null;
      if (low >= blinkRatio && dur >= blinkMinS && dur <= blinkMaxS && !squinting && !calibrating) {
        partialBlinks++;
        events.add(PartialBlink(dur));
      }
    }

    if (calibrating) return _endSquint(t, events); // the baseline is a guess until calibrated
    if (r >= squintLow && r < squintHigh) {
      _squintSince ??= t;
      if (!squinting && t - _squintSince! >= squintMinS) {
        squinting = true;
        events.add(const SquintStart());
      }
    } else if (!closed) {
      _endSquint(t, events); // a blink in the middle of a squint does not end it
    }
    return events;
  }

  List<EyeEvent> _endSquint(double t, List<EyeEvent> events) {
    if (squinting) events.add(SquintEnd(t - _squintSince!));
    squinting = false;
    _squintSince = null;
    return events;
  }

  /// Blinks per minute over the last [rateWindowS], or null in the first 10 s.
  double? blinkRate(double t) {
    _blinks.removeWhere((b) => b < t - rateWindowS);
    if (_tStart == null) return null;
    final span = math.min(t - _tStart!, rateWindowS);
    if (span < 10) return null;
    return _blinks.length * 60.0 / span;
  }
}

/// Long stretches of low blinking: under [below] a minute for [minS] while the
/// eye is in view. Ends when the rate is back above below + 1, or the eye has
/// been out of view for [absentS].
class LowBlinkMonitor {
  LowBlinkMonitor({this.below = 10, this.minS = 300, this.absentS = 30});
  final double below, minS, absentS;

  double? since;
  bool active = false;
  double? _absentSince;

  /// A finished stretch (start, end), when one just ended.
  (double, double)? update(double t, double? rate, bool present) {
    if (!present) {
      _absentSince ??= t;
      return t - _absentSince! >= absentS ? _end(_absentSince!) : null;
    }
    _absentSince = null;
    if (rate == null) return null;
    if (rate < below) {
      since ??= t;
      if (!active && t - since! >= minS) active = true;
    } else if (rate >= below + 1) {
      return _end(t);
    }
    return null;
  }

  (double, double)? _end(double t) {
    final was = active, s = since;
    active = false;
    since = null;
    return was ? (s!, t) : null;
  }
}

/// What the eye tracker knows right now.
class EyeState {
  const EyeState({
    this.eyeDetected = false,
    this.calibrated = false,
    this.calibrating = true,
    this.blinkRate,
    this.blinksTotal = 0,
    this.partialBlinks = 0,
    this.squinting = false,
    this.pupil,
    this.vector,
  });

  final bool eyeDetected, calibrated, calibrating, squinting;
  final double? blinkRate;
  final int blinksTotal, partialBlinks;
  final (double, double)? pupil;
  final List<double>? vector;
}

/// Pupil features over time -> [EyeState] and events (eye_tracking.EyeTracker).
class EyeTracker {
  EyeTracker({BlinkSquintDetector? detector, this.presenceS = 2.0}) : detector = detector ?? BlinkSquintDetector();

  final BlinkSquintDetector detector;
  final double presenceS;
  double? _lastSeen;
  EyeState state = const EyeState();

  void calibrate() => detector.startCalibration();

  /// One frame's features ([f] null = no frame came: the camera is gone).
  List<EyeEvent> process(EyeFeatures? f, double t) {
    final seen = f != null && (f.pupil != null || f.openness > 0);
    if (seen) _lastSeen = t;
    final present = _lastSeen != null && t - _lastSeen! <= presenceS;
    // No pupil right after seeing one = the lid is closed (toward a blink).
    // No pupil for longer = the eye is not in view (glasses off): not a closure.
    final openness = seen ? f.openness : (present && f != null ? 0.0 : null);
    final events = detector.update(openness, t);
    final d = detector;
    state = EyeState(
      eyeDetected: present,
      calibrated: d.calibrated,
      calibrating: d.calibrating,
      blinkRate: d.blinkRate(t),
      blinksTotal: d.totalBlinks,
      partialBlinks: d.partialBlinks,
      squinting: d.squinting,
      pupil: f?.pupil,
      vector: f?.vector,
    );
    return events;
  }
}
