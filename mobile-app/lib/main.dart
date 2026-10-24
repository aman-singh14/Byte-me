import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'alerts/alert_service.dart';
import 'alerts/voice.dart';
import 'app.dart';
import 'helper/helper_call.dart';
import 'net/glasses_link.dart';
import 'social/rings_source.dart';
import 'social/side_quests.dart';
import 'social/social_store.dart';
import 'social/together_time.dart';
import 'vision/detector.dart';
import 'vision/fire_namer.dart';
import 'vision/rear_vision.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final link = GlassesLink();
  link.start().catchError((Object e) => debugPrint('GlassesLink could not start: $e'));
  final vision = RearVision(link, YoloDetector());
  final alerts = AlertService(link, vision, namer: CamBFireNamer(link, YoloDetector()));
  alerts.start();
  // Stand-in until the rings code lands; it implements RingsSource too.
  final rings = StandInRings(link.sens);
  late final SideQuestStore quests;
  final social = SocialStore(link: link, rings: rings, questStars: () => quests.starsByQuest)..start();
  final together = TogetherTime(social: social, radio: BleNearbyRadio())..start();
  quests = SideQuestStore(rings: rings, sens: link.sens, together: together)..start();
  final voice = TtsVoice();
  final helper = HelperCall(toGlasses: link.send, cameras: GlassesCameras(vision), alerts: alerts.events, voice: voice);
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: link),
        ChangeNotifierProvider.value(value: vision),
        ChangeNotifierProvider.value(value: alerts),
        Provider<Voice?>.value(value: voice),
        ListenableProvider<RingsSource>.value(value: rings),
        ChangeNotifierProvider.value(value: social),
        ChangeNotifierProvider.value(value: quests),
        ChangeNotifierProvider.value(value: together),
        ChangeNotifierProvider.value(value: helper),
      ],
      child: const OmniApp(),
    ),
  );
}
