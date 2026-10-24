// StatusStrip: connection, battery, privacy chip. Turns into a full-width
// link-lost banner (safety register) when the glasses aren't watching.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../net/glasses_link.dart';
import '../theme/theme.dart';
import 'common.dart';
import 'privacy_chip.dart';

class StatusStrip extends StatelessWidget {
  const StatusStrip({super.key, required this.status, this.batteryPercent, this.lostFor});

  final LinkStatus status;
  final int? batteryPercent;

  /// How long ago the link dropped, when [status] is lost.
  final Duration? lostFor;

  @override
  Widget build(BuildContext context) {
    if (status != LinkStatus.connected) return LinkLostBanner(status: status, lostFor: lostFor);

    final c = context.colors;
    final battery = batteryPercent;
    return OmniCard(
      padding: EdgeInsets.symmetric(horizontal: context.space.l, vertical: context.space.m),
      child: Wrap(
        spacing: context.space.l,
        runSpacing: context.space.s,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.eyeglasses_rounded, color: c.ok, semanticLabel: 'Connected'),
              SizedBox(width: context.space.s),
              Flexible(child: Text('Glasses connected', style: context.type.label)),
            ],
          ),
          if (battery != null)
            Semantics(
              label: 'Battery $battery percent',
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_batteryIcon(battery), color: c.textSecondary),
                    SizedBox(width: context.space.xs),
                    Text('$battery%', style: context.type.label.copyWith(color: c.textSecondary)),
                  ],
                ),
              ),
            ),
          const PrivacyChip.nothingRecorded(),
        ],
      ),
    );
  }

  static IconData _batteryIcon(int p) {
    if (p >= 90) return Symbols.battery_full_rounded;
    if (p >= 60) return Symbols.battery_5_bar_rounded;
    if (p >= 30) return Symbols.battery_3_bar_rounded;
    return Symbols.battery_1_bar_rounded;
  }
}

/// Full-width banner shown whenever the glasses are not watching.
/// Neutral gray with a striped fill (DESIGN.md `linkLost`), strong border.
class LinkLostBanner extends StatelessWidget {
  const LinkLostBanner({super.key, required this.status, this.lostFor});

  final LinkStatus status;
  final Duration? lostFor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final detail = switch (status) {
      LinkStatus.lost when lostFor != null =>
        'Link lost ${_ago(lostFor!)}. Check the glasses are on and near your phone.',
      LinkStatus.lost => 'Link lost. Check the glasses are on and near your phone.',
      _ => "Not connected. Turn on the glasses and your phone's hotspot.",
    };

    return SafetyFadeIn(
      child: Semantics(
        container: true,
        label: 'Glasses not watching. $detail',
        child: ExcludeSemantics(
          child: CustomPaint(
            painter: _StripePainter(base: c.surfaceAlt, stripe: c.linkLost.withValues(alpha: 0.12)),
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: c.linkLost, width: 2),
                borderRadius: BorderRadius.circular(context.space.m),
              ),
              padding: EdgeInsets.all(context.space.l),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Symbols.link_off_rounded, size: 32, color: c.textPrimary),
                  SizedBox(width: context.space.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Glasses not watching', style: context.type.headline),
                        SizedBox(height: context.space.xs),
                        Text(detail, style: context.type.body),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _ago(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} s ago';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    return '${d.inHours} h ago';
  }
}

class _StripePainter extends CustomPainter {
  _StripePainter({required this.base, required this.stripe});

  final Color base;
  final Color stripe;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12));
    canvas.save();
    canvas.clipRRect(rect);
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final paint = Paint()
      ..color = stripe
      ..strokeWidth = 8;
    for (double x = -size.height; x < size.width; x += 20) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripePainter old) => old.base != base || old.stripe != stripe;
}
