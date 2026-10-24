// Builds the light and dark ThemeData from the tokens in tokens.dart.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

export 'tokens.dart';

/// Tests turn this off so they don't fetch fonts over the network.
bool useGoogleFonts = true;

ThemeData buildOmniTheme(Brightness brightness) {
  final c = brightness == Brightness.light ? OmniColors.light : OmniColors.dark;
  const space = OmniSpacing();
  const radii = OmniRadii();
  final type = _buildType(c);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.brand,
    onPrimary: c.onBrand,
    secondary: c.brand,
    onSecondary: c.onBrand,
    error: c.alertUrgent,
    onError: c.onAlertUrgent,
    surface: c.surface,
    onSurface: c.textPrimary,
    onSurfaceVariant: c.textSecondary,
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surfaceAlt,
    surfaceContainerHighest: c.surfaceAlt,
    outline: c.outline,
    outlineVariant: c.outline,
  );

  final pill = RoundedRectangleBorder(borderRadius: radii.pillRadius);
  const minButton = Size(48, 48);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    textTheme: _textTheme(type),
    extensions: [c, space, radii, type],
    materialTapTargetSize: MaterialTapTargetSize.padded,
    appBarTheme: AppBarTheme(
      backgroundColor: c.background,
      foregroundColor: c.textPrimary,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: type.title,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      indicatorColor: c.brand,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? c.onBrand : c.textSecondary),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => type.caption.copyWith(
          fontWeight: FontWeight.w700,
          color: s.contains(WidgetState.selected) ? c.brand : c.textSecondary,
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: radii.cardRadius,
        side: BorderSide(color: c.outline),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.brand,
        foregroundColor: c.onBrand,
        minimumSize: minButton,
        shape: pill,
        textStyle: type.label,
        padding: EdgeInsets.symmetric(horizontal: space.xl, vertical: space.m),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.textPrimary,
        minimumSize: minButton,
        shape: pill,
        side: BorderSide(color: c.textSecondary),
        textStyle: type.label,
        padding: EdgeInsets.symmetric(horizontal: space.xl, vertical: space.m),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.brand, minimumSize: minButton, shape: pill, textStyle: type.label),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: minButton, foregroundColor: c.textPrimary),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.surfaceAlt,
      side: BorderSide(color: c.outline),
      shape: pill,
      labelStyle: type.label.copyWith(color: c.textPrimary),
      iconTheme: IconThemeData(color: c.textPrimary, size: 20),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(radii.sheet))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: type.headline,
      contentTextStyle: type.body,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.textPrimary,
      contentTextStyle: type.body.copyWith(color: c.background),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radii.cardRadius),
    ),
    dividerTheme: DividerThemeData(color: c.outline, space: 1),
    listTileTheme: ListTileThemeData(
      iconColor: c.textPrimary,
      textColor: c.textPrimary,
      titleTextStyle: type.body,
      subtitleTextStyle: type.caption.copyWith(color: c.textSecondary),
      minTileHeight: 56,
    ),
    sliderTheme: SliderThemeData(activeTrackColor: c.brand, thumbColor: c.brand, inactiveTrackColor: c.outline),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.brand, linearTrackColor: c.surfaceAlt),
  );
}

OmniType _buildType(OmniColors c) {
  // Tabular figures so numbers don't jitter while they count.
  const tabular = [FontFeature.tabularFigures()];

  TextStyle nunito(double size, FontWeight weight) {
    final base = TextStyle(fontSize: size, fontWeight: weight, color: c.textPrimary, height: 1.2);
    return useGoogleFonts ? GoogleFonts.nunito(textStyle: base) : base;
  }

  TextStyle atkinson(double size, FontWeight weight) {
    final base = TextStyle(
      fontSize: size,
      fontWeight: weight,
      color: c.textPrimary,
      height: 1.35,
      fontFeatures: tabular,
    );
    return useGoogleFonts ? GoogleFonts.atkinsonHyperlegibleNext(textStyle: base) : base;
  }

  return OmniType(
    display: nunito(34, FontWeight.w800),
    title: nunito(24, FontWeight.w700),
    headline: nunito(20, FontWeight.w700),
    body: atkinson(17, FontWeight.w400),
    label: atkinson(15, FontWeight.w700),
    caption: atkinson(13, FontWeight.w400),
    captionView: atkinson(OmniType.captionViewDefault, FontWeight.w400),
  );
}

/// Maps the DESIGN.md styles onto Material's slots so built-in widgets
/// (buttons, list tiles, dialogs) use the same fonts.
TextTheme _textTheme(OmniType t) {
  return TextTheme(
    displayLarge: t.display,
    displayMedium: t.display,
    displaySmall: t.display,
    headlineLarge: t.title,
    headlineMedium: t.title,
    headlineSmall: t.headline,
    titleLarge: t.headline,
    titleMedium: t.label,
    titleSmall: t.label,
    bodyLarge: t.body,
    bodyMedium: t.body,
    bodySmall: t.caption,
    labelLarge: t.label,
    labelMedium: t.label,
    labelSmall: t.caption,
  );
}

/// Token access from any widget: `context.colors.brand`, `context.space.l`.
extension OmniThemeContext on BuildContext {
  OmniColors get colors => Theme.of(this).extension<OmniColors>()!;
  OmniSpacing get space => Theme.of(this).extension<OmniSpacing>()!;
  OmniRadii get radii => Theme.of(this).extension<OmniRadii>()!;
  OmniType get type => Theme.of(this).extension<OmniType>()!;

  /// True when the system asks for reduced motion.
  bool get reduceMotion => MediaQuery.of(this).disableAnimations;
}

/// Duration helper: motion is switched off under reduce motion.
Duration motion(BuildContext context, Duration d) => context.reduceMotion ? Duration.zero : d;
