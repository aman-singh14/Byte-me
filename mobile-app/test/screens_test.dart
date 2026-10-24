// Every screen and the Widget Gallery lay out without overflow on a small
// phone, in light and dark, at 100% and 200% text.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/alerts/alert_engine.dart';
import 'package:omni_glasses/alerts/alert_service.dart';
import 'package:omni_glasses/alerts/voice.dart';
import 'package:omni_glasses/app.dart';
import 'package:omni_glasses/components/alerts.dart';
import 'package:omni_glasses/gallery/widget_gallery.dart';
import 'package:omni_glasses/net/glasses_link.dart';
import 'package:omni_glasses/net/protocol.dart';
import 'package:omni_glasses/helper/helper_call.dart';
import 'package:omni_glasses/screens/home_shell.dart';
import 'package:omni_glasses/screens/profile_sheets.dart';
import 'package:omni_glasses/social/rings_source.dart';
import 'package:omni_glasses/social/side_quests.dart';
import 'package:omni_glasses/social/social_api.dart';
import 'package:omni_glasses/social/social_store.dart';
import 'package:omni_glasses/social/together_time.dart';
import 'package:omni_glasses/vision/detector.dart';
import 'package:omni_glasses/vision/fire_namer.dart';
import 'package:omni_glasses/vision/rear_vision.dart';
import 'package:provider/provider.dart';

import 'social_test.dart' show FakeRadio, FixedRings, signedInStore;

Future<AlertService> pumpApp(
  WidgetTester tester,
  Widget home, {
  required Brightness brightness,
  double textScale = 1,
  AlertEngine? engine,
  Voice? voice,
  FireNamer? namer,
  bool together = false,
}) async {
  tester.view.physicalSize = const Size(360 * 3, 740 * 3); // small Android phone
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);

  final link = GlassesLink(port: 0); // not started: stays "searching", no camera
  final vision = RearVision(link, _NoDetector());
  final alerts = AlertService(link, vision, engine: engine, namer: namer);
  final rings = FixedRings();
  final social = together ? await signedInStore(link) : SocialStore(link: link, rings: rings);
  final quests = SideQuestStore(rings: rings, sens: link.sens);
  if (together) rings.set(70, 0); // two Look up stars
  final togetherTime = TogetherTime(social: social, radio: FakeRadio());
  addTearDown(togetherTime.dispose);
  final helperCall = HelperCall(
    toGlasses: link.send,
    cameras: GlassesCameras(vision),
    alerts: alerts.events,
    watchLifecycle: false,
  );
  addTearDown(helperCall.dispose);
  addTearDown(quests.dispose);
  addTearDown(social.dispose);
  addTearDown(alerts.dispose);
  addTearDown(vision.dispose);
  addTearDown(link.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: link),
        ChangeNotifierProvider.value(value: vision),
        ChangeNotifierProvider.value(value: alerts),
        Provider<Voice?>.value(value: voice),
        ListenableProvider<RingsSource>.value(value: rings),
        ChangeNotifierProvider.value(value: social),
        ChangeNotifierProvider.value(value: quests),
        ChangeNotifierProvider.value(value: togetherTime),
        ChangeNotifierProvider.value(value: helperCall),
      ],
      child: MaterialApp(theme: omniLightTheme, darkTheme: omniDarkTheme, home: home),
    ),
  );
  await tester.pump(const Duration(milliseconds: 700));
  return alerts;
}

/// An engine whose current alert is an urgent reflex fire on the left.
AlertEngine firing() => AlertEngine()..addFire(DateTime.now(), WearerSide.left);

const _car = Alert(side: WearerSide.left, level: AlertLevel.urgent, label: 'car', source: AlertSource.camera);

class FakeVoice implements Voice {
  final said = <String>[];
  @override
  Future<void> say(String text, {bool interrupt = false}) async => said.add(text);
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
  _announcerTests();
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

