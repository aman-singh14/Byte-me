// Today, while the front camera streams: what it sees, the near-work found in it
// and how far away it is. Without the back camera it also says rear alerts are off.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../components/common.dart';
import '../components/live_camera.dart';
import '../eyes/nearwork.dart';
import '../eyes/phone_eyes.dart';
import '../theme/theme.dart';
import 'backend_widgets.dart';

class FrontCameraCard extends StatelessWidget {
  const FrontCameraCard({super.key, required this.rearConnected});

  /// The back camera is there: no need to warn that rear alerts are off.
  final bool rearConnected;

  @override
  Widget build(BuildContext context) {
    final eyes = context.watch<PhoneEyes>();
    final feed = eyes.frontFeed;
    final c = context.colors;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(icon: Symbols.photo_camera_front_rounded, title: 'Front camera'),
          SizedBox(height: context.space.s),
          if (feed != null)
            ListenableBuilder(
              listenable: Listenable.merge([feed.frame, feed.fps]),
              builder: (context, _) {
                final objects = eyes.nearwork.last;
                final nearest = objects.firstOrNull;
                final t = DateTime.now().millisecondsSinceEpoch / 1000;
                final ahead = eyes.aheadCm(t);
                final status = [
                  if (nearest == null)
                    'No screen or book in view'
                  else
                    '${nearWorkName(nearest.kind)}, about ${nearest.distanceCm.round()} cm away',
                  if (ahead != null) '${ahead.round()} cm ahead',
                  '${feed.fps.value} fps',
                ].join(' · ');
                return Semantics(
                  label: 'Front camera. $status',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LiveCameraPicture(
                        frame: feed.frame.value,
                        overlay: objects.isEmpty
                            ? null
                            : _NearWorkPainter(
                                objects,
                                line: c.background,
                                edge: c.textPrimary,
                                labelStyle: context.type.label.copyWith(color: c.background),
                              ),
                      ),
                      SizedBox(height: context.space.s),
                      ExcludeSemantics(child: Text(status, style: context.type.body)),
                    ],
                  ),
                );
              },
            ),
          if (!rearConnected) ...[
            SizedBox(height: context.space.s),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: Icon(Symbols.link_off_rounded, size: 20, color: c.textSecondary)),
                SizedBox(width: context.space.s),
                Expanded(
                  child: Text(
                    "Back camera not connected: no alerts from behind. Turn on the glasses and your phone's hotspot.",
                    style: context.type.caption.copyWith(color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A box and "Laptop · 62 cm" on each screen or book found.
class _NearWorkPainter extends CustomPainter {
  _NearWorkPainter(this.objects, {required this.line, required this.edge, required this.labelStyle});

  final List<NearObject> objects;
  final Color line, edge;
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    for (final o in objects) {
      final b = o.box;
      final rect = Rect.fromLTRB(
        b.left * size.width,
        b.top * size.height,
        b.right * size.width,
        b.bottom * size.height,
      );
      for (final (width, color) in [(5.0, edge), (2.5, line)]) {
        canvas.drawRect(
          rect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = width
            ..color = color,
        );
      }
      final tp = TextPainter(
        text: TextSpan(text: '${nearWorkName(o.kind)} · ${o.distanceCm.round()} cm', style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width);
      const pad = 4.0;
      final top = rect.top - tp.height - pad * 2 < 0 ? rect.top : rect.top - tp.height - pad * 2;
      final left = rect.left.clamp(0.0, size.width - tp.width - pad * 2);
      final bg = Rect.fromLTWH(left, top, tp.width + pad * 2, tp.height + pad * 2);
      canvas.drawRRect(RRect.fromRectAndRadius(bg, const Radius.circular(6)), Paint()..color = edge);
      tp.paint(canvas, Offset(bg.left + pad, bg.top + pad));
    }
  }

  @override
  bool shouldRepaint(_NearWorkPainter old) => true; // a new frame each time
}
