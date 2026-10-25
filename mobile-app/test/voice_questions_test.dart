import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:omni_glasses/alerts/voice.dart';
import 'package:omni_glasses/assist/voice_questions.dart';
import 'package:omni_glasses/net/backend_api.dart';
import 'package:omni_glasses/net/backend_link.dart';

import 'backend_fakes.dart';

class FakeQuestionSpeech implements QuestionSpeech {
  bool available = true;
  bool cancelled = false;
  int listens = 0, stops = 0;
  void Function(String, bool)? result;
  void Function(String)? status;
  void Function(String)? error;
  @override
  Future<bool> initialize({required void Function(String) status, required void Function(String) error}) async {
    this.status = status;
    this.error = error;
    return available;
  }

  @override
  Future<void> listen(void Function(String, bool) result) async {
    listens++;
    cancelled = false;
    this.result = result;
  }

  @override
  Future<void> stop() async {
    stops++;
    status?.call('done');
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

class WaitingVoice implements Voice {
  final done = Completer<void>();
  final said = <String>[];
  @override
  Future<void> say(String text, {bool interrupt = false}) {
    said.add(text);
    return done.future;
  }
}

void main() {
  late FakeTransport transport;
  late BackendLink backend;
  late FakeQuestionSpeech speech;

  setUp(() async {
    transport = FakeTransport();
    backend = BackendLink(store: MemorySettingsStore(), apiFactory: (u) => BackendApi(u, transport: transport));
    await backend.setManualUrl('localhost');
    speech = FakeQuestionSpeech();
  });

  tearDown(() => backend.dispose());

  int asked() => transport.requests.where((r) => r == 'POST /assist/look').length;

  testWidgets('listens only while held and sends what was heard once, with eye gaze', (tester) async {
    final voice = WaitingVoice();
    final questions = VoiceQuestions(backend: backend, speech: speech, voice: voice, watchLifecycle: false);
    addTearDown(questions.dispose);
    expect(speech.listens, 0); // nothing until the button is pressed
    await questions.hold();
    expect((questions.holding, questions.listening, speech.listens), (true, true, 1));
    speech.result!('Read the sign', false);
    speech.result!('Read the sign beside that door', false);
    expect(asked(), 0); // still holding
    unawaited(questions.release()); // finishes once the answer has been spoken
    await tester.pump();
    expect(speech.stops, 1);
    final i = transport.requests.indexOf('POST /assist/look');
    expect(transport.bodies[i], {'question': 'Read the sign beside that door', 'region_override': null, 'require_gaze': true});
    expect(asked(), 1);
    expect(questions.busy, true);

    await questions.hold(); // ignored while answering
    expect(speech.listens, 1);
    voice.done.complete();
    await tester.pump();
    expect(questions.busy, false);
    await tester.pump(const Duration(seconds: 5));
    expect(speech.listens, 1); // never starts again on its own
  });

  testWidgets("letting go with nothing heard says so and sends nothing", (tester) async {
    final questions = VoiceQuestions(backend: backend, speech: speech, watchLifecycle: false);
    addTearDown(questions.dispose);
    await questions.hold();
    await questions.release();
    expect(asked(), 0);
    expect(questions.error, VoiceQuestions.notHeard);
    await questions.hold(); // the next press clears it
    expect(questions.error, isNull);
  });

  testWidgets('without permission it explains, and works once allowed', (tester) async {
    final questions = VoiceQuestions(backend: backend, speech: speech..available = false, watchLifecycle: false);
    addTearDown(questions.dispose);
    await questions.hold();
    expect((questions.holding, speech.listens), (false, 0));
    expect(questions.error, VoiceQuestions.noPermission);
    speech.available = true;
    await questions.hold();
    expect(speech.listens, 1);
    speech.error!('error_speech_recognizer_request_not_authorized');
    expect((questions.holding, questions.error), (false, VoiceQuestions.noPermission));
  });

  testWidgets("a recognizer that fails to start (iOS error 300) is retried once, and the card isn't switched off", (
    tester,
  ) async {
    final questions = VoiceQuestions(backend: backend, speech: speech, watchLifecycle: false);
    addTearDown(questions.dispose);
    await questions.hold();
    speech.error!('error_unknown (300)');
    await tester.pump(const Duration(milliseconds: 400));
    expect(speech.listens, 2);
    expect(questions.error, isNull);
    speech.error!('error_unknown (300)');
    await tester.pump(const Duration(seconds: 1));
    expect(speech.listens, 2); // no loop
    await questions.release();
    expect(questions.error, VoiceQuestions.notStarted);
    await questions.hold(); // the next press just works
    expect(speech.listens, 3);
  });

  testWidgets('sliding off the button or leaving the app drops the question', (tester) async {
    final questions = VoiceQuestions(backend: backend, speech: speech);
    addTearDown(questions.dispose);
    await questions.hold();
    speech.result!('never mind', false);
    questions.cancel();
    expect((questions.holding, speech.cancelled), (false, true));
    speech.result!('never mind', true);
    await questions.release();
    expect(asked(), 0);

    await questions.hold();
    speech.result!('late question', false);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await questions.release();
    expect(asked(), 0);
    expect(questions.question, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
