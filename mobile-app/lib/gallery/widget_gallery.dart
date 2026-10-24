// Widget Gallery (debug): every DESIGN.md component in light, dark and 200%
// text, with fake data, so the team can review the design in one place.
//
// Open it from Settings > Developer > Widget Gallery, or start the app on it:
//   flutter run --route /gallery

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../alerts/alert_engine.dart' show ClearReason, PossiblyFollowing;
import '../alerts/alert_log.dart';
import '../app.dart';
import '../components/alerts.dart';
import '../components/captions_and_who.dart';
import '../components/celebration.dart';
import '../components/common.dart';
import '../components/event_log.dart';
import '../components/privacy_chip.dart';
import '../components/rear_view.dart';
import '../components/ring_stack.dart';
import '../components/social.dart';
import '../components/status_strip.dart';
import '../net/glasses_link.dart';
import '../net/protocol.dart';
import '../vision/detector.dart';
import '../theme/theme.dart';

enum _Variant {
  light('Light'),
  dark('Dark'),
  large('200% text');

  const _Variant(this.label);
  final String label;
}

class WidgetGallery extends StatefulWidget {
  const WidgetGallery({super.key});

  static const route = '/gallery';

  @override
  State<WidgetGallery> createState() => _WidgetGalleryState();
}

class _WidgetGalleryState extends State<WidgetGallery> {
  Set<_Variant> _shown = _Variant.values.toSet();

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    final sections = _sections();
    return Scaffold(
      appBar: AppBar(title: const Text('Widget Gallery')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(space.page, space.s, space.page, space.xxxl),
        children: [
          SegmentedButton<_Variant>(
            multiSelectionEnabled: true,
            showSelectedIcon: false,
            segments: [for (final v in _Variant.values) ButtonSegment(value: v, label: Text(v.label))],
            selected: _shown,
            onSelectionChanged: (s) => setState(() => _shown = s),
          ),
          for (final (title, builder) in sections) ...[
            SizedBox(height: space.xl),
            Semantics(header: true, child: Text(title, style: context.type.title)),
            for (final v in _Variant.values)
              if (_shown.contains(v)) _Preview(variant: v, builder: builder),
          ],
        ],
      ),
    );
  }

  List<(String, WidgetBuilder)> _sections() => [
    ('Tokens', (_) => const _TokenSwatches()),
    ('Type', (_) => const _TypeRamp()),
    ('Buttons and chips', (_) => const _Buttons()),
    (
      'StatusStrip',
      (_) => const _Column([
        StatusStrip(status: LinkStatus.connected, batteryPercent: 82),
        StatusStrip(status: LinkStatus.searching),
        StatusStrip(status: LinkStatus.lost, lostFor: Duration(seconds: 12)),
      ]),
    ),
    (
      'RingStack',
      (_) => const _Column([
        OmniCard(
          child: RingStack(
            rings: [
              RingData(RingKind.headsUp, minutes: 130, goalMinutes: 180),
              RingData(RingKind.outside, minutes: 25, goalMinutes: 60),
            ],
          ),
        ),
        OmniCard(
          child: RingStack(
            rings: [
              RingData(RingKind.headsUp, minutes: 180, goalMinutes: 180),
              RingData(RingKind.outside, minutes: 0, goalMinutes: 60),
              RingData(RingKind.team, minutes: 95, goalMinutes: 120),
            ],
          ),
        ),
      ]),
    ),
    (
      'AlertBanner',
      (_) => _Column([
        AlertBanner(
          level: AlertLevel.urgent,
          label: 'car',
          direction: Direction.left,
          announce: false,
          onDismiss: () {},
        ),
        AlertBanner(
          level: AlertLevel.gentle,
          label: 'bicycle',
          direction: Direction.behind,
          announce: false,
          onDismiss: () {},
        ),
      ]),
    ),
    (
      'SideIndicator',
      (_) => const Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          SideIndicator(active: Direction.left),
          SideIndicator(active: Direction.behind, tone: SideTone.gentle),
          SideIndicator(active: Direction.right, tone: SideTone.social),
          SideIndicator(),
        ],
      ),
    ),
    (
      'RearView',
      (_) => const _Column([
        RearView(frame: null, detections: []),
        RearView(
          frame: null,
          placeholder: '',
          detections: [
            Detection(label: 'car', confidence: 0.9, box: Rect.fromLTWH(0.08, 0.35, 0.35, 0.3)),
            Detection(label: 'person', confidence: 0.8, box: Rect.fromLTWH(0.62, 0.2, 0.16, 0.55)),
          ],
          notes: ['3.2 s', '-'],
        ),
      ]),
    ),
    (
      'FollowingCard',
      (_) => FollowingCard(notice: const PossiblyFollowing(WearerSide.right, Duration(minutes: 3)), onDismiss: () {}),
    ),
    (
      'EventLogCard',
      (_) => _Column([
        EventLogCard(entries: _fakeLog(), onClear: () {}, now: _fakeNow),
        EventLogCard(entries: const [], now: _fakeNow),
      ]),
    ),
    ('SocialTapCard', (_) => SocialTapCard(direction: Direction.left, announce: false, onDismiss: () {})),
    (
      'QuestCard',
      (_) => _Column([
        QuestCard(
          title: 'Group screen break',
          subtitle: '3:00 pm · Byte-me team',
          progress: 6 / 8,
          progressText: '6 of 8 joined',
          members: const ['Maya', 'Sam', 'Ana', 'Jo', 'Lee', 'Kai', 'Ravi', 'Tess'],
          countdown: 'Starts in 12 min',
          onJoin: () {},
        ),
        const QuestCard(
          title: 'Phone-down lunch',
          subtitle: 'Side quest · Easy',
          progress: 0.4,
          progressText: '12 of 30 min',
          joined: true,
        ),
      ]),
    ),
    (
      'FriendRow',
      (_) => OmniCard(
        child: _Column([
          FriendRow(name: 'Maya', headsUpPercent: 80, outsidePercent: 40, onTap: () {}),
          FriendRow(name: 'Sam', headsUpPercent: 35, outsidePercent: 100, onTap: () {}),
        ]),
      ),
    ),
    ('CaptionView', (_) => const _CaptionDemo()),
    (
      'WhoAroundSheet',
      (_) => _Column([
        _SheetFrame(
          child: WhoAroundSheet(state: WhoAroundState.idle, onAsk: () {}),
        ),
        _SheetFrame(
          child: WhoAroundSheet(state: WhoAroundState.loading, onAsk: () {}),
        ),
        _SheetFrame(
          child: WhoAroundSheet(
            state: WhoAroundState.result,
            result: 'Two people behind you, left. One is waving. One is on a phone.',
            onAsk: () {},
          ),
        ),
      ]),
    ),
    ('Celebration', (_) => const _CelebrationDemo()),
    (
      'PrivacyChip',
      (_) => const Wrap(spacing: 8, runSpacing: 8, children: [PrivacyChip.nothingRecorded(), PrivacyChip.ringsOnly()]),
    ),
  ];
}

