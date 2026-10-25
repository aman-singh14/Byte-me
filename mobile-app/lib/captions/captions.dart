// Live captions: microphone audio goes to the captions relay (backend/captions.py),
// which holds the Meta key and passes it to Muse Voice Transcribe; caption
// events come back and become lines (CaptionTranscript).
//
// Audio is 16 kHz signed 16-bit mono PCM, sent in 100 ms binary frames as it
// is recorded (Meta wants about real time). Nothing is saved: not the audio,
// not the text. Turning captions off discards the text.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helper/helper_call.dart' show HelperSocket, IoHelperSocket;
import '../net/backend_link.dart';
import '../net/cloud.dart';
import 'caption_transcript.dart';

/// Override the relay, e.g. the mock:
/// `--dart-define=CAPTIONS_URL=ws://localhost:8030/ws/captions`.
const captionsUrlOverride = String.fromEnvironment('CAPTIONS_URL');

/// Where the relay is: the override, else the cloud server's /ws/captions, else
/// the laptop backend's.
Uri? captionsRelay(BackendLink backend) {
  if (captionsUrlOverride.isNotEmpty) return Uri.parse(captionsUrlOverride);
  final base = cloudServer ?? backend.baseUrl;
  if (base == null) return null;
  return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: '/ws/captions');
}

enum CaptionsState {
  off,
  connecting,
  live,

  /// Stopped by the wearer; the text stays.
  paused,

  /// Stopped by a problem; [Captions.message] says what.
  failed,
}

/// The microphone, as 16 kHz signed 16-bit mono PCM.
abstract class CaptionMic {
  Future<bool> hasPermission();
  Future<Stream<Uint8List>> start();
  Future<void> stop();
}

class RecordCaptionMic implements CaptionMic {
  final _recorder = AudioRecorder();

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Stream<Uint8List>> start() => _recorder.startStream(
    const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: Captions.sampleRate,
      numChannels: 1,
      autoGain: true,
      noiseSuppress: true,
    ),
  );

  @override
  Future<void> stop() => _recorder.stop();
}

class Captions extends ChangeNotifier {
  Captions({
    required this.relay,
    CaptionMic? mic,
    Future<HelperSocket> Function(Uri url)? connect,
  }) : mic = mic ?? RecordCaptionMic(),
       _connect = connect ?? IoHelperSocket.connect;

  final Uri? Function() relay;
  final CaptionMic mic;
  final Future<HelperSocket> Function(Uri) _connect;

  static const sampleRate = 16000;

  /// Audio goes up in pieces this long (100 ms = 3200 bytes).
  static const chunkBytes = sampleRate * 2 ~/ 10;

  static const minFontSize = 20.0, maxFontSize = 48.0;

  final transcript = CaptionTranscript();

  CaptionsState _state = CaptionsState.off;
  CaptionsState get state => _state;

  /// Why captions stopped, to show.
  String? message;

  /// "meta", or "mock" / "wav" from a test relay.
  String? source;

  double fontSize = 28;

  /// DIARIZATION ("Speaker 1", "Speaker 2") or the faster ENDPOINTING.
  bool speakerLabels = true;

  /// The wearer has read what captions send, and agreed.
  bool consented = false;

  bool get on => _state != CaptionsState.off;

  SharedPreferences? _prefs;
  HelperSocket? _socket;
  StreamSubscription<String>? _events;
  StreamSubscription<Uint8List>? _audio;
  final _buffer = BytesBuilder(copy: false);
  int _session = 0;
  bool _ending = false;

  static const _sizeKey = 'captions_font_size', _consentKey = 'captions_consent', _labelsKey = 'captions_speakers';

