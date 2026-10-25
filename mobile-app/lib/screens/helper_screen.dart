// Call a helper: one big button that opens a call and shares the link, then
// the call's status, the camera the helper sees, and End. Built for VoiceOver
// and TalkBack: every state is announced, buttons are large and labeled.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../alerts/voice.dart';
import '../components/common.dart';
import '../helper/helper_call.dart';
import '../net/protocol.dart';
import '../theme/theme.dart';

void openHelperScreen(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HelperScreen()));

/// Opens the share sheet with the helper's link.
Future<void> shareHelperLink(BuildContext context, String url) {
  final box = context.findRenderObject() as RenderBox?;
  return SharePlus.instance.share(
    ShareParams(
      text: 'Can you help me see? Open this link to join my glasses (no app needed): $url',
      subject: 'Help me see',
      // iPad shows the sheet as a popover from here.
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}

/// Starts a call and shares the link.
Future<void> startHelperCall(BuildContext context) async {
  final call = context.read<HelperCall>();
  final messenger = ScaffoldMessenger.of(context);
  final error = await call.start();
  if (error != null) {
    messenger.showSnackBar(SnackBar(content: Text(error)));
    return;
  }
  if (context.mounted && call.helperUrl != null) await shareHelperLink(context, call.helperUrl!);
}

class HelperScreen extends StatelessWidget {
  const HelperScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final call = context.watch<HelperCall>();
    final space = context.space;
    return Scaffold(
      appBar: AppBar(title: Semantics(header: true, child: const Text('Call a helper'))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(space.page, space.m, space.page, space.xl),
        children: [
          switch (call.state) {
            HelperState.idle || HelperState.ended || HelperState.failed => const _StartPanel(),
            HelperState.starting => const _Busy('Starting the call…'),
            HelperState.waiting => const _WaitingPanel(),
            HelperState.live => const _LivePanel(),
          },
        ],
      ),
    );
  }
}

class _StartPanel extends StatelessWidget {
  const _StartPanel();

  @override
  Widget build(BuildContext context) {
    final call = context.watch<HelperCall>();
    final space = context.space;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'A friend, family member or guide sees through your glasses, talks with you, '
          'and guides you with buzzes: left, right, forward, stop.',
          style: context.type.body,
        ),
        SizedBox(height: space.s),
        Text(
          "You send them a link. They open it in any browser. Nothing is recorded.",
          style: context.type.body.copyWith(color: context.colors.textSecondary),
        ),
        if (call.state == HelperState.ended) ...[
          SizedBox(height: space.m),
          Text('Call ended.', style: context.type.label),
        ],
        if (call.error != null) ...[SizedBox(height: space.m), Text(call.error!, style: context.type.label)],
        SizedBox(height: space.l),
        _BigButton(
          icon: Symbols.support_agent_rounded,
          label: call.state == HelperState.idle ? 'Call a helper' : 'Call again',
          onPressed: () => startHelperCall(context),
        ),
      ],
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: context.space.xl),
    child: Column(
      children: [
        const CircularProgressIndicator(),
        SizedBox(height: context.space.m),
        Text(text, style: context.type.headline),
      ],
    ),
  );
}

class _WaitingPanel extends StatelessWidget {
  const _WaitingPanel();

  @override
  Widget build(BuildContext context) {
    final call = context.watch<HelperCall>();
    final space = context.space;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OmniCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                  SizedBox(width: space.m),
                  Expanded(child: Text('Waiting for helper…', style: context.type.headline)),
                ],
              ),
              SizedBox(height: space.s),
              Text(
                'Send them the link. They open it in any browser; no app needed.',
                style: context.type.body.copyWith(color: context.colors.textSecondary),
              ),
            ],
          ),
        ),
        SizedBox(height: space.l),
        Builder(
          builder: (context) => _BigButton(
            icon: Symbols.share_rounded,
            label: 'Send the link again',
            tonal: true,
            onPressed: () => shareHelperLink(context, call.helperUrl!),
          ),
        ),
        SizedBox(height: space.m),
        const _EndButton(),
      ],
    );
  }
}

