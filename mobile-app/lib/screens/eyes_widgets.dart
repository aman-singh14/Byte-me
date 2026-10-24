// Eyes tab cards fed by the laptop backend: blinking (EYE camera) and close-up
// time (FRONT camera). Copy talks about habits linked to eye strain, never a diagnosis.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../components/common.dart';
import '../net/backend_link.dart';
import '../net/backend_models.dart';
import '../theme/theme.dart';
import 'backend_widgets.dart';

const lowBlinkPerMin = 10.0;

bool _isToday(DateTime t) {
  final n = DateTime.now();
  return t.year == n.year && t.month == n.month && t.day == n.day;
}

String clock(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'am' : 'pm'}';
}

/// Live blink rate, low-blink note, partial blinks and squints today.
class BlinkCard extends StatelessWidget {
  const BlinkCard({super.key});

  @override
  Widget build(BuildContext context) {
    final link = watchBackend(context);
    final e = link?.eyes;
    final problem = backendProblem(link);
    final c = context.colors;
    final squintsToday = link?.eyesHistory?.squints.where(_isToday).length ?? 0;

    String status;
    if (e == null) {
      status = problem ?? 'Waiting for the eye camera.';
    } else if (e.eyeCameraOnline == false) {
      status = 'Eye camera offline.';
    } else if (e.calibrating) {
      status = 'Learning your eye: keep it open and look ahead for a few seconds.';
    } else if (!e.eyeDetected) {
      status = "The eye camera can't see your eye right now.";
    } else if (e.blinkRate == null) {
      status = 'Measuring…';
    } else {
      status = 'A relaxed blink rate is about 15 to 20 a minute.';
    }

    final rate = e?.blinkRate;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardTitle(icon: Symbols.visibility_rounded, title: 'Blinking'),
          SizedBox(height: context.space.s),
          Semantics(
            label: rate == null ? 'Blink rate not measured yet' : 'Blink rate ${rate.round()} per minute',
            child: ExcludeSemantics(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: context.space.s,
                children: [
                  Text(rate == null ? '–' : '${rate.round()}', style: context.type.display),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('blinks / min', style: context.type.body.copyWith(color: c.textSecondary)),
                  ),
                ],
              ),
            ),
          ),
          NoteText(status),
          if (e != null && e.lowBlink) ...[
            SizedBox(height: context.space.m),
            _Callout(
              icon: Symbols.water_drop_rounded,
              text:
                  'Low blinking${e.lowBlinkSince != null ? ' since ${clock(e.lowBlinkSince!)}' : ''}. '
                  'Try a few slow, full blinks, or look away for 20 seconds.',
            ),
          ],
          SizedBox(height: context.space.m),
          Wrap(
            spacing: context.space.s,
            runSpacing: context.space.s,
            children: [
              _Stat(label: 'Partial blinks', value: '${e?.partialBlinks ?? 0}'),
              _Stat(label: 'Squints today', value: '$squintsToday'),
              _Stat(label: 'Blinks counted', value: '${e?.blinksTotal ?? 0}'),
            ],
          ),
        ],
      ),
    );
  }
}

/// Blink rate over today, with the 10/min line and low-blink stretches shaded.
class BlinkTrendCard extends StatelessWidget {
  const BlinkTrendCard({super.key});

  @override
  Widget build(BuildContext context) {
    final link = watchBackend(context);
    final h = link?.eyesHistory;
    final pts = [
      for (final p in h?.points ?? const <BlinkPoint>[])
        if (p.blinkRate != null && _isToday(p.time)) p,
    ];
    final c = context.colors;
    String summary;
    if (pts.isEmpty) {
      summary = backendProblem(link) ?? 'No blink data yet today.';
    } else {
      final rates = pts.map((p) => p.blinkRate!).toList();
      final avg = rates.reduce((a, b) => a + b) / rates.length;
      summary = 'Average ${avg.round()} a minute today, lowest ${rates.reduce(math.min).round()}.';
    }
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardTitle(icon: Symbols.show_chart_rounded, title: 'Blink rate today'),
          SizedBox(height: context.space.s),
          if (pts.length >= 2)
            Semantics(
              label: 'Chart of blink rate today. $summary',
              child: ExcludeSemantics(
                child: SizedBox(
                  height: 140,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _BlinkChartPainter(
                      points: pts,
                      lowBlink: h?.lowBlink ?? const [],
                      line: c.brand,
                      guide: c.outline,
                      shade: c.alertGentle.withValues(alpha: 0.18),
                      text: c.textSecondary,
                      labelStyle: context.type.caption,
                    ),
                  ),
                ),
              ),
            ),
          SizedBox(height: context.space.s),
          NoteText(summary),
        ],
      ),
    );
  }
}

class _BlinkChartPainter extends CustomPainter {
  _BlinkChartPainter({
    required this.points,
    required this.lowBlink,
    required this.line,
    required this.guide,
    required this.shade,
    required this.text,
    required this.labelStyle,
  });

