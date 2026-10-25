import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:speech_to_text/speech_to_text.dart';

import '../alerts/voice.dart';
import '../eyes/gaze.dart' show regionColumns;
import '../net/backend_link.dart';
import '../net/backend_models.dart';
import '../net/glasses_link.dart' show CameraBoard;
import '../vision/phone_camera.dart';
import 'vlm.dart';

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

/// Ask without the laptop: one photo goes to Muse with the question (through
/// the cloud server, or the laptop's /vlm). The photo is a still from the
/// glasses' front camera when its board is on the hotspot (cropped to where
/// the wearer is looking, when the eye camera knows), else from the phone's
/// back camera, which runs only while the button is held and the answer
/// comes back.
class PhoneLook {
  PhoneLook({required this.camera, required this.vlm, this.glassesFront, this.gaze, http.Client? client})
    : _http = client ?? http.Client();

  final PhoneCamera camera;
  final VlmService vlm;

  /// The front camera board, if it said hello.
  final CameraBoard? Function()? glassesFront;

  /// Where the wearer is looking (left / center / right), or null when unknown.
  final String? Function()? gaze;
  final http.Client _http;
  bool _cameraOn = false;

  /// The photo comes from the glasses' front camera, not the phone's.
  bool get fromGlasses => glassesFront?.call() != null;

  void warmUp() {
    if (fromGlasses || _cameraOn) return;
    _cameraOn = true;
    unawaited(camera.start());
  }

  void coolDown() {
    if (!_cameraOn) return;
    _cameraOn = false;
    unawaited(camera.stop());
  }

  Future<LookResult> ask(String question) async {
    final board = glassesFront?.call();
    final region = board == null ? null : gaze?.call();
    final VlmImage image;
    if (board != null) {
      final still = await _still(board);
      image = VlmImage.front(region == null ? still : await compute(_cropColumns, (still, region)));
    } else {
      final jpeg = await camera.next();
      if (jpeg == null) throw VlmUnavailable(camera.error ?? "Couldn't get a picture from your phone camera.");
      image = VlmImage.phone(jpeg);
    }
    final r = await vlm.ask(VlmFeature.ask, images: [image], question: question);
    final answer = r['answer'];
    return LookResult(
      region: region ?? 'all',
      regionSource: region == null ? 'phone' : 'gaze',
      museAnswer: answer is String && answer.trim().isNotEmpty ? answer.trim() : null,
    );
  }

  /// One 640x480 still from the front camera board (HTTP /capture).
  Future<List<int>> _still(CameraBoard board) async {
    try {
      final r = await _http.get(board.capture()).timeout(const Duration(seconds: 4));
      if (r.statusCode == 200 && r.bodyBytes.length > 2) return r.bodyBytes;
    } catch (e) {
      debugPrint('PhoneLook: front still: $e');
    }
    throw const VlmUnavailable("Couldn't get a picture from the glasses' front camera.");
  }
}

/// The [regionColumns] part of a JPEG, as a JPEG (the whole picture if it doesn't decode).
List<int> _cropColumns((List<int>, String) job) {
  final (jpeg, region) = job;
  final im = img.decodeJpg(Uint8List.fromList(jpeg));
  final cols = regionColumns[region];
  if (im == null || cols == null) return jpeg;
  final x0 = (cols.$1 * im.width).round(), x1 = (cols.$2 * im.width).round();
  return img.encodeJpg(img.copyCrop(im, x: x0, y: 0, width: x1 - x0, height: im.height), quality: 85);
}

/// Press-and-hold voice questions. The microphone is on only while the button
/// is held; letting go sends what was heard, once.
class VoiceQuestions extends ChangeNotifier {
  VoiceQuestions({required this.backend, this.voice, this.phone, QuestionSpeech? speech, bool watchLifecycle = true})
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

  /// Used while the laptop isn't connected. Null: Ask needs the laptop.
  final PhoneLook? phone;
  final QuestionSpeech speech;
  bool _phoneOn = false;
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

  /// The next question goes with a photo straight to Muse: there's no laptop (the phone
  /// runs everything) or it isn't answering.
  bool get usesPhone => phone != null && (backend.onPhone || backend.status != BackendStatus.connected);

  /// That photo comes from the glasses' front camera rather than the phone's.
  bool get photoFromGlasses => phone?.fromGlasses == true;

  void _warmPhone() {
    if (_phoneOn || !usesPhone) return;
    _phoneOn = true;
    phone!.warmUp();
  }

  void _coolPhone() {
    if (!_phoneOn) return;
    _phoneOn = false;
    phone!.coolDown();
  }

  /// Button pressed: start listening.
  Future<void> hold() async {
    if (_disposed || holding || busy) return;
    final session = ++_session;
    holding = true;
    _retried = false;
    _failed = false;
    transcript = '';
    error = null;
    _warmPhone(); // a picture is ready by the time they let go
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
      _coolPhone();
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
    _coolPhone();
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
        if (finalResult && !(_lastWords?.isCompleted ?? true)) _lastWords!.complete();
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
    _coolPhone();
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
      final response = _phoneOn ? await phone!.ask(words) : await backend.look(question: words, requireGaze: true);
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
      _coolPhone();
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
    _coolPhone();
    unawaited(speech.cancel());
    super.dispose();
  }
}
