// Aware: rear view, alerts, social taps, captions, "Who's around me?".
// Phase 1 step 1 only shows whether the rear camera has been found.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../components/common.dart';
import '../components/privacy_chip.dart';
import '../net/glasses_link.dart';
import '../theme/theme.dart';
import 'home_shell.dart';

class AwareScreen extends StatelessWidget {
  const AwareScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final url = context.select<GlassesLink, Uri?>((l) => l.streamUrl);
    return TabPage(
      title: 'Aware',
      children: [
        OmniCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CardTitle(icon: Symbols.videocam_rounded, title: 'Rear view'),
              SizedBox(height: context.space.s),
              Text(url == null ? 'Rear camera not found yet.' : 'Rear camera found at $url', style: context.type.body),
              SizedBox(height: context.space.s),
              Text(
                'Live view with labeled boxes arrives in phase 1 step 2.',
                style: context.type.body.copyWith(color: context.colors.textSecondary),
              ),
              SizedBox(height: context.space.m),
              const PrivacyChip.nothingRecorded(),
            ],
          ),
        ),
      ],
    );
  }
}
