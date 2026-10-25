// Canned backend answers (shaped like backend/api.py's real output) for tests.

import 'package:omni_glasses/net/backend_api.dart';

double nowS([int offsetS = 0]) => DateTime.now().millisecondsSinceEpoch / 1000 + offsetS;

Map<String, Object?> eyesLiveJson() => {
  'ts': nowS(),
  'cameras': {'eye': 'online', 'front': 'online'},
  'eye_detected': true,
  'calibrated': true,
  'calibrating': false,
  'blink_rate': 7.4,
  'blinks_total': 312,
  'partial_blinks': 9,
  'squinting': false,
  'openness_ratio': 0.98,
  'low_blink': true,
  'low_blink_since': nowS(-420),
  'method': 'closeup',
  'nearwork': true,
  'nearwork_object': 'phone',
  'nearwork_distance_cm': 24.6,
  'nearwork_close': true,
  'nearwork_threshold_cm': 30,
  'nearwork_objects': [
    {'kind': 'phone', 'distance_cm': 24.6, 'close': true},
  ],
  'closeup_session': {'start': nowS(-300), 'object': 'phone', 'duration_s': 300},
  'heads_up': null,
};

Map<String, Object?> ringsTodayJson() => {
  'date': '2026-10-24',
  'heads_up': {'minutes': 96.4, 'goal_min': 180, 'percent': 54, 'active': false, 'breaks': 7},
  'outside': {'minutes': 41.0, 'goal_min': 120, 'percent': 34, 'active': true},
  'points': 48,
  'points_log': [],
};

Map<String, Object?> closeupJson() => {
  'date': '2026-10-24',
  'total_min': 132.5,
  'by_object': {'laptop': 98.0, 'phone': 30.5, 'book': 4.0},
  'longest_min': 61.2,
  'sessions': [
    {
      'start': nowS(-14000),
      'end': nowS(-10300),
      'object': 'laptop',
      'min_cm': 41.0,
      'avg_cm': 47.2,
      'duration_min': 61.2,
    },
    {'start': nowS(-9000), 'end': nowS(-7200), 'object': 'phone', 'min_cm': 18.0, 'avg_cm': 24.0, 'duration_min': 30.0},
    {'start': nowS(-300), 'end': nowS(), 'object': 'phone', 'open': true, 'duration_min': 5.0},
  ],
};

Map<String, Object?> eyesHistoryJson() => {
  'range': 'day',
  'bucket_s': 900,
  'points': [
    for (var i = 12; i >= 0; i--)
      {
        't': nowS(-i * 900),
        'blink_rate': 8.0 + (i % 5) * 2.5,
        'blinks': 120,
        'partial_blinks': i % 3,
        'squint_frac': 0.0,
      },
  ],
  'squints': [nowS(-5000), nowS(-2000)],
  'low_blink': [
    {'start': nowS(-6000), 'end': nowS(-5400), 'open': false},
  ],
};

List<Object?> ringsHistoryJson() => [
  for (var d = 6; d >= 0; d--)
    {
      'date': DateTime.now().subtract(Duration(days: d)).toIso8601String().substring(0, 10),
      'heads_up': {'minutes': 30.0 * d, 'goal_min': 180, 'percent': 0, 'active': false, 'breaks': d},
      'outside': {'minutes': 20.0 * d, 'goal_min': 120, 'percent': 0, 'active': false},
      'points': 5 * d,
    },
];

Map<String, Object?> lookJson(String? region) => {
  'question': 'What am I looking at?',
  'region': region ?? 'center',
  'region_source': region == null ? 'gaze' : 'override',
  'detections': [
    {'label': 'laptop', 'conf': 0.91, 'position': 'ahead', 'distance_cm': 55},
    {'label': 'cup', 'conf': 0.7, 'position': 'ahead'},
  ],
  'local_answer': 'Ahead: a laptop, about 60 centimeters away, and a cup.',
  'muse_answer': 'An open laptop is just ahead of you on a desk, with a white mug to its right.',
  'muse_error': null,
  'timing_s': {'local': 0.04, 'total': 3.2},
};

/// Answers like the backend; can be switched to fail.
class FakeTransport implements BackendTransport {
  FakeTransport({this.fail});

  BackendException? fail;
  final requests = <String>[];
  final bodies = <Map<String, Object?>?>[];

  @override
  Future<Object?> request(String method, Uri uri, {Map<String, Object?>? body, Duration? timeout}) async {
    requests.add('$method ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}');
    bodies.add(body);
    if (fail != null) throw fail!;
    return switch (uri.path) {
      '/eyes/live' => eyesLiveJson(),
      '/rings/today' => ringsTodayJson(),
      '/closeup/sessions' => closeupJson(),
      '/eyes/history' => eyesHistoryJson(),
      '/rings/history' => ringsHistoryJson(),
      '/closeup/calibrate' => {'object': body?['object'], 'known_cm': body?['known_cm']},
      '/dev/outside' => {'manual': body?['on']},
      '/assist/look' => lookJson(body?['region_override'] as String?),
      _ => throw BackendException('404 ${uri.path}', statusCode: 404),
    };
  }
}
