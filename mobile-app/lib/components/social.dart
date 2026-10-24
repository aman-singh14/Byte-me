// Play register: QuestCard, FriendRow, LeaderboardRow, SideQuestCard,
// TogetherTimeCard.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/theme.dart';
import 'common.dart';
import 'ring_stack.dart';

/// A group quest or side quest: title, progress, member initials, countdown,
/// join button.
class QuestCard extends StatelessWidget {
  const QuestCard({
    super.key,
    required this.title,
    required this.progress,
    required this.progressText,
    this.subtitle,
    this.members = const [],
    this.countdown,
    this.joined = false,
    this.onJoin,
  });

  final String title;
  final String? subtitle;

  /// 0..1
  final double progress;

  /// Progress as words, always shown: "6 of 8 joined".
  final String progressText;

  /// Member names; only their initials are shown.
  final List<String> members;

  /// "Starts in 12 min"
  final String? countdown;
  final bool joined;
  final VoidCallback? onJoin;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final space = context.space;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const RingIconDot(kind: RingKind.team, size: 32),
              SizedBox(width: space.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(header: true, child: Text(title, style: context.type.headline)),
                    if (subtitle != null) Text(subtitle!, style: context.type.body.copyWith(color: c.textSecondary)),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: space.m),
          ExcludeSemantics(
            child: ClipRRect(
              borderRadius: context.radii.pillRadius,
              child: LinearProgressIndicator(value: progress, minHeight: 10, color: c.ringTeam),
            ),
          ),
          SizedBox(height: space.s),
          Text(progressText, style: context.type.label),
          SizedBox(height: space.m),
          Wrap(
            spacing: space.m,
            runSpacing: space.s,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              if (members.isNotEmpty) _Initials(names: members),
              if (countdown != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.schedule_rounded, size: 20, color: c.textSecondary),
                    SizedBox(width: space.xs),
                    Flexible(
                      child: Text(countdown!, style: context.type.body.copyWith(color: c.textSecondary)),
                    ),
                  ],
                ),
              if (joined)
                // A status, not a disabled button, so it stays full contrast.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.check_circle_rounded, color: c.brand, fill: 1),
                    SizedBox(width: space.xs),
                    Text('Joined', style: context.type.label),
                  ],
                )
              else if (onJoin != null)
                FilledButton(onPressed: onJoin, child: const Text('Join')),
            ],
          ),
        ],
      ),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.names});

  final List<String> names;

  @override
  Widget build(BuildContext context) {
    const maxShown = 5;
    final shown = names.take(maxShown).toList();
    final extra = names.length - shown.length;
    return Semantics(
      label: 'Members: ${names.join(', ')}',
      child: ExcludeSemantics(
        child: Wrap(
          spacing: context.space.xs,
          runSpacing: context.space.xs,
          children: [
            for (final n in shown) InitialAvatar(name: n, size: 32),
            if (extra > 0) InitialAvatar(name: '+$extra', size: 32, literal: true),
          ],
        ),
      ),
    );
  }
}

/// A circle with someone's initial. No photos.
class InitialAvatar extends StatelessWidget {
  const InitialAvatar({super.key, required this.name, this.size = 40, this.literal = false});

  final String name;
  final double size;

  /// Show [name] as is instead of its first letter (for "+3").
  final bool literal;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = literal ? name : (name.isEmpty ? '?' : name.characters.first.toUpperCase());
    return Container(
      constraints: BoxConstraints(minWidth: size, minHeight: size),
      padding: EdgeInsets.symmetric(horizontal: context.space.xs),
      decoration: BoxDecoration(
        color: c.surfaceAlt,
        borderRadius: context.radii.pillRadius,
        border: Border.all(color: c.outline),
      ),
      // widthFactor/heightFactor keep the circle its own size inside a Wrap.
      child: Center(widthFactor: 1, heightFactor: 1, child: Text(text, style: context.type.label)),
    );
  }
}

