// Small shared pieces: directions, copy helpers, icons, announcements, cards.

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../net/protocol.dart';
import '../theme/theme.dart';

/// Where something is, from the wearer's point of view. The glasses only
/// report left and right; "behind" is for things straight back.
enum Direction {
  left,
  behind,
  right;

  static Direction fromWearerSide(WearerSide s) => s == WearerSide.left ? left : right;

  /// One word for indicators: "Left".
  String get word => switch (this) {
    left => 'Left',
    behind => 'Behind',
    right => 'Right',
  };

  /// Short form for banners: "behind left".
  String get short => switch (this) {
    left => 'behind left',
    behind => 'behind',
    right => 'behind right',
  };

  /// Sentence form: "behind you, left".
  String get phrase => switch (this) {
    left => 'behind you, left',
    behind => 'behind you',
    right => 'behind you, right',
  };
}

/// "2 h 10 m", "45 m", "3 h".
String formatMinutes(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m m';
  if (m == 0) return '$h h';
  return '$h h $m m';
}

/// "2 hours 10 minutes", for screen readers.
String spokenMinutes(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  String unit(int n, String word) => '$n $word${n == 1 ? '' : 's'}';
  if (h == 0) return unit(m, 'minute');
  if (m == 0) return unit(h, 'hour');
  return '${unit(h, 'hour')} ${unit(m, 'minute')}';
}

/// Icon for a detected object class.
IconData iconForObject(String label) => switch (label.toLowerCase()) {
  'person' => Symbols.person_rounded,
  'bicycle' => Symbols.pedal_bike_rounded,
  'car' => Symbols.directions_car_rounded,
  'motorcycle' => Symbols.motorcycle_rounded,
  'bus' => Symbols.directions_bus_rounded,
  'truck' => Symbols.local_shipping_rounded,
  'dog' => Symbols.pets_rounded,
  'skateboard' => Symbols.skateboarding_rounded,
  _ => Symbols.warning_rounded,
};

/// "car" -> "Car".
String capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Reads [message] aloud with the screen reader (TalkBack / VoiceOver).
void announce(BuildContext context, String message, {bool assertive = false}) {
  SemanticsService.sendAnnouncement(
    View.of(context),
    message,
    Directionality.of(context),
    assertiveness: assertive ? Assertiveness.assertive : Assertiveness.polite,
  );
}

/// Flat card: surface color, outline, radius 20, 16 padding.
class OmniCard extends StatelessWidget {
  const OmniCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: padding ?? EdgeInsets.all(context.space.l), child: child),
    );
  }
}

/// Card title row: icon + headline.
class CardTitle extends StatelessWidget {
  const CardTitle({super.key, required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: context.colors.textPrimary),
        SizedBox(width: context.space.s),
        Expanded(
          child: Semantics(header: true, child: Text(title, style: context.type.headline)),
        ),
      ],
    );
  }
}

/// A screen section that isn't built yet. Says so plainly.
class PlaceholderCard extends StatelessWidget {
  const PlaceholderCard({super.key, required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CardTitle(icon: icon, title: title),
          SizedBox(height: context.space.s),
          Text(text, style: context.type.body.copyWith(color: context.colors.textSecondary)),
        ],
      ),
    );
  }
}

/// Fades a safety-register widget in within 100 ms (instant under reduce motion).
class SafetyFadeIn extends StatelessWidget {
  const SafetyFadeIn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: motion(context, const Duration(milliseconds: 100)),
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: child,
    );
  }
}
