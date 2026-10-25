// Caption lines in the wearer's language, translated on the phone (iOS 26+:
// Apple's Translation framework, AppDelegate.swift). The text never leaves the
// device. The languages have to be downloaded once in iOS Settings.

import 'package:flutter/services.dart';

/// Languages captions can be translated into: code -> name.
const translationLanguages = {
  'en': 'English',
  'es': 'Spanish',
  'fr': 'French',
  'de': 'German',
  'it': 'Italian',
  'pt': 'Portuguese',
  'nl': 'Dutch',
  'pl': 'Polish',
  'tr': 'Turkish',
  'ru': 'Russian',
  'uk': 'Ukrainian',
  'ar': 'Arabic',
  'hi': 'Hindi',
  'zh-Hans': 'Chinese (Simplified)',
  'ja': 'Japanese',
  'ko': 'Korean',
  'vi': 'Vietnamese',
  'th': 'Thai',
  'id': 'Indonesian',
};

/// Where to get the languages on an iPhone.
const downloadLanguagesHint = 'Download them in Settings > Apps > Translate > Downloaded Languages.';

/// Why a line couldn't be translated: [code] "not_installed", "unsupported",
/// "unavailable" (older iOS, or not an iPhone) or "failed"; [source] the spoken language.
class TranslationUnavailable implements Exception {
  const TranslationUnavailable(this.code, [this.source]);
  final String code;
  final String? source;
}

abstract class CaptionTranslator {
  /// [text] in [target] and the language it was in. Throws [TranslationUnavailable].
  Future<(String, String)> translate(String text, String target);
}

class AppleCaptionTranslator implements CaptionTranslator {
  static const _channel = MethodChannel('omni/translate');

  @override
  Future<(String, String)> translate(String text, String target) async {
    try {
      final r = await _channel.invokeMapMethod<String, String>('translate', {'text': text, 'target': target});
      return (r?['text'] ?? text, r?['source'] ?? target);
    } on PlatformException catch (e) {
      throw TranslationUnavailable(e.code, e.details as String?);
    } on MissingPluginException {
      throw const TranslationUnavailable('unavailable');
    }
  }
}
