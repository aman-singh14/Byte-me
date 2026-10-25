// The shared VLM service: timeouts fall back, calls are rate limited and
// shared while running, mock mode needs no network, and latency is measured.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/assist/vlm.dart';
import 'package:omni_glasses/net/backend_api.dart';
import 'package:omni_glasses/settings/feature_flags.dart';

void main() {
  late List<String> calls;
  late Future<Map<String, dynamic>> Function() reply;
  late DateTime now;

  VlmService service({FeatureFlags? flags, Duration minInterval = const Duration(seconds: 2)}) => VlmService(
    flags: flags ?? FeatureFlags(),
    clock: () => now,
    minInterval: minInterval,
    call: (feature, {images = const [], useFront = false, question, timeout}) {
      calls.add('$feature ${[for (final i in images) i.$1]} front=$useFront${question == null ? '' : ' "$question"'}');
      return reply();
    },
  );

  setUp(() {
    calls = [];
    reply = () async => {'summary': 'A desk.'};
    now = DateTime(2026, 10, 24, 12);
  });

  test('sends the snapshots and returns the JSON', () async {
    final vlm = service();
    final answer = await vlm.ask(VlmFeature.describe, images: const [VlmImage.rear([1, 2])], useFront: true);
    expect(answer, {'summary': 'A desk.'});
    expect(calls, ['describe [rear] front=true']);
    expect(vlm.stats[VlmFeature.describe]!.count, 1);
  });

  testWidgets('a slow answer times out after 4 s and counts as a failure', (tester) async {
    reply = () => Completer<Map<String, dynamic>>().future; // never answers
    final vlm = service();
    Object? error;
    unawaited(vlm.ask(VlmFeature.socialConfirm).then<void>((_) {}, onError: (Object e) => error = e));
    await tester.pump(const Duration(milliseconds: 3900));
    expect(error, isNull);
    await tester.pump(const Duration(milliseconds: 200));
    expect(error, isA<VlmUnavailable>());
    expect(vlm.stats[VlmFeature.socialConfirm]!.failures, 1);
  });

  test('backend errors become VlmUnavailable with a readable message', () async {
    reply = () async => throw const BackendException('no Muse API key (set MUSE_API_KEY in .env)');
    await expectLater(
      service().ask(VlmFeature.describe),
      throwsA(isA<VlmUnavailable>().having((e) => e.message, 'message', contains('MUSE_API_KEY'))),
    );
  });

  test('one call at a time per feature, and not too often', () async {
    final gate = Completer<Map<String, dynamic>>();
    reply = () => gate.future;
    final vlm = service();
    final a = vlm.ask(VlmFeature.describe), b = vlm.ask(VlmFeature.describe);
    gate.complete({'summary': 'x'});
    expect(await a, await b);
    expect(calls, hasLength(1)); // the second shared the first
    now = now.add(const Duration(seconds: 1));
    await expectLater(vlm.ask(VlmFeature.describe), throwsA(isA<VlmUnavailable>()));
    now = now.add(const Duration(seconds: 2));
    reply = () async => {'summary': 'y'};
    expect(await vlm.ask(VlmFeature.describe), {'summary': 'y'});
  });

  test('mock mode answers without the network', () async {
    final flags = FeatureFlags(initial: {Feature.vlmMock: true});
    final vlm = service(flags: flags);
    expect(await vlm.ask(VlmFeature.socialConfirm), {'engaging': true, 'action': 'waving'});
    expect(calls, isEmpty);
  });

  test('p50 and p90', () {
    final s = VlmStats();
    expect(s.percentile(0.5), isNull);
    for (final ms in [900, 100, 500, 300, 700, 200, 800, 400, 600, 1000]) {
      s.add(Duration(milliseconds: ms));
    }
    expect(s.percentile(0.5), const Duration(milliseconds: 500));
    expect(s.percentile(0.9), const Duration(milliseconds: 900));
  });
}
