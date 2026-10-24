// Design tokens from DESIGN.md, as ThemeExtensions.
//
// This is the only file that contains hex colors. Widgets read tokens with
// `context.colors`, `context.space`, `context.radii` and `context.type`
// (see theme.dart), never raw values.

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Colors (DESIGN.md section 3)
// ---------------------------------------------------------------------------

class OmniColors extends ThemeExtension<OmniColors> {
  const OmniColors({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.outline,
    required this.textPrimary,
    required this.textSecondary,
    required this.brand,
    required this.onBrand,
    required this.ringHeadsUp,
    required this.ringOutside,
    required this.ringTeam,
    required this.onRing,
    required this.alertUrgent,
    required this.onAlertUrgent,
    required this.alertGentle,
    required this.onAlertGentle,
    required this.socialTap,
    required this.onSocialTap,
  });

  // Neutrals
  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color outline;
  final Color textPrimary;
  final Color textSecondary;

  // Brand and play
  final Color brand;
  final Color ringHeadsUp;
  final Color ringOutside;
  final Color ringTeam;

  // Safety and status
  final Color alertUrgent;
  final Color alertGentle;
  final Color socialTap;

  // "On" colors are not in DESIGN.md. Each is the text/icon color for content
  // placed on top of the matching fill, picked to pass 4.5:1 (see
  // test/contrast_test.dart).
  final Color onBrand;
  final Color onRing;
  final Color onAlertUrgent;
  final Color onAlertGentle;
  final Color onSocialTap;

  /// DESIGN.md: `ok` uses the brand color (never green-vs-red pairs).
  Color get ok => brand;

  /// DESIGN.md: `linkLost` is textSecondary with a striped fill.
  Color get linkLost => textSecondary;

  static const light = OmniColors(
    background: Color(0xFFFFFBF5),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF3EEE6),
    outline: Color(0xFFD9D3CA),
    textPrimary: Color(0xFF1C1B1F),
    textSecondary: Color(0xFF5D5A63),
    brand: Color(0xFF6C4CF1),
    onBrand: Color(0xFFFFFFFF),
    ringHeadsUp: Color(0xFF2D9CDB),
    ringOutside: Color(0xFFF2A900),
    ringTeam: Color(0xFFC2549A),
    onRing: Color(0xFF1C1B1F),
    alertUrgent: Color(0xFFC62828),
    onAlertUrgent: Color(0xFFFFFFFF),
    alertGentle: Color(0xFFF2A900),
    onAlertGentle: Color(0xFF1C1B1F),
    socialTap: Color(0xFF00796B),
    onSocialTap: Color(0xFFFFFFFF),
  );

  static const dark = OmniColors(
    background: Color(0xFF121214),
    surface: Color(0xFF1E1E22),
    surfaceAlt: Color(0xFF2A2A30),
    outline: Color(0xFF3A3A42),
    textPrimary: Color(0xFFF4F2EE),
    textSecondary: Color(0xFFB5B1BA),
    brand: Color(0xFFA99BFF),
    onBrand: Color(0xFF121214),
    ringHeadsUp: Color(0xFF6CC4F5),
    ringOutside: Color(0xFFFFC845),
    ringTeam: Color(0xFFE58AC4),
    onRing: Color(0xFF121214),
    alertUrgent: Color(0xFFFF6B6B),
    onAlertUrgent: Color(0xFF121214),
    alertGentle: Color(0xFFFFC845),
    onAlertGentle: Color(0xFF121214),
    socialTap: Color(0xFF4DD0C4),
    onSocialTap: Color(0xFF121214),
  );

  @override
  OmniColors copyWith() => this;

  @override
  OmniColors lerp(OmniColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return OmniColors(
      background: l(background, other.background),
      surface: l(surface, other.surface),
      surfaceAlt: l(surfaceAlt, other.surfaceAlt),
      outline: l(outline, other.outline),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      brand: l(brand, other.brand),
      onBrand: l(onBrand, other.onBrand),
      ringHeadsUp: l(ringHeadsUp, other.ringHeadsUp),
      ringOutside: l(ringOutside, other.ringOutside),
      ringTeam: l(ringTeam, other.ringTeam),
      onRing: l(onRing, other.onRing),
      alertUrgent: l(alertUrgent, other.alertUrgent),
      onAlertUrgent: l(onAlertUrgent, other.onAlertUrgent),
      alertGentle: l(alertGentle, other.alertGentle),
      onAlertGentle: l(onAlertGentle, other.onAlertGentle),
      socialTap: l(socialTap, other.socialTap),
      onSocialTap: l(onSocialTap, other.onSocialTap),
    );
  }
}

// ---------------------------------------------------------------------------
// Spacing (8-pt grid, DESIGN.md section 5)
// ---------------------------------------------------------------------------

class OmniSpacing extends ThemeExtension<OmniSpacing> {
  const OmniSpacing();

  final double xs = 4;
  final double s = 8;
  final double m = 12;
  final double l = 16;
  final double xl = 24;
  final double xxl = 32;
  final double xxxl = 48;

  double get page => l; // page margins
  double get cardGap => m; // gap between cards (12-16)
  double get minTouch => 48; // minimum touch target

  @override
  OmniSpacing copyWith() => this;

  @override
  OmniSpacing lerp(OmniSpacing? other, double t) => this;
}

// ---------------------------------------------------------------------------
// Radii (DESIGN.md section 5)
// ---------------------------------------------------------------------------

class OmniRadii extends ThemeExtension<OmniRadii> {
  const OmniRadii();

  final double card = 20;
  final double sheet = 28; // top corners only
  final double pill = 999; // buttons and chips

  BorderRadius get cardRadius => BorderRadius.circular(card);
  BorderRadius get pillRadius => BorderRadius.circular(pill);

  @override
  OmniRadii copyWith() => this;

  @override
  OmniRadii lerp(OmniRadii? other, double t) => this;
}

// ---------------------------------------------------------------------------
// Typography (DESIGN.md section 4). Built in theme.dart because it needs the
// fonts and the text color.
// ---------------------------------------------------------------------------

class OmniType extends ThemeExtension<OmniType> {
  const OmniType({
    required this.display,
    required this.title,
    required this.headline,
    required this.body,
    required this.label,
    required this.caption,
    required this.captionView,
  });

  final TextStyle display; // 34 / 800 Nunito
  final TextStyle title; // 24 / 700 Nunito
  final TextStyle headline; // 20 / 700 Nunito
  final TextStyle body; // 17 / 400 Atkinson Hyperlegible
  final TextStyle label; // 15 / 700 Atkinson Hyperlegible
  final TextStyle caption; // 13 / 400 Atkinson Hyperlegible, the minimum size
  final TextStyle captionView; // 28 default, user adjustable 20-48

  static const double captionViewMin = 20;
  static const double captionViewMax = 48;
  static const double captionViewDefault = 28;

  @override
  OmniType copyWith() => this;

  @override
  OmniType lerp(OmniType? other, double t) {
    if (other == null) return this;
    TextStyle l(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return OmniType(
      display: l(display, other.display),
      title: l(title, other.title),
      headline: l(headline, other.headline),
      body: l(body, other.body),
      label: l(label, other.label),
      caption: l(caption, other.caption),
      captionView: l(captionView, other.captionView),
    );
  }
}
