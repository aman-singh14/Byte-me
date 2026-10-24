import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'alerts/alert_service.dart';
import 'alerts/voice.dart';
import 'app.dart';
import 'net/glasses_link.dart';
import 'vision/detector.dart';
import 'vision/rear_vision.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final link = GlassesLink();
  link.start().catchError((Object e) => debugPrint('GlassesLink could not start: $e'));
  final vision = RearVision(link, YoloDetector());
  final alerts = AlertService(link, vision);
  alerts.start();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: link),
        ChangeNotifierProvider.value(value: vision),
        ChangeNotifierProvider.value(value: alerts),
        Provider<Voice?>.value(value: TtsVoice()),
      ],
      child: const OmniApp(),
    ),
  );
}
