"""The product's close-up eye method on synthetic close-up eyes (backend/synth_eye.py)."""

import unittest

import numpy as np

from backend import synth_eye
from backend.config import load_config
from backend.eye_tracking import BlinkSquintDetector, CloseupEye, EyeTracker

FPS = 15


def settled():
    ex = CloseupEye()
    for _ in range(20):
        ex.extract(synth_eye.render((0, 0), 1.0))
    return ex


def true_x(gx):
    return (synth_eye.CX + gx * synth_eye.GAZE_X_PX) / synth_eye.W * 2 - 1


class Pupil(unittest.TestCase):
    def test_center_follows_gaze(self):
        ex = settled()
        for gx in (-0.8, -0.4, 0.0, 0.4, 0.8):
            f = ex.extract(synth_eye.render((gx, 0), 1.0))
            self.assertAlmostEqual(f.pupil[0], true_x(gx), delta=0.02)
            self.assertAlmostEqual(f.openness, 1.0, delta=0.08)

    def test_glint_does_not_shrink_pupil(self):
        ex = settled()
        with_glint = ex.extract(synth_eye.render((0, 0), 1.0, glint=True)).openness
        without = ex.extract(synth_eye.render((0, 0), 1.0, glint=False)).openness
        self.assertAlmostEqual(with_glint, without, delta=0.05)

    def test_lashes_are_not_the_pupil(self):
        ex = settled()
        f = ex.extract(synth_eye.render((0, 0), 0.7, lashes=True))     # lashes touch the pupil here
        self.assertIsNotNone(f.pupil)
        self.assertAlmostEqual(f.pupil[0], true_x(0), delta=0.03)
        self.assertAlmostEqual(f.openness, 0.7, delta=0.12)

    def test_openness_tracks_lid(self):
        ex = settled()
        measured = [ex.extract(synth_eye.render((0, 0), o)).openness for o in (1.0, 0.7, 0.5, 0.3)]
        self.assertEqual(measured, sorted(measured, reverse=True))
        self.assertLess(measured[-1], 0.4)

    def test_closed_eye_has_no_pupil(self):
        ex = settled()
        for o in (0.05, 0.0):
            f = ex.extract(synth_eye.render((0, 0), o))
            self.assertIsNone(f.pupil)
            self.assertEqual(f.openness, 0.0)

    def test_noise_robust(self):
        ex = settled()
        rng = np.random.default_rng(3)
        for _ in range(20):
            f = ex.extract(synth_eye.render((0.3, 0), 1.0, noise=10, rng=rng))
            self.assertAlmostEqual(f.pupil[0], true_x(0.3), delta=0.03)


class BlinkFrames(unittest.TestCase):
    def feed(self, det, closed_frames):
        events, t = [], 0.0
        seq = [1.0] * 30 + [0.0] * closed_frames + [1.0] * 10
        for v in seq:
            events += det.update(v, t)
            t += 1 / FPS
        return [e for e in events if e[0] == "blink"]

    def det(self):
        return BlinkSquintDetector(calibration_s=1.0, default_baseline=1.0, blink_min_frames=2, blink_max_frames=7)

    def test_two_to_seven_frames_is_a_blink(self):
        for n in (2, 3, 5, 7):
            self.assertEqual(len(self.feed(self.det(), n)), 1, f"{n} closed frames")

    def test_one_frame_or_eight_is_not(self):
        for n in (1, 8, 20):
            self.assertEqual(self.feed(self.det(), n), [], f"{n} closed frames")


class Tracker(unittest.TestCase):
    def cfg(self):
        return load_config()            # product config: closeup, 2-7 frame blinks

    def test_scripted_timeline(self):
        tracker = EyeTracker(self.cfg())
        blinks_true = 0
        prev_blink = False
        squint_seen_at = []
        t = 0.0
        for frame, truth in synth_eye.timeline(FPS, seconds=30.0):
            state, events = tracker.process(frame, t)
            if truth["blink"] and not prev_blink:
                blinks_true += 1
            prev_blink = truth["blink"]
            if any(e[0] == "squint_start" for e in events):
                squint_seen_at.append(t)
            t += 1 / FPS
        self.assertTrue(state["calibrated"])
        self.assertAlmostEqual(tracker.detector.baseline, 1.0, delta=0.1)
        self.assertEqual(state["blinks_total"], blinks_true)
        self.assertEqual(len(squint_seen_at), 1)
        self.assertTrue(17.5 <= squint_seen_at[0] <= 19.0, squint_seen_at)   # 16.5 s + 1.5 s hold
        self.assertTrue(state["eye_detected"])

    def test_eye_out_of_view_is_not_a_closure(self):
        tracker = EyeTracker(self.cfg())
        skin = synth_eye.render((0, 0), 0.0, lashes=False)
        skin[:] = skin.mean(axis=(0, 1)).astype(np.uint8)                   # no eye anywhere
        t = 0.0
        for _ in range(3 * FPS):
            state, events = tracker.process(skin, t)
            t += 1 / FPS
        self.assertFalse(state["eye_detected"])
        self.assertTrue(state["calibrating"])                              # still waiting for an eye
        self.assertEqual(state["blinks_total"], 0)
        for _ in range(7 * FPS):                                            # eye appears: calibrates
            state, _ = tracker.process(synth_eye.render((0, 0), 1.0), t)
            t += 1 / FPS
        self.assertTrue(state["eye_detected"])
        self.assertTrue(state["calibrated"])

    def test_glasses_off_then_on_no_fake_blink(self):
        tracker = EyeTracker(self.cfg())
        t = 0.0
        for _ in range(7 * FPS):
            tracker.process(synth_eye.render((0, 0), 1.0), t)
            t += 1 / FPS
        blank = np.full((synth_eye.H, synth_eye.W, 3), 150, np.uint8)
        for _ in range(4 * FPS):                                            # 4 s with no eye
            state, _ = tracker.process(blank, t)
            t += 1 / FPS
        self.assertFalse(state["eye_detected"])
        for _ in range(FPS):
            state, _ = tracker.process(synth_eye.render((0, 0), 1.0), t)
            t += 1 / FPS
        self.assertEqual(state["blinks_total"], 0)


if __name__ == "__main__":
    unittest.main()