      testWidgets('tabs lay out with an alert, a notice and a log ($label)', (tester) async {
        final alerts = await pumpApp(
          tester,
          const HomeShell(),
          brightness: brightness,
          textScale: scale,
          engine: firing(),
        );
        alerts.handle([
          const AlertRaised(_car),
          const AlertCleared(_car, ClearReason.silenced),
          const PossiblyFollowing(WearerSide.right, Duration(minutes: 3)),
        ]);
        await tester.pump(const Duration(milliseconds: 700));
        for (final tab in ['Aware', 'Eyes', 'Together', 'Today']) {
          await tester.tap(find.text(tab).last);
          await tester.pump(const Duration(milliseconds: 700));
          expect(find.byType(AlertBanner), findsOneWidget, reason: 'banner on $tab');
          await scrollThrough(tester);
        }
      });

      testWidgets('Together and Today lay out signed in, with a team, a break and quests ($label)', (tester) async {
        await pumpApp(tester, const HomeShell(), brightness: brightness, textScale: scale, together: true);
        for (final tab in ['Together', 'Today']) {
          await tester.tap(find.text(tab).last);
          await tester.pump(const Duration(milliseconds: 700));
          await scrollThrough(tester);
        }
        expect(find.textContaining(RegExp('screen break', caseSensitive: false)), findsWidgets);
      });

      testWidgets('person and team profiles lay out ($label)', (tester) async {
        await pumpApp(tester, const HomeShell(), brightness: brightness, textScale: scale, together: true);
        final context = tester.element(find.byType(HomeShell));
        final social = Provider.of<SocialStore>(context, listen: false);

        unawaited(
          showPersonSheet(
            context,
            const Person(
              id: 2,
              name: 'Maya',
              headsUp: 85,
              outside: 60,
              starsThisWeek: 7,
              questsThisWeek: {'look_up': 4},
              ringWeek: 55,
            ),
            subtitle: 'Friend',
            onRemove: () async {},
          ),
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('Side quests this week'), findsOneWidget);
        await tester.drag(find.byType(DraggableScrollableSheet), const Offset(0, -2000));
        await tester.pump(const Duration(milliseconds: 700));
        Navigator.pop(context);
        await tester.pump(const Duration(milliseconds: 700));

        unawaited(showTeamSheet(context, social.league.first));
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('Members'), findsOneWidget);
        await tester.drag(find.byType(DraggableScrollableSheet), const Offset(0, -3000));
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('Maya'), findsWidgets); // the members loaded
      });

      testWidgets('Widget Gallery lays out ($label)', (tester) async {
        await pumpApp(tester, const WidgetGallery(), brightness: brightness, textScale: scale);
        await scrollThrough(tester);
        expect(find.text('Friends see your ring % only'), findsWidgets); // last section
      });
    }
  }
}

void _announcerTests() {
  testWidgets('speaks one word, buzzes and dismisses', (tester) async {
    final voice = FakeVoice();
    final alerts = await pumpApp(
      tester,
      const HomeShell(),
      brightness: Brightness.light,
      voice: voice,
      engine: firing(),
    );
    alerts.handle([const AlertRaised(_car)]);
    await tester.pump(const Duration(milliseconds: 500));
    expect(voice.said, ['Car']);

    expect(find.textContaining('Something', findRichText: true), findsOneWidget); // banner for the reflex fire
    await tester.tap(find.byTooltip('Dismiss alert'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(AlertBanner), findsNothing);
    expect(alerts.log.latest?.ended, ClearReason.dismissed);
  });

  testWidgets('stays quiet with a screen reader on', (tester) async {
    final voice = FakeVoice();
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      accessibleNavigation: true,
    );
    final alerts = await pumpApp(tester, const HomeShell(), brightness: Brightness.light, voice: voice);
    alerts.handle([const AlertRaised(_car)]);
    await tester.pump(const Duration(milliseconds: 500));
    expect(voice.said, isEmpty);
  });
}

class _NoDetector implements ObjectDetector {
  @override
  Future<void> load() async {}

  @override
  Future<List<Detection>> detect(Uint8List jpeg) async => const [];

  @override
  void dispose() {}
}