  final List<BlinkPoint> points;
  final List<TimeSpan> lowBlink;
  final Color line, guide, shade, text;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    const bottom = 18.0;
    final h = size.height - bottom;
    final t0 = points.first.time.millisecondsSinceEpoch.toDouble();
    final t1 = math.max(points.last.time.millisecondsSinceEpoch.toDouble(), t0 + 1);
    final maxRate = math.max(25.0, points.map((p) => p.blinkRate!).reduce(math.max) * 1.1);
    double x(DateTime t) => (t.millisecondsSinceEpoch - t0) / (t1 - t0) * size.width;
    double y(double r) => h - r / maxRate * h;

    for (final s in lowBlink) {
      final a = x(s.start).clamp(0.0, size.width), b = x(s.end).clamp(0.0, size.width);
      if (b > a) canvas.drawRect(Rect.fromLTRB(a, 0, b, h), Paint()..color = shade);
    }
    final g = Paint()
      ..color = guide
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, y(lowBlinkPerMin)), Offset(size.width, y(lowBlinkPerMin)), g);
    canvas.drawLine(Offset(0, h), Offset(size.width, h), g);
    _label(canvas, '10 / min', Offset(4, y(lowBlinkPerMin) - 16));

    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final o = Offset(x(points[i].time), y(points[i].blinkRate!));
      i == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    _label(canvas, clock(points.first.time), Offset(0, h + 2));
    final end = clock(points.last.time);
    _label(canvas, end, Offset(size.width - _measure(end), h + 2));
  }

  double _measure(String s) => (TextPainter(
    text: TextSpan(text: s, style: labelStyle),
    textDirection: TextDirection.ltr,
  )..layout()).width;

  void _label(Canvas canvas, String s, Offset at) {
    (TextPainter(
      text: TextSpan(
        text: s,
        style: labelStyle.copyWith(color: text),
      ),
      textDirection: TextDirection.ltr,
    )..layout()).paint(canvas, at);
  }

  @override
  bool shouldRepaint(_BlinkChartPainter old) => old.points != points || old.lowBlink != lowBlink || old.line != line;
}

/// Close-up time today: total, what's in front right now, by object, timeline.
class CloseupCard extends StatelessWidget {
  const CloseupCard({super.key});

  @override
  Widget build(BuildContext context) {
    final link = watchBackend(context);
    final day = link?.closeup;
    final e = link?.eyes;
    final c = context.colors;
    final total = (day?.totalMinutes ?? 0).round();

    String now;
    if (e == null) {
      now = backendProblem(link) ?? 'Waiting for the front camera.';
    } else if (e.frontCameraOnline == false) {
      now = 'Front camera offline.';
    } else if (!e.nearwork) {
      now = 'No screen or book in view.';
    } else {
      final d = e.nearworkDistanceCm;
      now =
          '${nearWorkName(e.nearworkObject)}${d == null ? '' : ', about ${d.round()} cm away'}'
          '${e.nearworkClose ? ' (close)' : ''}.';
    }

    final byObject = (day?.byObject.entries.toList() ?? [])..sort((a, b) => b.value.compareTo(a.value));
    final maxMin = byObject.isEmpty ? 1.0 : byObject.first.value;

    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardTitle(icon: Symbols.straighten_rounded, title: 'Close-up time'),
          SizedBox(height: context.space.s),
          Semantics(
            label: '${spokenMinutes(total)} of close-up time today',
            child: ExcludeSemantics(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: context.space.s,
                children: [
                  Text(formatMinutes(total), style: context.type.display),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text('today', style: context.type.body.copyWith(color: c.textSecondary)),
                  ),
                ],
              ),
            ),
          ),
          NoteText('Now: $now'),
          if (byObject.isNotEmpty) ...[
            SizedBox(height: context.space.l),
            for (final entry in byObject)
              Padding(
                padding: EdgeInsets.only(bottom: context.space.s),
                child: _ObjectRow(kind: entry.key, minutes: entry.value, fraction: entry.value / maxMin),
              ),
          ],
          if ((day?.sessions ?? const []).isNotEmpty) ...[
            SizedBox(height: context.space.s),
            Text('Sessions today', style: context.type.label),
            SizedBox(height: context.space.xs),
            _SessionTimeline(sessions: day!.sessions),
            SizedBox(height: context.space.xs),
            NoteText(
              '${day.sessions.length} session${day.sessions.length == 1 ? '' : 's'}, '
              'longest ${formatMinutes(day.longestMinutes.round())}.',
            ),
          ],
          SizedBox(height: context.space.m),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Symbols.tune_rounded),
              label: const Text('Calibrate distance'),
              onPressed: link == null ? null : () => showCloseupCalibration(context, link),
            ),
          ),
        ],
      ),
    );
  }
}

