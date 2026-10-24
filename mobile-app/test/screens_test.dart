// Every screen and the Widget Gallery lay out without overflow on a small
// phone, in light and dark, at 100% and 200% text.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/app.dart';
import 'package:omni_glasses/gallery/widget_gallery.dart';
import 'package:omni_glasses/net/glasses_link.dart';
import 'package:omni_glasses/screens/home_shell.dart';
import 'package:provider/provider.dart';

Future<void> pumpApp(WidgetTester tester, Widget home, {required Brightness brightness, double textScale = 1}) async {
  tester.view.physicalSize = const Size(360 * 3, 740 * 3); // small Android phone
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);

  final link = GlassesLink(port: 0); // not started: stays "searching"
  addTearDown(link.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: link,
      child: MaterialApp(theme: omniLightTheme, darkTheme: omniDarkTheme, home: home),
    ),
  );
  await tester.pump(const Duration(milliseconds: 700));
}

/// Scrolls the first scrollable to the end so every lazily built item lays out.
Future<void> scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 300; i++) {
    final pos = tester.state<ScrollableState>(scrollable).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -500));
    // Not pumpAndSettle: the "Who's around me?" loading spinner never settles.
    await tester.pump(const Duration(milliseconds: 700));
  }
}

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      final label = '${brightness.name}, ${(scale * 100).round()}% text';

      testWidgets('tabs lay out ($label)', (tester) async {
        await pumpApp(tester, const HomeShell(), brightness: brightness, textScale: scale);
        expect(find.text('Glasses not watching'), findsOneWidget);
        for (final tab in ['Aware', 'Eyes', 'Together', 'Today']) {
          await tester.tap(find.text(tab).last);
          await tester.pump(const Duration(milliseconds: 700));
          await scrollThrough(tester);
        }
      });

      testWidgets('Widget Gallery lays out ($label)', (tester) async {
        await pumpApp(tester, const WidgetGallery(), brightness: brightness, textScale: scale);
        await scrollThrough(tester);
        expect(find.text('Friends see your ring % only'), findsWidgets); // last section
      });
    }
  }
}
