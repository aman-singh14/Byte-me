// Together: your team and its team ring, group screen break reminders,
// the team league, time with friends (best friends), the weekly star
// leaderboard, side quests. Play register. Only names, ring percentages and star counts are
// shared.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../components/common.dart';
import '../components/ring_stack.dart';
import '../components/social.dart';
import '../social/side_quests.dart';
import '../social/social_api.dart';
import '../social/social_store.dart';
import '../social/together_time.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'profile_sheets.dart';
import 'rings_widgets.dart';

class TogetherScreen extends StatelessWidget {
  const TogetherScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final social = context.watch<SocialStore>();
    return TabPage(
      title: 'Together',
      children: [
        if (social.offline)
          Text(
            "Can't reach the Together server. Showing what was last loaded.",
            style: context.type.body.copyWith(color: context.colors.textSecondary),
          ),
        // Rings detail (from the laptop backend) first, then friends and groups.
        const RingsHistoryCard(key: ValueKey('rings week')),
        if (!social.signedIn)
          const _JoinCard()
        else ...[
          // Keyed, so a card keeps its state (and its ring doesn't replay)
          // when cards above it come and go.
          for (final g in social.groups) _GroupCard(key: ValueKey('group ${g.id}'), group: g),
          if (social.groups.isEmpty) const _NoGroupCard(),
          if (social.league.isNotEmpty) const _LeagueCard(key: ValueKey('league')),
          const LiveTogetherTimeCard(key: ValueKey('together time')),
          const _LeaderboardCard(key: ValueKey('leaderboard')),
        ],
        const SideQuestList(key: ValueKey('side quests')),
      ],
    );
  }
}

/// Shows [message] at the bottom, if there is one.
void _say(BuildContext context, String? message) {
  if (message == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// Runs a Together action and shows its error, or [done] if it worked.
/// The messenger is looked up first, so it works after the await.
Future<void> _run(BuildContext context, Future<String?> Function() action, {String? done}) async {
  final messenger = ScaffoldMessenger.of(context);
  final text = await action() ?? done;
  if (text != null) messenger.showSnackBar(SnackBar(content: Text(text)));
}

/// A one-field dialog. Returns the text, or null if cancelled.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  required String action,
  String? hint,
  bool code = false,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: code ? 12 : 24,
        textCapitalization: code ? TextCapitalization.characters : TextCapitalization.words,
        decoration: InputDecoration(labelText: label, hintText: hint),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(action)),
      ],
    ),
  );
}

Future<void> _copy(BuildContext context, String text, String what) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) _say(context, '$what copied.');
}

// --- signing up ---------------------------------------------------------------

class _JoinCard extends StatefulWidget {
  const _JoinCard();

  @override
  State<_JoinCard> createState() => _JoinCardState();
}

class _JoinCardState extends State<_JoinCard> {
  final _name = TextEditingController();
  bool _busy = false;

  Future<void> _join() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    final error = await context.read<SocialStore>().signUp(name);
    if (mounted) setState(() => _busy = false);
    if (mounted) _say(context, error);
  }

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(icon: Symbols.groups_rounded, title: 'Join Together'),
          SizedBox(height: space.s),
          Text(
            'Race friends for side quest stars, make a team, and take screen breaks together. '
            'Pick the name friends will see. No account or password.',
            style: context.type.body,
          ),
          SizedBox(height: space.m),
          TextField(
            controller: _name,
            maxLength: 24,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Your name'),
            onSubmitted: (_) => _join(),
          ),
          SizedBox(height: space.s),
          FilledButton(onPressed: _busy ? null : _join, child: Text(_busy ? 'Joining…' : 'Join Together')),
        ],
      ),
    );
  }
}

// --- groups ----------------------------------------------------------------------

class _NoGroupCard extends StatelessWidget {
  const _NoGroupCard();

