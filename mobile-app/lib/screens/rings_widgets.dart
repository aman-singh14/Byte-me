// Rings from the laptop backend: Heads-up (no phone/screen/book in view, glasses on)
// and Outside (exposure-aware brightness from the FRONT camera). Play register:
// a partial ring is progress, never failure.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../components/common.dart';
import '../components/ring_stack.dart';
import '../net/backend_models.dart';
import '../theme/theme.dart';
import 'backend_widgets.dart';

List<RingData> ringData(RingsDay d) => [
  RingData(RingKind.headsUp, minutes: d.headsUp.minutes.round(), goalMinutes: d.headsUp.goalMinutes),
  RingData(RingKind.outside, minutes: d.outside.minutes.round(), goalMinutes: d.outside.goalMinutes),
];

/// Today's Heads-up and Outside rings, heads-up breaks and points.
class RingsCard extends StatelessWidget {
  const RingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final link = watchBackend(context);
    final d = link?.rings;
    final problem = backendProblem(link);
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardTitle(icon: Symbols.eye_tracking_rounded, title: 'Rings'),
          SizedBox(height: context.space.m),
          RingStack(
            rings: ringData(
              d ?? const RingsDay(headsUp: RingProgress(goalMinutes: 180), outside: RingProgress(goalMinutes: 120)),
            ),
          ),
          SizedBox(height: context.space.m),
          if (d == null)
            NoteText(problem ?? 'Waiting for today\'s rings.')
          else ...[
            Wrap(
              spacing: context.space.s,
              runSpacing: context.space.s,
              children: [
                _Pill(
                  icon: Symbols.eye_tracking_rounded,
                  text: '${d.headsUpBreaks} heads-up break${d.headsUpBreaks == 1 ? '' : 's'}',
                ),
                _Pill(icon: Symbols.star_rounded, text: '${d.points} points today'),
                if (d.headsUp.active) const _Pill(icon: Symbols.visibility_rounded, text: 'Heads-up now'),
                if (d.outside.active) const _Pill(icon: Symbols.sunny_rounded, text: 'Outside now'),
              ],
            ),
            SizedBox(height: context.space.s),
            const NoteText(
              'Heads-up counts when no phone, screen or book is in view for 20 seconds. '
              'Breaks and outside time earn points.',
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact Eyes summary for Today: close-up time, blink rate.
class EyesSummaryCard extends StatelessWidget {
  const EyesSummaryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final link = watchBackend(context);
    final e = link?.eyes;
    final closeup = link?.closeup;
    final lines = <String>[
      if (closeup != null) '${formatMinutes(closeup.totalMinutes.round())} of close-up time today.',
      if (e?.nearwork == true && e?.nearworkDistanceCm != null)
        '${nearWorkName(e!.nearworkObject)} about ${e.nearworkDistanceCm!.round()} cm away right now.',
      if (e?.blinkRate != null) 'Blinking ${e!.blinkRate!.round()} times a minute.',
      if (e?.lowBlink == true) 'Low blinking for a while: try a few slow blinks.',
    ];
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardTitle(icon: Symbols.visibility_rounded, title: 'Eyes'),
          SizedBox(height: context.space.s),
          if (lines.isEmpty) NoteText(backendProblem(link) ?? 'No eye data yet today.'),
          for (final l in lines) Text(l, style: context.type.body),
        ],
      ),
    );
  }
}

/// Rings for the last 7 days (Together tab: rings detail).
class RingsHistoryCard extends StatelessWidget {
  const RingsHistoryCard({super.key});

  static const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final link = watchBackend(context);
    final history = link?.ringsHistory ?? const <RingsDay>[];
    final c = context.colors;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardTitle(icon: Symbols.calendar_month_rounded, title: 'Rings this week'),
          SizedBox(height: context.space.s),
          if (history.isEmpty) NoteText(backendProblem(link) ?? 'No ring history yet.'),
          for (final d in history.reversed)
            Padding(
              padding: EdgeInsets.only(top: context.space.m),
              child: Semantics(
                label:
                    '${_label(d.date)}: heads-up ${d.headsUp.minutes.round()} minutes, '
                    'outside ${d.outside.minutes.round()} minutes, ${d.points} points.',
                child: ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(_label(d.date), style: context.type.label)),
                          Text('${d.points} pts', style: context.type.caption.copyWith(color: c.textSecondary)),
                        ],
                      ),
                      SizedBox(height: context.space.xs),
                      _Bar(
                        fraction: _frac(d.headsUp),
                        color: c.ringHeadsUp,
                        text: 'Heads-up ${formatMinutes(d.headsUp.minutes.round())}',
                      ),
                      SizedBox(height: context.space.xs),
                      _Bar(
                        fraction: _frac(d.outside),
                        color: c.ringOutside,
                        text: 'Outside ${formatMinutes(d.outside.minutes.round())}',
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static double _frac(RingProgress p) => p.goalMinutes <= 0 ? 0 : (p.minutes / p.goalMinutes).clamp(0.0, 1.0);

  String _label(String date) {
    final d = DateTime.tryParse(date);
    if (d == null) return date;
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) return 'Today';
    return '${_days[d.weekday - 1]} ${d.month}/${d.day}';
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction, required this.color, required this.text});
  final double fraction;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: context.type.caption.copyWith(color: c.textSecondary)),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: fraction, minHeight: 8, color: color, backgroundColor: c.surfaceAlt),
        ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.space.m, vertical: context.space.xs + 2),
      decoration: BoxDecoration(color: c.surfaceAlt, borderRadius: BorderRadius.circular(context.radii.pill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: c.textPrimary),
          SizedBox(width: context.space.xs),
          Flexible(child: Text(text, style: context.type.label)),
        ],
      ),
    );
  }
}
