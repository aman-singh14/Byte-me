// Live captions: turn assembly from Muse Voice Transcribe's events (partial ->
// final), speaker labels, and the session with the relay (start message,
// audio chunks, pause, off, failures). Plus CaptionView and first-run consent.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/captions/caption_transcript.dart';
import 'package:omni_glasses/captions/captions.dart';
import 'package:omni_glasses/components/captions_and_who.dart';
import 'package:omni_glasses/helper/helper_call.dart' show HelperSocket;
import 'package:omni_glasses/screens/captions_widgets.dart';
import 'package:omni_glasses/app.dart';
import 'package:provider/provider.dart';

class FakeCaptionSocket implements HelperSocket {
  final _in = StreamController<String>();
  final texts = <Map<String, dynamic>>[];
  final audio = <Uint8List>[];
  bool closed = false;

  @override
  int? closeCode;

  @override
  Stream<String> get messages => _in.stream;

  @override
  void sendText(String text) {
    final msg = jsonDecode(text) as Map<String, dynamic>;
    texts.add(msg);
    if (msg['type'] == 'endStream') unawaited(drop(1000)); // the relay finishes and closes
  }

  @override
  void sendBytes(Uint8List bytes) => audio.add(bytes);

  @override
  Future<void> close() async {
    closed = true;
    if (!_in.isClosed && _in.hasListener) await _in.close(); // nobody left to tell otherwise
  }

  void server(Map<String, Object> msg) => _in.add(jsonEncode(msg));

  Future<void> drop([int? code]) async {
    closeCode = code;
    if (!_in.isClosed) await _in.close();
  }
}

class FakeCaptionMic implements CaptionMic {
  bool allowed = true;
  StreamController<Uint8List>? live;

  @override
  Future<bool> hasPermission() async => allowed;

  @override
  Future<Stream<Uint8List>> start() async => (live = StreamController<Uint8List>()).stream;

  @override
  Future<void> stop() async {
    await live?.close();
    live = null;
  }
}

/// Captions wired to fakes, for screen tests.
Captions fakeCaptions({List<FakeCaptionSocket>? sockets, FakeCaptionMic? mic, Uri? relay}) => Captions(
  relay: () => relay ?? Uri.parse('ws://laptop.test:8001/ws/captions'),
  mic: mic ?? FakeCaptionMic(),
  connect: (url) async {
    final s = FakeCaptionSocket();
    sockets?.add(s);
    return s;
  },
);

