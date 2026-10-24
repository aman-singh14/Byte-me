// "Privacy you can see": a chip that states what is (not) tracked, right where
// it happens. Tap for one plain sentence of detail.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

class PrivacyChip extends StatelessWidget {
  const PrivacyChip({super.key, required this.icon, required this.label, required this.detail});

  /// Shown on the rear view and in the status strip.
  const PrivacyChip.nothingRecorded({super.key})
    : icon = Symbols.videocam_off_rounded,
      label = 'Nothing recorded',
      detail =
          'Video is checked on your phone and thrown away right after. '
          'No video or audio is ever saved.';

  /// Shown next to anything friends can see.
  const PrivacyChip.ringsOnly({super.key})
    : icon = Symbols.lock_rounded,
      label = 'Friends see your ring % only',
      detail =
          'Only your ring percentages leave this phone. '
          'Sensor data, video and audio stay here.';

  final IconData icon;
  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon),
      label: Text(label),
      tooltip: 'About: $label',
      onPressed: () => showAdaptiveDialog<void>(
        context: context,
        builder: (context) => AlertDialog.adaptive(
          title: Text(label),
          content: Text(detail),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))],
        ),
      ),
    );
  }
}