class _LivePanel extends StatelessWidget {
  const _LivePanel();

  @override
  Widget build(BuildContext context) {
    final call = context.watch<HelperCall>();
    final c = context.colors;
    final space = context.space;
    final guide = call.lastGuide;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          label: 'Live with helper. They see your ${call.camera.label.toLowerCase()} camera.',
          child: ExcludeSemantics(
            child: Container(
              padding: EdgeInsets.all(space.m),
              decoration: BoxDecoration(color: c.alertUrgent, borderRadius: context.radii.cardRadius),
              child: Row(
                children: [
                  Icon(Symbols.radio_button_checked_rounded, color: c.onAlertUrgent, fill: 1),
                  SizedBox(width: space.s),
                  Expanded(
                    child: Text('LIVE with helper', style: context.type.headline.copyWith(color: c.onAlertUrgent)),
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(height: space.l),
        const _AudioRow(),
        SizedBox(height: space.l),
        Text('Camera they see', style: context.type.label),
        SizedBox(height: space.s),
        if (call.camera == HelperCamera.phone)
          Row(
            children: [
              ExcludeSemantics(child: Icon(Symbols.smartphone_rounded, color: c.textPrimary)),
              SizedBox(width: space.s),
              Expanded(
                child: Text(
                  call.cameraProblem ??
                      "Your phone's camera: no glasses camera is connected. Point your phone where they should look.",
                  style: context.type.body,
                ),
              ),
            ],
          )
        else
          SegmentedButton<HelperCamera>(
            segments: [
              for (final cam in HelperCamera.glasses)
                ButtonSegment(
                  value: cam,
                  label: Text(cam.label),
                  icon: Icon(cam == HelperCamera.front ? Symbols.visibility_rounded : Symbols.history_rounded),
                ),
            ],
            selected: {call.camera},
            onSelectionChanged: (s) => call.selectCamera(s.first),
          ),
        if (guide != null) ...[
          SizedBox(height: space.l),
          Semantics(
            label: 'Last guidance: ${_guideWord(guide)}',
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Icon(_guideIcon(guide), size: 40, color: c.textPrimary),
                  SizedBox(width: space.m),
                  Text(_guideWord(guide), style: context.type.title),
                ],
              ),
            ),
          ),
        ],
        SizedBox(height: space.xl),
        const _EndButton(),
      ],
    );
  }
}

/// Call audio: talking, connecting, or why not; and a big Mute button.
class _AudioRow extends StatelessWidget {
  const _AudioRow();

  @override
  Widget build(BuildContext context) {
    final call = context.watch<HelperCall>();
    final space = context.space;
    final on = call.audioState == HelperAudioState.on;
    final text = switch (call.audioState) {
      HelperAudioState.on => call.muted ? 'Your microphone is muted.' : 'You and your helper can talk.',
      HelperAudioState.connecting => 'Connecting audio…',
      HelperAudioState.off || HelperAudioState.unavailable => call.audioNote ?? 'No call audio.',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Row(
            children: [
              ExcludeSemantics(
                child: Icon(
                  on && !call.muted ? Symbols.mic_rounded : Symbols.mic_off_rounded,
                  color: context.colors.textPrimary,
                ),
              ),
              SizedBox(width: space.s),
              Expanded(child: Text(text, style: context.type.body)),
            ],
          ),
        ),
        if (on) ...[
          SizedBox(height: space.s),
          FilledButton.tonalIcon(
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size.fromHeight(56)),
              textStyle: WidgetStatePropertyAll(context.type.headline),
            ),
            onPressed: () {
              HapticFeedback.selectionClick();
              call.setMuted(!call.muted);
            },
            icon: Icon(call.muted ? Symbols.mic_rounded : Symbols.mic_off_rounded),
            label: Text(call.muted ? 'Unmute' : 'Mute'),
          ),
        ],
      ],
    );
  }
}

String _guideWord(GuideDirection d) => switch (d) {
  GuideDirection.left => 'Left',
  GuideDirection.right => 'Right',
  GuideDirection.forward => 'Forward',
  GuideDirection.stop => 'Stop',
};

