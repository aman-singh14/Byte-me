// Picking the most natural voice the phone has.

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/alerts/voice.dart';

TtsVoiceInfo v(String name, String locale, String quality, [String id = 'com.apple.voice.compact.x']) =>
    TtsVoiceInfo(name: name, locale: locale, quality: quality, identifier: id);

void main() {
  test("Premium beats Enhanced beats basic; the wearer's accent first; no novelty voices", () {
    final voices = [
      v('Samantha', 'en-US', 'default'),
      v('Zarvox', 'en-US', 'default', 'com.apple.speech.synthesis.voice.Zarvox'),
      v('Eddy', 'en-US', 'default', 'com.apple.eloquence.en-US.Eddy'),
      v('Daniel', 'en-GB', 'enhanced'),
      v('Thomas', 'fr-FR', 'premium'),
    ];
    expect(pickVoice(voices, 'en-US')!.name, 'Daniel');
    expect(pickVoice([...voices, v('Evan', 'en-US', 'enhanced')], 'en-US')!.name, 'Evan');
    expect(pickVoice([...voices, v('Ava', 'en-US', 'premium')], 'en-US').toString(), 'Ava (Premium)');
    expect(pickVoice(voices.sublist(0, 3), 'en-US')!.name, 'Samantha');
    expect(pickVoice(voices, 'de-DE'), isNull);
  });

  test("reads flutter_tts's voice maps", () {
    final info = TtsVoiceInfo.fromMap({'name': 'Ava', 'locale': 'en-US', 'quality': 'premium', 'identifier': 'id'})!;
    expect(info.natural, isTrue);
    expect(info.toMap(), {'name': 'Ava', 'locale': 'en-US', 'identifier': 'id'});
    expect(TtsVoiceInfo.fromMap({'name': 'x'}), isNull);
  });
}