  @override
  Widget build(BuildContext context) {
    final social = context.read<SocialStore>();
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(icon: Symbols.group_add_rounded, title: 'Your team'),
          SizedBox(height: context.space.s),
          Text('Make a team to share a team ring and take group screen breaks.', style: context.type.body),
          SizedBox(height: context.space.m),
          Wrap(
            spacing: context.space.s,
            runSpacing: context.space.s,
            children: [
              FilledButton(
                onPressed: () async {
                  final name = await askText(context, title: 'Make a team', label: 'Team name', action: 'Make');
                  if (name != null && name.isNotEmpty && context.mounted) {
                    _run(context, () => social.createGroup(name));
                  }
                },
                child: const Text('Make a team'),
              ),
              OutlinedButton(
                onPressed: () async {
                  final code = await askText(
                    context,
                    title: 'Join a team',
                    label: 'Team code',
                    hint: 'From a teammate',
                    action: 'Join',
                    code: true,
                  );
                  if (code != null && code.isNotEmpty && context.mounted) _run(context, () => social.joinGroup(code));
                },
                child: const Text('Join with a code'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({super.key, required this.group});

  final Group group;

  @override
  Widget build(BuildContext context) {
    final social = context.read<SocialStore>();
    final me = social.me;
    final space = context.space;
    final g = group;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardTitle(icon: Symbols.groups_rounded, title: g.name),
          SizedBox(height: space.m),
          RingStack(rings: [RingData.percent(RingKind.team, g.team, note: 'Team average')], size: 112),
          SizedBox(height: space.m),
          for (final m in g.members)
            FriendRow(
              name: m.id == me?.id ? '${m.name} (you)' : m.name,
              headsUpPercent: m.headsUp,
              outsidePercent: m.outside,
              onTap: () => showPersonSheet(context, m, subtitle: m.id == me?.id ? 'You' : 'On ${g.name}'),
            ),
          SizedBox(height: space.m),
          for (final b in g.breaks) BreakLine(group: g, brk: b),
          SizedBox(height: space.s),
          FilledButton.icon(
            onPressed: () => showScheduleSheet(context, g),
            icon: const Icon(Symbols.event_rounded),
            label: const Text('Schedule a group screen break'),
          ),
          SizedBox(height: space.s),
          Wrap(
            spacing: space.s,
            runSpacing: space.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Team code: ${g.inviteCode}', style: context.type.label),
              TextButton.icon(
                onPressed: () => _copy(context, g.inviteCode, 'Team code'),
                icon: const Icon(Symbols.content_copy_rounded),
                label: const Text('Copy'),
              ),
            ],
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: g.isPublic,
            title: const Text('Public team'),
            subtitle: const Text('In the team league, with a page anyone can open.'),
            onChanged: (on) async => _run(context, () => social.setPublic(g, on)),
          ),
          if (g.isPublic)
            Wrap(
              spacing: space.s,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(social.teamPage(g).toString(), style: context.type.caption),
                TextButton.icon(
                  onPressed: () => _copy(context, social.teamPage(g).toString(), 'Link'),
                  icon: const Icon(Symbols.public_rounded),
                  label: const Text('Copy link'),
                ),
              ],
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () async => _run(context, () => social.leaveGroup(g)),
              child: const Text('Leave team'),
            ),
          ),
        ],
      ),
    );
  }
}

// --- group screen breaks -------------------------------------------------------

/// When and how long: a bottom sheet with a few quick choices.
Future<void> showScheduleSheet(BuildContext context, Group group) async {
  final social = context.read<SocialStore>();
  final picked = await showModalBottomSheet<(DateTime, int)>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _ScheduleSheet(),
  );
  if (picked == null || !context.mounted) return;
  await _run(context, () => social.scheduleBreak(group, picked.$1, minutes: picked.$2), done: 'Group break scheduled.');
}

class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet();

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  static const _quick = [0, 5, 15, 30]; // minutes from now
  int? _inMinutes = 5;
  TimeOfDay? _at;
  int _length = 10;

  DateTime get _start {
    final now = DateTime.now();
    final at = _at;
    if (at == null) return now.add(Duration(minutes: _inMinutes ?? 0));
    var t = DateTime(now.year, now.month, now.day, at.hour, at.minute);
    if (t.isBefore(now)) t = t.add(const Duration(days: 1));
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    final l = MaterialLocalizations.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(space.page, space.l, space.page, space.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(header: true, child: Text('Group screen break', style: context.type.title)),
            SizedBox(height: space.s),
            Text("Everyone on the team gets a nudge on their glasses to look up and talk.", style: context.type.body),
            SizedBox(height: space.l),
            Text('When', style: context.type.label),
            SizedBox(height: space.s),
            Wrap(
              spacing: space.s,
              runSpacing: space.s,
              children: [
                for (final m in _quick)
                  ChoiceChip(
                    label: Text(m == 0 ? 'Now' : 'In $m min'),
                    selected: _at == null && _inMinutes == m,
                    onSelected: (_) => setState(() {
                      _inMinutes = m;
                      _at = null;
                    }),
                  ),
                ChoiceChip(
                  label: Text(_at == null ? 'Pick a time' : l.formatTimeOfDay(_at!)),
                  selected: _at != null,
                  onSelected: (_) async {
                    final t = await showTimePicker(context: context, initialTime: TimeOfDay.now());
                    if (t != null) {
                      setState(() {
                        _inMinutes = null;
                        _at = t;
                      });
                    }
                  },
                ),
              ],
            ),
            SizedBox(height: space.l),
            Text('How long', style: context.type.label),
            SizedBox(height: space.s),
            Wrap(
              spacing: space.s,
              runSpacing: space.s,
              children: [
                for (final m in const [10, 15, 20])
                  ChoiceChip(
                    label: Text('$m min'),
                    selected: _length == m,
                    onSelected: (_) => setState(() => _length = m),
                  ),
              ],
            ),
            SizedBox(height: space.xl),
            FilledButton(onPressed: () => Navigator.pop(context, (_start, _length)), child: const Text('Schedule')),
          ],
        ),
      ),
    );
  }
}