IconData _guideIcon(GuideDirection d) => switch (d) {
  GuideDirection.left => Symbols.arrow_back_rounded,
  GuideDirection.right => Symbols.arrow_forward_rounded,
  GuideDirection.forward => Symbols.arrow_upward_rounded,
  GuideDirection.stop => Symbols.front_hand_rounded,
};

class _BigButton extends StatelessWidget {
  const _BigButton({required this.icon, required this.label, required this.onPressed, this.tonal = false});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final bool tonal;

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size.fromHeight(72)),
      textStyle: WidgetStatePropertyAll(context.type.headline),
    );
    final icon = Icon(this.icon, size: 28);
    return tonal
        ? FilledButton.tonalIcon(style: style, onPressed: onPressed, icon: icon, label: Text(label))
        : FilledButton.icon(style: style, onPressed: onPressed, icon: icon, label: Text(label));
  }
}

class _EndButton extends StatelessWidget {
  const _EndButton();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return FilledButton.icon(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.fromHeight(72)),
        backgroundColor: WidgetStatePropertyAll(c.alertUrgent),
        foregroundColor: WidgetStatePropertyAll(c.onAlertUrgent),
        textStyle: WidgetStatePropertyAll(context.type.headline),
      ),
      onPressed: () {
        HapticFeedback.mediumImpact();
        context.read<HelperCall>().end();
      },
      icon: const Icon(Symbols.call_end_rounded, size: 28),
      label: const Text('End call'),
    );
  }
}

/// A card for Aware and Today: "Call a helper", or the live call's status.
class HelperCallCard extends StatelessWidget {
  const HelperCallCard({super.key});

  @override
  Widget build(BuildContext context) {
    final call = context.watch<HelperCall>();
    final status = switch (call.state) {
      HelperState.waiting => 'Waiting for helper…',
      HelperState.live => 'LIVE with helper',
      HelperState.starting => 'Starting…',
      _ => null,
    };
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(icon: Symbols.support_agent_rounded, title: 'Call a helper'),
          SizedBox(height: context.space.s),
          Text(
            status ?? 'Someone you trust sees through your glasses and guides you.',
            style: status != null ? context.type.label : context.type.body,
          ),
          SizedBox(height: context.space.m),
          FilledButton.icon(
            style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size.fromHeight(56))),
            onPressed: () {
              openHelperScreen(context);
              if (!call.active && call.state != HelperState.starting) startHelperCall(context);
            },
            icon: Icon(status == null ? Symbols.support_agent_rounded : Symbols.open_in_full_rounded),
            label: Text(status == null ? 'Call a helper' : 'Open the call'),
          ),
        ],
      ),
    );
  }
}

/// Says when the helper joins or leaves and when the call ends, on any tab:
/// to the screen reader if one is on, otherwise out loud.
class HelperAnnouncer extends StatefulWidget {
  const HelperAnnouncer({super.key, required this.child});
  final Widget child;

  @override
  State<HelperAnnouncer> createState() => _HelperAnnouncerState();
}

class _HelperAnnouncerState extends State<HelperAnnouncer> {
  late final HelperCall _call = context.read<HelperCall>();
  late HelperState _last = _call.state;

  @override
  void initState() {
    super.initState();
    _call.addListener(_changed);
  }

  void _changed() {
    final now = _call.state;
    if (now == _last || !mounted) return;
    final before = _last;
    _last = now;
    final sentence = switch (now) {
      HelperState.waiting when before == HelperState.live => 'Helper left. Waiting for them to come back.',
      HelperState.waiting => 'Waiting for helper.',
      HelperState.live => 'Helper connected.',
      HelperState.ended => 'Call ended.',
      _ => null,
    };
    if (sentence == null) return;
    if (MediaQuery.accessibleNavigationOf(context)) {
      announce(context, sentence);
    } else {
      context.read<Voice?>()?.say(sentence);
    }
  }

  @override
  void dispose() {
    _call.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
