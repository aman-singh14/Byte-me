"""Gaze calibration, classification with hysteresis + smoothing, region crops, and the voice."""

import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

from backend import distance, synth_eye
from backend.config import load_config
from backend.eye_tracking import EyeTracker
from backend.gaze import GazeTracker
from backend.speech import URGENT, Voice

FPS = 15


class TempCalibration(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._patch = mock.patch.object(distance, "CALIB_PATH", Path(self._tmp.name) / "calibration.json")
        self._patch.start()

    def tearDown(self):
        self._patch.stop()
        self._tmp.cleanup()


def run_steps(g, per_region, t=0.0, noise=0.0, rng=None):
    """Feed one calibration pass: per_region maps region -> pupil (x, y)."""
    rng = rng or np.random.default_rng(0)
    for region in ("left", "center", "right"):
        if not g.calibrating:
            break
        n = int(g.step_s * FPS) + 2
        for i in range(n):
            x, y = per_region[region]
            pupil = None if i in (12, 13) else (x + rng.normal(0, noise), y + rng.normal(0, noise))
            g.update(pupil, t)
            t += 1 / FPS
    return t


class Calibration(TempCalibration):
    def test_centroids_are_medians_and_persist(self):
        g = GazeTracker(load_config())
        self.assertFalse(g.calibrated)
        g.start_calibration()
        run_steps(g, {"left": (-0.3, 0.1), "center": (0.02, 0.0), "right": (0.31, -0.05)}, noise=0.01)
        self.assertTrue(g.calibrated)
        self.assertFalse(g.calibrating)
        self.assertAlmostEqual(g.centroids["left"][0], -0.3, delta=0.02)
        self.assertAlmostEqual(g.centroids["right"][0], 0.31, delta=0.02)
        again = GazeTracker(load_config())                       # loaded from calibration.json
        self.assertTrue(again.calibrated)
        self.assertAlmostEqual(again.centroids["center"][0], 0.02, delta=0.02)

    def test_settle_period_skipped(self):
        g = GazeTracker(load_config())
        g.start_calibration(["left"])
        t = 0.0
        for i in range(int(3.0 * FPS) + 2):
            x = 0.9 if t < 0.4 else -0.3                         # eye still moving at the start
            g.update((x, 0.0), t)
            t += 1 / FPS
        self.assertAlmostEqual(g.centroids["left"][0], -0.3, delta=0.01)

    def test_prompts_spoken(self):
        said = []
        g = GazeTracker(load_config(), say=said.append)
        g.start_calibration()
        run_steps(g, {"left": (-0.3, 0), "center": (0, 0), "right": (0.3, 0)})
        self.assertEqual(said, ["Look left", "Look straight ahead", "Look right", "Gaze calibrated"])

    def test_mirrored_camera_mount(self):
        g = GazeTracker(load_config())
        g.start_calibration()
        t = run_steps(g, {"left": (0.3, 0), "center": (0, 0), "right": (-0.3, 0)})   # signs flipped
        for _ in range(FPS):
            state = g.update((0.29, 0.0), t)
            t += 1 / FPS
        self.assertEqual(state["gaze"], "left")


class Classification(TempCalibration):
    def tracker(self):
        g = GazeTracker(load_config())
        g.centroids = {"left": (-0.3, 0.0), "center": (0.0, 0.0), "right": (0.3, 0.0)}
        return g

    def test_nearest_centroid(self):
        g = self.tracker()
        self.assertEqual(g.classify_raw((-0.28, 0.0)), "left")
        g.current = None
        self.assertEqual(g.classify_raw((0.05, 0.0)), "center")
        g.current = None
        self.assertEqual(g.classify_raw((0.26, 0.02)), "right")

    def test_hysteresis_holds_near_boundary(self):
        g = self.tracker()
        g.classify_raw((0.0, 0.0))                                # center
        self.assertEqual(g.classify_raw((0.16, 0.0)), "center")   # just past the midpoint: hold
        self.assertEqual(g.classify_raw((0.25, 0.0)), "right")    # clearly right: switch

    def test_majority_smoothing_ignores_glitches(self):
        g = self.tracker()
        t, labels = 0.0, []
        for i in range(60):
            x = 0.3 if i % 10 == 5 else 0.0                       # one-frame glitches to the right
            labels.append(g.update((x, 0.0), t)["gaze"])
            t += 1 / FPS
        self.assertEqual(set(labels[3:]), {"center"})

    def test_no_pupil_keeps_last_answer(self):
        g = self.tracker()
        t = 0.0
        for _ in range(10):
            g.update((-0.3, 0.0), t)
            t += 1 / FPS
        state = g.update(None, t)                                 # a blink
        self.assertEqual(state["gaze"], "left")


class Regions(TempCalibration):
    def test_bounds_overlap_and_cover(self):
        g = GazeTracker(load_config())
        w = 640
        left, center, right = (g.region_bounds(r, w) for r in ("left", "center", "right"))
        self.assertEqual(left[0], 0)
        self.assertEqual(right[1], w)
        self.assertGreater(left[1], center[0])                    # overlap
        self.assertGreater(center[1], right[0])
        for a, b in (left, center, right):
            self.assertGreater((b - a) / w, 0.4)                  # a third + ~15% overlap
        self.assertEqual(g.region_bounds("all", w), (0, w))

    def test_crop(self):
        g = GazeTracker(load_config())
        frame = np.zeros((480, 640, 3), np.uint8)
        frame[:, 400:] = 255                                       # bright right side
        crop, x0 = g.crop(frame, "right")
        self.assertEqual(x0, g.region_bounds("right", 640)[0])
        self.assertEqual(crop.shape[0], 480)
        self.assertGreater(crop.mean(), 200)
        crop, x0 = g.crop(frame, "left")
        self.assertEqual((x0, crop.mean()), (0, 0))


class EndToEnd(TempCalibration):
    def test_synthetic_eye_calibrate_then_classify(self):
        tracker = EyeTracker(load_config())                       # product close-up method
        g = GazeTracker(load_config())
        t = 0.0
        rng = np.random.default_rng(5)

        def frame(gx, openness=1.0):
            return synth_eye.render((gx, 0.0), openness, rng=rng)

        for _ in range(3 * FPS):                                   # eye calibration first
            st, _ = tracker.process(frame(0.0), t)
            g.update(tuple(st["pupil"]) if st["pupil"] else None, t)
            t += 1 / FPS
        g.start_calibration()
        for region, gx in (("left", -0.8), ("center", 0.0), ("right", 0.8)):
            for i in range(int(3.0 * FPS) + 2):
                st, _ = tracker.process(frame(gx, 0.0 if i == 20 else 1.0), t)   # includes a blink
                g.update(tuple(st["pupil"]) if st["pupil"] else None, t)
                t += 1 / FPS
        self.assertTrue(g.calibrated)

        script = [(-0.8, "left")] * 30 + [(0.0, "center")] * 30 + [(0.8, "right")] * 30 + [(-0.7, "left")] * 30
        hits = total = 0
        for i, (gx, want) in enumerate(script):
            st, _ = tracker.process(frame(gx), t)
            out = g.update(tuple(st["pupil"]) if st["pupil"] else None, t)["gaze"]
            t += 1 / FPS
            if i % 30 >= 10:                                       # skip the first frames after each move
                total += 1
                hits += out == want
        self.assertGreaterEqual(hits / total, 0.95, f"{hits}/{total}")


class VoiceTests(unittest.TestCase):
    def test_browser_event_and_priorities(self):
        events = []
        v = Voice({"speech": {"laptop": "print", "browser": True}}, emit=lambda k, d: events.append((k, d)))
        v.say("I see a laptop")
        v.say("Something approaching from behind", URGENT, source="rear")
        self.assertEqual([d["text"] for k, d in events if k == "speak"],
                         ["I see a laptop", "Something approaching from behind"])
        self.assertEqual(events[-1][1]["priority"], "urgent")
        self.assertEqual(v.history[-1], (URGENT, "Something approaching from behind"))

    def test_print_mode_queues_nothing(self):
        v = Voice({"speech": {"laptop": "print", "browser": False}})
        v.say("hello")
        self.assertTrue(v._q.empty())


if __name__ == "__main__":
    unittest.main()
