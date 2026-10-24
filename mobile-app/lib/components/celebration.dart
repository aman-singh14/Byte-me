// Celebration: confetti in ring colors + success haptic, at most 1.5 s, tap to
// skip. Under reduce motion it is replaced by a text toast. Play register only:
// never used for anything safety related.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';
import 'common.dart';

/// Celebrates with confetti over the whole screen, plus a text toast so the
/// message is never only visual.
void celebrate(BuildContext context, String message) {
  HapticFeedback.mediumImpact();
  announce(context, message);
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(SnackBar(content: Text(message)));
  if (context.reduceMotion) return;

  final overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(builder: (_) => Celebration(onDone: entry.remove));
  overlay.insert(entry);
}

class Celebration extends StatefulWidget {
  const Celebration({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<Celebration> createState() => _CelebrationState();
}

class _CelebrationState extends State<Celebration> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) widget.onDone();
        })
        ..forward();

  final _pieces = List.generate(70, (i) => _Piece(math.Random(i)));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final colors = [c.ringHeadsUp, c.ringOutside, c.ringTeam, c.brand];
    return Semantics(
      button: true,
      label: 'Skip celebration',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _controller.value = 1, // completes immediately -> onDone
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) =>
              CustomPaint(size: Size.infinite, painter: _ConfettiPainter(_pieces, colors, _controller.value)),
        ),
      ),
    );
  }
}

class _Piece {
  _Piece(math.Random r)
    : x = r.nextDouble(),
      vx = (r.nextDouble() - 0.5) * 0.4,
      vy = -0.6 - r.nextDouble() * 0.6,
      spin = (r.nextDouble() - 0.5) * 12,
      color = r.nextInt(4),
      w = 6 + r.nextDouble() * 6;

  final double x, vx, vy, spin, w;
  final int color;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.pieces, this.colors, this.t);

  final List<_Piece> pieces;
  final List<Color> colors;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    // Burst up from the bottom, fall back with gravity, fade in the last 30%.
    final fade = t < 0.7 ? 1.0 : (1 - (t - 0.7) / 0.3);
    for (final p in pieces) {
      final x = (p.x + p.vx * t) * size.width;
      final y = size.height * (1 + p.vy * t * 1.6 + 1.4 * t * t);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.spin * t);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: p.w, height: p.w * 0.5),
        Paint()..color = colors[p.color].withValues(alpha: fade),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
