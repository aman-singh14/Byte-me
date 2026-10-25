// CaptionView and WhoAroundSheet: the accessibility tools on the Aware tab.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/theme.dart';

class CaptionTurn {
  const CaptionTurn({this.id, this.speaker, required this.text, this.isFinal = true});

  /// Stable per line, so a partial and its final text are the same widget.
  final int? id;

  /// "Speaker 1", never a real identity; null without speaker labels.
  final String? speaker;
  final String text;

  /// Partial text is shown lighter and in italics until the final text replaces it.
  final bool isFinal;
}

/// Live captions: large high-contrast text with clear speaker turns and a
/// font-size slider. Never auto-hides. Follows the newest line unless the
/// reader scrolls up; then "Jump to latest" brings it back. Lines aren't
/// announced one by one (that would talk over everyone); state changes are.
class CaptionView extends StatefulWidget {
  const CaptionView({
    super.key,
    required this.turns,
    required this.fontSize,
    required this.onFontSizeChanged,
    this.placeholder = 'Listening…',
    this.height = 320,
  });

  final List<CaptionTurn> turns;

  /// Caption size in sp, 20..48. The system text size still applies on top.
  final double fontSize;
  final ValueChanged<double> onFontSizeChanged;

  /// Shown while there are no lines yet.
  final String placeholder;

  /// Height of the scrolling caption area; null sizes the box to its lines
  /// (no scrolling of its own, for short previews).
  final double? height;

  @override
  State<CaptionView> createState() => _CaptionViewState();
}

class _CaptionViewState extends State<CaptionView> {
  final _scroll = ScrollController();
  bool _follow = true;

  @override
  void didUpdateWidget(CaptionView old) {
    super.didUpdateWidget(old);
    if (_follow) WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
  }

  void _toEnd() {
    // Jump, never animate: calm, and fine under reduce motion.
    if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  bool _onScroll(ScrollNotification n) {
    if (n is ScrollUpdateNotification && n.dragDetails != null) {
      final atEnd = n.metrics.pixels >= n.metrics.maxScrollExtent - 24;
      if (atEnd != _follow) setState(() => _follow = atEnd);
    }
    return false;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final space = context.space;
    final turns = widget.turns;
    // Inverted for maximum contrast: dark box in light theme, light box in dark.
    final fg = c.background;
    final textStyle = context.type.captionView.copyWith(fontSize: widget.fontSize, color: fg);
    final partialStyle = textStyle.copyWith(color: fg.withValues(alpha: 0.72), fontStyle: FontStyle.italic);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          label: 'Live captions',
          child: Container(
            height: widget.height,
            decoration: BoxDecoration(color: c.textPrimary, borderRadius: context.radii.cardRadius),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: _onScroll,
                  child: ListView(
                    controller: _scroll,
                    shrinkWrap: widget.height == null,
                    physics: widget.height == null ? const NeverScrollableScrollPhysics() : null,
                    padding: EdgeInsets.all(space.l),
                    children: [
                      if (turns.isEmpty) Text(widget.placeholder, style: partialStyle),
                      for (var i = 0; i < turns.length; i++)
                        _Turn(
                          key: ValueKey(turns[i].id ?? i),
                          turn: turns[i],
                          // A label only where the speaker changes.
                          showSpeaker: turns[i].speaker != null && (i == 0 || turns[i - 1].speaker != turns[i].speaker),
                          divider: i > 0,
                          style: turns[i].isFinal ? textStyle : partialStyle,
                          fg: fg,
                        ),
                    ],
                  ),
                ),
                if (!_follow)
                  Positioned(
                    right: space.s,
                    bottom: space.s,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () {
                        setState(() => _follow = true);
                        _toEnd();
                      },
                      icon: const Icon(Symbols.arrow_downward_rounded),
                      label: const Text('Jump to latest'),
                    ),
                  ),
              ],
            ),
          ),
        ),
        SizedBox(height: space.s),
        Row(
          children: [
            Icon(Symbols.format_size_rounded, color: c.textSecondary),
            SizedBox(width: space.s),
            Expanded(child: Text('Caption size ${widget.fontSize.round()}', style: context.type.label)),
          ],
        ),
        Slider.adaptive(
          value: widget.fontSize.clamp(OmniType.captionViewMin, OmniType.captionViewMax),
          min: OmniType.captionViewMin,
          max: OmniType.captionViewMax,
          divisions: 7,
          label: widget.fontSize.round().toString(),
          semanticFormatterCallback: (v) => '${v.round()} point captions',
          onChanged: widget.onFontSizeChanged,
        ),
      ],
    );
  }
}

class _Turn extends StatelessWidget {
  const _Turn({
    super.key,
    required this.turn,
    required this.showSpeaker,
    required this.divider,
    required this.style,
    required this.fg,
  });

  final CaptionTurn turn;
  final bool showSpeaker, divider;
  final TextStyle style;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final space = context.space;
    return Semantics(
      label: '${turn.speaker == null ? '' : '${turn.speaker}: '}${turn.text}${turn.isFinal ? '' : ' (still listening)'}',
      child: ExcludeSemantics(
        child: Container(
          margin: EdgeInsets.only(top: divider ? space.m : 0),
          padding: EdgeInsets.only(top: divider ? space.m : 0),
          decoration: BoxDecoration(
            border: divider ? Border(top: BorderSide(color: fg.withValues(alpha: 0.3))) : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showSpeaker) Text(turn.speaker!, style: context.type.label.copyWith(color: fg)),
              Text(turn.text, style: style),
            ],
          ),
        ),
      ),
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
