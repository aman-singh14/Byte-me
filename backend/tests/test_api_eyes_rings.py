"""API responses for the app: /eyes/*, /closeup/*, /rings/*, /outdoor, /dev/outside, /discovery.
Runs a real Runtime in dev mode (synthetic cameras, temporary database, silent speech)."""

import tempfile
import time
import unittest
import warnings
from pathlib import Path
from unittest import mock

import numpy as np

from backend import distance

with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    from fastapi.testclient import TestClient

from backend.api import create_app
from backend.config import load_config
from backend.main import Runtime
from backend.vision import Detection


class FakeDet:
    def __init__(self):
        self.dets = []

    def detect(self, frame, **_):
        return self.dets


PHONE = Detection("cell phone", 0.9, (130, 30, 190, 210), "ahead", 0.1)      # ~25 cm


class Api(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.patch = mock.patch.object(distance, "CALIB_PATH", Path(cls.tmp.name) / "c.json")
        cls.patch.start()
        cfg = load_config(dev=True)
        cfg["cameras"] = {"eye": {"source": "synthetic-eye"}, "front": {"source": "synthetic"}}
        cfg["eye"]["method"] = "closeup"
        cfg["distance"]["method"] = "nearwork"
        cfg["db"]["path"] = str(Path(cls.tmp.name) / "test.db")
        cfg["speech"] = {"laptop": "print", "browser": False}
        cfg["app_bridge"]["enabled"] = False
        cfg["muse"]["enabled"] = False
        cls.rt = Runtime(cfg)
        cls.det = FakeDet()
        cls.rt.front.nearwork.detector = cls.det
        cls.rt.front.sensor_fn = lambda: {"exposure_lines": 30, "gain": 1.0}    # bright outdoors
        cls.rt._update_live(eye_detected=True)
        cls.client = TestClient(create_app(cls.rt))
        # Simulate 10 minutes ending now: 4 min on the phone, then 6 min heads-up outdoors.
        now = time.time()
        img = np.full((240, 320, 3), 120, np.uint8)
        t = now - 600
        while t < now:
            cls.det.dets = [PHONE] if t < now - 360 else []
            cls.rt._front_step(img, t)
            t += 1 / 3

    @classmethod
    def tearDownClass(cls):
        cls.rt.stop()
        cls.patch.stop()
        cls.tmp.cleanup()

    def get(self, path):
        r = self.client.get(path)
        self.assertEqual(r.status_code, 200, r.text)
        return r.json()

    def test_voice_question_requires_eye_camera_gaze(self):
        response = self.client.post('/assist/look', json={
            'question': 'Read the sign on my left', 'require_gaze': True,
        })
        self.assertEqual(response.status_code, 400)
        self.assertIn('inward-facing', response.json()['detail'])

    def test_eyes_live(self):
        d = self.get("/eyes/live")
        for k in ("blink_rate", "partial_blinks", "squinting", "low_blink", "nearwork", "nearwork_object",
                  "nearwork_distance_cm", "closeup_session", "heads_up"):
            self.assertIn(k, d)
        self.assertFalse(d["nearwork"])                    # the phone was put away 6 min ago
        self.assertIsNotNone(d["heads_up"])

    def test_closeup_sessions(self):
        d = self.get("/closeup/sessions")
        self.assertEqual(len(d["sessions"]), 1)
        s = d["sessions"][0]
        self.assertEqual(s["object"], "phone")
        self.assertTrue(20 < s["avg_cm"] < 30)
        self.assertAlmostEqual(d["total_min"], 4.0, delta=0.2)
        self.assertEqual(list(d["by_object"]), ["phone"])
        r = self.client.get("/closeup/sessions?date=not-a-date")
        self.assertEqual(r.status_code, 400)

    def test_rings_today(self):
        d = self.get("/rings/today")
        self.assertAlmostEqual(d["heads_up"]["minutes"], 6.0, delta=0.3)
        self.assertEqual(d["heads_up"]["breaks"], 1)
        self.assertTrue(d["heads_up"]["active"])
        self.assertAlmostEqual(d["outside"]["minutes"], 10.0, delta=0.3)     # bright the whole time
        self.assertTrue(d["outside_now"])
        self.assertEqual(d["outside"]["goal_min"], 120)
        self.assertIn("points", d)

    def test_rings_history(self):
        h = self.get("/rings/history?days=3")
        self.assertEqual(len(h), 3)
        self.assertEqual(h[-1]["date"], time.strftime("%Y-%m-%d"))

    def test_eyes_history(self):
        d = self.get("/eyes/history?range=hour")
        for k in ("points", "squints", "low_blink", "bucket_s"):
            self.assertIn(k, d)

    def test_z_closeup_calibration(self):      # runs last: it feeds frames at the real time
        self.det.dets = []
        self.rt._front_step(np.zeros((240, 320, 3), np.uint8), time.time())
        r = self.client.post("/closeup/calibrate", json={"object": "phone", "known_cm": 30})
        self.assertEqual(r.status_code, 409)                # no phone in view
        self.det.dets = [PHONE]
        self.rt._front_step(np.zeros((240, 320, 3), np.uint8), time.time())
        r = self.client.post("/closeup/calibrate", json={"object": "phone", "known_cm": 30})
        self.assertEqual(r.status_code, 200, r.text)
        self.assertTrue(self.get("/closeup/calibration")["phone"]["calibrated"])
        self.assertEqual(self.client.post("/closeup/calibrate", json={"object": "toaster", "known_cm": 30}).status_code, 409)
        self.det.dets = []

    def test_outdoor_and_dev_toggle(self):
        d = self.get("/outdoor")
        self.assertTrue(d["sensor_ok"])
        self.assertTrue(self.client.post("/dev/outside", json={"on": True}).json()["manual"])
        self.client.post("/dev/outside", json={"on": None})
        self.rt.cfg["dev"] = False
        try:
            self.assertEqual(self.client.post("/dev/outside", json={"on": True}).status_code, 403)
        finally:
            self.rt.cfg["dev"] = True

    def test_discovery(self):
        d = self.get("/discovery")
        self.assertEqual(d["port"], 4310)
        self.assertIn("eye", d["candidates"])


if __name__ == "__main__":
    unittest.main()
