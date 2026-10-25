// Two-way call audio for Call a helper, through LiveKit Cloud. Video and
// buzzes stay on our own relay; only the voices go through LiveKit.
//
// The phone publishes its microphone (echo cancellation, noise suppression
// and auto gain on) and plays the helper's voice. LiveKit puts the phone in
// call audio mode, which routes to Bluetooth headsets such as open-ear or
// bone-conduction ones. Nothing is recorded.

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

abstract class HelperAudio {
  /// Joins the call's audio room and turns the microphone on.
  Future<void> join(String url, String token);
  Future<void> setMuted(bool muted);

  /// Leaves and releases the microphone.
  Future<void> leave();
}

class LiveKitHelperAudio implements HelperAudio {
  Room? _room;

  static const _capture = AudioCaptureOptions(echoCancellation: true, noiseSuppression: true, autoGainControl: true);

  @override
  Future<void> join(String url, String token) async {
    await leave();
    final room = _room = Room(
      roomOptions: const RoomOptions(defaultAudioCaptureOptions: _capture, adaptiveStream: false, dynacast: false),
    );
    await room.connect(url, token);
    await room.localParticipant?.setMicrophoneEnabled(true, audioCaptureOptions: _capture);
  }

  @override
  Future<void> setMuted(bool muted) async {
    await _room?.localParticipant?.setMicrophoneEnabled(!muted, audioCaptureOptions: _capture);
  }

  @override
  Future<void> leave() async {
    final room = _room;
    _room = null;
    if (room == null) return;
    try {
      await room.disconnect();
      await room.dispose();
    } catch (e) {
      debugPrint('HelperAudio: leaving: $e');
    }
  }
}
