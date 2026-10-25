// Outside time from the FRONT camera, with its auto-exposure taken out:
// backend/outdoor.py. Auto-exposure keeps the picture's brightness about the
// same indoors and out; what changes is how hard the sensor works. So
//
//   scene brightness ~ mean luma / (exposure lines x gain)      (log10)
//
// from the board's /sensor. Outside = above a threshold for 60 s, inside again
// = below a lower one for 60 s. A blue or bright top third (sky) lowers the
// threshold a little. Without fresh sensor numbers there is no call, except
// from a camera that has none (a webcam, stock firmware): then sky in the top
// third of a daylit picture for 60 s is outside, and too little sky for 60 s
// is inside again. Rougher: a bright window can pass for sky.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// log10 of exposure-normalised brightness, or null without usable sensor values.
double? sceneBrightness(double meanLuma, double? exposureLines, double? gain) {
  if (exposureLines == null || gain == null || exposureLines <= 0 || gain <= 0) return null;
  return math.log(math.max(meanLuma, 1.0) / (exposureLines * gain)) / math.ln10;
}

/// OV2640 register 0x00 (GAIN) -> multiplier: (b7+1)(b6+1)(b5+1)(b4+1)(1 + b[3:0]/16).
double gainFromOv2640(int reg) {
  var g = 1.0;
  for (final bit in [7, 6, 5, 4]) {
    if (reg & (1 << bit) != 0) g *= 2;
  }
  return g * (1 + (reg & 0x0F) / 16);
}

/// The board's /sensor JSON -> (exposure lines, gain).
(double?, double?) parseSensor(Map<String, dynamic> j) {
  final exp = (j['aec_lines'] as num?)?.toDouble();
  var gain = (j['gain_x'] as num?)?.toDouble();
  if (gain == null && j['gain_reg'] is num) gain = gainFromOv2640((j['gain_reg'] as num).toInt());
  return (exp, gain);
}

/// A front frame's mean luma and how much of its top third looks like sky,
/// from its JPEG. Null if it doesn't decode. Slow-ish: run it off the UI isolate.
(double, double)? frontFrameStats(Uint8List jpeg) {
  final img.Image? im;
  try {
    im = img.decodeJpg(jpeg);
  } on Object {
    return null; // a frame mangled on the way
  }
  if (im == null || im.width == 0) return null;
  var luma = 0.0, sky = 0;
  final top = im.height ~/ 3;
  for (final p in im) {
    final r = p.r.toInt(), g = p.g.toInt(), b = p.b.toInt();
    luma += 0.299 * r + 0.587 * g + 0.114 * b;
    if (p.y < top && _isSky(r, g, b)) sky++;
  }
  return (luma / (im.width * im.height), top == 0 ? 0.0 : sky / (top * im.width));
}

/// Blue-ish and bright, or bright overcast, in OpenCV's 8-bit HSV (H 0..180).
bool _isSky(int r, int g, int b) {
  final v = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
  final s = v == 0 ? 0.0 : (v - mn) * 255 / v;
  if (s < 30 && v >= 220) return true;
  if (v < 120 || s < 40) return false;
  final d = (v - mn).toDouble();
  final h = v == r ? 60 * (g - b) / d : (v == g ? 120 + 60 * (b - r) / d : 240 + 60 * (r - g) / d);
  final h180 = (h < 0 ? h + 360 : h) / 2;
  return h180 >= 90 && h180 <= 130;
}

class OutdoorDetector {
  OutdoorDetector({
    this.indoorRef,
    this.outdoorRef,
    this.holdS = 60,
    this.band = 0.25,
    this.skyBoost = 0.2,
    this.skyMin = 0.3,
    this.dayLuma = 50,
  }) : threshold = indoorRef != null && outdoorRef != null ? (indoorRef + outdoorRef) / 2 : 0.0;

  double? indoorRef, outdoorRef;
  final double holdS, band, skyBoost, skyMin;

  /// Camera-only: darker pictures than this are night, never outside time.
  final double dayLuma;
  double threshold;
  bool outside = false;
  double? _candidateSince;
  double? since; // start of the current outside stretch
  bool? manual; // debug override
  double? lastBrightness;

  /// Returns ('start', t0) when outside began, ('end', (start, end)) when it ended.
  /// [cameraOnly]: the camera has no exposure numbers, so judge by the sky.
  Object? update(
    double t, {
    double? luma,
    double sky = 0,
    double? exposureLines,
    double? gain,
    bool cameraOnly = false,
  }) {
    final b = luma == null ? null : sceneBrightness(luma, exposureLines, gain);
    lastBrightness = b;
    final thr = threshold - (sky >= skyMin ? skyBoost : 0.0);
    final bool want;
    final double hold;
    if (manual != null) {
      want = manual!;
      hold = 0;
    } else if (b == null) {
      if (!cameraOnly || luma == null) return null; // no trustworthy reading: keep the current state
      want = !outside ? sky >= skyMin && luma >= dayLuma : sky >= skyMin / 3 && luma >= dayLuma;
      hold = holdS;
    } else {
      want = !outside ? b > thr + band : !(b < thr - band);
      hold = holdS;
    }
    if (want == outside) {
      _candidateSince = null;
      return null;
    }
    _candidateSince ??= t;
    if (t - _candidateSince! < hold) return null;
    final start = _candidateSince!;
    _candidateSince = null;
    outside = want;
    if (want) {
      since = start; // the stretch began when it first got bright
      return ('start', start);
    }
    final stretch = (since ?? start, start);
    since = null;
    return ('end', stretch);
  }

  /// The glasses came off or the camera went away: end the stretch.
  (double, double)? flush(double t) {
    if (!outside || since == null) return null;
    final s = since!;
    since = null;
    outside = false;
    return (s, t);
  }
}
