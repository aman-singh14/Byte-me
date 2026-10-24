// Together: rings detail, friends, groups, quests (phase 3).

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../components/common.dart';
import '../components/privacy_chip.dart';
import 'home_shell.dart';

class TogetherScreen extends StatelessWidget {
  const TogetherScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const TabPage(
      title: 'Together',
      children: [
        Align(alignment: Alignment.centerLeft, child: PrivacyChip.ringsOnly()),
        PlaceholderCard(
          icon: Symbols.groups_rounded,
          title: 'Friends and groups',
          text: 'Friends, team rings, group breaks and quests arrive in phase 3.',
        ),
      ],
    );
  }
}
