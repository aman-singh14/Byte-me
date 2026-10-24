// CaptionView and WhoAroundSheet: the accessibility tools on the Aware tab.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/theme.dart';

class CaptionTurn {
  const CaptionTurn({required this.speaker, required this.text});
  final String speaker; // "Speaker 1", never a real identity
  final String text;
}

/// Live captions: large high-contrast text with clear speaker turns and a
/// font-size slider. Never auto-hides.
class CaptionView extends StatelessWidget {
  const CaptionView({super.key, required this.turns, required this.fontSize, required this.onFontSizeChanged});

  final List<CaptionTurn> turns;

  /// Caption size in sp, 20..48. The system text size still applies on top.
  final double fontSize;
  final ValueChanged<double> onFontSizeChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final space = context.space;
    // Inverted for maximum contrast: dark box in light theme, light box in dark.
    final fg = c.background;
    final textStyle = context.type.captionView.copyWith(fontSize: fontSize, color: fg);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(color: c.textPrimary, borderRadius: context.radii.cardRadius),
          padding: EdgeInsets.all(space.l),
          child: turns.isEmpty
              ? Text('Listening…', style: textStyle)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < turns.length; i++)
                      Semantics(
                        liveRegion: i == turns.length - 1,
                        child: Padding(
                          padding: EdgeInsets.only(bottom: i == turns.length - 1 ? 0 : space.m),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(turns[i].speaker, style: context.type.label.copyWith(color: fg)),
                              Text(turns[i].text, style: textStyle),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        SizedBox(height: space.s),
        Row(
          children: [
            Icon(Symbols.format_size_rounded, color: c.textSecondary),
            SizedBox(width: space.s),
            Expanded(child: Text('Caption size ${fontSize.round()}', style: context.type.label)),
          ],
        ),
        Slider.adaptive(
          value: fontSize.clamp(OmniType.captionViewMin, OmniType.captionViewMax),
          min: OmniType.captionViewMin,
          max: OmniType.captionViewMax,
          divisions: 7,
          label: fontSize.round().toString(),
          semanticFormatterCallback: (v) => '${v.round()} point captions',
          onChanged: onFontSizeChanged,
        ),
      ],
    );
  }
}

enum WhoAroundState { idle, loading, result, error }

/// "Who's around me?": one big button. The result is shown as large text and
/// read aloud automatically.
class WhoAroundSheet extends StatelessWidget {
  const WhoAroundSheet({super.key, required this.state, this.result, required this.onAsk});

  final WhoAroundState state;

  /// The description, or the error message when [state] is error.
  final String? result;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final space = context.space;
    final busy = state == WhoAroundState.loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          onPressed: busy ? null : onAsk,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(72), textStyle: context.type.headline),
          icon: const Icon(Symbols.groups_rounded, size: 32),
          label: Text(state == WhoAroundState.idle ? "Who's around me?" : 'Ask again'),
        ),
        SizedBox(height: space.l),
        if (busy)
          Semantics(
            liveRegion: true,
            label: 'Looking around',
            child: Row(
              children: [
                const SizedBox.square(dimension: 24, child: CircularProgressIndicator.adaptive()),
                SizedBox(width: space.m),
                Expanded(
                  child: ExcludeSemantics(child: Text('Looking around…', style: context.type.body)),
                ),
              ],
            ),
          ),
        if ((state == WhoAroundState.result || state == WhoAroundState.error) && result != null)
          Semantics(liveRegion: true, child: Text(result!, style: context.type.title)),
        SizedBox(height: space.l),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Symbols.lock_rounded, size: 20, color: c.textSecondary),
            SizedBox(width: space.s),
            Expanded(
              child: Text(
                'Sends 1 photo to describe what people are doing. Not saved. No names or faces.',
                style: context.type.caption.copyWith(color: c.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