/// A friend: initial, name, ring percentages. Nothing else is shared.
class FriendRow extends StatelessWidget {
  const FriendRow({
    super.key,
    required this.name,
    required this.headsUpPercent,
    required this.outsidePercent,
    this.onTap,
  });

  final String name;
  final int headsUpPercent;
  final int outsidePercent;
  final VoidCallback? onTap;

  /// "Maya: heads-up 80 percent, outside 40 percent."
  String get semanticLabel => '$name: heads-up $headsUpPercent percent, outside $outsidePercent percent.';

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    final rings = Wrap(
      spacing: space.m,
      runSpacing: space.xs,
      children: [
        _MiniRing(kind: RingKind.headsUp, percent: headsUpPercent),
        _MiniRing(kind: RingKind.outside, percent: outsidePercent),
      ],
    );
    return Semantics(
      label: semanticLabel,
      button: onTap != null,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: context.radii.cardRadius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: space.s, horizontal: space.xs),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Name and rings on one line; the rings go under the name
                  // only when large text leaves no room.
                  final scale = MediaQuery.textScalerOf(context).scale(1);
                  final oneLine =
                      constraints.maxWidth >= 40 + space.m + 90 * scale + 2 * (32 + 50 * scale) + 2 * space.m;
                  final person = Row(
                    children: [
                      InitialAvatar(name: name),
                      SizedBox(width: space.m),
                      Expanded(child: Text(name, style: context.type.body)),
                    ],
                  );
                  if (oneLine) {
                    return Row(
                      children: [
                        Expanded(child: person),
                        SizedBox(width: space.s),
                        rings,
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      person,
                      SizedBox(height: space.xs),
                      Padding(
                        padding: EdgeInsetsDirectional.only(start: 40 + space.m),
                        child: rings,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small ring with its icon inside and the percentage beside it.
class _MiniRing extends StatelessWidget {
  const _MiniRing({required this.kind, required this.percent});

  final RingKind kind;
  final int percent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 28,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size.square(28),
                painter: RingPainter(
                  fractions: [(percent / 100).clamp(0.0, 1.0)],
                  colors: [kind.color(c)],
                  icons: [kind.icon],
                  track: c.surfaceAlt,
                  iconColor: c.onRing,
                ),
              ),
              Icon(kind.icon, size: 14, color: c.textSecondary),
            ],
          ),
        ),
        SizedBox(width: context.space.xs),
        // Room for "100%", so the rings line up from row to row.
        ConstrainedBox(
          constraints: BoxConstraints(minWidth: 46 * MediaQuery.textScalerOf(context).scale(1)),
          child: Text('$percent%', style: context.type.label),
        ),
      ],
    );
  }
}

/// Stars as icons: filled for earned, outlined for the rest.
class StarRow extends StatelessWidget {
  const StarRow({super.key, required this.stars, this.of = 3, this.size = 22});

  final int stars;
  final int of;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: '$stars of $of stars',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < of; i++)
              Icon(
                Symbols.star_rounded,
                size: size,
                fill: i < stars ? 1 : 0,
                color: i < stars ? c.brand : c.textSecondary,
              ),
          ],
        ),
      ),
    );
  }
}

/// 7, 2.5: whole stars, or stars per member to one decimal.
String formatStars(num n) => n == n.roundToDouble() ? '${n.round()}' : n.toStringAsFixed(1);

/// One place on a weekly star leaderboard: friends, or teams in the league.
class LeaderboardRow extends StatelessWidget {
  const LeaderboardRow({
    super.key,
    required this.rank,
    required this.name,
    required this.stars,
    this.subtitle,
    this.isMe = false,
    this.meLabel = 'you',
    this.starsLabel = 'stars this week',
    this.points,
    this.onTap,
  });

  final int rank;
  final String name;

  /// Whole stars, or stars per member (one decimal).
  final num stars;

  /// "3 members"
  final String? subtitle;
  final bool isMe;

