// The Eyes, Today and Together tabs filled with backend data lay out without
// overflow on a small phone (light/dark, 100%/200% text) and show the numbers.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/alerts/alert_service.dart';
import 'package:omni_glasses/alerts/voice.dart';
import 'package:omni_glasses/app.dart';
import 'package:omni_glasses/assist/voice_questions.dart';
import 'package:omni_glasses/helper/helper_call.dart';
import 'package:omni_glasses/net/backend_api.dart';
import 'package:omni_glasses/net/backend_link.dart';
import 'package:omni_glasses/net/backend_rings.dart';
import 'package:omni_glasses/net/glasses_link.dart';
import 'package:omni_glasses/screens/home_shell.dart';
import 'package:omni_glasses/screens/settings_screen.dart';
import 'package:omni_glasses/settings/feature_flags.dart';
import 'package:omni_glasses/social/rings_source.dart';
import 'package:omni_glasses/social/side_quests.dart';
import 'package:omni_glasses/social/social_store.dart';
import 'package:omni_glasses/social/together_time.dart';
import 'package:omni_glasses/vision/detector.dart';
import 'package:omni_glasses/vision/rear_vision.dart';
import 'package:provider/provider.dart';

import 'backend_fakes.dart';
import 'captions_test.dart' show fakeCaptions;
import 'voice_questions_test.dart' show FakeQuestionSpeech;
import 'social_test.dart' show FakeRadio, FixedRings;

class _NoDetector implements ObjectDetector {
  @override
  Future<void> load() async {}

  @override
  Future<List<Detection>> detect(Uint8List jpeg) async => const [];

  @override
  void dispose() {}
}

Future<BackendLink> filledLink(WidgetTester tester) async {
  final link = BackendLink(
    store: MemorySettingsStore(),
    apiFactory: (b) => BackendApi(b, transport: FakeTransport()),
  );
  await tester.runAsync(() async {
    await link.setManualUrl('172.20.10.2');
    await link.refreshAll();
  });
  return link;
}

class _FakeVoice implements Voice {
  final said = <String>[];
  @override
  Future<void> say(String text, {bool interrupt = false}) async => said.add(text);
}

Future<void> pump(
  WidgetTester tester,
  Widget home,
  BackendLink backend, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
  Voice? voice,
}) async {
  tester.view.physicalSize = const Size(360 * 3, 740 * 3);
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  // Same providers as main.dart (and Aman's screens_test), with the backend's rings
  // feeding the social features through BackendRings.
  final glasses = GlassesLink(port: 0);
  final vision = RearVision(glasses, _NoDetector());
  final alerts = AlertService(glasses, vision);
  final helper = HelperCall(
    toGlasses: glasses.send,
    cameras: GlassesCameras(vision),
    alerts: alerts.events,
    watchLifecycle: false,
  );
  final questions = VoiceQuestions(backend: backend, voice: voice, speech: FakeQuestionSpeech(), watchLifecycle: false);
  final rings = BackendRings(backend, FixedRings());
  final social = SocialStore(link: glasses, rings: rings);
  final quests = SideQuestStore(rings: rings, sens: glasses.sens);
  final together = TogetherTime(social: social, radio: FakeRadio());
  for (final d in [
    questions.dispose,
    helper.dispose,
    together.dispose,
    quests.dispose,
    social.dispose,
    rings.dispose,
    alerts.dispose,
    vision.dispose,
    glasses.dispose,
    backend.dispose,
  ]) {
    addTearDown(d);
  }
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: FeatureFlags()),
        ChangeNotifierProvider.value(value: fakeCaptions()),
        ChangeNotifierProvider.value(value: glasses),
        ChangeNotifierProvider.value(value: vision),
        ChangeNotifierProvider.value(value: alerts),
        Provider<Voice?>.value(value: voice),
        ListenableProvider<RingsSource>.value(value: rings),
        ChangeNotifierProvider.value(value: social),
        ChangeNotifierProvider.value(value: quests),
        ChangeNotifierProvider.value(value: together),
        ChangeNotifierProvider.value(value: backend),
        ChangeNotifierProvider.value(value: helper),
        ChangeNotifierProvider.value(value: questions),
      ],
      child: MaterialApp(theme: omniLightTheme, darkTheme: omniDarkTheme, home: home),
    ),
  );
  await tester.pump(const Duration(milliseconds: 700));
}

