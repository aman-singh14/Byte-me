// Play register: QuestCard and FriendRow.

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
              child: Wrap(
                spacing: space.m,
                runSpacing: space.s,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InitialAvatar(name: name),
                      SizedBox(width: space.m),
                      Flexible(child: Text(name, style: context.type.body)),
                    ],
                  ),
                  Wrap(
                    spacing: space.m,
                    runSpacing: space.xs,
                    children: [
                      _MiniRing(kind: RingKind.headsUp, percent: headsUpPercent),
                      _MiniRing(kind: RingKind.outside, percent: outsidePercent),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
        SizedBox(width: context.space.xs),
        Icon(kind.icon, size: 18, color: c.textSecondary),
        Text(' $percent%', style: context.type.label),
      ],
    );
  }
}