  /// "you", "your team"
  final String meLabel;
  final String starsLabel;

  /// Shown instead of [stars] when set ("113 pts"), for the team league.
  final int? points;
  final VoidCallback? onTap;

  String get starsText => formatStars(stars);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final space = context.space;
    final leads = rank == 1 && (points ?? stars) > 0;
    final score = points != null ? '$points points' : '$starsText $starsLabel';
    return Semantics(
      label:
          '$rank. $name${isMe ? ', $meLabel' : ''}: $score${subtitle != null ? ', $subtitle' : ''}'
          '${leads ? ', in the lead' : ''}.',
      button: onTap != null,
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: context.radii.cardRadius,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: EdgeInsets.symmetric(vertical: space.s, horizontal: space.s),
            decoration: isMe ? BoxDecoration(color: c.surfaceAlt, borderRadius: context.radii.cardRadius) : null,
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: leads
                      ? Icon(Symbols.trophy_rounded, color: c.brand, fill: 1)
                      : Text('$rank', style: context.type.label, textAlign: TextAlign.center),
                ),
                SizedBox(width: space.s),
                InitialAvatar(name: name),
                SizedBox(width: space.m),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(isMe ? '$name ($meLabel)' : name, style: isMe ? context.type.label : context.type.body),
                      if (subtitle != null)
                        Text(subtitle!, style: context.type.caption.copyWith(color: c.textSecondary)),
                    ],
                  ),
                ),
                SizedBox(width: space.s),
                if (points != null) ...[
                  Text('$points', style: context.type.headline),
                  Text(' pts', style: context.type.caption.copyWith(color: c.textSecondary)),
                ] else ...[
                  Icon(Symbols.star_rounded, color: c.brand, fill: 1, size: 22),
                  SizedBox(width: space.xs),
                  Text(starsText, style: context.type.headline),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A side quest, always running: what counts, today's progress with a tick
/// at each goal, and the stars earned. Nothing to tap; the app measures it.
class SideQuestCard extends StatelessWidget {
  const SideQuestCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.goals,
    required this.progress,
    required this.stars,
    required this.progressText,
  });

  final IconData icon;
  final String title;

  /// What counts: "Time outside between 5 and 8 pm."
  final String description;

  /// One star at each, lowest first.
  final List<int> goals;

  /// Today, in the goals' unit.
  final int progress;
  final int stars;

  /// "45 min · next star at 1 h"
  final String progressText;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final space = context.space;
    final top = goals.last;
    return Semantics(
      label: '$title. $description $progressText. $stars of ${goals.length} stars.',
      child: ExcludeSemantics(
        child: OmniCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: c.surfaceAlt, shape: BoxShape.circle),
                    child: Icon(icon, color: c.textPrimary),
                  ),
                  SizedBox(width: space.m),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: context.type.headline),
                        Text(description, style: context.type.body.copyWith(color: c.textSecondary)),
                      ],
                    ),
                  ),
                  SizedBox(width: space.s),
                  StarRow(stars: stars, of: goals.length),
                ],
              ),
              SizedBox(height: space.m),
              // The bar runs to the top goal, with a tick at each goal.
              LayoutBuilder(
                builder: (context, constraints) => SizedBox(
                  height: 10,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: context.radii.pillRadius,
                          child: LinearProgressIndicator(
                            value: (progress / top).clamp(0.0, 1.0),
                            minHeight: 10,
                            color: c.brand,
                            backgroundColor: c.surfaceAlt,
                          ),
                        ),
                      ),
                      for (final g in goals.take(goals.length - 1))
                        Positioned(
                          left: constraints.maxWidth * g / top - 1,
                          top: 0,
                          bottom: 0,
                          child: Container(width: 2, color: c.surface),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: space.s),
              Text(progressText, style: context.type.label),
            ],
          ),
        ),
      ),
    );
  }
}

