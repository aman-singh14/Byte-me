"""Product config is ESP32 + FPGA only; dev stand-ins live only in config.dev.yaml."""

import tempfile
import time
import unittest
from pathlib import Path

import cv2
import numpy as np

from backend.config import deep_merge, load_config
from backend.distance import DistanceEstimator
from backend.eye_tracking import CloseupEye, EyeTracker
from backend.streams import FrameReader, is_stream


class ProductConfig(unittest.TestCase):
    def setUp(self):
        self.cfg = load_config()

    def test_cameras_are_esp32_streams_only(self):
        for name, cam in self.cfg["cameras"].items():
            self.assertTrue(is_stream(cam["source"]), f"{name} source {cam['source']!r} is not an MJPEG URL")
            self.assertIsNone(cam.get("fallback"), f"{name} must not silently fall back")
        self.assertEqual(set(self.cfg["cameras"]), {"eye", "front"})

    def test_no_webcam_anywhere(self):
        for name, cam in self.cfg["cameras"].items():
            for key in ("source", "fallback"):
                self.assertNotIsInstance(cam.get(key), int, f"{name}.{key} is a webcam index")

    def test_product_methods(self):
        self.assertEqual(self.cfg["eye"]["method"], "closeup")
        self.assertEqual(self.cfg["distance"]["method"], "nearwork")
        self.assertEqual(self.cfg["rear"]["mode"], "fpga")
        self.assertFalse(self.cfg["dev"])

    def test_default_extractor_is_closeup(self):
        self.assertIsInstance(EyeTracker(self.cfg).extractor, CloseupEye)
        self.assertIsInstance(EyeTracker({"eye": {}}).extractor, CloseupEye)

    def test_distance_width_follows_device(self):
        est = DistanceEstimator(self.cfg)
        self.assertEqual(est.real_cm, 30.0)
        est.set_device("phone")
        self.assertEqual(est.real_cm, 7.0)
        self.assertEqual(est.threshold_cm, 30)


class DevConfig(unittest.TestCase):
    def test_dev_overlay(self):
        cfg = load_config(dev=True)
        self.assertTrue(cfg["dev"])
        self.assertEqual(cfg["cameras"]["eye"]["source"], 0)
        self.assertEqual(cfg["eye"]["method"], "facemesh")
        self.assertEqual(cfg["distance"]["method"], "face")
        self.assertEqual(cfg["rear"]["mode"], "fpga")             # mock FPGA in dev
        # Untouched product values survive the merge.
        self.assertEqual(cfg["distance"]["too_close_cm"], {"laptop": 50, "phone": 30})
        self.assertEqual(cfg["api"]["port"], 8000)

    def test_dev_gaze_defaults_match_a_facing_webcam(self):
        g = load_config(dev=True)["gaze"]
        self.assertTrue(g["front_mirrored"])
        self.assertGreater(g["default_centroids"]["left"][0], 0)    # look left = iris to picture's right
        self.assertLess(g["default_centroids"]["right"][0], 0)
        self.assertEqual(load_config()["gaze"]["default_centroids"]["left"][0], -0.25)   # product unchanged

    def test_deep_merge_does_not_mutate(self):
        base = {"a": {"b": 1, "c": 2}, "d": [1]}
        out = deep_merge(base, {"a": {"b": 9}, "d": [2]})
        self.assertEqual(out, {"a": {"b": 9, "c": 2}, "d": [2]})
        self.assertEqual(base, {"a": {"b": 1, "c": 2}, "d": [1]})


class StillImageSource(unittest.TestCase):
    def test_image_repeats(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "desk.png")
            cv2.imwrite(path, np.full((120, 160, 3), 77, np.uint8))
            r = FrameReader(path, stale_s=2.0)
            try:
                seq, frame, _ = r.wait_new(0, timeout=2.0)
                seq2, _, _ = r.wait_new(seq, timeout=2.0)
                self.assertEqual(frame.shape, (120, 160, 3))
                self.assertGreater(seq2, seq)         # keeps delivering, unlike cv2.VideoCapture
                self.assertTrue(r.status()["ok"])
            finally:
                r.close()

    def test_missing_source_reports_offline(self):
        r = FrameReader("/nonexistent/eye.mp4", reconnect_s=0.2, stale_s=0.5)
        try:
            time.sleep(0.5)
            st = r.status()
            self.assertFalse(st["ok"])
            self.assertIsNone(st["active"])
        finally:
            r.close()


if __name__ == "__main__":
    unittest.main()
