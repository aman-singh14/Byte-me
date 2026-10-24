"""Distance math and the screen finder on synthetic frames."""

import tempfile
import unittest
from pathlib import Path
from unittest import mock

import cv2
import numpy as np

from backend import distance
from backend.distance import DistanceEstimator, find_screen


def cfg(**over):
    d = {"method": "object", "device": "laptop", "too_close_cm": {"laptop": 50, "phone": 30},
         "object_width_cm": 30.0, "focal_px": 500.0, "smoothing": 1.0}
    d.update(over)
    return {"distance": d}


def screen_frame(width_px, w=640, h=480):
    img = np.full((h, w, 3), 40, np.uint8)
    hh = int(width_px * 0.62)
    x0, y0 = (w - width_px) // 2, (h - hh) // 2
    cv2.rectangle(img, (x0, y0), (x0 + width_px, y0 + hh), (230, 230, 230), -1)
    return img


class ScreenDistance(unittest.TestCase):
    def test_find_screen_width(self):
        width, box = find_screen(screen_frame(300))
        self.assertAlmostEqual(width, 300, delta=4)
        self.assertEqual(box.shape, (4, 2))

    def test_no_screen(self):
        self.assertIsNone(find_screen(np.full((480, 640, 3), 40, np.uint8)))

    def test_distance_and_too_close(self):
        est = DistanceEstimator(cfg())
        state, events = est.process(screen_frame(250), 0.0)    # 500 * 30 / 250 = 60 cm
        self.assertAlmostEqual(state["distance_cm"], 60, delta=1.5)
        self.assertFalse(state["too_close"])
        state, events = est.process(screen_frame(375), 1.0)    # 40 cm
        self.assertAlmostEqual(state["distance_cm"], 40, delta=1.5)
        self.assertTrue(state["too_close"])
        self.assertEqual(events[0][0], "too_close_start")
        state, events = est.process(screen_frame(250), 5.0)
        self.assertEqual(events, [("too_close_end", 4.0)])

    def test_phone_threshold(self):
        est = DistanceEstimator(cfg(device="phone"))
        state, _ = est.process(screen_frame(375), 0.0)         # 40 cm is fine for a phone
        self.assertFalse(state["too_close"])

    def test_calibration_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(distance, "CALIB_PATH", Path(tmp) / "c.json"):
            est = DistanceEstimator(cfg(focal_px=None))
            est.process(screen_frame(300), 0.0)
            est.calibrate(50.0)                                 # focal = 300 * 50 / 30 = 500
            self.assertAlmostEqual(est.focal, 300 * 50 / 30, delta=5)
            state, _ = est.process(screen_frame(150), 1.0)
            self.assertAlmostEqual(state["distance_cm"], 100, delta=3)


if __name__ == "__main__":
    unittest.main()
