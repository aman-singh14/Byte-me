// Buzzes on the phone, for when there's no frame ESP32 to buzz: the camera
// boards (firmware/) have no motor, only the back camera's own collision
// buzzer. The words (which side, which way) are spoken elsewhere; these are
// only the feel, so each kind of message still feels different. iOS haptics
// are short taps, so a pattern is a few of them in a row.

import 'dart:async';

import 'package:flutter/services.dart';

import '../net/protocol.dart';

enum Tap { light, medium, heavy }

/// The taps for [cmd], each with the pause before it (ms). Empty: nothing to feel.
List<(Tap, int)> buzzPattern(GlassesCommand cmd) => switch (cmd) {
  AlertCommand(level: >= 2) => const [(Tap.heavy, 0), (Tap.heavy, 120), (Tap.heavy, 120)],
  AlertCommand() => const [(Tap.medium, 0), (Tap.medium, 180)],
  TapCommand(kind: 'lookup') => const [(Tap.light, 0), (Tap.light, 150), (Tap.light, 150)],
  TapCommand() => const [(Tap.light, 0), (Tap.light, 150)],
  GuideCommand(dir: GuideDirection.left) => const [(Tap.medium, 0)],
  GuideCommand(dir: GuideDirection.right) => const [(Tap.medium, 0), (Tap.medium, 150)],
  GuideCommand(dir: GuideDirection.forward) => const [(Tap.heavy, 0)],
  GuideCommand(dir: GuideDirection.stop) => const [(Tap.heavy, 0), (Tap.heavy, 100), (Tap.heavy, 100), (Tap.heavy, 100)],
  GroupBreakCommand() => const [(Tap.medium, 0), (Tap.light, 250), (Tap.medium, 250)],
  _ => const [], // the LIVE light, stop and heartbeats have nothing to feel
};

class PhoneBuzzer {
  PhoneBuzzer({Future<void> Function(Tap)? tap}) : _tap = tap ?? _haptic;

  final Future<void> Function(Tap) _tap;

  /// A newer buzz cuts the one playing short.
  int _playing = 0;

  Future<void> play(GlassesCommand cmd) async {
    final pattern = buzzPattern(cmd);
    if (pattern.isEmpty) return;
    final id = ++_playing;
    for (final (tap, pause) in pattern) {
      if (pause > 0) await Future<void>.delayed(Duration(milliseconds: pause));
      if (id != _playing) return;
      await _tap(tap);
    }
  }

  static Future<void> _haptic(Tap tap) => switch (tap) {
    Tap.light => HapticFeedback.lightImpact(),
    Tap.medium => HapticFeedback.mediumImpact(),
    Tap.heavy => HapticFeedback.heavyImpact(),
  };
}
