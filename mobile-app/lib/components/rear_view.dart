// RearView: the live rear camera with labeled boxes and a "Nothing recorded"
// chip. Safety register: neutral, literal labels, no animation.
//
// The image is shown mirrored, like a rear-view mirror, so something on the
// wearer's left appears on the left of the screen. Box labels also name the
// wearer's side, so the view never depends on getting the mirror right.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../net/protocol.dart';
import '../theme/theme.dart';
import '../vision/detector.dart';
import 'common.dart';
import 'privacy_chip.dart';

class RearView extends StatelessWidget {
  const RearView({
    super.key,
    required this.frame,
    required this.detections,
    this.placeholder = 'Rear camera not found yet.',
    this.mirror = true,
    this.notes,
  });

  /// Newest JPEG frame, or null when there is no video.
  final Uint8List? frame;
  final List<Detection> detections;

  /// What to say when [frame] is null.
  final String placeholder;

  /// Show the image like a rear-view mirror (wearer's left on screen left).
  final bool mirror;

  /// Extra text per box, same order as [detections] (debug builds: time to
  /// contact).
  final List<String?>? notes;

  /// "Rear view. Car on your left. Person on your right."
  String get semanticLabel {
    if (frame == null) return 'Rear view. $placeholder';
    if (detections.isEmpty) return 'Rear view. Nothing detected behind you.';
    final things = detections.map((d) => '${capitalize(d.label)} ${_where(d.side)}.').join(' ');
    return 'Rear view. $things';
  }

  static String _where(WearerSide s) => switch (s) {
    WearerSide.left => 'on your left',
    WearerSide.right => 'on your right',
    WearerSide.behind => 'straight behind you',
  };

  @override
  Widget build(BuildContext context) {
    final jpeg = frame;
    const chip = PrivacyChip.nothingRecorded();
    final chipAt = context.space.s;

    // No video: size to the message (it must fit at 200% text), at least 4:3.
    if (jpeg == null && detections.isEmpty) {
      return Semantics(
        label: semanticLabel,
        child: ClipRRect(
          borderRadius: context.radii.cardRadius,
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth, minHeight: constraints.maxWidth * 3 / 4),
                  child: ExcludeSemantics(child: _Placeholder(text: placeholder)),
                ),
                Positioned(left: chipAt, top: chipAt, child: chip),
              ],
            ),
          ),
        ),
      );
    }

    final c = context.colors;
    return Semantics(
      label: semanticLabel,
      child: ClipRRect(
        borderRadius: context.radii.cardRadius,
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ExcludeSemantics(
                child: jpeg == null
                    ? ColoredBox(color: c.surfaceAlt)
                    : Transform.flip(
                        flipX: mirror,
                        child: Image.memory(jpeg, gaplessPlayback: true, fit: BoxFit.cover),
                      ),
              ),
              ExcludeSemantics(
                child: CustomPaint(
                  painter: _BoxPainter(
                    detections: detections,
                    notes: notes,
                    mirror: mirror,
                    line: c.background,
                    edge: c.textPrimary,
                    labelStyle: context.type.label.copyWith(color: c.background),
                  ),
                ),
              ),
              // Bottom, so it never covers box labels (drawn above each box).
              Positioned(left: chipAt, bottom: chipAt, child: chip),
            ],
          ),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfaceAlt,
      child: Center(
        child: Padding(
          // Top padding keeps the message clear of the privacy chip.
          padding: EdgeInsets.fromLTRB(
            context.space.l,
            context.space.xxxl + context.space.l,
            context.space.l,
            context.space.l,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Symbols.videocam_off_rounded, size: 32, color: c.textSecondary),
              SizedBox(height: context.space.s),
              Text(text, textAlign: TextAlign.center, style: context.type.body),
            ],
          ),
        ),
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter({
    required this.detections,
    required this.notes,
    required this.mirror,
    required this.line,
    required this.edge,
    required this.labelStyle,
  });

  final List<Detection> detections;
  final List<String?>? notes;
  final bool mirror;
  final Color line; // light stroke
  final Color edge; // dark stroke and label background, so boxes show on any video
  final TextStyle labelStyle;

  @override
  void paint(Canvas canvas, Size size) {
    for (final (i, d) in detections.indexed) {
      final b = d.box;
      final left = mirror ? 1 - b.right : b.left;
      final rect = Rect.fromLTWH(left * size.width, b.top * size.height, b.width * size.width, b.height * size.height);

      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..color = edge,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = line,
      );

      final side = d.side.name; // left, right, behind
      final tp = TextPainter(
        text: TextSpan(text: '${capitalize(d.label)} · $side${_note(i)}', style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: size.width);
      const pad = 4.0;
      var labelTop = rect.top - tp.height - pad * 2;
      if (labelTop < 0) labelTop = rect.top; // no room above: put it inside
      final labelLeft = rect.left.clamp(0.0, size.width - tp.width - pad * 2);
      final bg = Rect.fromLTWH(labelLeft, labelTop, tp.width + pad * 2, tp.height + pad * 2);
      canvas.drawRRect(RRect.fromRectAndRadius(bg, const Radius.circular(6)), Paint()..color = edge);
      tp.paint(canvas, Offset(bg.left + pad, bg.top + pad));
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.detections != detections ||
      old.notes != notes ||
      old.mirror != mirror ||
      old.line != line ||
      old.edge != edge;

  String _note(int i) {
    final n = notes;
    final note = n != null && i < n.length ? n[i] : null;
    return note == null ? '' : ' · $note';
  }
}
