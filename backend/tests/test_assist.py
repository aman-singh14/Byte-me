""""What am I looking at?": region choice, local-answer-first ordering, Muse budget guard.
The Muse API is always mocked here: these tests never spend credits."""

import tempfile
import time
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

import cv2
import numpy as np

from backend import distance
from backend.assist import Assistant, region_from_question
from backend.config import load_config
from backend.db import DB
from backend.gaze import GazeTracker
from backend.muse_client import MuseClient, MuseUnavailable, encode_image, load_key
from backend.streams import resolve_sample
from backend.vision import Detection, Detector, quick_answer


def fake_response(text="A laptop is ahead of you, about an arm's length away.", pt=320, ct=110, rt=80):
    return {"model": "muse-spark-1.3", "choices": [{"message": {"content": text}}],
            "usage": {"prompt_tokens": pt, "completion_tokens": ct,
                      "completion_tokens_details": {"reasoning_tokens": rt},
                      "prompt_tokens_details": {"cached_tokens": 0}}}


class Transport:
    def __init__(self, response=None, error=None):
        self.calls, self.response, self.error = [], response or fake_response(), error

    def __call__(self, url, body, headers, timeout):
        self.calls.append((url, body, headers))
        if self.error:
            raise self.error
        return self.response


def muse(db=None, transport=None, **over):
    cfg = {"muse": {"lifetime_cap_usd": 10.0, "daily_cap_usd": 5.0, "max_calls_per_min": 6, "prior_spend_usd": 0.0}}
    cfg["muse"].update(over)
    return MuseClient(cfg, db or DB(":memory:"), key="test-key", transport=transport or Transport())


