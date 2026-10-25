import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'alerts/alert_service.dart';
import 'alerts/social_taps.dart';
import 'alerts/voice.dart';
import 'app.dart';
import 'assist/vlm.dart';
import 'assist/voice_questions.dart';
import 'captions/captions.dart';
import 'helper/helper_call.dart';
import 'net/backend_link.dart';
import 'net/backend_rings.dart';
import 'net/cloud.dart';
import 'net/glasses_link.dart';
import 'settings/feature_flags.dart';
import 'social/rings_source.dart';
import 'social/side_quests.dart';
import 'social/social_store.dart';
import 'social/together_time.dart';
import 'vision/detector.dart';
import 'vision/fire_namer.dart';
import 'vision/rear_vision.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final flags = FeatureFlags()..load();
  final link = GlassesLink();
  link.start().catchError((Object e) => debugPrint('GlassesLink could not start: $e'));
  final vision = RearVision(link, YoloDetector());
  final alerts = AlertService(link, vision, namer: CamBFireNamer(link, YoloDetector()));
  alerts.start();
  // Eye, close-up and ring data from the laptop backend; its address comes from Settings
  // or from the laptop's UDP hello on the glasses link.
  final backend = BackendLink();
  backend.start(glasses: link).catchError((Object e) => debugPrint('BackendLink could not start: $e'));
  // Real rings from the backend; the sensor stand-in fills in while it isn't answering.
  final rings = BackendRings(backend, StandInRings(link.sens));
  late final SideQuestStore quests;
  final social = SocialStore(link: link, rings: rings, questStars: () => quests.starsByQuest)..start();
  final together = TogetherTime(social: social, radio: BleNearbyRadio())..start();
  quests = SideQuestStore(rings: rings, sens: link.sens, together: together)..start();
  // One VLM service (Muse, through the cloud server or the laptop backend) for every snapshot feature.
  final cloud = cloudServer;
  final vlm = cloud == null ? VlmService.backend(backend, flags) : VlmService.cloud(cloud, flags);
  SocialTapService(
    alerts: alerts,
    rearSnapshot: () => vision.camera?.frame.value,
    vlm: vlm,
    flags: flags,
    sens: link.sens,
    backendCloseUp: () => backend.eyes?.sessionStart != null,
    onLookedUp: quests.creditLookUp,
  );
  final voice = TtsVoice();
  final helper = HelperCall(
    toGlasses: link.send,
    cameras: GlassesCameras(vision),
    alerts: alerts.events,
    voice: voice,
    wearerName: () => social.me?.name,
    audioEnabled: () => flags[Feature.helperAudio],
  );
  final questions = VoiceQuestions(backend: backend, voice: voice);
  // Live captions go through the laptop's relay, which holds the Meta key.
  final captions = Captions(relay: () => captionsRelay(backend))..load();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: flags),
        ChangeNotifierProvider.value(value: vlm),
        ChangeNotifierProvider.value(value: link),
        ChangeNotifierProvider.value(value: vision),
        ChangeNotifierProvider.value(value: alerts),
        Provider<Voice?>.value(value: voice),
        ListenableProvider<RingsSource>.value(value: rings),
        ChangeNotifierProvider.value(value: social),
        ChangeNotifierProvider.value(value: quests),
        ChangeNotifierProvider.value(value: together),
        ChangeNotifierProvider.value(value: helper),
        ChangeNotifierProvider.value(value: backend),
        ChangeNotifierProvider.value(value: questions),
        ChangeNotifierProvider.value(value: captions),
      ],
      child: const OmniApp(),
    ),
  );
}
