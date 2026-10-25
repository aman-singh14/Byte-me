// Switches for the newer features, so any of them can be turned off for a
// demo without a rebuild. Kept on the phone (shared preferences).

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum Feature {
  socialTaps('Social taps', 'A soft tap when someone stops close behind or beside you.', true),
  socialTapCheck('Check social taps with Muse', 'One rear snapshot asks Muse if the person is trying to get your attention.', true),
  lookUpNudge('"Look up" nudge', 'During close-up work, a social tap also asks you to look up.', true),
  captions('Live captions', 'Captions of what people around you say (Muse Voice Transcribe).', true),
  helperAudio('Helper call audio', 'Talk with your helper during a call (LiveKit).', true),
  vlmMock('Muse mock mode', 'Canned answers instead of Muse, for offline demos.', false);

  const Feature(this.title, this.blurb, this.byDefault);
  final String title;
  final String blurb;
  final bool byDefault;
}

class FeatureFlags extends ChangeNotifier {
  FeatureFlags({Map<Feature, bool>? initial}) {
    if (initial != null) _on.addAll(initial);
  }

  static const _prefix = 'feature_';
  final _on = <Feature, bool>{};
  SharedPreferences? _prefs;

  bool operator [](Feature f) => _on[f] ?? f.byDefault;

  Future<void> load() async {
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      for (final f in Feature.values) {
        final saved = prefs.getBool('$_prefix${f.name}');
        if (saved != null) _on[f] = saved;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('FeatureFlags: could not load: $e');
    }
  }

  void set(Feature f, bool on) {
    _on[f] = on;
    _prefs?.setBool('$_prefix${f.name}', on);
    notifyListeners();
  }
}
