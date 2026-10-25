// Muse speed check: times real VLM requests (p50 / p90) so we know how fast
// snapshot features are on this network. Times stay in memory; images and
// answers aren't kept.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../assist/vlm.dart';
import '../components/common.dart';
import '../settings/feature_flags.dart';
import '../theme/theme.dart';
import '../vision/rear_vision.dart';

class VlmDebugScreen extends StatefulWidget {
  const VlmDebugScreen({super.key});

  @override
  State<VlmDebugScreen> createState() => _VlmDebugScreenState();
}

class _VlmDebugScreenState extends State<VlmDebugScreen> {
  String? _result;
  bool _running = false;

  Future<void> _test({required bool front}) async {
    final vlm = context.read<VlmService>();
    final rear = context.read<RearVision>().camera?.frame.value;
    if (!front && rear == null) {
      setState(() => _result = 'No rear camera picture yet.');
      return;
    }
    setState(() => _running = true);
    final watch = Stopwatch()..start();
    String result;
    try {
      final answer = await vlm.ask(
        VlmFeature.describe,
        images: front ? const [] : [VlmImage.rear(rear!)],
        useFront: front,
      );
      result = '${answer['summary']} (${watch.elapsedMilliseconds} ms)';
    } on VlmUnavailable catch (e) {
      result = '${e.message} (${watch.elapsedMilliseconds} ms)';
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _result = result;
    });
    announce(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final vlm = context.watch<VlmService>();
    final flags = context.watch<FeatureFlags>();
    final space = context.space;
    String ms(Duration? d) => d == null ? '-' : '${d.inMilliseconds} ms';
    return Scaffold(
      appBar: AppBar(title: const Text('Muse speed check')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(space.page, space.m, space.page, space.xl),
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(Feature.vlmMock.title),
            subtitle: Text(Feature.vlmMock.blurb),
            value: flags[Feature.vlmMock],
            onChanged: (on) => flags.set(Feature.vlmMock, on),
          ),
          SizedBox(height: space.m),
          FilledButton.icon(
            style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(56))),
            onPressed: _running ? null : () => _test(front: false),
            icon: const Icon(Symbols.history_rounded),
            label: const Text('Test with the rear camera'),
          ),
          SizedBox(height: space.s),
          FilledButton.tonalIcon(
            style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(56))),
            onPressed: _running ? null : () => _test(front: true),
            icon: const Icon(Symbols.visibility_rounded),
            label: const Text("Test with the laptop's front camera"),
          ),
          if (_running || _result != null) ...[
            SizedBox(height: space.m),
            Semantics(liveRegion: true, child: Text(_running ? 'Asking Muse…' : _result!, style: context.type.body)),
          ],
          SizedBox(height: space.l),
          for (final f in VlmFeature.values)
            Builder(
              builder: (context) {
                final s = vlm.stats[f]!;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(f.title, style: context.type.label),
                  subtitle: Text(
                    '${s.count} answered · ${s.failures} failed · p50 ${ms(s.percentile(0.5))} · '
                    'p90 ${ms(s.percentile(0.9))} · last ${ms(s.latencies.lastOrNull)}',
                    style: context.type.body,
                  ),
                );
              },
            ),
          TextButton(onPressed: vlm.clearStats, child: const Text('Clear times')),
          Text(
            'Times include the trip to the laptop. Timeout: ${VlmFeature.describe.timeout.inSeconds} s per request.',
            style: context.type.caption.copyWith(color: context.colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
