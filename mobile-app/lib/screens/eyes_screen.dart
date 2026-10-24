// Eyes: eye-health dashboard. Phase 1 step 1 shows the live sensor values so
// you can see the link working. Nothing here is stored.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../components/common.dart';
import '../net/glasses_link.dart';
import '../net/protocol.dart';
import '../theme/theme.dart';
import 'home_shell.dart';

class EyesScreen extends StatelessWidget {
  const EyesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final link = context.read<GlassesLink>();
    return TabPage(
      title: 'Eyes',
      children: [
        OmniCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CardTitle(icon: Symbols.straighten_rounded, title: 'Right now'),
              SizedBox(height: context.space.s),
              StreamBuilder<SensMessage>(
                stream: link.sens,
                builder: (context, snap) {
                  final s = snap.data;
                  if (s == null) {
                    return Text('Waiting for the glasses.', style: context.type.body);
                  }
                  return Text('${s.distCm} cm to what you are looking at. ${s.lux} lux.', style: context.type.body);
                },
              ),
            ],
          ),
        ),
        const PlaceholderCard(
          icon: Symbols.visibility_rounded,
          title: 'Habits linked to eye strain',
          text: 'Close-up time, reading distance, blink rate, longest session and breaks arrive in phase 3.',
        ),
      ],
    );
  }
}
