// Profiles in Together: a person (friend or teammate) and a team from the
// league. Bottom sheets with this week's side quest stars and rings. Only
// what the server shares: names, ring percentages and star counts.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../components/ring_stack.dart';
import '../components/social.dart';
import '../social/side_quests.dart';
import '../social/social_api.dart';
import '../social/social_store.dart';
import '../theme/theme.dart';

Future<T?> _sheet<T>(BuildContext context, Widget child) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.75,
    maxChildSize: 0.95,
    builder: (context, scroll) => SingleChildScrollView(
      controller: scroll,
      padding: EdgeInsets.fromLTRB(context.space.page, 0, context.space.page, context.space.xl),
      child: child,
    ),
  ),
);

/// [person]'s profile. [onRemove] adds "Remove friend".
Future<void> showPersonSheet(
  BuildContext context,
  Person person, {
  String? subtitle,
  Future<void> Function()? onRemove,
}) => _sheet(context, _PersonProfile(person: person, subtitle: subtitle, onRemove: onRemove));

/// A team's page: points, rings, quest stars and members.
Future<void> showTeamSheet(BuildContext context, LeagueTeam team) =>
    _sheet(context, _TeamProfile(team: team, social: context.read<SocialStore>()));

class _PersonProfile extends StatelessWidget {
  const _PersonProfile({required this.person, this.subtitle, this.onRemove});

  final Person person;
  final String? subtitle;
  final Future<void> Function()? onRemove;

  @override
  Widget build(BuildContext context) {
    final p = person;
    final space = context.space;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(initial: p.name, title: p.name, subtitle: subtitle),
        SizedBox(height: space.l),
        _Stats([
          ('${p.starsThisWeek}', 'stars this week', Symbols.star_rounded),
          ('${p.ringWeek}%', 'average ring this week', Symbols.donut_large_rounded),
        ]),
        SizedBox(height: space.l),
        _Section('Today'),
        RingStack(
          rings: [
            RingData.percent(RingKind.headsUp, p.headsUp, note: 'Today'),
            RingData.percent(RingKind.outside, p.outside, note: 'Today'),
          ],
          size: 104,
        ),
        SizedBox(height: space.l),
        _Section('Side quests this week'),
        _QuestStars(p.questsThisWeek),
        if (onRemove != null) ...[
          SizedBox(height: space.l),
          OutlinedButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              await onRemove!();
            },
            icon: const Icon(Symbols.person_remove_rounded),
            label: const Text('Remove friend'),
          ),
        ],
      ],
    );
  }
}

class _TeamProfile extends StatefulWidget {
  const _TeamProfile({required this.team, required this.social});

  final LeagueTeam team;
  final SocialStore social;

  @override
  State<_TeamProfile> createState() => _TeamProfileState();
}

class _TeamProfileState extends State<_TeamProfile> {
  late final Future<(TeamDetails?, String?)> _details = widget.social.team(widget.team);

  @override
  Widget build(BuildContext context) {
    final t = widget.team;
    final space = context.space;
    final count = '${t.members} ${t.members == 1 ? 'member' : 'members'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          initial: t.name,
          title: t.name,
          subtitle: '${_ordinal(t.rank)} in the league · $count${t.mine ? ' · your team' : ''}',
        ),
        SizedBox(height: space.l),
        _Stats([
          ('${t.points}', 'points this week', Symbols.emoji_events_rounded),
          (formatStars(t.stars), 'stars per member', Symbols.star_rounded),
          ('${t.ringWeek}%', 'average ring this week', Symbols.donut_large_rounded),
        ]),
        SizedBox(height: space.s),
        Text(
          'Points: ${formatStars(t.stars)} stars × 10 + ${t.ringWeek}% average ring.',
          style: context.type.caption.copyWith(color: context.colors.textSecondary),
        ),
        SizedBox(height: space.l),
        _Section('Today, team average'),
        RingStack(
          rings: [
            RingData.percent(RingKind.headsUp, t.headsUp, note: 'Average today'),
            RingData.percent(RingKind.outside, t.outside, note: 'Average today'),
            RingData.percent(RingKind.team, t.ringToday, note: 'Team ring'),
          ],
          size: 120,
        ),
        SizedBox(height: space.l),
        _Section('Side quests this week, whole team'),
        _QuestStars(t.quests),
        SizedBox(height: space.l),
        _Section('Members'),
        FutureBuilder(
          future: _details,
          builder: (context, snap) {
            final (details, error) = snap.data ?? (null, null);
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (details == null) {
              return Text(error ?? "Couldn't load the members.", style: context.type.body);
            }
            return Column(
              children: [
                for (final p in details.people)
                  LeaderboardRow(
                    rank: details.people.indexOf(p) + 1,
                    name: p.name,
                    stars: p.starsThisWeek,
                    subtitle: 'Heads-up ${p.headsUp}% · outside ${p.outside}% today',
                    onTap: () => showPersonSheet(context, p, subtitle: 'On ${t.name}'),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

String _ordinal(int n) {
  final suffix = n % 100 >= 11 && n % 100 <= 13 ? 'th' : const {1: 'st', 2: 'nd', 3: 'rd'}[n % 10] ?? 'th';
  return '$n$suffix';
}

class _Header extends StatelessWidget {
  const _Header({required this.initial, required this.title, this.subtitle});

  final String initial;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        InitialAvatar(name: initial, size: 56),
        SizedBox(width: context.space.m),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(header: true, child: Text(title, style: context.type.title)),
              if (subtitle != null)
                Text(subtitle!, style: context.type.body.copyWith(color: context.colors.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: context.space.s),
    child: Semantics(header: true, child: Text(title, style: context.type.headline)),
  );
}

/// Big numbers side by side, as equal columns when they fit: (value, label,
/// icon).
class _Stats extends StatelessWidget {
  const _Stats(this.stats);
  final List<(String, String, IconData)> stats;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final space = context.space;
    Widget tile((String, String, IconData) stat) {
      final (value, label, icon) = stat;
      return Semantics(
        label: '$value $label',
        child: ExcludeSemantics(
          child: Container(
            padding: EdgeInsets.all(space.m),
            decoration: BoxDecoration(color: c.surfaceAlt, borderRadius: context.radii.cardRadius),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: c.brand, fill: 1, size: 20),
                    SizedBox(width: space.xs),
                    Flexible(child: Text(value, style: context.type.title)),
                  ],
                ),
                Text(label, style: context.type.caption.copyWith(color: c.textSecondary)),
              ],
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(1);
        if (constraints.maxWidth < stats.length * 104 * scale) {
          return Wrap(spacing: space.s, runSpacing: space.s, children: [for (final s in stats) tile(s)]);
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, s) in stats.indexed) ...[if (i > 0) SizedBox(width: space.s), Expanded(child: tile(s))],
            ],
          ),
        );
      },
    );
  }
}

/// Stars this week for each side quest.
class _QuestStars extends StatelessWidget {
  const _QuestStars(this.byQuest);
  final Map<String, int> byQuest;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final space = context.space;
    return Column(
      children: [
        for (final q in sideQuests)
          Semantics(
            label: '${q.title}: ${byQuest[q.id] ?? 0} stars this week.',
            child: ExcludeSemantics(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: space.xs),
                child: Row(
                  children: [
                    Icon(q.icon, color: c.textPrimary),
                    SizedBox(width: space.m),
                    Expanded(child: Text(q.title, style: context.type.label)),
                    Icon(Symbols.star_rounded, color: c.brand, fill: 1, size: 20),
                    SizedBox(width: space.xs),
                    Text('${byQuest[q.id] ?? 0}', style: context.type.headline),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