/// Time near friends over Bluetooth: today's total, who's nearby now, and
/// best friends by time together. Off until the wearer turns it on.
class TogetherTimeCard extends StatelessWidget {
  const TogetherTimeCard({
    super.key,
    required this.enabled,
    required this.minutesToday,
    required this.nearbyNow,
    required this.bestFriends,
    this.bestFriendDays = 30,
    this.problem,
    this.onEnabled,
  });

  final bool enabled;
  final int minutesToday;

  /// Names of friends nearby right now.
  final List<String> nearbyNow;

  /// Name and minutes together, most first.
  final List<(String, int)> bestFriends;
  final int bestFriendDays;

  /// Why it isn't running ("Turn on Bluetooth...").
  final String? problem;
  final ValueChanged<bool>? onEnabled;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final space = context.space;
    final secondary = context.type.body.copyWith(color: c.textSecondary);
    final top = bestFriends.isEmpty ? 1 : bestFriends.first.$2;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: CardTitle(icon: Symbols.diversity_1_rounded, title: 'Together time'),
              ),
              Semantics(
                label: 'Count time with friends nearby',
                child: Switch.adaptive(value: enabled, onChanged: onEnabled),
              ),
            ],
          ),
          SizedBox(height: space.s),
          if (!enabled)
            Text(
              'Count the time you spend with friends in person. Uses Bluetooth while the app is open; '
              'your phone sends a random code only your friends know.',
              style: secondary,
            )
          else ...[
            if (problem != null) ...[Text(problem!, style: context.type.body), SizedBox(height: space.s)],
            Semantics(
              label: '${spokenMinutes(minutesToday)} with friends today.',
              child: ExcludeSemantics(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.end,
                  spacing: space.s,
                  children: [
                    Text(formatMinutes(minutesToday), style: context.type.display),
                    Padding(
                      padding: EdgeInsets.only(bottom: space.xs),
                      child: Text('with friends today', style: secondary),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: space.s),
            Row(
              children: [
                Icon(
                  Symbols.bluetooth_searching_rounded,
                  size: 20,
                  color: nearbyNow.isEmpty ? c.textSecondary : c.brand,
                ),
                SizedBox(width: space.xs),
                Expanded(
                  child: Text(
                    nearbyNow.isEmpty ? 'No friends nearby right now' : 'With ${nearbyNow.join(', ')} now',
                    style: nearbyNow.isEmpty ? secondary : context.type.label,
                  ),
                ),
              ],
            ),
          ],
          if (enabled || bestFriends.isNotEmpty) ...[
            SizedBox(height: space.l),
            Text('Best friends', style: context.type.headline),
            Text('Most time together, last $bestFriendDays days', style: secondary),
            SizedBox(height: space.s),
            if (bestFriends.isEmpty)
              Text('Spend time near a friend and they show up here.', style: secondary)
            else
              for (final (i, (name, minutes)) in bestFriends.take(5).indexed)
                Semantics(
                  label: '${i + 1}. $name, ${spokenMinutes(minutes)} together.',
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: space.xs),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 28,
                            child: i == 0
                                ? Icon(Symbols.favorite_rounded, color: c.ringTeam, fill: 1)
                                : Text('${i + 1}', style: context.type.label, textAlign: TextAlign.center),
                          ),
                          SizedBox(width: space.s),
                          InitialAvatar(name: name),
                          SizedBox(width: space.m),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  alignment: WrapAlignment.spaceBetween,
                                  spacing: space.s,
                                  children: [
                                    Text(name, style: context.type.body),
                                    Text(formatMinutes(minutes), style: context.type.label),
                                  ],
                                ),
                                SizedBox(height: space.xs),
                                ClipRRect(
                                  borderRadius: context.radii.pillRadius,
                                  child: LinearProgressIndicator(
                                    value: minutes / top,
                                    minHeight: 6,
                                    color: c.ringTeam,
                                    backgroundColor: c.surfaceAlt,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
          ],
        ],
      ),
    );
  }
}
