import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:speech_to_text/speech_to_text.dart';

import '../alerts/voice.dart';
import '../net/backend_link.dart';
import '../net/backend_models.dart';

abstract class QuestionSpeech {
  Future<bool> initialize({required void Function(String) status, required void Function(String) error});
  Future<void> listen(void Function(String, bool) result);

  /// Stops listening; the recognizer still delivers its last words.
  Future<void> stop();
  Future<void> cancel();
}

class DeviceQuestionSpeech implements QuestionSpeech {
  final _speech = SpeechToText();

  @override
  Future<bool> initialize({required void Function(String) status, required void Function(String) error}) =>
      _speech.initialize(onStatus: status, onError: (e) => error(e.errorMsg));

  @override
  Future<void> listen(void Function(String, bool) result) => _speech.listen(
    onResult: (r) => result(r.recognizedWords, r.finalResult),
    listenOptions: SpeechListenOptions(
      partialResults: true,
      cancelOnError: true,
      listenMode: ListenMode.dictation,
      // No pause limit: the wearer decides when they're done by letting go.
      listenFor: const Duration(seconds: 60),
    ),
  );

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}

/// Press-and-hold voice questions. The microphone is on only while the button
/// is held; letting go sends what was heard, once.
class VoiceQuestions extends ChangeNotifier {
  VoiceQuestions({required this.backend, this.voice, QuestionSpeech? speech, bool watchLifecycle = true})
    : speech = speech ?? DeviceQuestionSpeech() {
    if (watchLifecycle) {
      // Leaving the app (or the permission prompt) drops a held question.
      _lifecycle = AppLifecycleListener(
        onStateChange: (state) {
          if (state != AppLifecycleState.resumed) cancel();
        },
      );
    }
  }

  static const notHeard = "Didn't catch that. Hold the button while you ask.";
  static const notStarted = "Couldn't start listening. Try again in a moment.";
  static const noPermission = 'Allow the microphone and speech recognition in Settings to ask questions.';

  final BackendLink backend;
  final Voice? voice;
  final QuestionSpeech speech;
  AppLifecycleListener? _lifecycle;
  Completer<void>? _lastWords;
  bool _ready = false, _disposed = false, _retried = false, _failed = false;
  int _session = 0;

  /// The button is down.
  bool holding = false;

  /// The microphone is on.
  bool listening = false;

  /// Sending the question or speaking the answer.
  bool busy = false;
  String transcript = '';
  String? question, error;
  LookResult? answer;

  /// Button pressed: start listening.
  Future<void> hold() async {
    if (_disposed || holding || busy) return;
    final session = ++_session;
    holding = true;
    _retried = false;
    _failed = false;
    transcript = '';
    error = null;
    _notify();
    if (!_ready) {
      try {
        _ready = await speech.initialize(status: _status, error: _error);
      } catch (_) {
        _ready = false;
      }
      if (!_ready) {
        if (session == _session) _stopHolding(noPermission);
        return;
      }
    }
    // Let go while the permission prompt was up: they'll press again.
    if (session == _session && holding) await _listen(session);
  }

  /// Button released: send what was heard.
  Future<void> release() async {
    if (!holding) return;
    final session = _session;
    holding = false;
    _notify();
    _lastWords = Completer<void>();
    final wasListening = listening;
    await speech.stop();
    if (wasListening) await _lastWords!.future.timeout(const Duration(milliseconds: 1500), onTimeout: () {});
    if (_disposed || session != _session) return;
    listening = false;
    final words = transcript.trim();
    if (words.isEmpty) {
      error = _failed ? notStarted : notHeard;
      _notify();
      return;
    }
    await _ask(words);
  }

  /// Dropped without sending (finger slid away, or the app went to the background).
  void cancel() {
    if (!holding && !listening) return;
    _session++;
    holding = false;
    listening = false;
    transcript = '';
    unawaited(speech.cancel());
    _notify();
  }

  Future<void> _listen(int session) async {
    listening = true;
    _notify();
    try {
      await speech.listen((words, finalResult) {
        if (_disposed || session != _session) return;
        transcript = words;
        if (finalResult) _lastWords?.complete();
        _notify();
      });
    } catch (_) {
      if (session == _session) _stopHolding("Couldn't start the microphone. Try again.");
    }
  }

  void _status(String status) {
    if (_disposed) return;
    if (status == 'done' || status == 'notListening') {
      listening = false;
      if (status == 'done' && !(_lastWords?.isCompleted ?? true)) _lastWords!.complete();
      _notify();
    }
  }

  void _error(String message) {
    if (_disposed) return;
    debugPrint('Voice questions: $message');
    // After letting go, release() decides what to say.
    if (!holding) {
      if (!(_lastWords?.isCompleted ?? true)) _lastWords!.complete();
      return;
    }
    if (message.contains('permission') || message.contains('not_authorized') || message.contains('disabled')) {
      _ready = false;
      _stopHolding(noPermission);
      return;
    }
    // iOS often fails the first start (error 300, "failed to initialize
    // recognizer"); try once more while the button is still down.
    listening = false;
    _failed = transcript.isEmpty;
    if (transcript.isEmpty && !_retried) {
      _retried = true;
      final session = _session;
      Timer(const Duration(milliseconds: 300), () {
        if (!_disposed && holding && session == _session) {
          _failed = false;
          _listen(session);
        }
      });
    }
    _notify();
  }

  void _stopHolding(String message) {
    _session++;
    holding = false;
    listening = false;
    error = message;
    unawaited(speech.cancel());
    _notify();
  }

  Future<void> _ask(String words) async {
    busy = true;
    final session = ++_session;
    question = words;
    answer = null;
    error = null;
    _notify();
    try {
      await speech.cancel(); // the microphone is off before network work or speaking
      final response = await backend.look(question: words, requireGaze: true);
      if (_disposed || session != _session) return;
      answer = response;
      _notify();
      await voice?.say(response.spoken, interrupt: true);
    } catch (e) {
      if (!_disposed && session == _session) {
        error = e.toString();
        _notify();
        await voice?.say(error!, interrupt: true);
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _session++;
    _lifecycle?.dispose();
    unawaited(speech.cancel());
    super.dispose();
  }
}
