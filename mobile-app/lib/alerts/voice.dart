// Spoken alerts with the phone's own text-to-speech (on device, nothing is
// sent anywhere). It uses the most natural voice the phone has: on iPhone a
// Premium or Enhanced voice when one is downloaded, at the normal pace.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

abstract class Voice {
  /// Says [text]. [interrupt] cuts off whatever is being said.
  Future<void> say(String text, {bool interrupt = false});
}

/// Where to get a better iPhone voice.
const betterVoiceHint =
    'For a more natural voice, download a Premium or Enhanced English voice in Settings > '
    'Accessibility > Spoken Content > Voices, then reopen the app.';

/// One of the phone's voices, as flutter_tts lists them.
class TtsVoiceInfo {
  const TtsVoiceInfo({required this.name, required this.locale, this.quality = 'default', this.identifier});
  final String name, locale, quality;
  final String? identifier;

  /// Premium and Enhanced voices sound like a person; default ones sound robotic.
  bool get natural => quality == 'premium' || quality == 'enhanced';

  static TtsVoiceInfo? fromMap(Object? m) {
    if (m is! Map) return null;
    final name = m['name'], locale = m['locale'];
    if (name is! String || locale is! String) return null;
    return TtsVoiceInfo(
      name: name,
      locale: locale,
      quality: m['quality'] is String ? m['quality'] as String : 'default',
      identifier: m['identifier'] is String ? m['identifier'] as String : null,
    );
  }

  Map<String, String> toMap() => {'name': name, 'locale': locale, 'identifier': ?identifier};

  @override
  String toString() => natural ? '$name (${quality[0].toUpperCase()}${quality.substring(1)})' : name;
}

/// The most natural voice for [language] (e.g. "en-US"): Premium, then Enhanced,
/// then the rest, the wearer's own accent first. Novelty voices (Bells, Zarvox, ...)
/// and the old Eloquence ones (Eddy, Grandma, ...) never.
TtsVoiceInfo? pickVoice(List<TtsVoiceInfo> voices, String language) {
  final lang = language.replaceAll('_', '-');
  final base = lang.split('-').first;
  int rank(TtsVoiceInfo v) =>
      ({'premium': 20, 'enhanced': 10}[v.quality] ?? 0) + (v.locale.replaceAll('_', '-') == lang ? 5 : 0);
  final candidates = [
    for (final v in voices)
      if (v.locale.replaceAll('_', '-').split('-').first == base &&
          !(v.identifier ?? '').contains('eloquence') &&
          !(v.identifier ?? '').contains('speech.synthesis'))
        v,
  ];
  if (candidates.isEmpty) return null;
  return candidates.reduce((a, b) => rank(b) > rank(a) ? b : a);
}

class TtsVoice implements Voice {
  final _tts = FlutterTts();
  Future<void>? _ready;

  /// The voice in use, once set up (null: the system default).
  TtsVoiceInfo? voice;

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
    try {
      final all = await _tts.getVoices;
      final list = [for (final m in all is List ? all : const []) ?TtsVoiceInfo.fromMap(m)];
      voice = pickVoice(list, PlatformDispatcher.instance.locale.toLanguageTag());
      if (voice != null) await _tts.setVoice(voice!.toMap());
    } catch (e) {
      debugPrint('TtsVoice: no voice list, using the default: $e');
    }
    await _tts.setSpeechRate(0.5); // the normal pace: faster sounds clipped and robotic
    await _tts.setPitch(1.0);
  }

  /// Picks the voice (if not done yet) and returns it, for Settings.
  Future<TtsVoiceInfo?> chosenVoice() async {
    await (_ready ??= _setUp());
    return voice;
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