void main() {
  group('CaptionTranscript', () {
    test('partials replace each other, then the final text replaces them', () {
      final t = CaptionTranscript()..startSession();
      t.apply({'type': 'speechStart', 'turnId': 1});
      t.apply({'type': 'transcript', 'transcript': 'are you', 'final': false});
      t.apply({'type': 'transcript', 'transcript': 'are you coming', 'final': false}); // cumulative
      expect([for (final l in t.lines) (l.text, l.isFinal)], [('are you coming', false)]);
      t.apply({'type': 'speechEnd', 'turnId': 1});
      t.apply({'type': 'speechComplete', 'turnId': 1, 'transcript': ' Are you coming?'}); // as Meta sends it
      expect([for (final l in t.lines) (l.text, l.isFinal)], [('Are you coming?', true)]);
    });

    test('overlapping turns are kept apart by turn id', () {
      final t = CaptionTranscript()..startSession();
      t.apply({'type': 'speechStart', 'turnId': 1});
      t.apply({'type': 'transcript', 'transcript': 'first', 'final': false});
      t.apply({'type': 'speechStart', 'turnId': 2});
      t.apply({'type': 'transcript', 'transcript': 'second', 'final': false});
      t.apply({'type': 'speechComplete', 'turnId': 1, 'transcript': 'First.'});
      t.apply({'type': 'speechComplete', 'turnId': 2, 'transcript': 'Second.'});
      expect([for (final l in t.lines) l.text], ['First.', 'Second.']);
    });

    test('speaker labels become Speaker 1, Speaker 2 in order of appearance', () {
      final t = CaptionTranscript()..startSession();
      for (final (id, label, text) in [(1, 'B', 'Hi.'), (2, 'A', 'Hello.'), (3, 'B', 'How are you?')]) {
        t.apply({'type': 'speechStart', 'turnId': id});
        t.apply({'type': 'transcript', 'transcript': text, 'final': false});
        t.apply({'type': 'speaker', 'label': label});
        t.apply({'type': 'speechComplete', 'turnId': id, 'transcript': text});
      }
      expect([for (final l in t.lines) l.speaker], ['Speaker 1', 'Speaker 2', 'Speaker 1']);
    });

    test('a new session keeps the text; labels and turn ids start over', () {
      final t = CaptionTranscript()..startSession();
      t.apply({'type': 'speechStart', 'turnId': 1});
      t.apply({'type': 'speaker', 'label': 'A'});
      t.apply({'type': 'transcript', 'transcript': 'cut off mid', 'final': false});
      t.startSession(); // reconnect: the old open turn keeps its last words
      t.apply({'type': 'speechStart', 'turnId': 1});
      t.apply({'type': 'speaker', 'label': 'A'}); // "A" in a new session may be someone else
      t.apply({'type': 'speechComplete', 'turnId': 1, 'transcript': 'New session.'});
      expect([for (final l in t.lines) (l.text, l.isFinal, l.speaker)], [
        ('cut off mid', true, 'Speaker 1'),
        ('New session.', true, 'Speaker 2'),
      ]);
    });

    test('turns with no words disappear; unknown events are ignored', () {
      final t = CaptionTranscript()..startSession();
      t.apply({'type': 'speechStart', 'turnId': 1});
      expect(t.apply({'type': 'audioProgress', 'audioProcessedMs': 900}), isFalse);
      expect(t.apply({'type': 'somethingNew'}), isFalse);
      t.apply({'type': 'speechComplete', 'turnId': 1, 'transcript': ''});
      expect(t.lines, isEmpty);
    });
  });

  group('Captions', () {
    late List<FakeCaptionSocket> sockets;
    late FakeCaptionMic mic;
    late Captions captions;

    setUp(() {
      sockets = [];
      mic = FakeCaptionMic();
      captions = fakeCaptions(sockets: sockets, mic: mic);
    });

    tearDown(() => captions.dispose());

    Future<FakeCaptionSocket> goLive() async {
      await captions.turnOn();
      final s = sockets.last;
      s.server({'type': 'ready', 'sessionId': 's1', 'source': 'meta'});
      await pumpEventQueue();
      return s;
    }

    test('asks for diarized 16 kHz captions, then streams the mic in 100 ms pieces', () async {
      final s = await goLive();
      expect(s.texts.first, {'type': 'start', 'audioEncoding': 'PCM_16KHZ', 'mode': 'DIARIZATION'});
      expect(captions.state, CaptionsState.live);
      for (var i = 0; i < 5; i++) {
        mic.live!.add(Uint8List(1280)); // 40 ms each
      }
      await pumpEventQueue();
      expect(s.audio.map((a) => a.length), [3840]); // 120 ms batched; the rest waits for more
    });

    test('caption events become lines', () async {
      final s = await goLive();
      s.server({'type': 'speechStart', 'turnId': 1});
      s.server({'type': 'transcript', 'transcript': 'hello there', 'final': false});
      await pumpEventQueue();
      expect(captions.transcript.lines.single.text, 'hello there');
      s.server({'type': 'speaker', 'label': 'A'});
      s.server({'type': 'speechComplete', 'turnId': 1, 'transcript': 'Hello there.'});
      await pumpEventQueue();
      final line = captions.transcript.lines.single;
      expect((line.text, line.isFinal, line.speaker), ('Hello there.', true, 'Speaker 1'));
    });

    test('without speaker labels it asks for the faster ENDPOINTING mode', () async {
      captions.setSpeakerLabels(false);
      final s = await goLive();
      expect(s.texts.first['mode'], 'ENDPOINTING');
    });

    test('pause ends the stream but keeps the text; off throws it away', () async {
      final s = await goLive();
      s.server({'type': 'speechStart', 'turnId': 1});
      s.server({'type': 'transcript', 'transcript': 'one two', 'final': false});
      await pumpEventQueue();
      await captions.pause();
      expect(s.texts.last, {'type': 'endStream'});
      expect(mic.live, isNull); // the mic is off
      expect((captions.state, captions.transcript.lines.single.text), (CaptionsState.paused, 'one two'));

      await captions.resume();
      expect(sockets, hasLength(2));
      await captions.turnOff();
      expect(captions.state, CaptionsState.off);
      expect(captions.transcript.lines, isEmpty);
      expect(sockets.last.closed, isTrue);
    });

    test('a dropped connection or a refusal says so', () async {
      final s = await goLive();
      s.server({'type': 'error', 'message': "Captions aren't set up on this server (no Meta API key)"});
      await s.drop(4503);
      await pumpEventQueue();
      expect(captions.state, CaptionsState.failed);
      expect(captions.message, contains('no Meta API key'));
      expect(mic.live, isNull);
    });

    test('no laptop address, or no microphone permission', () async {
      final none = Captions(relay: () => null, mic: mic, connect: (_) async => FakeCaptionSocket());
      await none.turnOn();
      expect(none.state, CaptionsState.failed);
      expect(none.message, contains('laptop address'));
      none.dispose();
      mic.allowed = false;
      await captions.turnOn();
      expect(captions.message, contains('microphone'));
      expect(sockets, isEmpty);
    });
  });

  group('screens', () {
    Future<Captions> pump(WidgetTester tester, Widget child) async {
      final captions = fakeCaptions();
      addTearDown(captions.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: captions,
          child: MaterialApp(
            theme: omniLightTheme,
            home: Scaffold(body: ListView(children: [child])),
          ),
        ),
      );
      return captions;
    }

    testWidgets('a speaker label only where the speaker changes; partial text is italic', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: omniLightTheme,
          home: Scaffold(
            body: CaptionView(
              fontSize: 28,
              onFontSizeChanged: (_) {},
              turns: const [
                CaptionTurn(id: 1, speaker: 'Speaker 1', text: 'Are you coming?'),
                CaptionTurn(id: 2, speaker: 'Speaker 1', text: 'It starts at three.'),
                CaptionTurn(id: 3, speaker: 'Speaker 2', text: 'yes after my', isFinal: false),
              ],
            ),
          ),
        ),
      );
      expect(find.text('Speaker 1'), findsOneWidget);
      expect(find.text('Speaker 2'), findsOneWidget);
      final partial = tester.widget<Text>(find.text('yes after my'));
      expect(partial.style?.fontStyle, FontStyle.italic);
      expect(tester.widget<Text>(find.text('Are you coming?')).style?.fontStyle, isNot(FontStyle.italic));
    });

    testWidgets('the first time, captions explain themselves and wait for a yes', (tester) async {
      final captions = await pump(tester, const CaptionsCard());
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Turn on live captions?'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(captions.on, isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Turn on'));
      await tester.pumpAndSettle();
      expect((captions.consented, captions.on), (true, true));
      expect(find.text('Captions on · audio sent to Meta for transcription'), findsOneWidget);
      // Cancelling a stream subscription under widget-test fake time and then
      // pumping hangs this Flutter version, so stop in the real zone.
      await tester.runAsync(captions.turnOff);
      expect(captions.on, isFalse);
    });
  });
}
