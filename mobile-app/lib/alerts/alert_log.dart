// The event log: one entry per alert (from first warning to all clear) and
// per "possibly following" notice. Pure Dart. Kept on the phone only; it
// holds what was warned about and when, never video, audio or sensor data.

import '../net/protocol.dart';
import 'alert_engine.dart';

enum LogKind { alert, following }

class LogEntry {
  LogEntry({
    required this.kind,
    required this.at,
    required this.side,
    this.label = 'something',
    this.level = AlertLevel.gentle,
    this.reflex = false,
    this.closestSeconds,
    this.ended,
    this.behindFor,
  });

  final LogKind kind;
  final DateTime at;
  WearerSide side;

  /// One word: "car", or "something" if only the reflex saw it.
  String label;

  /// Highest level it reached.
  AlertLevel level;

  /// Cam B's collision reflex fired during it.
  bool reflex;

  /// Closest time to contact the camera measured, in seconds.
  double? closestSeconds;

  /// How it ended, or null while it's still going (or it was replaced).
  ClearReason? ended;

  /// For [LogKind.following]: how long they had been behind.
  Duration? behindFor;

  /// Urgent alerts count as near misses.
  bool get nearMiss => kind == LogKind.alert && level == AlertLevel.urgent;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'at': at.toIso8601String(),
    'side': side.wire,
    'label': label,
    'level': level.name,
    'reflex': reflex,
    'closest': closestSeconds,
    'ended': ended?.name,
    'behindFor': behindFor?.inSeconds,
  };

  /// Null for anything unreadable (an older or damaged save).
  static LogEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final kind = LogKind.values.asNameMap()[j['kind']];
    final at = j['at'] is String ? DateTime.tryParse(j['at'] as String) : null;
    final side = WearerSide.fromWire(j['side']);
    final level = AlertLevel.values.asNameMap()[j['level']];
    if (kind == null || at == null || side == null || level == null) return null;
    final closest = j['closest'], behind = j['behindFor'], label = j['label'];
    return LogEntry(
      kind: kind,
      at: at,
      side: side,
      label: label is String ? label : 'something',
      level: level,
      reflex: j['reflex'] == true,
      closestSeconds: closest is num ? closest.toDouble() : null,
      ended: ClearReason.values.asNameMap()[j['ended']],
      behindFor: behind is num ? Duration(seconds: behind.round()) : null,
    );
  }
}

class AlertLog {
  AlertLog({this.maxEntries = 200, this.keepFor = const Duration(days: 7)});

  final int maxEntries;
  final Duration keepFor;

  final _entries = <LogEntry>[]; // oldest first
  LogEntry? _open; // the alert currently going on
  int? _openTrack; // its camera track, if any

  /// Newest first.
  List<LogEntry> get entries => _entries.reversed.toList(growable: false);

  LogEntry? get latest => _entries.lastOrNull;

  /// Adds an engine event. Returns true if the log changed.
  bool record(DateTime at, AlertEvent e) {
    switch (e) {
      case AlertRaised(:final alert):
        final open = _open;
        if (open == null || !_sameThing(open, alert)) {
          _openTrack = null;
          _open = _add(LogEntry(kind: LogKind.alert, at: at, side: alert.side, level: alert.level));
        }
        _update(_open!, alert);
      case AlertCleared(:final reason):
        final open = _open;
        if (open == null) return false;
        open.ended = reason;
        _open = null;
        _openTrack = null;
      case PossiblyFollowing(:final side, :final behindFor):
        _add(LogEntry(kind: LogKind.following, at: at, side: side, label: 'person', behindFor: behindFor));
    }
    _prune(at);
    return true;
  }

  void clear() {
    _entries.clear();
    _open = null;
    _openTrack = null;
  }

  List<Object?> toJson() => [for (final e in _entries) e.toJson()];

  void load(Object? json, DateTime now) {
    clear();
    if (json is! List) return;
    for (final j in json) {
      final e = LogEntry.fromJson(j);
      if (e != null) _entries.add(e);
    }
    _entries.sort((a, b) => a.at.compareTo(b.at));
    _prune(now);
  }

  // The same camera track (even if it drifts to another side), or a reflex
  // fire on the side the camera is already warning about, is the same thing
  // getting closer, not a second event. Straight behind is next to both sides.
  bool _sameThing(LogEntry open, Alert a) {
    if (a.trackId != null && a.trackId == _openTrack) return true;
    final nearby = open.side == a.side || open.side == WearerSide.behind || a.side == WearerSide.behind;
    return nearby && (a.source == AlertSource.reflex || open.reflex);
  }

  void _update(LogEntry entry, Alert a) {
    if (a.level.index > entry.level.index) entry.level = a.level;
    entry.side = a.side;
    if (a.source == AlertSource.reflex) entry.reflex = true;
    if (a.label != 'something') entry.label = a.label;
    final s = a.secondsToContact;
    if (s != null && (entry.closestSeconds == null || s < entry.closestSeconds!)) entry.closestSeconds = s;
    if (a.trackId != null) _openTrack = a.trackId;
  }

  LogEntry _add(LogEntry e) {
    _entries.add(e);
    return e;
  }

  void _prune(DateTime now) {
    _entries.removeWhere((e) => now.difference(e.at) > keepFor);
    while (_entries.length > maxEntries) {
      _entries.removeAt(0);
    }
  }
}
