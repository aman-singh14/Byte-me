// Turns Muse Voice Transcribe's events into caption lines. Pure Dart.
//
// The events, as documented (dev.meta.ai/docs/speech-to-text):
//   speechStart {turnId}          a turn begins
//   transcript {transcript}       the open turn's partial text; each one REPLACES
//                                 the previous (cumulative), never appended
//   speaker {label}               DIARIZATION: "A", "B", ... for the audio since the
//                                 previous speechStart or speaker event
//   speechComplete {turnId, transcript}   the turn's final text
// Turn ids and labels only mean something within one session, and a new
// WebSocket is a new session, so they're scoped by [startSession].
//
// Labels become "Speaker 1", "Speaker 2" in order of appearance. They're who
// is talking in this conversation, never who someone is.

class CaptionLine {
  CaptionLine({required this.id, required this.session, this.turnId});

  /// Stable across the whole captions run, for widget keys.
  final int id;
  final int session;
  final int? turnId;
  String text = '';
  bool isFinal = false;

  /// "Speaker 1", or null without speaker labels.
  String? speaker;

  /// The final text in the wearer's language ([translatedTo]), when it was in another.
  String? translation;
  String? translatedTo;

  /// The final text arrived with the line still empty: nothing was said.
  bool get isEmpty => text.trim().isEmpty;
}

class CaptionTranscript {
  CaptionTranscript({this.maxLines = 200});

  /// Older lines are dropped beyond this (nothing is kept anyway).
  final int maxLines;

  final _lines = <CaptionLine>[];
  List<CaptionLine> get lines => List.unmodifiable(_lines);

  int _session = 0;
  int _nextId = 0;
  CaptionLine? _open; // the turn the latest speechStart opened
  final _names = <(int, String), String>{}; // (session, label) -> "Speaker N"
  int _speakers = 0;

  /// A new Meta session (a new WebSocket): turn ids and labels start over.
  /// Lines on screen stay; a turn left open by the old session keeps its
  /// last partial, marked final.
  void startSession() {
    _session++;
    final open = _open;
    if (open != null) {
      open.isFinal = true;
      if (open.isEmpty) _lines.remove(open);
    }
    _open = null;
  }

  void clear() {
    _lines.clear();
    _open = null;
    _names.clear();
    _speakers = 0;
  }

  /// Applies one event from the relay. Returns true if the lines changed.
  bool apply(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'speechStart':
        final turnId = event['turnId'];
        _open = _add(turnId is int ? turnId : null);
        return true;
      case 'transcript':
        final text = event['transcript'];
        if (text is! String) return false;
        final line = _open ??= _add(null);
        line.text = text.trim(); // Meta's text can start with a space
        if (event['final'] == true) _finish(line); // PUSH_TO_TALK style
        return true;
      case 'speaker':
        final label = event['label'];
        final line = _open ?? _lines.lastOrNull;
        if (label is! String || label.isEmpty || line == null) return false;
        line.speaker = _names.putIfAbsent((_session, label), () => 'Speaker ${++_speakers}');
        return true;
      case 'speechComplete':
        final turnId = event['turnId'], text = event['transcript'];
        if (text is! String) return false;
        final line =
            _lines.reversed.where((l) => l.session == _session && l.turnId == turnId && turnId != null).firstOrNull ??
            _open ??
            _add(turnId is int ? turnId : null);
        line.text = text.trim();
        _finish(line);
        return true;
      default:
        return false; // speechEnd, audioProgress and unknown types change nothing on screen
    }
  }

  CaptionLine _add(int? turnId) {
    final line = CaptionLine(id: _nextId++, session: _session, turnId: turnId);
    _lines.add(line);
    if (_lines.length > maxLines) _lines.removeAt(0);
    return line;
  }

  void _finish(CaptionLine line) {
    line.isFinal = true;
    if (identical(line, _open)) _open = null;
    if (line.isEmpty) _lines.remove(line);
  }
}
