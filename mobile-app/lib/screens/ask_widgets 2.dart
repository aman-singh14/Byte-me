// Spoken questions use the inward-facing camera's gaze to select the front view.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../assist/voice_questions.dart';
import '../components/common.dart';
import '../theme/theme.dart';
import 'backend_widgets.dart';

class AskCard extends StatelessWidget {
  const AskCard({super.key});

  @override
  Widget build(BuildContext context) {
    final questions = context.watch<VoiceQuestions?>();
    final backend = watchBackend(context);
    final problem = backendProblem(backend);
    final space = context.space;
    final answer = questions?.answer;
    final holding = questions?.holding == true;
    final busy = questions?.busy == true;
    final status = problem != null
        ? 'Connect your laptop to ask a question.'
        : busy
        ? 'Answering…'
        : holding
        ? 'Listening…'
        : 'Hold the button and ask anything out loud.';
    final prompt = holding ? questions?.transcript : questions?.question;
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(icon: Symbols.mic_rounded, title: 'Ask your glasses'),
          SizedBox(height: space.s),
          Text(status, style: context.type.body),
          if (prompt != null && prompt.isNotEmpty) ...[
            SizedBox(height: space.m),
            Text('“$prompt”', style: context.type.body),
          ],
          if (questions?.error != null) ...[
            SizedBox(height: space.m),
            Semantics(liveRegion: true, child: Text(questions!.error!, style: context.type.body)),
          ],
          SizedBox(height: space.m),
          HoldToAskButton(questions: questions, enabled: questions != null && problem == null && !busy),
          if (answer != null) ...[
            SizedBox(height: space.l),
            Text('Answer', style: context.type.label),
            Text(answer.spoken, style: context.type.body),
          ],
        ],
      ),
    );
  }
}

/// Hold to talk, let go to send. A screen reader can't hold, so there a
/// double tap starts listening and a second double tap sends.
class HoldToAskButton extends StatelessWidget {
  const HoldToAskButton({super.key, required this.questions, required this.enabled});

  final VoiceQuestions? questions;
  final bool enabled;

  void _down() {
    HapticFeedback.mediumImpact();
    questions!.hold();
  }

  void _up() {
    HapticFeedback.lightImpact();
    questions!.release();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final holding = questions?.holding == true;
    final background = !enabled ? c.surfaceAlt : (holding ? c.alertUrgent : c.brand);
    final foreground = !enabled ? c.textSecondary : (holding ? c.onAlertUrgent : c.onBrand);
    return Semantics(
      button: true,
      enabled: enabled,
      label: holding ? 'Listening. Double tap to send.' : 'Ask your glasses',
      hint: holding ? null : 'Double tap to start listening, then double tap again to send.',
      onTap: enabled ? (holding ? _up : _down) : null,
      child: ExcludeSemantics(
        child: GestureDetector(
          onTapDown: enabled ? (_) => _down() : null,
          onTapUp: enabled ? (_) => _up() : null,
          onTapCancel: enabled ? () => questions!.cancel() : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            constraints: const BoxConstraints(minHeight: 72),
            padding: EdgeInsets.symmetric(horizontal: context.space.l, vertical: context.space.m),
            decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(999)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(holding ? Symbols.graphic_eq_rounded : Symbols.mic_rounded, size: 28, color: foreground, fill: 1),
                SizedBox(width: context.space.s),
                Flexible(
                  child: Text(
                    holding ? 'Listening… let go to send' : 'Hold to ask',
                    textAlign: TextAlign.center,
                    style: context.type.headline.copyWith(color: foreground),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
