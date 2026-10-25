// The phone's eye tracking against the laptop's: the same synthetic eye
// frames (tools/make_eye_fixtures.py) through lib/eyes/pupil.dart, expecting
// what backend/pupil.py and backend/eye_tracking.py found in them.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omni_glasses/eyes/image_ops.dart';
import 'package:omni_glasses/eyes/pupil.dart';

void main() {
  final expected = jsonDecode(File('test/fixtures/eye/expected.json').readAsStringSync()) as Map<String, dynamic>;
  final w = expected['width'] as int, h = expected['height'] as int;
  final raw = gzip.decode(File('test/fixtures/eye/frames.gray.gz').readAsBytesSync());
  final rows = (expected['frames'] as List).cast<Map<String, dynamic>>();
  Grey frame(int i) => Grey(w, h, Uint8List.fromList(raw.sublist(i * w * h, (i + 1) * w * h)));

  // How far the port may drift from OpenCV, per vector feature: well inside how far ordinary
  // lighting changes move them (featureFloors), so gaze calibrations mean the same thing.
  const tolerance = [0.01, 0.01, 0.01, 0.02, 0.004, 0.03, 0.01, 0.01];

  test('locate() finds the same dark mass as the laptop', () {
    for (final (i, row) in rows.indexed) {
      final fix = locate(frame(i));
      final want = row['locate'] as List?;
      expect(fix == null, want == null, reason: '${row['name']}: pupil found?');
      if (fix == null) continue;
      for (final (k, v) in fix.vector.indexed) {
        expect(v, closeTo((want![k] as num).toDouble(), tolerance[k]), reason: '${row['name']} feature $k');
      }
    }
  });

  test('CloseupEye sees the same openness and pupil, frame after frame', () {
    final eye = CloseupEye();
    for (final (i, row) in rows.indexed) {
      if (!row.containsKey('openness')) continue;
      final f = eye.extract(frame(i));
      expect(f.openness, closeTo((row['openness'] as num).toDouble(), 0.05), reason: '${row['name']} openness');
      final want = row['pupil'] as List?;
      expect(f.pupil == null, want == null, reason: '${row['name']}: pupil visible?');
      if (want == null) continue;
      expect(f.pupil!.$1, closeTo((want[0] as num).toDouble(), 0.01), reason: '${row['name']} x');
      expect(f.pupil!.$2, closeTo((want[1] as num).toDouble(), 0.01), reason: '${row['name']} y');
    }
  });

  test('fast enough to keep up with the eye camera', () {
    final eye = CloseupEye(), f = frame(0), clock = Stopwatch()..start();
    for (var i = 0; i < 20; i++) {
      eye.extract(f);
    }
    // 25 fps on the phone (AOT) needs < 40 ms; the test VM is several times slower.
    expect(clock.elapsedMilliseconds / 20, lessThan(150));
  });
}