Future<void> scrollUntil(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (var i = 0; i < 200; i++) {
    final pos = tester.state<ScrollableState>(scrollable).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -500));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> openTab(WidgetTester tester, String tab) async {
  await tester.tap(find.text(tab).last);
  await tester.pump(const Duration(milliseconds: 700));
}

void main() {
  testWidgets('Eyes tab shows blinking and close-up time', (tester) async {
    await pump(tester, const HomeShell(), await filledLink(tester));
    await openTab(tester, 'Eyes');
    expect(find.text('Blinking'), findsOneWidget);
    expect(find.text('7'), findsOneWidget); // 7.4 blinks/min
    expect(find.textContaining('Low blinking since'), findsOneWidget);
    await scrollUntil(tester, find.text('Close-up time'));
    expect(find.text('2 h 13 m'), findsOneWidget); // 132.5 minutes
    expect(find.textContaining('Phone, about 25 cm away (close)'), findsOneWidget);
    await scrollUntil(tester, find.text('Calibrate distance'));
    expect(find.text('Laptop'), findsOneWidget); // by-object breakdown
    expect(find.textContaining('3 sessions'), findsOneWidget);
  });

  testWidgets('Today shows the rings, breaks and points', (tester) async {
    await pump(tester, const HomeShell(), await filledLink(tester));
    await scrollUntil(tester, find.text('Rings'));
    expect(find.text('Rings'), findsOneWidget);
    await scrollUntil(tester, find.text('7 heads-up breaks'));
    expect(find.text('48 points today'), findsOneWidget);
    expect(find.text('Outside now'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Heads-up ring, 1 hour 36 minutes of 3 hours')), findsOneWidget);
  });

  testWidgets('Together omits personal ring history', (tester) async {
    await pump(tester, const HomeShell(), await filledLink(tester));
    await openTab(tester, 'Together');
    expect(find.text('Rings this week'), findsNothing);
    expect(find.text('Join Together'), findsWidgets);
  });

  testWidgets('calibration sheet posts the chosen object and distance', (tester) async {
    final link = await filledLink(tester);
    await pump(tester, const HomeShell(), link);
    await openTab(tester, 'Eyes');
    await scrollUntil(tester, find.text('Calibrate distance'));
    await tester.tap(find.text('Calibrate distance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Laptop').last);
    await tester.pump();
    expect(find.text('Distance: 50 cm'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Calibrate'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('Laptop calibrated at 50 cm.'), findsOneWidget);
  });

  testWidgets('hold to ask sends what was heard, and works with a screen reader', (tester) async {
    final voice = _FakeVoice();
    await pump(tester, const HomeShell(), await filledLink(tester), voice: voice);
    expect(find.text('Ask your glasses'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    final button = find.text('Hold to ask');
    await tester.ensureVisible(button);
    final questions = tester.element(button).read<VoiceQuestions>();
    final speech = questions.speech as FakeQuestionSpeech;
    final finger = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Listening… let go to send'), findsOneWidget);
    speech.result!('Read the label on that cup', false);
    await finger.up();
    await tester.pump();
    await tester.pump();
    expect(questions.question, 'Read the label on that cup');
    expect(questions.answer?.regionSource, 'gaze');
    expect(voice.said, ['An open laptop is just ahead of you on a desk, with a white mug to its right.']);

    // With a screen reader: double tap to start, double tap again to send.
    final semantics = tester.ensureSemantics();
    final askButton = find.semantics.byPredicate(
      (n) => n.getSemanticsData().hasAction(SemanticsAction.tap) && n.label.contains(RegExp('Ask your glasses|Listening')),
    );
    tester.semantics.tap(askButton);
    await tester.pump();
    expect(questions.holding, isTrue);
    speech.result!('What color is the mug', false);
    tester.semantics.tap(askButton);
    await tester.pump();
    await tester.pump();
    expect(questions.question, 'What color is the mug');
    semantics.dispose();
  });

  testWidgets('Settings shows the laptop address', (tester) async {
    await pump(tester, const SettingsScreen(), await filledLink(tester));
    expect(find.text('Laptop (backend)'), findsOneWidget);
    expect(find.textContaining('172.20.10.2:8001 (typed in)'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Muse speed check'), 300);
    expect(find.text(Feature.socialTaps.title), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('tabs with data lay out (${brightness.name}, ${(scale * 100).round()}% text)', (tester) async {
        await pump(tester, const HomeShell(), await filledLink(tester), brightness: brightness, textScale: scale);
        for (final tab in ['Eyes', 'Together', 'Today']) {
          await openTab(tester, tab);
          await scrollThrough(tester);
        }
      });
    }
  }
}