class Muse(unittest.TestCase):
    def test_request_shape_and_cost(self):
        t = Transport()
        m = muse(transport=t)
        r = m.ask("What is this?", image=np.zeros((480, 640, 3), np.uint8), purpose="assist")
        url, body, headers = t.calls[0]
        self.assertEqual(url, "https://api.meta.ai/v1/chat/completions")
        self.assertEqual(headers["Authorization"], "Bearer test-key")
        self.assertEqual(body["reasoning_effort"], "minimal")
        parts = body["messages"][1]["content"]
        self.assertTrue(parts[1]["image_url"]["url"].startswith("data:image/jpeg;base64,"))
        self.assertIn("Never identify people", body["messages"][0]["content"])
        self.assertAlmostEqual(r.cost_usd, 320 * 1.25e-6 + 110 * 4.25e-6)
        u = m.usage()
        self.assertEqual(u["calls"], 1)
        self.assertAlmostEqual(u["total_usd"], r.cost_usd, places=5)

    def test_image_downscaled(self):
        b64 = encode_image(np.zeros((1080, 1920, 3), np.uint8), 512, 70)
        import base64
        img = cv2.imdecode(np.frombuffer(base64.b64decode(b64), np.uint8), cv2.IMREAD_COLOR)
        self.assertEqual(max(img.shape[:2]), 512)

    def test_lifetime_cap_blocks_before_calling(self):
        db = DB(":memory:")
        db.add_muse_call(time.time() - 86400 * 2, "assist", "m", True, cost_usd=9.9995)
        t = Transport()
        m = muse(db, t, lifetime_cap_usd=10.0)
        m.ask("one more")                                   # 9.9995 < 10: allowed, then over
        with self.assertRaises(MuseUnavailable):
            m.ask("over the cap")
        self.assertEqual(len(t.calls), 1)

    def test_prior_spend_counts(self):
        t = Transport()
        m = muse(transport=t, lifetime_cap_usd=1.0, prior_spend_usd=1.0)
        with self.assertRaises(MuseUnavailable):
            m.ask("x")
        self.assertEqual(t.calls, [])

    def test_daily_cap(self):
        db = DB(":memory:")
        db.add_muse_call(time.time(), "assist", "m", True, cost_usd=0.5)
        m = muse(db, daily_cap_usd=0.5)
        with self.assertRaises(MuseUnavailable):
            m.ask("x")

    def test_rate_limit(self):
        t = Transport()
        m = muse(transport=t, max_calls_per_min=2)
        m.ask("1")
        m.ask("2")
        with self.assertRaises(MuseUnavailable):
            m.ask("3")
        self.assertEqual(len(t.calls), 2)

    def test_no_key(self):
        m = MuseClient({"muse": {}}, DB(":memory:"), key="", transport=Transport())
        with self.assertRaises(MuseUnavailable) as cm:
            m.ask("x")
        self.assertIn("key", str(cm.exception))

    def test_http_error_logged_not_raised_raw(self):
        err = urllib.error.HTTPError("u", 429, "rate", {}, None)
        err.read = lambda *a: b"slow down"
        m = muse(transport=Transport(error=err))
        with self.assertRaises(MuseUnavailable):
            m.ask("x")
        self.assertEqual(m.usage()["failed_calls"], 1)

    def test_empty_answer_is_unavailable_but_billed(self):
        m = muse(transport=Transport(fake_response(text="")))
        with self.assertRaises(MuseUnavailable):
            m.ask("x")
        self.assertGreater(m.usage()["total_usd"], 0)

    def test_key_from_env_file(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict("os.environ", {}, clear=True):
            p = Path(tmp) / ".env"
            p.write_text("# comment\nMUSE_API_KEY=abc123\n")
            self.assertEqual(load_key(p), "abc123")


class FakeReader:
    def __init__(self, frame, ok=True):
        self.frame, self.ok = frame, ok

    def latest(self):
        return 1, self.frame, time.time()

    def status(self):
        return {"ok": self.ok}


class FakeDetector:
    def __init__(self, dets=None):
        self.dets, self.calls = dets or [], []

    def detect(self, frame, x_offset=0, full_width=None, focal_px=None, mirrored=False):
        self.calls.append((frame.shape, x_offset, full_width))
        return self.dets


class FakeVoice:
    def __init__(self, log):
        self.log = log

    def say(self, text, priority="normal", source=None):
        self.log.append(("say", text))


class Flow(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._p = mock.patch.object(distance, "CALIB_PATH", Path(self._tmp.name) / "c.json")
        self._p.start()

    def tearDown(self):
        self._p.stop()
        self._tmp.cleanup()

    def make(self, frame=None, ok=True, dets=None, transport=None, muse_client=None):
        self.log = []
        frame = np.zeros((480, 640, 3), np.uint8) if frame is None else frame
        log = self.log

        class LoggingTransport(Transport):
            def __call__(s, *a):
                log.append(("muse_call",))
                return Transport.__call__(s, *a)

        m = muse_client or muse(transport=transport or LoggingTransport())
        gaze = GazeTracker(load_config())
        a = Assistant(FakeReader(frame, ok), FakeDetector(dets), m, gaze, FakeVoice(self.log),
                      lambda k, d: self.log.append(("event", k, d.get("stage"))), focal_px=lambda w: 500.0)
        return a

    def test_local_answer_spoken_before_muse_is_called(self):
        dets = [Detection("laptop", 0.9, (250, 200, 400, 300), "ahead", 0.05, 60.0)]
        a = self.make(dets=dets)
        r = a.look("What am I looking at?", "center")
        kinds = [x[0] if x[0] != "say" else "say:" + x[1][:5] for x in self.log]
        self.assertEqual(kinds[0], "say:Ahead")
        self.assertLess(kinds.index("say:Ahead"), kinds.index("muse_call"))
        self.assertEqual(r["local_answer"], "Ahead: a laptop, about 60 centimeters away.")
        self.assertTrue(r["muse_answer"].startswith("A laptop"))
        self.assertEqual([x[2] for x in self.log if x[0] == "event"], ["local", "muse"])

    def test_region_from_gaze_and_crop(self):
        a = self.make()
        a.gaze.smoothed = "right"
        r = a.look()
        self.assertEqual((r["region"], r["region_source"]), ("right", "gaze"))
        shape, x0, full_w = a.detector.calls[0]
        self.assertEqual(x0, a.gaze.region_bounds("right", 640)[0])
        self.assertEqual(full_w, 640)
        self.assertLess(shape[1], 640)

    def test_voice_questions_always_use_fresh_eye_gaze(self):
        a = self.make()
        a.gaze.smoothed = "right"
        a.gaze.observed_at = time.time()
        r = a.look("Read the label on the left", require_gaze=True)
        self.assertEqual((r["region"], r["region_source"]), ("right", "gaze"))
        self.assertEqual(r["question"], "Read the label on the left")
        self.assertEqual(a.look("Describe everything", require_gaze=True)["region"], "right")

    def test_voice_questions_refuse_missing_stale_or_calibrating_gaze(self):
        a = self.make()
        with self.assertRaisesRegex(ValueError, "inward-facing"):
            a.look("Read that sign", require_gaze=True)
        a.gaze.smoothed = "left"
        a.gaze.observed_at = time.time() - 10
        with self.assertRaises(ValueError):
            a.look("Read that sign", require_gaze=True)
        a.gaze.observed_at = time.time()
        a.gaze.start_calibration()
        with self.assertRaises(ValueError):
            a.look("Read that sign", require_gaze=True)
        self.assertEqual(a.detector.calls, [])

    def test_question_overrides_gaze(self):
        a = self.make()
        a.gaze.smoothed = "right"
        self.assertEqual(a.look("What's on my left?")["region"], "left")
        self.assertEqual(a.look("Describe everything around me")["region"], "all")
        self.assertEqual(a.look("what is that", region_override="center")["region"], "center")

    def test_region_parsing(self):
        self.assertEqual(region_from_question("what's on my right side?"), "right")
        self.assertEqual(region_from_question("what is in front of me"), "center")
        self.assertIsNone(region_from_question("what is this"))
        with self.assertRaises(ValueError):
            self.make().look(region_override="up")

    def test_front_offline(self):
        a = self.make(ok=False)
        r = a.look()
        self.assertIn("offline", r["local_answer"])
        self.assertEqual(a.detector.calls, [])
        self.assertNotIn(("muse_call",), self.log)

    def test_muse_unavailable_keeps_local_answer(self):
        m = MuseClient({"muse": {}}, DB(":memory:"), key="", transport=Transport())
        a = self.make(dets=[Detection("cup", 0.8, (300, 200, 340, 260), "ahead", 0.01, None)], muse_client=m)
        r = a.look()
        self.assertEqual(r["local_answer"], "Ahead: a cup.")
        self.assertIsNone(r["muse_answer"])
        self.assertIn("key", r["muse_error"])
        self.assertEqual([x[0] for x in self.log].count("say"), 1)


class LocalVision(unittest.TestCase):
    """Real YOLO on the sample street photo (local, free)."""

    @classmethod
    def setUpClass(cls):
        cls.img = cv2.imread(resolve_sample("sample:bus.jpg"))
        cls.det = Detector()

    def test_detects_bus_and_people(self):
        ds = self.det.detect(self.img, focal_px=600.0)
        labels = [d.label for d in ds]
        self.assertIn("bus", labels)
        self.assertGreaterEqual(labels.count("person"), 2)
        bus = next(d for d in ds if d.label == "bus")
        self.assertEqual(bus.position, "ahead")
        self.assertTrue(100 < bus.distance_cm < 1000)

    def test_crop_positions_refer_to_full_frame(self):
        w = self.img.shape[1]
        crop = self.img[:, : int(w * 0.41)]
        ds = self.det.detect(crop, x_offset=0, full_width=w)
        self.assertTrue(any(d.label == "person" and d.position == "left" for d in ds))

    def test_mirrored_positions(self):
        w = self.img.shape[1]
        crop = self.img[:, : int(w * 0.41)]
        ds = self.det.detect(crop, x_offset=0, full_width=w, mirrored=True)
        self.assertTrue(any(d.label == "person" and d.position == "right" for d in ds))

    def test_quick_answer_wording(self):
        d = [Detection("bus", .9, (0, 0, 1, 1), "ahead", .4, 361), Detection("person", .9, (0, 0, 1, 1), "left", .1, 213),
             Detection("person", .9, (0, 0, 1, 1), "right", .1, 222)]
        self.assertEqual(quick_answer(d, "all"), "I see a bus, about 4 meters away, and 2 people.")
        self.assertEqual(quick_answer([], "left"), "On your left, nothing I recognize.")
        self.assertEqual(quick_answer([], None), "I don't see anything I recognize.")


if __name__ == "__main__":
    unittest.main()
