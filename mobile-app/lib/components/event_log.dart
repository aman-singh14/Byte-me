// Event log rows and the "possibly following" notice. Safety register:
// plain and literal. Near misses are listed as facts, never scored.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../alerts/alert_engine.dart';
import '../alerts/alert_log.dart';
import '../theme/theme.dart';
import 'common.dart';

/// "10:42", or "Oct 23, 10:42" before today.
String formatLogTime(BuildContext context, DateTime at, {DateTime? now}) {
  final l = MaterialLocalizations.of(context);
  final time = l.formatTimeOfDay(
    TimeOfDay.fromDateTime(at),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  final today = DateUtils.isSameDay(at, now ?? DateTime.now());
  return today ? time : '${l.formatShortMonthDay(at)}, $time';
}

/// "3 minutes", "1 minute".
String _minutes(Duration d) {
  final m = d.inMinutes;
  return m == 1 ? '1 minute' : '$m minutes';
}

/// One line of the event log: what, where, when, how it ended.
class LogEntryRow extends StatelessWidget {
  const LogEntryRow({super.key, required this.entry, this.now});

  final LogEntry entry;

  /// For tests and the gallery; defaults to the clock.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final direction = Direction.fromWearerSide(e.side);
    final time = formatLogTime(context, e.at, now: now);

    final String title, sentence;
    final details = <String>[time];
    final IconData icon;
    switch (e.kind) {
      case LogKind.alert:
        final urgent = e.level == AlertLevel.urgent;
        icon = urgent ? Symbols.warning_rounded : iconForObject(e.label);
        title = '${capitalize(e.label)}  ·  ${urgent ? 'close, ' : ''}${direction.short}';
        sentence = '${capitalize(e.label)} ${urgent ? 'close ' : ''}${direction.phrase}, at $time.';
        final closest = e.closestSeconds;
        if (closest != null) details.add('within ${closest.toStringAsFixed(1)} s');
        if (e.reflex) details.add('reflex fired');
        switch (e.ended) {
          case ClearReason.silenced:
            details.add('you looked back');
          case ClearReason.dismissed:
            details.add('dismissed');
          case ClearReason.gone || null:
            break;
        }
      case LogKind.following:
        icon = Symbols.person_alert_rounded;
        title = 'Someone stayed ${direction.short}';
        final behind = e.behindFor;
        if (behind != null) details.add('for ${_minutes(behind)}');
        sentence = 'Someone stayed ${direction.phrase}${behind == null ? '' : ' for ${_minutes(behind)}'}, at $time.';
    }

    return Semantics(
      container: true,
      label: details.length > 1 ? '$sentence ${capitalize(details.skip(1).join(', '))}.' : sentence,
      child: ExcludeSemantics(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: context.space.s),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: context.colors.textPrimary, fill: e.nearMiss ? 1 : 0),
              SizedBox(width: context.space.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: context.type.label),
                    Text(
                      details.join(' · '),
                      style: context.type.caption.copyWith(color: context.colors.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The event log card, newest first.
class EventLogCard extends StatelessWidget {
  const EventLogCard({super.key, required this.entries, this.onClear, this.now, this.limit = 20});

  final List<LogEntry> entries;
  final VoidCallback? onClear;
  final DateTime? now;
  final int limit;

  @override
  Widget build(BuildContext context) {
    return OmniCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardTitle(icon: Symbols.history_rounded, title: 'Recent alerts'),
          SizedBox(height: context.space.s),
          if (entries.isEmpty)
            Text('No alerts yet.', style: context.type.body.copyWith(color: context.colors.textSecondary))
          else
            for (final e in entries.take(limit)) LogEntryRow(entry: e, now: now),
          if (entries.isNotEmpty && onClear != null) ...[
            SizedBox(height: context.space.s),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(onPressed: onClear, child: const Text('Clear history')),
            ),
          ],
          SizedBox(height: context.space.xs),
          Text(
            'Kept on this phone for 7 days. Never shared.',
            style: context.type.caption.copyWith(color: context.colors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Someone has stayed behind the wearer for a while. Calm, literal, and
/// clear that it's about presence, not identity.
class FollowingCard extends StatelessWidget {
  const FollowingCard({super.key, required this.notice, this.onDismiss});

  final PossiblyFollowing notice;
  final VoidCallback? onDismiss;

  /// "Someone has been behind you, right, for 3 minutes."
  String get sentence =>
      'Someone has been ${Direction.fromWearerSide(notice.side).phrase} for ${_minutes(notice.behindFor)}.';

  @override
  Widget build(BuildContext context) {
    return SafetyFadeIn(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: sentence,
        child: OmniCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Symbols.person_alert_rounded, size: 32, color: context.colors.textPrimary),
                    SizedBox(width: context.space.m),
                    Expanded(child: Text(sentence, style: context.type.headline)),
                  ],
                ),
              ),
              SizedBox(height: context.space.s),
              Text(
                'Based only on how long someone has been there, not who they are.',
                style: context.type.caption.copyWith(color: context.colors.textSecondary),
              ),
              if (onDismiss != null)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