int _minutesUntil(DateTime t, DateTime now) => (t.difference(now).inSeconds / 60).ceil().clamp(1, 100000);

/// One group screen break as a line: "Screen break now · 6 m left" or
/// "Screen break at 3:00 PM · 10 min", with Cancel before it starts. Ticks
/// while on screen so the time stays current.
class BreakLine extends StatefulWidget {
  const BreakLine({super.key, required this.group, required this.brk, this.showGroup = false});

  final Group group;
  final GroupBreak brk;

  /// Say which team ("Byte-me screen break"), for outside the team card.
  final bool showGroup;

  @override
  State<BreakLine> createState() => _BreakLineState();
}

class _BreakLineState extends State<BreakLine> {
  late final Timer _tick = Timer.periodic(const Duration(seconds: 15), (_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    _tick;
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.brk;
    final c = context.colors;
    final now = DateTime.now();
    final l = MaterialLocalizations.of(context);
    final starts = l.formatTimeOfDay(
      TimeOfDay.fromDateTime(b.startsAt),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
    final name = widget.showGroup ? '${widget.group.name} screen break' : 'Screen break';
    final running = !now.isBefore(b.startsAt);
    final text = running
        ? '$name now · ${formatMinutes(_minutesUntil(b.endsAt, now))} left'
        : '$name at $starts · ${b.minutes} min';
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.space.xs),
      child: Row(
        children: [
          Icon(running ? Symbols.visibility_rounded : Symbols.event_rounded, color: running ? c.brand : c.textPrimary),
          SizedBox(width: context.space.s),
          Expanded(child: Text(text, style: context.type.label)),
          if (!running)
            TextButton(
              onPressed: () =>
                  _run(context, () => context.read<SocialStore>().cancelBreak(b), done: 'Break cancelled.'),
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }
}

// --- team league ---------------------------------------------------------------

/// Teams against teams: public teams and yours, by points this week (10 per
/// side quest star per member, plus the average ring), so a small team can
/// win. Tap a team for its page.
class _LeagueCard extends StatelessWidget {
  const _LeagueCard({super.key});

  @override
  Widget build(BuildContext context) {
    final social = context.watch<SocialStore>();
    final private = social.groups.where((g) => !g.isPublic).toList();
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(icon: Symbols.emoji_events_rounded, title: 'Team league'),
          Text(
            '10 points per star per member, plus the average ring',
            style: context.type.body.copyWith(color: context.colors.textSecondary),
          ),
          SizedBox(height: context.space.s),
          for (final t in social.league)
            LeaderboardRow(
              rank: t.rank,
              name: t.name,
              stars: t.stars,
              points: t.points,
              subtitle: '★ ${formatStars(t.stars)} each · ring ${t.ringWeek}%',
              isMe: t.mine,
              meLabel: 'your team',
              onTap: () => showTeamSheet(context, t),
            ),
          for (final g in private) ...[
            SizedBox(height: context.space.s),
            Text("${g.name} is private, so other teams can't see it.", style: context.type.body),
            SizedBox(height: context.space.xs),
            FilledButton.tonal(
              onPressed: () => _run(context, () => social.setPublic(g, true), done: '${g.name} joined the league.'),
              child: const Text('Join the league'),
            ),
          ],
        ],
      ),
    );
  }
}

// --- friends: this week's stars ----------------------------------------------

/// You and your friends, most side quest stars this week first. Stars reset
/// on Monday.
class _LeaderboardCard extends StatelessWidget {
  const _LeaderboardCard({super.key});