  Future<void> load() async {
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      fontSize = (prefs.getDouble(_sizeKey) ?? fontSize).clamp(minFontSize, maxFontSize);
      consented = prefs.getBool(_consentKey) ?? false;
      speakerLabels = prefs.getBool(_labelsKey) ?? true;
      notifyListeners();
    } catch (e) {
      debugPrint('Captions: could not load settings: $e');
    }
  }

  void acceptConsent() {
    consented = true;
    _prefs?.setBool(_consentKey, true);
    notifyListeners();
  }

  void setFontSize(double size) {
    fontSize = size.clamp(minFontSize, maxFontSize);
    _prefs?.setDouble(_sizeKey, fontSize);
    notifyListeners();
  }

  /// Takes effect from the next session (Meta fixes the mode per session).
  void setSpeakerLabels(bool on) {
    speakerLabels = on;
    _prefs?.setBool(_labelsKey, on);
    notifyListeners();
  }

  /// Starts captions. The caller asks for consent first.
  Future<void> turnOn() async {
    if (on && _state != CaptionsState.failed) return;
    await _startSession();
  }

  /// Stops captions and discards the text.
  Future<void> turnOff() async {
    await _stopSession();
    transcript.clear();
    message = null;
    _set(CaptionsState.off);
  }

  /// Stops listening; the text stays until cleared or turned off.
  Future<void> pause() async {
    if (_state != CaptionsState.live && _state != CaptionsState.connecting) return;
    await _stopSession(finish: true);
    _set(CaptionsState.paused);
  }

  Future<void> resume() => _startSession();

  void clear() {
    transcript.clear();
    notifyListeners();
  }

  Future<void> _startSession() async {
    final session = ++_session;
    message = null;
    _set(CaptionsState.connecting);
    final url = relay();
    if (url == null) return _fail(session, 'Set the laptop address in Settings to use captions.');
    if (!await mic.hasPermission()) {
      return _fail(session, 'Allow the microphone in Settings to use captions.');
    }
    final HelperSocket socket;
    try {
      socket = await _connect(url);
    } catch (e) {
      debugPrint('Captions: connect: $e');
      return _fail(session, "Can't reach the captions server.");
    }
    if (session != _session) {
      unawaited(socket.close());
      return;
    }
    _socket = socket;
    _ending = false;
    transcript.startSession();
    _events = socket.messages.listen((text) => _onMessage(session, text), onDone: () => _onClosed(session, socket));
    socket.sendText(
      jsonEncode({
        'type': 'start',
        'audioEncoding': 'PCM_16KHZ',
        'mode': speakerLabels ? 'DIARIZATION' : 'ENDPOINTING',
      }),
    );
  }

  void _onMessage(int session, String text) {
    if (session != _session) return;
    final Object? event;
    try {
      event = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (event is! Map<String, dynamic>) return;
    switch (event['type']) {
      case 'ready':
        source = event['source'] as String?;
        unawaited(_startAudio(session));
      case 'error':
        message = event['message'] as String?;
        debugPrint('Captions: error: $message');
        notifyListeners();
      default:
        if (transcript.apply(event)) notifyListeners();
    }
  }

  Future<void> _startAudio(int session) async {
    try {
      final stream = await mic.start();
      if (session != _session) {
        await mic.stop();
        return;
      }
      _audio = stream.listen((pcm) => _onAudio(session, pcm));
      _set(CaptionsState.live);
    } catch (e) {
      debugPrint('Captions: mic: $e');
      await _stopSession();
      _fail(session, "Couldn't start the microphone.");
    }
  }

  void _onAudio(int session, Uint8List pcm) {
    final socket = _socket;
    if (session != _session || socket == null || _ending) return;
    _buffer.add(pcm);
    if (_buffer.length >= chunkBytes) socket.sendBytes(_buffer.takeBytes());
  }

  void _onClosed(int session, HelperSocket socket) {
    if (session != _session || !identical(socket, _socket)) return;
    _socket = null;
    unawaited(_stopAudio());
    if (_ending || _state == CaptionsState.off) return;
    final code = socket.closeCode;
    debugPrint('Captions: closed $code');
    _fail(session, message ?? 'Captions stopped. Turn them on again.');
  }

  void _fail(int session, String why) {
    if (session != _session) return;
    message = why;
    _set(CaptionsState.failed);
  }

  /// [finish]: send endStream and let the open turn's final text arrive.
  Future<void> _stopSession({bool finish = false}) async {
    final socket = _socket;
    _ending = true;
    await _stopAudio();
    if (socket == null) {
      _session++;
      return;
    }
    if (finish) {
      final rest = _buffer.takeBytes();
      if (rest.isNotEmpty) socket.sendBytes(rest);
      socket.sendText(jsonEncode({'type': 'endStream'}));
      // The relay closes once Meta has sent the last results; don't wait forever.
      await _events?.asFuture<void>().timeout(const Duration(seconds: 3), onTimeout: () {}).catchError((_) {});
    }
    _session++;
    _socket = null;
    await _events?.cancel();
    _events = null;
    await socket.close();
  }

  Future<void> _stopAudio() async {
    final audio = _audio;
    _audio = null;
    _buffer.clear();
    if (audio == null) return;
    await audio.cancel();
    try {
      await mic.stop();
    } catch (e) {
      debugPrint('Captions: mic stop: $e');
    }
  }

  void _set(CaptionsState s) {
    _state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_stopSession());
    super.dispose();
  }
}
