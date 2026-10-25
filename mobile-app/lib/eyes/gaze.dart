// Gaze (left / center / right) from the pupil, mapped onto the FRONT
// camera's picture: backend/gaze.py with the product's settings. The eye and
// front cameras are both fixed to the glasses, so where the eye points picks
// a part of what the front camera sees.
//
// Calibration: "look left / straight ahead / right", 3 s each. The first
// 0.5 s of each step is skipped (the eye is still moving) and frames without
// a pupil are ignored; each centre is the median of the rest. Without one,
// default centres are used and [calibrated] is false.

import 'dart:math' as math;

import 'image_ops.dart';
import 'pupil.dart';

const gazeRegions = ['left', 'center', 'right'];
const gazePrompts = {'left': 'Look left', 'center': 'Look straight ahead', 'right': 'Look right'};

String gazePrompt(String step) => gazePrompts[step] ?? step;

/// FRONT frame columns per region (0 = left edge, 1 = right edge), ~15% overlap.
const regionColumns = {'left': (0.0, 0.41), 'center': (0.26, 0.74), 'right': (0.59, 1.0)};

class GazeTracker {
  GazeTracker({
    Map<String, dynamic>? saved,
    this.say,
    this.onSaved,
    this.stepS = 3.0,
    this.settleS = 0.5,
    this.windowS = 0.5,
    this.hysteresis = 0.15,
    this.yWeight = 1.0,
  }) {
    final s = saved;
    if (s != null && gazeRegions.every((r) => s[r] is List)) {
      for (final r in gazeRegions) {
        centroids[r] = [for (final v in s[r] as List) (v as num).toDouble()];
      }
      if (s['scale'] is List) scale = [for (final v in s['scale'] as List) (v as num).toDouble()];
      calibrated = true;
    }
  }

  /// Says the calibration prompts.
  final void Function(String)? say;

  /// Gets the new calibration to keep.
  final void Function(Map<String, dynamic>)? onSaved;
  final double stepS, settleS, windowS, hysteresis, yWeight;

  final centroids = <String, List<double>>{
    'left': [-0.25, 0.0],
    'center': [0.0, 0.0],
    'right': [0.25, 0.0],
  };

  /// How much each feature normally wobbles for this wearer (position + shape calibrations).
  List<double>? scale;
  bool calibrated = false;
  String? _current; // hysteresis output
  final _history = <(double, String)>[];
  String? smoothed;

  final _steps = <String>[];
  (String, double, List<List<double>>)? _step;
  final _cal = <String, List<List<double>>>{};

  void startCalibration() {
    _steps
      ..clear()
      ..addAll(gazeRegions);
    _step = null;
    _cal.clear();
  }

  bool get calibrating => _step != null || _steps.isNotEmpty;

  /// The step being calibrated ("left", ...), or null.
  String? get calibrationStep => _step?.$1 ?? (_steps.isEmpty ? null : _steps.first);

  void _advance(List<double>? pupil, double t) {
    final step = _step;
    if (step == null) {
      if (_steps.isEmpty) return;
      _step = (_steps.first, t, []);
      say?.call(gazePrompts[_steps.first]!);
      return;
    }
    final (region, t0, samples) = step;
    if (pupil != null && t - t0 >= settleS) samples.add(pupil);
    if (t - t0 < stepS) return;
    _steps.removeAt(0);
    _step = null;
    if (samples.length >= 3) {
      // the median of every number: one odd frame can't move it
      centroids[region] = [
        for (var k = 0; k < samples.first.length; k++) median([for (final s in samples) s[k]]),
      ];
      _cal[region] = samples;
    }
    if (_steps.isEmpty) _finish();
  }

  /// How much each number wobbles within a direction, pooled over the three; a feature that sat
  /// perfectly still can't dominate (the floors).
  static List<double> scaleFromSamples(Map<String, List<List<double>>> byClass) {
    final dims = byClass.values.first.first.length;
    final pooled = List.filled(dims, 0.0);
    for (final samples in byClass.values) {
      for (var k = 0; k < dims; k++) {
        final col = [for (final s in samples) s[k]];
        final med = median(col);
        final mad = median([for (final v in col) (v - med).abs()]) * 1.4826;
        pooled[k] += mad * mad / byClass.length;
      }
    }
    final spread = [for (final v in pooled) math.sqrt(v)];
    final floors = dims == featureFloors.length ? featureFloors : List.filled(dims, 0.5 * median(spread) + 1e-6);
    return [for (var k = 0; k < dims; k++) math.max(spread[k], floors[k])];
  }

  void _finish() {
    calibrated = true;
    final dims = {for (final c in centroids.values) c.length};
    if (_cal.length == gazeRegions.length) scale = dims.length == 1 && dims.first > 2 ? scaleFromSamples(_cal) : null;
    onSaved?.call({for (final e in centroids.entries) e.key: e.value, 'scale': ?scale});
    _current = smoothed = null;
    _history.clear();
    say?.call('Gaze calibrated');
  }

  bool _shaped(List<double> v) =>
      scale != null && v.length == scale!.length && centroids.values.every((c) => c.length == scale!.length);

  double _distance(List<double> v, String region, bool shaped) {
    final c = centroids[region]!;
    if (shaped) {
      var s = 0.0;
      for (var k = 0; k < v.length; k++) {
        final d = (v[k] - c[k]) / scale![k];
        s += d * d;
      }
      return math.sqrt(s);
    }
    final dx = v[0] - c[0], dy = yWeight * (v[1] - c[1]);
    return math.sqrt(dx * dx + dy * dy);
  }

  double _span(bool shaped) =>
      shaped ? _distance(centroids['left']!, 'right', true) : (centroids['left']![0] - centroids['right']![0]).abs();

  /// Nearest centre, kept unless another is closer by more than [hysteresis] x the left-right span.
  String classify(List<double> pupil) {
    final shaped = _shaped(pupil);
    double dist(String r) => _distance(pupil, r, shaped);
    var best = gazeRegions.reduce((a, b) => dist(b) < dist(a) ? b : a);
    final cur = _current;
    if (cur != null && best != cur && dist(cur) - dist(best) < hysteresis * _span(shaped)) best = cur;
    return _current = best;
  }

  /// Every eye frame. [pupil]: position + shape ([PupilFix.vector]), or (x, y), or null.
  String? update(List<double>? pupil, double t) {
    if (calibrating) _advance(pupil, t);
    if (pupil != null && !calibrating) _history.add((t, classify(pupil)));
    _history.removeWhere((h) => h.$1 < t - windowS);
    if (_history.isNotEmpty) {
      final counts = <String, int>{};
      for (final (_, label) in _history) {
        counts[label] = (counts[label] ?? 0) + 1;
      }
      final top = counts.entries.reduce((a, b) => b.value > a.value ? b : a);
      // keep the previous answer on a tie, so it doesn't flicker
      if (smoothed == null || (counts[smoothed] ?? 0) < top.value) smoothed = top.key;
    }
    return smoothed;
  }
}
