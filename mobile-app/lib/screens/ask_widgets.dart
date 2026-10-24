// "What am I looking at?": asks the laptop backend to look through the FRONT camera.
// The backend crops to the chosen side, names objects with YOLO (spoken at once on the
// laptop) and asks Muse for a fuller description, which this card shows and speaks.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../alerts/voice.dart';
import '../components/common.dart';
import '../net/backend_api.dart';
import '../net/backend_models.dart';
import '../theme/theme.dart';
import 'backend_widgets.dart';

/// Where to look: null = where the wearer's eyes point (gaze), else a fixed side.
const _regions = <(String?, String)>[
  (null, "Where I'm looking"),
  ('left', 'Left'),
  ('center', 'Ahead'),
  ('right', 'Right'),
  ('all', 'Everything'),
];

class AskCard extends StatefulWidget {
  const AskCard({super.key});

  @override
  State<AskCard> createState() => _AskCardState();
}

class _AskCardState extends State<AskCard> {
  final _question = TextEditingController();
  String? _region;
  bool _busy = false;
  LookResult? _result;
  String? _error;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  Voice? _voice() {
    try {
      return context.read<Voice?>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _ask() async {
    final link = readBackend(context);
    if (link == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    announce(context, 'Looking.');
    try {
      final q = _question.text.trim();
      final r = await link.look(question: q.isEmpty ? null : q, region: _region);
      if (!mounted) return;
      setState(() => _result = r);
      await _voice()?.say(r.spoken, interrupt: true);
    } on BackendException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = watchBackend(context);
    final space = context.space;
    final c = context.colors;
    final problem = backendProblem(link);
    final r = _result;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(icon: Symbols.center_focus_strong_rounded, title: 'What am I looking at?'),
          SizedBox(height: space.s),
          const NoteText('Uses the front camera. A quick answer comes first, then a fuller description.'),
          SizedBox(height: space.m),
          Wrap(
            spacing: space.s,
            runSpacing: space.s,
            children: [
              for (final (value, label) in _regions)
                ChoiceChip(
                  label: Text(label),
                  selected: _region == value,
                  onSelected: _busy ? null : (_) => setState(() => _region = value),
                ),
            ],
          ),
          SizedBox(height: space.m),
          TextField(
            controller: _question,
            enabled: !_busy,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _busy || problem != null ? null : _ask(),
            decoration: const InputDecoration(
              labelText: 'Ask something (optional)',
              hintText: 'Is there a door on my right?',
              border: OutlineInputBorder(),
            ),
          ),
          SizedBox(height: space.m),
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            icon: _busy
                ? SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2, color: c.onBrand))
                : const Icon(Symbols.visibility_rounded),
            label: Text(_busy ? 'Looking…' : 'What am I looking at?'),
            onPressed: _busy || problem != null ? null : _ask,
          ),
          if (problem != null) ...[SizedBox(height: space.s), NoteText(problem)],
          if (_error != null) ...[SizedBox(height: space.m), Text(_error!, style: context.type.body)],
          if (r != null) ...[
            SizedBox(height: space.l),
            Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (r.museAnswer != null) ...[
                    Text('Description', style: context.type.label),
                    SizedBox(height: space.xs),
                    Text(r.museAnswer!, style: context.type.body),
                    SizedBox(height: space.m),
                  ],
                  if (r.localAnswer != null) ...[
                    Text('Quick answer', style: context.type.label),
                    SizedBox(height: space.xs),
                    Text(r.localAnswer!, style: context.type.body),
                  ],
                  if (r.museError != null) ...[
                    SizedBox(height: space.s),
                    NoteText('No fuller description: ${r.museError}.'),
                  ],
                  SizedBox(height: space.s),
                  NoteText(
                    'Looked ${_where(r.region)}'
                    '${r.seconds != null ? ' · ${r.seconds!.toStringAsFixed(1)} s' : ''}.',
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _where(String region) => switch (region) {
    'left' => 'left',
    'right' => 'right',
    'all' => 'at everything in view',
    _ => 'ahead',
  };
}
