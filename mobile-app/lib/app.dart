import 'package:flutter/material.dart';

import 'gallery/widget_gallery.dart';
import 'screens/home_shell.dart';
import 'theme/theme.dart';

// Built once (lazily) and shared with the Widget Gallery.
final omniLightTheme = buildOmniTheme(Brightness.light);
final omniDarkTheme = buildOmniTheme(Brightness.dark);

class OmniApp extends StatelessWidget {
  const OmniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Omni Glasses',
      theme: omniLightTheme,
      darkTheme: omniDarkTheme,
      themeMode: ThemeMode.system,
      // `flutter run --route /gallery` opens straight on the gallery.
      routes: {'/': (_) => const HomeShell(), WidgetGallery.route: (_) => const WidgetGallery()},
    );
  }
}
