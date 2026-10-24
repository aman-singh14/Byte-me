// Together on every tab: group break reminders and side quest stars, and
// the Quests card on Today.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../alerts/voice.dart';
import '../components/celebration.dart';
import '../components/common.dart';
import '../components/social.dart';
import '../social/side_quests.dart';
import '../social/social_store.dart';
import '../theme/theme.dart';
import 'together_screen.dart';

/// Group break reminders and side quest stars, once
/// for the whole app. Play register: warm words, celebrations, no alarms.
class TogetherAnnouncer extends StatefulWidget {
  const TogetherAnnouncer({super.key, required this.child});

  final Widget child;

  @override
  State<TogetherAnnouncer> createState() => _TogetherAnnouncerState();
}

class _TogetherAnnouncerState extends State<TogetherAnnouncer> {
  final _subs = <StreamSubscription<Object>>[];
  late final Voice? _voice = context.read<Voice?>();

  @override
  void initState() {
    super.initState();
    _subs.add(context.read<SocialStore>().events.listen(_onTogether));
    _subs.add(context.read<SideQuestStore>().starred.listen(_onStar));
  }

  void _say(String sentence, {bool speak = false}) {
    if (!mounted) return;
    announce(context, sentence);
    if (speak && !MediaQuery.accessibleNavigationOf(context)) _voice?.say(sentence);
  }

  void _onTogether(TogetherEvent e) {
    if (!mounted) return;
    switch (e) {
      case BreakStarted(:final group, :final brk):
        HapticFeedback.mediumImpact();
        _say('${group.name} screen break. Look up and talk for ${brk.minutes} minutes.', speak: true);
        _snack('${group.name} screen break: look up and talk for ${brk.minutes} min.');
    }
  }

  void _onStar(StarEarned e) {
    if (!mounted) return;
    final week = context.read<SideQuestStore>().starsThisWeek;
    // Friends this star just moved you past.
    final passed = [
      for (final f in context.read<SocialStore>().friends)
        if (f.starsThisWeek >= week - e.gained && f.starsThisWeek < week) f.name,
    ];
    final stars = e.stars == e.quest.maxStars
        ? 'all ${e.quest.maxStars} stars'
        : '${e.stars} of ${e.quest.maxStars} stars';
    celebrate(
      context,
      '${e.quest.title}: $stars.${passed.isEmpty ? '' : ' You passed ${passed.join(' and ')} this week.'}',
    );
  }

  void _snack(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Today's Quests card: the next group break, then each side quest's stars.
class QuestsTodayCard extends StatelessWidget {
  const QuestsTodayCard({super.key});

  @override
  Widget build(BuildContext context) {
    final social = context.watch<SocialStore>();
    final quests = context.watch<SideQuestStore>();
    final next = social.nextBreak;
    final space = context.space;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CardTitle(
                icon: Symbols.flag_rounded,
                title: 'Side quests · ${quests.starsToday} of $maxStarsPerDay stars',
              ),
              SizedBox(height: space.s),
              if (next != null) BreakLine(group: next.$1, brk: next.$2, showGroup: true),
              for (final q in sideQuests)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: space.xs),
                  child: Semantics(
                    label:
                        '${q.title}: ${questProgressText(q, quests.progress(q))}, ${quests.stars(q)} of ${q.maxStars} stars.',
                    child: ExcludeSemantics(
                      child: Row(
                        children: [
                          Icon(q.icon, color: context.colors.textPrimary),
                          SizedBox(width: space.m),
                          Expanded(child: Text(q.title, style: context.type.label)),
                          StarRow(stars: quests.stars(q), of: q.maxStars, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
