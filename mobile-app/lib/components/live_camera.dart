// LiveCameraPicture: a glasses camera's newest frame at 4:3, with an optional
// overlay and the "Nothing recorded" chip. Used for the eye and front cameras.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/theme.dart';
import 'privacy_chip.dart';

class LiveCameraPicture extends StatelessWidget {
  const LiveCameraPicture({super.key, required this.frame, this.overlay});

  /// The newest JPEG, or null while connecting.
  final Uint8List? frame;

  /// Drawn over the picture (0..1 of its size), when there is one.
  final CustomPainter? overlay;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final jpeg = frame;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: context.radii.cardRadius,
        child: AspectRatio(
          aspectRatio: 4 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (jpeg == null)
                ColoredBox(
                  color: c.surfaceAlt,
                  child: Icon(Symbols.videocam_off_rounded, size: 32, color: c.textSecondary),
                )
              else
                Image.memory(jpeg, gaplessPlayback: true, fit: BoxFit.cover),
              if (jpeg != null && overlay != null) CustomPaint(painter: overlay),
              Positioned(left: context.space.s, bottom: context.space.s, child: const PrivacyChip.nothingRecorded()),
            ],
          ),
        ),
      ),
    );
  }
}
