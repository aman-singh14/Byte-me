// Aware: rear view, alerts, social taps, captions, "Who's around me?".
// Phase 1: side indicator, live rear view with detection boxes, event log.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../alerts/alert_engine.dart';
import '../alerts/alert_service.dart';
import '../alerts/tracker.dart';
import '../components/alerts.dart';
import '../components/common.dart';
import '../components/event_log.dart';
import '../components/rear_view.dart';
import '../net/protocol.dart';
import '../settings/feature_flags.dart';
import '../theme/theme.dart';
import '../vision/detector.dart';
import '../vision/mjpeg.dart';
import '../vision/rear_vision.dart';
import 'alert_widgets.dart';
import 'captions_widgets.dart';
import 'helper_screen.dart';
import 'home_shell.dart';

class AwareScreen extends StatelessWidget {
  const AwareScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final vision = context.watch<RearVision>();
    final alerts = context.watch<AlertService>();
    final camera = vision.camera;
    final alert = alerts.current;
    return TabPage(
      title: 'Aware',
      children: [
        Center(
          child: SideIndicator(
            active: alert == null ? null : Direction.fromWearerSide(alert.side),
            tone: alert?.level == AlertLevel.urgent ? SideTone.urgent : SideTone.gentle,
          ),
        ),
        if (camera == null)
          const RearView(frame: null, detections: [])
        else
          _LiveRearView(camera: camera, loop: vision.loop, detectorState: vision.detectorState),
        if (alerts.socialTap != null) const LiveSocialTapCard(),
        if (alerts.following != null) const LiveFollowingCard(),
        if (context.watch<FeatureFlags>()[Feature.captions]) const CaptionsCard(),
        const HelperCallCard(),
        EventLogCard(entries: alerts.log.entries, onClear: alerts.clearLog),
      ],
    );
  }
}

String _count(int n) => n == 1 ? '1 object' : '$n objects';

/// Debug builds: what the engine makes of each box, for tuning. Time to
/// contact ("3.2 s"), or why there's no alert: "not closing", "cut off",
/// "too small", "measuring", "passing" (people off to the side), or a
/// confidence below the cutoff.
List<String?> _debugNotes(List<Detection> detections, AlertEngine engine) => [
  for (final d in detections)
    if (d.confidence < engine.minConfidence)
      '${(d.confidence * 100).round()}% ignored'
    else if (onlyStraightBehind.contains(d.label) && d.side != WearerSide.behind)
      'passing'
    else
      _trackFor(d, engine.tracker.tracks)?.debugReason ?? 'measuring',
];

// The engine's view lags the boxes on screen by up to a frame, so match by
// overlap rather than exact position.
Track? _trackFor(Detection d, List<Track> tracks) {
  final box = Box(d.box.left, d.box.top, d.box.right, d.box.bottom);
  Track? best;
  var bestIou = 0.3;
  for (final t in tracks) {
    final iou = t.label == d.label ? t.box.iou(box) : 0.0;
    if (iou > bestIou) (best, bestIou) = (t, iou);
  }
  return best;
}

class _LiveRearView extends StatelessWidget {
  const _LiveRearView({required this.camera, required this.loop, required this.detectorState});

  final CameraFeed camera;
  final DetectionLoop? loop;
  final DetectorState detectorState;

  @override
  Widget build(BuildContext context) {
    final loop = this.loop;
    return ListenableBuilder(
      listenable: Listenable.merge([camera.frame, camera.state, camera.fps, ?loop]),
      builder: (context, _) {
        final placeholder = switch (camera.state.value) {
          CameraState.retrying => 'Rear camera not responding. Trying again.',
          _ => 'Connecting to the rear camera.',
        };
        final detectorNote = switch (detectorState) {
          DetectorState.loading => 'Detector loading.',
          DetectorState.failed => 'Detector failed to load. Video only.',
          DetectorState.ready => null,
        };
        final detections = loop?.latest ?? const <Detection>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RearView(
              frame: camera.frame.value,
              detections: detections,
              placeholder: placeholder,
              notes: kDebugMode ? _debugNotes(detections, context.read<AlertService>().engine) : null,
            ),
            if (detectorNote != null) ...[
              SizedBox(height: context.space.s),
              Text(detectorNote, style: context.type.body),
            ],
            if (kDebugMode) ...[
              SizedBox(height: context.space.s),
              Text(
                '${camera.fps.value} fps · detector ${loop?.lastInference.inMilliseconds ?? '-'} ms · '
                '${_count((loop?.latest ?? const <Detection>[]).length)}',
                style: context.type.caption.copyWith(color: context.colors.textSecondary),
              ),
            ],
          ],
        );
      },
    );
  }
}
