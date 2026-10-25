// Spoken alerts with the phone's own text-to-speech (on device, nothing is
// sent anywhere).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

abstract class Voice {
  /// Says [text]. [interrupt] cuts off whatever is being said.
  Future<void> say(String text, {bool interrupt = false});
}

class TtsVoice implements Voice {
  final _tts = FlutterTts();
  Future<void>? _ready;

  Future<void> _setUp() async {
    if (Platform.isIOS) {
      // Speak even with the silent switch on, and lower music while speaking.
      await _tts.setSharedInstance(true);
      await _tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
        IosTextToSpeechAudioCategoryOptions.duckOthers,
        IosTextToSpeechAudioCategoryOptions.interruptSpokenAudioAndMixWithOthers,
      ], IosTextToSpeechAudioMode.voicePrompt);
    }
    await _tts.awaitSpeakCompletion(true);
    await _tts.setSpeechRate(Platform.isIOS ? 0.55 : 0.6); // a little brisk
  }

  @override
  Future<void> say(String text, {bool interrupt = false}) async {
    try {
      await (_ready ??= _setUp());
      if (interrupt) await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('TtsVoice: $e'); // no voice is better than a crash
    }
  }
}
