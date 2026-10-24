// Today: the balanced overview (home). Cards in DESIGN.md order.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../components/common.dart';
import 'home_shell.dart';
import 'link_widgets.dart';
import 'settings_screen.dart';

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return TabPage(
      title: 'Today',
      linkBanner: false,
      actions: [
        IconButton(
          icon: const Icon(Symbols.account_circle_rounded),
          tooltip: 'Settings and privacy',
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
        ),
      ],
      children: const [
        LiveStatusStrip(),
        PlaceholderCard(
          icon: Symbols.eye_tracking_rounded,
          title: 'Rings',
          text: 'Heads-up and Outside rings arrive in phase 3.',
        ),
        PlaceholderCard(
          icon: Symbols.radar_rounded,
          title: 'Awareness',
          text: "Last alert and \"Who's around me?\" arrive in phases 1 and 2.",
        ),
        PlaceholderCard(
          icon: Symbols.visibility_rounded,
          title: 'Eyes',
          text: 'Close-up minutes and blink rate arrive in phase 3.',
        ),
        PlaceholderCard(
          icon: Symbols.groups_rounded,
          title: 'Quests',
          text: 'Group and side quests arrive in phase 3.',
        ),
      ],
    );
  }
}
