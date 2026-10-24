// Safety register: AlertBanner, SideIndicator, SocialTapCard.
// Plain, high contrast, literal. Instant appear (<=100 ms fade), no bounce,
// no confetti, nothing gamified.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/theme.dart';
import 'common.dart';

enum AlertLevel { gentle, urgent }

/// Full-width approach warning: icon + one word + side ("Car · behind left").
/// Stays until resolved or dismissed.
class AlertBanner extends StatefulWidget {
  const AlertBanner({
    super.key,
    required this.level,
    required this.label,
    required this.direction,
    this.onDismiss,
    this.announce = true,
  });

  final AlertLevel level;

  /// Object class, one word ("car").
  final String label;
  final Direction direction;
  final VoidCallback? onDismiss;

  /// Speak it and buzz the phone when shown. The Widget Gallery turns this off.
  final bool announce;

  /// "Car close behind you, left." / "Car behind you, left."
  String get sentence => '${capitalize(label)} ${level == AlertLevel.urgent ? 'close ' : ''}${direction.phrase}.';

  @override
  State<AlertBanner> createState() => _AlertBannerState();
}

class _AlertBannerState extends State<AlertBanner> {
  @override
  void initState() {
    super.initState();
    if (widget.announce) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        announce(context, widget.sentence, assertive: true);
        // TODO(phase 1.4): match the glasses' buzz pattern for this level.
        widget.level == AlertLevel.urgent ? HapticFeedback.heavyImpact() : HapticFeedback.mediumImpact();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final urgent = widget.level == AlertLevel.urgent;
    final bg = urgent ? c.alertUrgent : c.alertGentle;
    final fg = urgent ? c.onAlertUrgent : c.onAlertGentle;
    final word = capitalize(widget.label);
    final where = urgent ? 'close, ${widget.direction.short}' : widget.direction.short;

    return SafetyFadeIn(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: widget.sentence,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(context.space.m),
            border: Border.all(color: c.textPrimary, width: urgent ? 3 : 2),
          ),
          padding: EdgeInsets.fromLTRB(context.space.l, context.space.m, context.space.xs, context.space.m),
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  urgent ? Symbols.warning_rounded : iconForObject(widget.label),
                  size: 32,
                  color: fg,
                  fill: 1,
                ),
              ),
              SizedBox(width: context.space.m),
              Expanded(
                child: ExcludeSemantics(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: word,
                          style: context.type.title.copyWith(color: fg),
                        ),
                        TextSpan(
                          text: '  ·  $where',
                          style: context.type.label.copyWith(color: fg, fontSize: 17),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.onDismiss != null)
                IconButton(
                  onPressed: widget.onDismiss,
                  icon: Icon(Symbols.close_rounded, color: fg),
                  tooltip: 'Dismiss alert',
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What an active side means, which picks its color.
enum SideTone { urgent, gentle, social }

/// Top-down head outline with left / behind / right arcs. The active arc
/// fills. The text equivalent is always shown underneath.
class SideIndicator extends StatelessWidget {
  const SideIndicator({super.key, this.active, this.tone = SideTone.urgent, this.size = 112});

  final Direction? active;
  final SideTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = switch (tone) {
      SideTone.urgent => c.alertUrgent,
      SideTone.gentle => c.alertGentle,
      SideTone.social => c.socialTap,
    };
    final text = active?.word ?? 'All clear';
    return Semantics(
      label: active == null ? 'Nothing behind you' : 'Side: ${active!.word}',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              size: Size.square(size),
              painter: _HeadPainter(active: active, activeColor: color, idle: c.outline, head: c.textPrimary),
            ),
            SizedBox(height: context.space.xs),
            Text(text, style: context.type.label),
          ],
        ),
      ),
    );
  }
}

class _HeadPainter extends CustomPainter {
  _HeadPainter({required this.active, required this.activeColor, required this.idle, required this.head});

  final Direction? active;
  final Color activeColor;
  final Color idle;
  final Color head;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final headR = size.width * 0.22;
    final arcR = size.width * 0.40;
    final arcStroke = size.width * 0.12;

    // Seen from above, facing up: the wearer's left is on the left. Canvas
    // angles: 0 = right, pi/2 = down (behind), pi = left.
    const span = 0.85;
    final arcs = {Direction.right: math.pi * 0.12, Direction.behind: math.pi / 2, Direction.left: math.pi * 0.88};
    final rect = Rect.fromCircle(center: center, radius: arcR);
    for (final MapEntry(key: dir, value: mid) in arcs.entries) {
      final on = dir == active;
      canvas.drawArc(
        rect,
        mid - span / 2,
        span,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = on ? arcStroke : arcStroke * 0.45
          ..color = on ? activeColor : idle,
      );
    }

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = head;
    // Nose (front) at the top, ears at the sides.
    final nose = Path()
      ..moveTo(center.dx - headR * 0.3, center.dy - headR * 0.9)
      ..lineTo(center.dx, center.dy - headR * 1.35)
      ..lineTo(center.dx + headR * 0.3, center.dy - headR * 0.9);
    canvas.drawPath(nose, outline);
    for (final dx in [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(center: center + Offset(dx * headR, 0), width: headR * 0.35, height: headR * 0.6),
        outline,
      );
    }
    canvas.drawCircle(center, headR, Paint()..color = idle.withValues(alpha: 0.35));
    canvas.drawCircle(center, headR, outline);
  }

  @override
  bool shouldRepaint(_HeadPainter old) =>
      old.active != active || old.activeColor != activeColor || old.idle != idle || old.head != head;
}

/// Someone stopped to talk. Teal and friendly, never the urgent color.
class SocialTapCard extends StatefulWidget {
  const SocialTapCard({super.key, required this.direction, this.onDismiss, this.announce = true});

  final Direction direction;
  final VoidCallback? onDismiss;
  final bool announce;

  /// "Someone stopped behind you, left."
  String get sentence => 'Someone stopped ${direction.phrase}.';

  @override
  State<SocialTapCard> createState() => _SocialTapCardState();
}

class _SocialTapCardState extends State<SocialTapCard> {
  @override
  void initState() {
    super.initState();
    if (widget.announce) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        announce(context, widget.sentence);
        HapticFeedback.lightImpact();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SafetyFadeIn(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: widget.sentence,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(color: c.socialTap, borderRadius: context.radii.cardRadius),
          padding: EdgeInsets.fromLTRB(context.space.l, context.space.m, context.space.xs, context.space.m),
          child: Row(
            children: [
              ExcludeSemantics(child: Icon(Symbols.waving_hand_rounded, size: 32, color: c.onSocialTap)),
              SizedBox(width: context.space.m),
              Expanded(
                child: ExcludeSemantics(
                  child: Text(widget.sentence, style: context.type.headline.copyWith(color: c.onSocialTap)),
                ),
              ),
              if (widget.onDismiss != null)
                IconButton(
                  onPressed: widget.onDismiss,
                  icon: Icon(Symbols.close_rounded, color: c.onSocialTap),
                  tooltip: 'Dismiss',
                ),
            ],
          ),
        ),
      ),
    );
  }
}
