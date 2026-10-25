// Live captions on the Aware tab (full captions) and Today (a quick toggle and
// the newest line). Off by default; the first time, the wearer reads what
// captions send and agrees.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../captions/captions.dart';
import '../components/captions_and_who.dart';
import '../components/common.dart';
import '../theme/theme.dart';

/// Turns captions on or off, asking for consent the first time.
Future<void> setCaptions(BuildContext context, bool on) async {
  final captions = context.read<Captions>();
  if (!on) return captions.turnOff();
  if (!captions.consented) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn on live captions?'),
        content: const Text(
          'While captions are on, your phone sends what its microphone hears to Meta to turn speech into '
          'text. Your laptop passes it on; neither keeps the audio or the text. Captions are cleared when '
          'you turn them off.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Turn on')),
        ],
      ),
    );
    if (ok != true) return;
    captions.acceptConsent();
  }
  await captions.turnOn();
}

String _stateText(Captions c) => switch (c.state) {
  CaptionsState.off => 'Off. Turn on to read what people around you say.',
  CaptionsState.connecting => 'Connecting…',
  CaptionsState.live => c.source == 'mock' ? 'Live (mock captions)' : 'Live',
  CaptionsState.paused => 'Paused',
  CaptionsState.failed => c.message ?? 'Captions stopped.',
};

/// The Aware tab's captions: toggle, privacy line, captions, Pause and Clear.
class CaptionsCard extends StatefulWidget {
  const CaptionsCard({super.key});

  @override
  State<CaptionsCard> createState() => _CaptionsCardState();
}

class _CaptionsCardState extends State<CaptionsCard> {
  late final Captions _captions = context.read<Captions>();
  late CaptionsState _last = _captions.state;

  @override
  void initState() {
    super.initState();
    _captions.addListener(_announce);
  }

  // State changes only, never each caption line.
  void _announce() {
    final now = _captions.state;
    if (now == _last || !mounted) return;
    _last = now;
    if (now != CaptionsState.connecting) announce(context, 'Captions: ${_stateText(_captions)}');
  }

  @override
  void dispose() {
    _captions.removeListener(_announce);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final captions = context.watch<Captions>();
    final space = context.space;
    final on = captions.on;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const CardTitle(icon: Symbols.closed_caption_rounded, title: 'Live captions'),
            value: on,
            onChanged: (v) => setCaptions(context, v),
          ),
          Text(_stateText(captions), style: context.type.body),
          if (on) ...[
            SizedBox(height: space.s),
            const CaptionsPrivacyLine(),
            SizedBox(height: space.m),
            CaptionView(
              turns: [
                for (final l in captions.transcript.lines)
                  CaptionTurn(id: l.id, speaker: l.speaker, text: l.text, isFinal: l.isFinal),
              ],
              fontSize: captions.fontSize,
              onFontSizeChanged: captions.setFontSize,
              placeholder: captions.state == CaptionsState.live ? 'Listening…' : 'No captions yet.',
              height: MediaQuery.sizeOf(context).height * 0.45,
            ),
            SizedBox(height: space.s),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(56))),
                    onPressed: switch (captions.state) {
                      CaptionsState.live || CaptionsState.connecting => captions.pause,
                      CaptionsState.paused || CaptionsState.failed => captions.resume,
                      CaptionsState.off => null,
                    },
                    icon: Icon(captions.state == CaptionsState.live ? Symbols.pause_rounded : Symbols.play_arrow_rounded),
                    label: Text(captions.state == CaptionsState.live || captions.state == CaptionsState.connecting
                        ? 'Pause'
                        : 'Resume'),
                  ),
                ),
                SizedBox(width: space.s),
                Expanded(
                  child: OutlinedButton.icon(
                    style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(56))),
                    onPressed: captions.transcript.lines.isEmpty ? null : captions.clear,
                    icon: const Icon(Symbols.clear_all_rounded),
                    label: const Text('Clear'),
                  ),
                ),
              ],
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Speaker labels'),
              subtitle: const Text('"Speaker 1", "Speaker 2". Final text comes a little slower. From the next start.'),
              value: captions.speakerLabels,
              onChanged: captions.setSpeakerLabels,
            ),
          ],
        ],
      ),
    );
  }
}

/// "Captions on · audio sent to Meta for transcription", shown while they're on.
class CaptionsPrivacyLine extends StatelessWidget {
  const CaptionsPrivacyLine({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        ExcludeSemantics(child: Icon(Symbols.mic_rounded, size: 20, color: c.textSecondary)),
        SizedBox(width: context.space.s),
        Expanded(
          child: Text(
            'Captions on · audio sent to Meta for transcription',
            style: context.type.caption.copyWith(color: c.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// Today: a quick toggle and the newest line.
class CaptionsQuickCard extends StatelessWidget {
  const CaptionsQuickCard({super.key});

  @override
  Widget build(BuildContext context) {
    final captions = context.watch<Captions>();
    final last = captions.transcript.lines.lastOrNull;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const CardTitle(icon: Symbols.closed_caption_rounded, title: 'Captions'),
            subtitle: captions.on ? null : const Text('Full captions are on the Aware tab.'),
            value: captions.on,
            onChanged: (v) => setCaptions(context, v),
          ),
          if (captions.on) ...[
            const CaptionsPrivacyLine(),
            SizedBox(height: context.space.s),
            Text(
              last == null ? _stateText(captions) : '${last.speaker == null ? '' : '${last.speaker}: '}${last.text}',
              style: context.type.title,
            ),
          ],
        ],
      ),
    );
  }
}
