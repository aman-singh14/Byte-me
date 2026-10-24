// RingStack: concentric progress rings (the app's signature motif, used only
// for goals). Icon at each ring's start, value text beside it. Play register.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/theme.dart';
import 'common.dart';

enum RingKind {
  headsUp('Heads-up', Symbols.eye_tracking_rounded),
  outside('Outside', Symbols.sunny_rounded),
  team('Team', Symbols.groups_rounded);

  const RingKind(this.label, this.icon);
  final String label;
  final IconData icon;

  Color color(OmniColors c) => switch (this) {
    headsUp => c.ringHeadsUp,
    outside => c.ringOutside,
    team => c.ringTeam,
  };
}

class RingData {
  const RingData(this.kind, {required this.minutes, required this.goalMinutes});

  final RingKind kind;
  final int minutes;
  final int goalMinutes;

  double get fraction => goalMinutes <= 0 ? 0 : (minutes / goalMinutes).clamp(0.0, 1.0);
  int get percent => goalMinutes <= 0 ? 0 : (minutes * 100 / goalMinutes).round();

  /// "2 h 10 m of 3 h"
  String get valueText => '${formatMinutes(minutes)} of ${formatMinutes(goalMinutes)}';

  /// "Heads-up ring, 2 hours 10 minutes of 3 hours, 72 percent."
  String get semanticLabel =>
      '${kind.label} ring, ${spokenMinutes(minutes)} of ${spokenMinutes(goalMinutes)}, $percent percent.';
}

class RingStack extends StatefulWidget {
  const RingStack({super.key, required this.rings, this.size = 148, this.showLegend = true});

  /// Outermost ring first.
  final List<RingData> rings;
  final double size;
  final bool showLegend;

  @override
  State<RingStack> createState() => _RingStackState();
}

class _RingStackState extends State<RingStack> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  late final Animation<double> _curve = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  List<double> _from = [];
  List<double> _to = [];

  @override
  void initState() {
    super.initState();
    _to = widget.rings.map((r) => r.fraction).toList();
    _from = List.filled(_to.length, 0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _animate());
  }

  @override
  void didUpdateWidget(RingStack old) {
    super.didUpdateWidget(old);
    final next = widget.rings.map((r) => r.fraction).toList();
    if (next.length != _to.length || !_sameValues(next, _to)) {
      _from = next.length == _to.length ? _current() : List.filled(next.length, 0);
      _to = next;
      _animate();
    }
  }

  void _animate() {
    if (!mounted) return;
    if (context.reduceMotion) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  List<double> _current() => [for (var i = 0; i < _to.length; i++) _from[i] + (_to[i] - _from[i]) * _curve.value];

  static bool _sameValues(List<double> a, List<double> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final rings = AnimatedBuilder(
      animation: _curve,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: RingPainter(
          fractions: _current(),
          colors: [for (final r in widget.rings) r.kind.color(c)],
          icons: [for (final r in widget.rings) r.kind.icon],
          track: c.surfaceAlt,
          iconColor: c.onRing,
        ),
      ),
    );

    final semantics = widget.rings.map((r) => r.semanticLabel).join(' ');
    if (!widget.showLegend) {
      return Semantics(
        label: semantics,
        child: ExcludeSemantics(child: rings),
      );
    }

    final legend = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in widget.rings)
          Padding(
            padding: EdgeInsets.symmetric(vertical: context.space.xs),
            child: _LegendRow(ring: r),
          ),
      ],
    );

    return Semantics(
      label: semantics,
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Side by side when there is room for the legend, stacked otherwise
            // (narrow screens, large text).
            final scale = MediaQuery.textScalerOf(context).scale(1);
            final sideBySide = constraints.maxWidth >= widget.size + 24 + 170 * scale;
            if (sideBySide) {
              return Row(
                children: [
                  rings,
                  SizedBox(width: context.space.xl),
                  Expanded(child: legend),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: rings),
                SizedBox(height: context.space.l),
                legend,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.ring});

  final RingData ring;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RingIconDot(kind: ring.kind),
        SizedBox(width: context.space.s),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${ring.kind.label} · ${ring.percent}%', style: context.type.label),
              Text(ring.valueText, style: context.type.body.copyWith(color: c.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }
}

/// The ring's icon in a dot of the ring's color, as drawn at the ring's start.
class RingIconDot extends StatelessWidget {
  const RingIconDot({super.key, required this.kind, this.size = 24});

  final RingKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: kind.color(c), shape: BoxShape.circle),
      child: Icon(kind.icon, size: size * 0.7, color: c.onRing, fill: 1),
    );
  }
}

/// Paints concentric arcs, outermost first, starting at 12 o'clock.
class RingPainter extends CustomPainter {
  RingPainter({
    required this.fractions,
    required this.colors,
    required this.icons,
    required this.track,
    required this.iconColor,
  });

  final List<double> fractions;
  final List<Color> colors;
  final List<IconData> icons;
  final Color track;
  final Color iconColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (fractions.isEmpty) return;
    final center = size.center(Offset.zero);
    final n = fractions.length;
    final stroke = math.min(18.0, size.width / (n * 2 + 1.5));
    final gap = stroke * 0.25;

    for (var i = 0; i < n; i++) {
      final radius = size.width / 2 - stroke / 2 - i * (stroke + gap);
      if (radius <= 0) break;
      final rect = Rect.fromCircle(center: center, radius: radius);
      final base = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round;

      canvas.drawCircle(center, radius, base..color = track);
      final sweep = 2 * math.pi * fractions[i];
      if (sweep > 0) canvas.drawArc(rect, -math.pi / 2, sweep, false, base..color = colors[i]);

      // Start dot with the ring's icon, so even an empty ring shows its color.
      final start = Offset(center.dx, center.dy - radius);
      canvas.drawCircle(start, stroke / 2, Paint()..color = colors[i]);
      if (stroke >= 14) _paintIcon(canvas, icons[i], start, stroke * 0.75);
    }
  }

  void _paintIcon(Canvas canvas, IconData icon, Offset at, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: size, color: iconColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(RingPainter old) => old.fractions != fractions || old.colors != colors || old.track != track;
}
