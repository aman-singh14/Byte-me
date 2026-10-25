// Widgets that connect the alert components to the live AlertService.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../alerts/alert_engine.dart';
import '../alerts/alert_service.dart';
import '../alerts/voice.dart';
import '../components/alerts.dart';
import '../components/common.dart';
import '../components/event_log.dart';

Direction _direction(Alert a) => Direction.fromWearerSide(a.side);

/// The one word spoken for an alert: "Car". A reflex fire the camera can't
/// name says "Behind". The side comes from which motor on the glasses buzzes.
String spokenWord(Alert a) => a.label == 'something' ? 'Behind' : capitalize(a.label);

/// The current alert, pinned at the top of every tab. Silent: the
/// [AlertAnnouncer] speaks and buzzes once for the whole app.
class LiveAlertBanner extends StatelessWidget {
  const LiveAlertBanner({super.key, this.padding = EdgeInsets.zero});

  /// Around the banner, only while it shows.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AlertService>();
    final alert = service.current;
    if (alert == null) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: AlertBanner(
        key: ValueKey((alert.level, alert.side, alert.label)), // fade in again on change
        level: alert.level,
        label: alert.label,
        direction: _direction(alert),
        onDismiss: service.dismiss,
        announce: false,
      ),
    );
  }
}

/// What a social tap says: "Someone stopped behind you, left. Waving." or,
/// during close-up work, "Look up, someone's here. Behind you, left."
String socialTapSentence(SocialTapped tap) {
  final where = Direction.fromWearerSide(tap.side).phrase;
  if (tap.lookUp) return "Look up, someone's here. ${capitalize(where)}.";
  final action = tap.action?.trim();
  final doing = action == null || action.isEmpty || !_worthSaying(action) ? '' : ' ${capitalize(action)}.';
  return 'Someone stopped $where.$doing';
}

// "standing still" adds nothing to "someone stopped".
bool _worthSaying(String action) => !RegExp(r'^(standing|stopped|still|standing still|a person)$').hasMatch(action.toLowerCase());

/// The last social tap, until dismissed. Teal and friendly, never urgent.
class LiveSocialTapCard extends StatelessWidget {
  const LiveSocialTapCard({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AlertService>();
    final tap = service.socialTap;
    if (tap == null) return const SizedBox.shrink();
    return SocialTapCard(
      key: ObjectKey(tap), // a new tap fades in again
      direction: Direction.fromWearerSide(tap.side),
      customSentence: socialTapSentence(tap),
      onDismiss: service.dismissSocialTap,
      announce: false, // AlertAnnouncer says it once for the whole app
    );
  }
}

/// The "possibly following" notice, until dismissed.
class LiveFollowingCard extends StatelessWidget {
  const LiveFollowingCard({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AlertService>();
    final notice = service.following;
    if (notice == null) return const SizedBox.shrink();
    return FollowingCard(notice: notice, onDismiss: service.dismissFollowing);
  }
}

/// Speaks, announces and buzzes alerts once for the whole app, whichever tab
/// is open. With a screen reader on, the reader says the full sentence and
/// text-to-speech stays quiet so they don't talk over each other.
class AlertAnnouncer extends StatefulWidget {
  const AlertAnnouncer({super.key, required this.child});

  final Widget child;

  @override
  State<AlertAnnouncer> createState() => _AlertAnnouncerState();
}

class _AlertAnnouncerState extends State<AlertAnnouncer> {
  late final StreamSubscription<AlertEvent> _sub = context.read<AlertService>().events.listen(_onEvent);
  late final Voice? _voice = context.read<Voice?>();
  Alert? _lastRaised;
  Timer? _waitForName;

  /// A reflex fire nobody has named yet buzzes at once, but waits this long
  /// for Cam B's video to name it before speaking, so the wearer hears
  /// "Car" rather than "Behind" and then "Car".
  static const nameWait = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    _sub; // start listening now
  }

  void _onEvent(AlertEvent e) {
    if (!mounted) return;
    final screenReader = MediaQuery.accessibleNavigationOf(context);
    switch (e) {
      case AlertRaised(:final alert):
        // The same object only changing side: the glasses move the buzz,
        // but there is nothing new to say.
        final last = _lastRaised;
        _lastRaised = alert;
        final sideOnly =
            last != null &&
            last.trackId != null &&
            last.trackId == alert.trackId &&
            last.level == alert.level &&
            last.label == alert.label;
        if (sideOnly) return;

        // Cam B just named a fire that already buzzed: say the name only.
        final named =
            last != null &&
            last.source == AlertSource.reflex &&
            alert.source == AlertSource.reflex &&
            last.side == alert.side &&
            last.level == alert.level &&
            last.label == 'something';
        if (!named) alertHaptic(alert.level);

        _waitForName?.cancel();
        void speak() {
          if (!mounted) return;
          announce(context, alertSentence(alert.level, alert.label, _direction(alert)), assertive: true);
          if (!screenReader) _voice?.say(spokenWord(alert), interrupt: true);
        }

        final unnamedFire = alert.source == AlertSource.reflex && alert.label == 'something';
        if (unnamedFire) {
          _waitForName = Timer(nameWait, speak);
        } else {
          speak();
        }
      case SocialTapped():
        // Gentle, never the alert pattern or its haptic.
        final sentence = socialTapSentence(e);
        HapticFeedback.lightImpact();
        announce(context, sentence);
        if (!screenReader) _voice?.say(sentence, interrupt: true);
      case PossiblyFollowing(update: true):
        break; // the card's time updates quietly
      case PossiblyFollowing():
        final sentence = FollowingCard(notice: e).sentence;
        announce(context, sentence);
        if (!screenReader) _voice?.say(sentence);
      case AlertCleared():
        _lastRaised = null; // the buzz stops; nothing to say
        _waitForName?.cancel();
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    _waitForName?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
