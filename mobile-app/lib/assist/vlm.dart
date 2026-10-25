// The one VLM service every snapshot feature uses (Muse Spark, through the
// laptop backend's /vlm endpoint, which holds the key and the spending cap).
//
// Each call sends one or more camera snapshots and gets back the feature's
// JSON. Calls time out (4 s by default) so a feature can fall back, and they
// are rate limited per feature. Mock mode answers with canned JSON, for
// offline work and as a demo fallback. Nothing is kept: not the images, not
// the answers; only how long each call took, for the speed check.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net/backend_api.dart';
import '../net/backend_link.dart';
import '../settings/feature_flags.dart';

/// Said when a description can't be had in time.
const vlmFallback = "I couldn't describe that right now.";

enum VlmFeature {
  /// Is the person who stopped behind the wearer trying to get their attention?
  /// {"engaging": bool, "action": string}
  socialConfirm('social_confirm', 'Social tap check'),

  /// One sentence about a snapshot, for the speed check. {"summary": string}
  describe('describe', 'Describe');

  const VlmFeature(this.wire, this.title);
  final String wire;
  final String title;

  /// How long a feature waits before it falls back.
  Duration get timeout => const Duration(seconds: 4);
}

/// Canned answers for mock mode.
const vlmMockAnswers = <VlmFeature, Map<String, Object>>{
  VlmFeature.socialConfirm: {'engaging': true, 'action': 'waving'},
  VlmFeature.describe: {'summary': 'A hallway with a door on the left. This is a mock answer.'},
};

class VlmImage {
  const VlmImage.rear(this.jpeg) : camera = 'rear';
  const VlmImage.front(this.jpeg) : camera = 'front';
  final String camera;
  final List<int> jpeg;
}

/// No answer: timed out, rate limited, laptop unreachable, Muse unavailable.
/// [message] is safe to show.
class VlmUnavailable implements Exception {
  const VlmUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Request times for one feature, newest last.
class VlmStats {
  final latencies = <Duration>[];
  int failures = 0;

  static const keep = 100;

  void add(Duration d) {
    latencies.add(d);
    if (latencies.length > keep) latencies.removeAt(0);
  }

  int get count => latencies.length;

  /// The [p] percentile (0..1) of successful calls, or null with none.
  Duration? percentile(double p) {
    if (latencies.isEmpty) return null;
    final sorted = [...latencies]..sort();
    return sorted[((p * sorted.length).ceil() - 1).clamp(0, sorted.length - 1)];
  }
}

typedef VlmCall =
    Future<Map<String, dynamic>> Function(
      String feature, {
      List<(String, List<int>)> images,
      bool useFront,
      Duration? timeout,
    });

class VlmService extends ChangeNotifier {
  VlmService({
    required this.call,
    required this.flags,
    DateTime Function()? clock,
    this.minInterval = const Duration(seconds: 2),
  }) : _clock = clock ?? DateTime.now;

  /// The usual setup: calls go to the laptop backend.
  factory VlmService.backend(BackendLink backend, FeatureFlags flags) => VlmService(call: backend.vlm, flags: flags);

  /// Calls go to the cloud server (no laptop; it has no front camera of its own).
  factory VlmService.cloud(Uri server, FeatureFlags flags) => VlmService(call: BackendApi(server).vlm, flags: flags);

  /// Sends one request (the backend's /vlm, or a fake in tests).
  final VlmCall call;
  final FeatureFlags flags;
  final DateTime Function() _clock;

  /// At most one call per feature this often; a call while one is running
  /// gets that one's answer.
  final Duration minInterval;

  final stats = {for (final f in VlmFeature.values) f: VlmStats()};
  final _running = <VlmFeature, Future<Map<String, dynamic>>>{};
  final _lastStart = <VlmFeature, DateTime>{};

  bool get mock => flags[Feature.vlmMock];

  /// The feature's JSON answer. Throws [VlmUnavailable].
  Future<Map<String, dynamic>> ask(VlmFeature feature, {List<VlmImage> images = const [], bool useFront = false}) {
    final running = _running[feature];
    if (running != null) return running;
    final now = _clock(), last = _lastStart[feature];
    if (last != null && now.difference(last) < minInterval) {
      return Future.error(const VlmUnavailable('Asked too often. Try again in a moment.'));
    }
    _lastStart[feature] = now;
    // A block body: returning the removed future would make it wait on itself.
    final future = _run(feature, images, useFront).whenComplete(() {
      _running.remove(feature);
    });
    return _running[feature] = future;
  }

  Future<Map<String, dynamic>> _run(VlmFeature feature, List<VlmImage> images, bool useFront) async {
    final watch = Stopwatch()..start();
    try {
      final Map<String, dynamic> answer;
      if (mock) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        answer = Map.of(vlmMockAnswers[feature]!);
      } else {
        answer = await call(
          feature.wire,
          images: [for (final i in images) (i.camera, i.jpeg)],
          useFront: useFront,
          timeout: feature.timeout + const Duration(seconds: 1),
        ).timeout(feature.timeout);
      }
      stats[feature]!.add(watch.elapsed);
      debugPrint('Vlm: ${feature.wire} ${watch.elapsedMilliseconds} ms${mock ? ' (mock)' : ''}');
      return answer;
    } on TimeoutException {
      _failed(feature, watch, 'timed out');
      throw const VlmUnavailable('Muse took too long.');
    } on BackendException catch (e) {
      _failed(feature, watch, e.message);
      throw VlmUnavailable(e.message);
    } finally {
      notifyListeners();
    }
  }

  void _failed(VlmFeature feature, Stopwatch watch, String why) {
    stats[feature]!.failures++;
    debugPrint('Vlm: ${feature.wire} failed after ${watch.elapsedMilliseconds} ms: $why');
  }

  void clearStats() {
    for (final s in stats.values) {
      s.latencies.clear();
      s.failures = 0;
    }
    notifyListeners();
  }
}