/// Renders [builder] inside the variant's theme and text scale.
class _Preview extends StatelessWidget {
  const _Preview({required this.variant, required this.builder});

  final _Variant variant;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final appIsDark = Theme.of(context).brightness == Brightness.dark;
    final dark = variant == _Variant.dark || (variant == _Variant.large && appIsDark);
    final theme = dark ? omniDarkTheme : omniLightTheme;
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(top: context.space.m),
      child: Theme(
        data: theme,
        child: MediaQuery(
          data: variant == _Variant.large ? mq.copyWith(textScaler: const TextScaler.linear(2)) : mq,
          child: Builder(
            builder: (context) {
              final c = context.colors;
              return Container(
                decoration: BoxDecoration(
                  color: c.background,
                  borderRadius: context.radii.cardRadius,
                  border: Border.all(color: c.outline),
                ),
                padding: EdgeInsets.all(context.space.l),
                child: DefaultTextStyle(
                  style: context.type.body,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(variant.label, style: context.type.caption.copyWith(color: c.textSecondary)),
                      SizedBox(height: context.space.s),
                      builder(context),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Column extends StatelessWidget {
  const _Column(this.children);
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: context.space.m), children[i]],
      ],
    );
  }
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(context.radii.sheet)),
        border: Border.all(color: context.colors.outline),
      ),
      padding: EdgeInsets.all(context.space.l),
      child: child,
    );
  }
}

