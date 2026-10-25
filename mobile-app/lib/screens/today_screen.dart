// Today: the balanced overview (home). Cards in DESIGN.md order.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../alerts/alert_service.dart';
import '../components/common.dart';
import '../components/event_log.dart';
import '../settings/feature_flags.dart';
import '../theme/theme.dart';
import 'alert_widgets.dart';
import 'captions_widgets.dart';
import 'ask_widgets.dart';
import 'home_shell.dart';
import 'together_widgets.dart';
import 'link_widgets.dart';
import 'helper_screen.dart';
import 'rings_widgets.dart';
import 'settings_screen.dart';

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final alerts = context.watch<AlertService>();
    final following = alerts.following;
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
      children: [
        const LiveStatusStrip(),
        const AskCard(),
        if (context.watch<FeatureFlags>()[Feature.captions]) const CaptionsQuickCard(),
        const RingsCard(),
        if (alerts.socialTap != null) const LiveSocialTapCard(),
        if (following != null) const LiveFollowingCard(),
        const HelperCallCard(),
        const _AwarenessCard(),
        const EyesSummaryCard(),
        const QuestsTodayCard(),
      ],
    );
  }
}

/// Last alert or social tap with its time and side. "Who's around me?" comes in phase 2.
class _AwarenessCard extends StatelessWidget {
  const _AwarenessCard();

  @override
  Widget build(BuildContext context) {
    final latest = context.watch<AlertService>().log.latest;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(icon: Symbols.radar_rounded, title: 'Awareness'),
          SizedBox(height: context.space.s),
          if (latest == null)
            Text('No alerts yet.', style: context.type.body.copyWith(color: context.colors.textSecondary))
          else
            LogEntryRow(entry: latest),
          SizedBox(height: context.space.s),
          Text(
            "\"Who's around me?\" arrives in phase 2.",
            style: context.type.caption.copyWith(color: context.colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
