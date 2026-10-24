"""Blink/squint detector on synthetic openness signals. Run: python -m unittest discover backend/tests"""

import unittest

from backend.eye_tracking import BlinkSquintDetector

FPS = 15
DT = 1 / FPS


def feed(det, samples, t0=0.0):
    events, t = [], t0
    for v in samples:
        events += det.update(v, t)
        t += DT
    return events, t


def calibrated(open_ear=0.30):
    det = BlinkSquintDetector(calibration_s=2.0, default_baseline=0.2)
    events, t = feed(det, [open_ear] * (3 * FPS))
    assert det.calibrated
    return det, t, events


class Calibration(unittest.TestCase):
    def test_baseline_is_open_eye_median(self):
        det, _, events = calibrated(0.30)
        self.assertAlmostEqual(det.baseline, 0.30)
        self.assertIn("calibrated", [e[0] for e in events])

    def test_calibration_waits_for_a_face(self):
        det = BlinkSquintDetector(calibration_s=2.0)
        _, t = feed(det, [None] * (10 * FPS))          # nobody there for 10 s
        self.assertTrue(det.calibrating)
        feed(det, [0.31] * (3 * FPS), t)
        self.assertTrue(det.calibrated)
        self.assertAlmostEqual(det.baseline, 0.31)

    def test_recalibrate(self):
        det, t, _ = calibrated(0.30)
        det.start_calibration()
        feed(det, [0.25] * (3 * FPS), t)
        self.assertAlmostEqual(det.baseline, 0.25)

    def test_blink_during_calibration_does_not_lower_baseline(self):
        det = BlinkSquintDetector(calibration_s=2.0)
        feed(det, [0.30] * 10 + [0.05] * 3 + [0.30] * 30)
        self.assertAlmostEqual(det.baseline, 0.30)


class Blinks(unittest.TestCase):
    def test_normal_blink_counts(self):
        det, t, _ = calibrated()
        events, _ = feed(det, [0.30] * 5 + [0.08] * 3 + [0.30] * 5, t)   # 200 ms closure
        self.assertEqual([e[0] for e in events], ["blink"])

    def test_one_frame_dip_is_noise(self):
        det = BlinkSquintDetector(calibration_s=2.0, blink_min_s=0.1)
        _, t = feed(det, [0.30] * 45)
        events, _ = feed(det, [0.30, 0.08, 0.30], t)
        self.assertEqual(events, [])

    def test_long_closure_is_not_a_blink(self):
        det, t, _ = calibrated()
        events, _ = feed(det, [0.08] * FPS + [0.30] * 3, t)   # 1 s closed
        self.assertEqual([e for e in events if e[0] == "blink"], [])

    def test_lost_face_is_not_a_blink(self):
        det, t, _ = calibrated()
        events, _ = feed(det, [0.30, None, None, 0.30], t)
        self.assertEqual(events, [])

    def test_blink_rate(self):
        det, t, _ = calibrated()
        # 12 blinks over 60 s: one every 5 s.
        one = [0.08] * 3 + [0.30] * (5 * FPS - 3)
        _, t = feed(det, one * 12, t)
        self.assertAlmostEqual(det.blink_rate(t), 12, delta=1.5)

    def test_rate_unknown_early(self):
        det = BlinkSquintDetector()
        feed(det, [0.3] * 30)
        self.assertIsNone(det.blink_rate(2.0))


class Squint(unittest.TestCase):
    def test_sustained_partial_closure_is_squint(self):
        det, t, _ = calibrated()
        events, t = feed(det, [0.22] * (2 * FPS), t)   # ratio 0.73 for 2 s
        self.assertIn("squint_start", [e[0] for e in events])
        self.assertTrue(det.squinting)
        events, _ = feed(det, [0.30] * 3, t)
        self.assertEqual(events[0][0], "squint_end")
        self.assertFalse(det.squinting)

    def test_no_squint_while_calibrating(self):
        det = BlinkSquintDetector(calibration_s=5.0, default_baseline=0.30)
        events, _ = feed(det, [0.22] * (4 * FPS))       # real baseline is lower than the default
        self.assertNotIn("squint_start", [e[0] for e in events])

    def test_short_partial_closure_is_not_squint(self):
        det, t, _ = calibrated()
        events, _ = feed(det, [0.22] * 10 + [0.30] * 5, t)
        self.assertEqual(events, [])

    def test_blink_inside_squint_keeps_squint(self):
        det, t, _ = calibrated()
        _, t = feed(det, [0.22] * (2 * FPS), t)
        events, _ = feed(det, [0.05] * 3 + [0.22] * 5, t)
        self.assertTrue(det.squinting)
        self.assertEqual([e[0] for e in events], ["blink"])


if __name__ == "__main__":
    unittest.main()