class _TokenSwatches extends StatelessWidget {
  const _TokenSwatches();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final swatches = <(String, Color, Color)>[
      ('background', c.background, c.textPrimary),
      ('surface', c.surface, c.textPrimary),
      ('surfaceAlt', c.surfaceAlt, c.textPrimary),
      ('outline', c.outline, c.textPrimary),
      ('textPrimary', c.textPrimary, c.background),
      ('textSecondary', c.textSecondary, c.background),
      ('brand', c.brand, c.onBrand),
      ('ringHeadsUp', c.ringHeadsUp, c.onRing),
      ('ringOutside', c.ringOutside, c.onRing),
      ('ringTeam', c.ringTeam, c.onRing),
      ('alertUrgent', c.alertUrgent, c.onAlertUrgent),
      ('alertGentle', c.alertGentle, c.onAlertGentle),
      ('socialTap', c.socialTap, c.onSocialTap),
    ];
    return Wrap(
      spacing: context.space.s,
      runSpacing: context.space.s,
      children: [
        for (final (name, bg, fg) in swatches)
          Container(
            constraints: const BoxConstraints(minWidth: 96, minHeight: 48),
            padding: EdgeInsets.all(context.space.s),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(context.space.m),
              border: Border.all(color: c.outline),
            ),
            child: Text(
              name,
              style: context.type.caption.copyWith(color: fg, fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

class _TypeRamp extends StatelessWidget {
  const _TypeRamp();

  @override
  Widget build(BuildContext context) {
    final t = context.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Display 2 h 10 m', style: t.display),
        Text('Title · Today', style: t.title),
        Text('Headline · Rings', style: t.headline),
        Text('Body: 2 h 10 m heads-up today. Nice.', style: t.body),
        Text('Label · 0123456789', style: t.label),
        Text('Caption: Friends see your ring % only.', style: t.caption),
        Text('Caption view', style: t.captionView),
      ],
    );
  }
}

class _Buttons extends StatelessWidget {
  const _Buttons();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: context.space.s,
      runSpacing: context.space.s,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton(onPressed: () {}, child: const Text('Join')),
        OutlinedButton(onPressed: () {}, child: const Text('Not now')),
        TextButton(onPressed: () {}, child: const Text('Learn more')),
        IconButton(onPressed: () {}, icon: const Icon(Symbols.settings_rounded), tooltip: 'Settings'),
        Switch.adaptive(value: true, onChanged: (_) {}),
      ],
    );
  }
}

class _CaptionDemo extends StatefulWidget {
  const _CaptionDemo();

  @override
  State<_CaptionDemo> createState() => _CaptionDemoState();
}

class _CaptionDemoState extends State<_CaptionDemo> {
  double _size = OmniType.captionViewDefault;

  @override
  Widget build(BuildContext context) {
    return CaptionView(
      fontSize: _size,
      onFontSizeChanged: (v) => setState(() => _size = v),
      turns: const [
        CaptionTurn(speaker: 'Speaker 1', text: 'Are you coming to the demo at three?'),
        CaptionTurn(speaker: 'You', text: 'Yes, see you there.'),
      ],
    );
  }
}

class _CelebrationDemo extends StatelessWidget {
  const _CelebrationDemo();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilledButton.icon(
          onPressed: () => celebrate(context, 'Heads-up ring closed. Nice.'),
          icon: const Icon(Symbols.celebration_rounded),
          label: const Text('Play celebration'),
        ),
        Text('Under reduce motion: text toast only.', style: context.type.caption),
      ],
    );
  }
}

final _fakeNow = DateTime(2026, 10, 24, 15, 30);

List<LogEntry> _fakeLog() => [
  LogEntry(
    kind: LogKind.alert,
    at: DateTime(2026, 10, 24, 15, 12),
    side: WearerSide.left,
    label: 'car',
    level: AlertLevel.urgent,
    reflex: true,
    closestSeconds: 1.8,
    ended: ClearReason.silenced,
  ),
  LogEntry(
    kind: LogKind.following,
    at: DateTime(2026, 10, 24, 14, 2),
    side: WearerSide.right,
    behindFor: const Duration(minutes: 3),
  ),
  LogEntry(
    kind: LogKind.alert,
    at: DateTime(2026, 10, 23, 18, 40),
    side: WearerSide.right,
    label: 'bicycle',
    closestSeconds: 4.1,
    ended: ClearReason.dismissed,
  ),
];