class _ObjectRow extends StatelessWidget {
  const _ObjectRow({required this.kind, required this.minutes, required this.fraction});
  final String kind;
  final double minutes;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: '${nearWorkName(kind)}, ${spokenMinutes(minutes.round())}',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(iconForNearWork(kind), size: 20, color: c.textPrimary),
                SizedBox(width: context.space.s),
                Expanded(child: Text(nearWorkName(kind), style: context.type.body)),
                Text(formatMinutes(minutes.round()), style: context.type.label),
              ],
            ),
            SizedBox(height: context.space.xs),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction.clamp(0.0, 1.0),
                minHeight: 8,
                color: c.brand,
                backgroundColor: c.surfaceAlt,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sessions as blocks on a line from the first session to now.
class _SessionTimeline extends StatelessWidget {
  const _SessionTimeline({required this.sessions});
  final List<CloseupSession> sessions;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final start = sessions.map((s) => s.start).reduce((a, b) => a.isBefore(b) ? a : b);
    final now = DateTime.now();
    final label = sessions.map((s) => '${nearWorkName(s.object)} from ${clock(s.start)} to ${clock(s.end)}').join(', ');
    return Semantics(
      label: 'Timeline: $label',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 22,
              child: CustomPaint(painter: _TimelinePainter(sessions, start, now, c.brand, c.surfaceAlt)),
            ),
            Row(
              children: [
                Text(clock(start), style: context.type.caption.copyWith(color: c.textSecondary)),
                const Spacer(),
                Text('now', style: context.type.caption.copyWith(color: c.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.sessions, this.start, this.end, this.color, this.track);
  final List<CloseupSession> sessions;
  final DateTime start, end;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = track);
    final span = math.max(end.difference(start).inSeconds, 1);
    for (final s in sessions) {
      final a = s.start.difference(start).inSeconds / span * size.width;
      final b = math.max(a + 3, s.end.difference(start).inSeconds / span * size.width);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(a, 2, math.min(b, size.width), size.height - 2),
          const Radius.circular(4),
        ),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_TimelinePainter old) => old.sessions != sessions || old.end != end;
}

/// Bottom sheet: hold an object at a known distance from the glasses and calibrate.
Future<void> showCloseupCalibration(BuildContext context, BackendLink link) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _CalibrationSheet(link: link),
  );
}

class _CalibrationSheet extends StatefulWidget {
  const _CalibrationSheet({required this.link});
  final BackendLink link;

  @override
  State<_CalibrationSheet> createState() => _CalibrationSheetState();
}

class _CalibrationSheetState extends State<_CalibrationSheet> {
  static const _defaults = {'phone': 30.0, 'book': 30.0, 'laptop': 50.0, 'tv': 150.0, 'keyboard': 50.0};
  String _object = 'phone';
  double _cm = 30;
  bool _busy = false;
  String? _message;

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(space.page, 0, space.page, space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Calibrate distance', style: context.type.title),
            SizedBox(height: space.s),
            const NoteText(
              'Hold the object in front of the glasses at the distance below (measure from the front camera), '
              'then tap Calibrate. Do it once per object.',
            ),
            SizedBox(height: space.l),
            Wrap(
              spacing: space.s,
              runSpacing: space.s,
              children: [
                for (final kind in _defaults.keys)
                  ChoiceChip(
                    avatar: Icon(iconForNearWork(kind), size: 18),
                    label: Text(nearWorkName(kind)),
                    selected: _object == kind,
                    onSelected: (_) => setState(() {
                      _object = kind;
                      _cm = _defaults[kind]!;
                    }),
                  ),
              ],
            ),
            SizedBox(height: space.l),
            Text('Distance: ${_cm.round()} cm', style: context.type.label),
            Slider(
              value: _cm,
              min: 15,
              max: 200,
              divisions: 37,
              label: '${_cm.round()} cm',
              onChanged: (v) => setState(() => _cm = v),
            ),
            if (_message != null) ...[NoteText(_message!), SizedBox(height: space.s)],
            FilledButton.icon(
              icon: const Icon(Symbols.check_rounded),
              label: Text(_busy ? 'Calibrating…' : 'Calibrate'),
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      final err = await widget.link.calibrateCloseup(_object, _cm);
                      if (!mounted) return;
                      setState(() {
                        _busy = false;
                        _message = err ?? '${nearWorkName(_object)} calibrated at ${_cm.round()} cm.';
                      });
                    },
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: context.space.m, vertical: context.space.s),
      decoration: BoxDecoration(color: c.surfaceAlt, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: context.type.headline),
          Text(label, style: context.type.caption.copyWith(color: c.textSecondary)),
        ],
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  const _Callout({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: EdgeInsets.all(context.space.m),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.outline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: c.textPrimary),
          SizedBox(width: context.space.s),
          Expanded(child: Text(text, style: context.type.body)),
        ],
      ),
    );
  }
}