  @override
  Widget build(BuildContext context) {
    final social = context.watch<SocialStore>();
    final quests = context.watch<SideQuestStore>();
    final me = social.me!;
    final space = context.space;
    final board = leaderboard(social.friends, me, quests.starsThisWeek);
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(icon: Symbols.trophy_rounded, title: "This week's stars"),
          SizedBox(height: space.s),
          for (final (i, (person, stars)) in board.indexed)
            LeaderboardRow(
              rank: i + 1,
              name: person?.name ?? me.name,
              stars: stars,
              isMe: person == null,
              onTap: person == null
                  ? null
                  : () => showPersonSheet(
                      context,
                      person,
                      subtitle: 'Friend',
                      onRemove: () => _run(context, () => social.removeFriend(person)),
                    ),
            ),
          if (social.friends.isEmpty) ...[
            SizedBox(height: space.s),
            Text(
              'Add friends to race them for stars.',
              style: context.type.body.copyWith(color: context.colors.textSecondary),
            ),
          ],
          SizedBox(height: space.m),
          FilledButton.tonalIcon(
            onPressed: () async {
              final code = await askText(
                context,
                title: 'Add a friend',
                label: 'Their friend code',
                action: 'Add',
                code: true,
              );
              if (code != null && code.isNotEmpty && context.mounted) _run(context, () => social.addFriend(code));
            },
            icon: const Icon(Symbols.person_add_rounded),
            label: const Text('Add a friend'),
          ),
          SizedBox(height: space.s),
          Wrap(
            spacing: space.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Your friend code: ${me.friendCode}', style: context.type.label),
              TextButton.icon(
                onPressed: () => _copy(context, me.friendCode, 'Friend code'),
                icon: const Icon(Symbols.content_copy_rounded),
                label: const Text('Copy'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// You (a null person) and [friends], most stars first; ties by name.
List<(Person?, int)> leaderboard(List<Person> friends, Me me, int myStars) {
  final rows = <(Person?, int)>[(null, myStars), for (final f in friends) (f, f.starsThisWeek)];
  String name((Person?, int) r) => (r.$1?.name ?? me.name).toLowerCase();
  return rows..sort((a, b) => a.$2 != b.$2 ? b.$2.compareTo(a.$2) : name(a).compareTo(name(b)));
}

// --- together time ------------------------------------------------------------------

class LiveTogetherTimeCard extends StatelessWidget {
  const LiveTogetherTimeCard({super.key});

  @override
  Widget build(BuildContext context) {
    final together = context.watch<TogetherTime>();
    context.watch<SocialStore>(); // friends' names
    return TogetherTimeCard(
      enabled: together.enabled,
      problem: together.problem,
      minutesToday: together.minutesToday,
      nearbyNow: [for (final f in together.nearbyNow) f.name],
      bestFriends: [for (final (f, minutes) in together.bestFriends) (f.name, minutes)],
      bestFriendDays: TogetherTime.bestFriendDays,
      onEnabled: together.setEnabled,
    );
  }
}

// --- side quests -------------------------------------------------------------------

/// "45 m · next star at 1 h", "2 h 10 m · all 3 stars"
String questProgressText(SideQuest q, int progress) {
  final next = q.nextGoal(progress);
  if (next == null) return '${formatMinutes(progress)} · all ${q.maxStars} stars';
  return '${formatMinutes(progress)} · ${q.starsFor(progress) == 0 ? 'first' : 'next'} star at ${formatMinutes(next)}';
}

/// Every side quest, always running.
class SideQuestList extends StatelessWidget {
  const SideQuestList({super.key});

  @override
  Widget build(BuildContext context) {
    final quests = context.watch<SideQuestStore>();
    final space = context.space;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: space.m,
          runSpacing: space.xs,
          children: [
            Semantics(header: true, child: Text('Side quests', style: context.type.title)),
            Semantics(
              label: '${quests.starsToday} of $maxStarsPerDay stars today',
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.star_rounded, color: context.colors.brand, fill: 1),
                    SizedBox(width: space.xs),
                    Flexible(child: Text('${quests.starsToday} of $maxStarsPerDay today', style: context.type.label)),
                  ],
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: space.xs),
        Text(
          'Each goal you reach earns a star.',
          style: context.type.body.copyWith(color: context.colors.textSecondary),
        ),
        for (final q in sideQuests) ...[SizedBox(height: space.cardGap), SideQuestTile(quest: q)],
      ],
    );
  }
}

class SideQuestTile extends StatelessWidget {
  const SideQuestTile({super.key, required this.quest});

  final SideQuest quest;

  @override
  Widget build(BuildContext context) {
    final quests = context.watch<SideQuestStore>();
    final q = quest;
    final progress = quests.progress(q);
    return SideQuestCard(
      icon: q.icon,
      title: q.title,
      description: q.blurb,
      goals: q.goals,
      progress: progress,
      stars: quests.stars(q),
      progressText: questProgressText(q, progress),
    );
  }
}
