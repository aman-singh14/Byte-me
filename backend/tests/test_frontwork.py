"""FRONT camera logic: close-up sessions, heads-up, outdoor detection, near-work distance,
eye extras (partial blinks, low-blink stretches), camera discovery and rings/points."""

import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

from backend import distance
from backend.db import DB
from backend.discovery import CameraDirectory, parse_hello
from backend.eye_tracking import BlinkSquintDetector, LowBlinkMonitor
from backend.nearwork import CloseupTracker, HeadsUpTracker, NearWorkEstimator
from backend.outdoor import OutdoorDetector, SensorPoller, gain_from_ov2640, scene_brightness
from backend.rings import DAY, Rings, closeup_summary, day_start
from backend.vision import Detection


class TempCalib(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._p = mock.patch.object(distance, "CALIB_PATH", Path(self._tmp.name) / "c.json")
        self._p.start()

    def tearDown(self):
        self._p.stop()
        self._tmp.cleanup()


def run_closeup(tr, samples, dt=1 / 3):
    """samples: list of (obj, dist, close) per front frame at 3 fps. Returns finished sessions."""
    done, t = [], 0.0
    for obj, dist, close in samples:
        d, _ = tr.update(t, obj, dist, close)
        done += d
        t += dt
    return done, t


class Closeup(unittest.TestCase):
    def test_missed_frames_do_not_split(self):
        tr = CloseupTracker(gap_s=5, min_s=10)
        phone = [("phone", 25.0, True)] * 30                  # 10 s
        gap = [(None, None, False)] * 9                        # 3 s of missed detections
        done, t = run_closeup(tr, phone + gap + phone + [(None, None, False)] * 30)
        self.assertEqual(len(done), 1)
        self.assertGreater(done[0]["end"] - done[0]["start"], 22)
        self.assertEqual(done[0]["object"], "phone")
        self.assertEqual((done[0]["min_cm"], done[0]["avg_cm"]), (25.0, 25.0))

    def test_long_gap_splits(self):
        tr = CloseupTracker(gap_s=5, min_s=10)
        phone = [("phone", 25.0, True)] * 36
        done, _ = run_closeup(tr, phone + [(None, None, False)] * 24 + phone + [(None, None, False)] * 24)
        self.assertEqual(len(done), 2)

    def test_glance_is_not_a_session(self):
        tr = CloseupTracker(gap_s=5, min_s=10)
        done, _ = run_closeup(tr, [("phone", 20.0, True)] * 9 + [(None, None, False)] * 30)
        self.assertEqual(done, [])

    def test_far_object_is_not_closeup(self):
        tr = CloseupTracker()
        done, _ = run_closeup(tr, [("laptop", 80.0, False)] * 90)
        self.assertEqual(done, [])
        self.assertIsNone(tr.open_session(30))

    def test_object_switch_splits(self):
        tr = CloseupTracker(gap_s=5, switch_s=5, min_s=10)
        done, t = run_closeup(tr, [("phone", 25.0, True)] * 45 + [("laptop", 45.0, True)] * 45)
        done += tr.flush(t)
        self.assertEqual([s["object"] for s in done], ["phone", "laptop"])
        self.assertAlmostEqual(done[0]["end"], done[1]["start"], delta=0.01)

    def test_distance_stats(self):
        tr = CloseupTracker(min_s=1)
        done, t = run_closeup(tr, [("book", d, True) for d in (20.0, 24.0, 28.0)] * 5)
        done += tr.flush(t)
        self.assertEqual(done[0]["min_cm"], 20.0)
        self.assertAlmostEqual(done[0]["avg_cm"], 24.0)


class HeadsUp(unittest.TestCase):
    def test_counts_after_min_s_from_last_nearwork(self):
        h = HeadsUpTracker(min_s=20)
        h.update(0, nearwork=True)
        for t in range(1, 25):
            h.update(t, nearwork=False)
        self.assertEqual(h.active(24)["start"], 0)            # the whole stretch counts
        done = h.update(30, nearwork=True)
        self.assertEqual(done, {"start": 0, "end": 30})
        self.assertIsNone(h.active(31))

    def test_short_look_away_is_not_heads_up(self):
        h = HeadsUpTracker(min_s=20)
        h.update(0, True)
        for t in range(1, 15):
            self.assertIsNone(h.update(t, False))
        self.assertIsNone(h.update(15, True))
        self.assertIsNone(h.active(15))

    def test_not_worn_does_not_count(self):
        h = HeadsUpTracker(min_s=20)
        for t in range(0, 60):
            h.update(t, nearwork=False, worn=False)
        self.assertIsNone(h.active(60))

    def test_taking_glasses_off_ends_stretch(self):
        h = HeadsUpTracker(min_s=20)
        for t in range(0, 40):
            h.update(t, nearwork=False)
        self.assertEqual(h.update(40, nearwork=False, worn=False), {"start": 0, "end": 40})


INDOOR = {"exposure_lines": 600, "gain": 4.0}
OUTDOOR = {"exposure_lines": 30, "gain": 1.0}


def frame(luma=120, sky=False):
    img = np.full((240, 320, 3), luma, np.uint8)
    if sky:
        img[:80] = (235, 190, 120)
    return img


class Outdoor(TempCalib):
    def det(self, **over):
        cfg = {"outdoor": {"hold_s": 60, "threshold_log": 0.0, "hysteresis_log": 0.25, **over}}
        return OutdoorDetector(cfg)

    def feed(self, d, sensor, seconds, t0=0.0, img=None):
        evs = []
        for i in range(int(seconds)):
            ev = d.update(t0 + i, img if img is not None else frame(), sensor)
            if ev:
                evs.append(ev)
        return evs, t0 + seconds

    def test_exposure_normalization(self):
        # Same picture brightness (auto exposure), very different scenes.
        self.assertLess(scene_brightness(120, **INDOOR), -1.0)
        self.assertGreater(scene_brightness(120, **OUTDOOR), 0.5)
        self.assertIsNone(scene_brightness(120, None, 2.0))

    def test_ov2640_gain_register(self):
        self.assertEqual(gain_from_ov2640(0x00), 1.0)
        self.assertEqual(gain_from_ov2640(0x10), 2.0)
        self.assertEqual(gain_from_ov2640(0x30), 4.0)
        self.assertAlmostEqual(gain_from_ov2640(0x08), 1.5)
        p = SensorPoller.parse({"aec_lines": 300, "gain_reg": 0x10})
        self.assertEqual((p["exposure_lines"], p["gain"]), (300, 2.0))

    def test_needs_60_s_to_switch(self):
        d = self.det()
        evs, t = self.feed(d, OUTDOOR, 59)
        self.assertEqual(evs, [])
        self.assertFalse(d.outside)
        evs, t = self.feed(d, OUTDOOR, 3, t)
        self.assertEqual(evs[0][0], "outside_start")
        self.assertEqual(evs[0][1], 0)                         # the stretch began when it got bright
        self.assertTrue(d.outside)

    def test_hysteresis_and_brief_dips(self):
        d = self.det()
        _, t = self.feed(d, OUTDOOR, 70)
        evs, t = self.feed(d, INDOOR, 30, t)                    # 30 s in a shop: still "outside"
        self.assertEqual(evs, [])
        evs, t = self.feed(d, OUTDOOR, 10, t)
        evs, t = self.feed(d, INDOOR, 65, t)
        self.assertEqual(evs[0][0], "outside_end")
        self.assertFalse(d.outside)

    def test_band_prevents_flicker(self):
        d = self.det()
        near = {"exposure_lines": 120, "gain": 1.0}            # log10(120/120) = 0: on the threshold
        evs, _ = self.feed(d, near, 200)
        self.assertEqual(evs, [])

    def test_no_sensor_no_decision(self):
        d = self.det()
        evs, _ = self.feed(d, None, 120, img=frame(250))        # very bright raw pixels, no exposure data
        self.assertEqual(evs, [])
        self.assertFalse(d.last["sensor_ok"])

    def test_sky_lowers_threshold(self):
        d = self.det()
        d.update(0, frame(sky=True), OUTDOOR)
        self.assertLess(d.last["threshold_log"], 0.0)

    def test_calibration_midpoint(self):
        d = self.det()
        d.update(0, frame(), INDOOR)
        d.calibrate("indoor")
        d.update(1, frame(), OUTDOOR)
        r = d.calibrate("outdoor")
        mid = (scene_brightness(120, **INDOOR) + scene_brightness(120, **OUTDOOR)) / 2
        self.assertAlmostEqual(r["threshold_log"], mid, places=2)
        self.assertAlmostEqual(OutdoorDetector({}).threshold, mid, places=2)   # persisted

    def test_manual_override(self):
        d = self.det()
        d.manual = True
        evs, _ = self.feed(d, None, 2)
        self.assertEqual(evs[0][0], "outside_start")


class FakeDet:
    def __init__(self, dets):
        self.dets = dets

    def detect(self, frame, **_):
        return self.dets


class NearWork(TempCalib):
    def test_distance_from_size_and_thresholds(self):
        phone = Detection("cell phone", 0.9, (130, 40, 190, 200), "ahead", 0.1)   # 160 px tall in 320
        est = NearWorkEstimator({}, FakeDet([phone, Detection("person", 0.9, (0, 0, 10, 10), "left", 0.01)]))
        s = est.process(np.zeros((240, 320, 3), np.uint8), 0)
        self.assertEqual(s["nearwork_object"], "phone")
        self.assertEqual(len(s["nearwork_objects"]), 1)        # person is not near-work
        self.assertTrue(10 < s["nearwork_distance_cm"] < 40)
        self.assertEqual(s["nearwork_threshold_cm"], 30)

    def test_calibration_changes_distance(self):
        laptop = Detection("laptop", 0.9, (60, 60, 260, 190), "ahead", 0.3)
        est = NearWorkEstimator({}, FakeDet([laptop]))
        img = np.zeros((240, 320, 3), np.uint8)
        est.process(img, 0)
        est.calibrate("laptop", 60.0)
        self.assertAlmostEqual(est.process(img, 1)["nearwork_distance_cm"], 60.0, delta=0.1)
        again = NearWorkEstimator({}, FakeDet([laptop]))       # calibration persisted
        self.assertAlmostEqual(again.process(img, 2)["nearwork_distance_cm"], 60.0, delta=0.1)
        with self.assertRaises(ValueError):
            est.calibrate("phone", 30)                         # no phone in view

    def test_resolution_independent(self):
        k = NearWorkEstimator({}, FakeDet([Detection("book", .9, (0, 0, 100, 60), "ahead", .1)]))
        small = k.process(np.zeros((240, 320, 3), np.uint8), 0)["nearwork_distance_cm"]
        k.detector = FakeDet([Detection("book", .9, (0, 0, 200, 120), "ahead", .1)])
        big = k.process(np.zeros((480, 640, 3), np.uint8), 0)["nearwork_distance_cm"]
        self.assertAlmostEqual(small, big, places=3)


class FrontPreview(TempCalib):
    def test_boxes_are_drawn_green_orange_and_grey(self):
        from backend.front import FrontAnalyzer
        dets = [Detection("cell phone", 0.9, (130, 30, 190, 210), "ahead", 0.1),     # close
                Detection("laptop", 0.9, (10, 150, 60, 175), "left", 0.01),           # small = far
                Detection("person", 0.9, (200, 20, 300, 230), "right", 0.2)]          # not near-work
        fa = FrontAnalyzer({}, DB(":memory:"), FakeDet(dets), Rings({}, DB(":memory:")), lambda *a: None,
                           worn_fn=lambda: True, sensor_fn=lambda: None)
        img = np.zeros((240, 320, 3), np.uint8)
        fa.process(img, 0.0)
        out = fa.annotate(img.copy())
        def has(color, region):
            x0, y0, x1, y1 = region
            return bool((np.abs(out[y0:y1, x0:x1].astype(int) - color).sum(2) < 30).any())
        self.assertTrue(has((0, 140, 255), (125, 25, 195, 215)))     # phone: orange (close)
        self.assertTrue(has((0, 200, 0), (5, 145, 65, 180)))         # laptop: green
        self.assertTrue(has((150, 150, 150), (195, 15, 305, 235)))   # person: grey, ignored


class EyeExtras(unittest.TestCase):
    def feed(self, det, seq, t=0.0, dt=1 / 25):
        evs = []
        for v in seq:
            evs += det.update(v, t)
            t += dt
        return evs, t

    def test_partial_blink(self):
        det = BlinkSquintDetector(calibration_s=1.0, default_baseline=1.0)
        _, t = self.feed(det, [1.0] * 50)
        evs, _ = self.feed(det, [1.0] * 5 + [0.75] * 4 + [1.0] * 5, t)     # dips to 75%, 160 ms
        self.assertEqual([e[0] for e in evs], ["partial_blink"])
        self.assertEqual(det.partial_blinks, 1)

    def test_full_blink_is_not_partial(self):
        det = BlinkSquintDetector(calibration_s=1.0, default_baseline=1.0)
        _, t = self.feed(det, [1.0] * 50)
        evs, _ = self.feed(det, [1.0] * 5 + [0.75, 0.3, 0.0, 0.3, 0.75] + [1.0] * 5, t)
        self.assertEqual([e[0] for e in evs], ["blink"])

    def test_squint_is_not_partial(self):
        det = BlinkSquintDetector(calibration_s=1.0, default_baseline=1.0)
        _, t = self.feed(det, [1.0] * 50)
        evs, _ = self.feed(det, [0.75] * 75 + [1.0] * 5, t)                # 3 s
        self.assertNotIn("partial_blink", [e[0] for e in evs])

    def test_low_blink_stretch(self):
        m = LowBlinkMonitor(below=10, min_s=300)
        evs = [m.update(t, 6.0, True) for t in range(0, 301, 5)]
        starts = [e for e in evs if e]
        self.assertEqual(starts, [("low_blink_start", 0)])
        self.assertEqual(m.update(400, 14.0, True), ("low_blink_end", {"start": 0, "end": 400}))

    def test_short_low_blink_not_flagged(self):
        m = LowBlinkMonitor(below=10, min_s=300)
        evs = [m.update(t, 6.0, True) for t in range(0, 200, 5)] + [m.update(200, 15.0, True)]
        self.assertEqual([e for e in evs if e], [])


class Discovery(unittest.TestCase):
    def cfg(self):
        return {"cameras": {"eye": {"source": "http://eye-cam.local:81/stream", "static_ip": "172.20.10.9"},
                            "front": {"source": "http://front-cam.local:81/stream"}}}

    def hello(self, role="eye", ip="172.20.10.3"):
        return json.dumps({"t": "cam_hello", "role": role, "ip": ip, "stream_port": 81, "http_port": 80}).encode()

    def test_parse(self):
        self.assertEqual(parse_hello(self.hello())["ip"], "172.20.10.3")
        for bad in (b"junk", b'{"t":"hello","id":"frame"}', self.hello(role="rear"), self.hello(ip="999.1.1.1"),
                    self.hello(ip="eye-cam.local")):
            self.assertIsNone(parse_hello(bad))

    def test_candidates_order_and_freshness(self):
        d = CameraDirectory(self.cfg(), fresh_s=10)
        self.assertEqual(d.candidates("eye", now=0), ["http://eye-cam.local:81/stream",
                                                       "http://172.20.10.9:81/stream"])
        d.handle(self.hello(), now=100)
        self.assertEqual(d.stream_url("eye", now=105), "http://172.20.10.3:81/stream")
        self.assertEqual(d.http_base("eye", now=105), "http://172.20.10.3")
        self.assertEqual(d.stream_url("eye", now=200), "http://eye-cam.local:81/stream")   # stale
        self.assertEqual(d.http_base("front", now=0), "http://front-cam.local")

    def test_on_change_switches_reader(self):
        moved = []
        d = CameraDirectory(self.cfg(), on_change=lambda r, u: moved.append((r, u)))
        d.handle(self.hello(), now=1)
        d.handle(self.hello(), now=3)                          # same IP: no change
        d.handle(self.hello(ip="172.20.10.4"), now=5)          # new IP after a reconnect
        self.assertEqual(moved, [("eye", "http://172.20.10.3:81/stream"), ("eye", "http://172.20.10.4:81/stream")])

    def test_runtime_points_reader_at_announced_ip(self):
        from backend.main import Runtime

        class Reader:
            source = None

            def set_source(self, s):
                self.source = s

        fake = mock.Mock()
        fake.streams.cameras = {"eye": Reader()}
        Runtime._camera_moved(fake, "eye", "http://172.20.10.3:81/stream")
        self.assertEqual(fake.streams.cameras["eye"].source, "http://172.20.10.3:81/stream")


class RingsAndPoints(unittest.TestCase):
    def setUp(self):
        self.db = DB(":memory:")
        self.rings = Rings({"rings": {"heads_up_goal_min": 60, "outside_goal_min": 120}}, self.db)
        self.d0 = day_start(time.time())

    def test_minutes_breaks_points(self):
        t = self.d0 + 3600
        self.rings.stretch_ended("heads_up", t, t + 600)                # 10 min break: +5
        self.rings.stretch_ended("heads_up", t + 700, t + 730)          # 30 s: no points
        self.rings.stretch_ended("outside", t + 1000, t + 1000 + 26 * 60)   # 26 min: +5
        day = self.rings.day(self.d0, now=t + 4000)
        self.assertAlmostEqual(day["heads_up"]["minutes"], 10.5)
        self.assertEqual(day["heads_up"]["breaks"], 2)
        self.assertAlmostEqual(day["outside"]["minutes"], 26.0)
        self.assertEqual(day["points"], 10)

    def test_ring_complete_bonus_once(self):
        t = self.d0 + 3600
        self.rings.stretch_ended("heads_up", t, t + 61 * 60)            # over the 60 min goal
        self.rings.check_goals(t + 61 * 60 + 5)
        kinds = [p["kind"] for p in self.db.points(self.d0)]
        self.assertEqual(kinds.count("heads_up_ring"), 1)

    def test_open_stretch_counts_until_now(self):
        now = time.time()
        self.rings.stretch_started("heads_up", now - 300)
        d = self.rings.today(now)
        self.assertAlmostEqual(d["heads_up"]["minutes"], 5.0, delta=0.1)
        self.assertTrue(d["heads_up"]["active"])

    def test_history_days(self):
        t = self.d0 - DAY + 3600
        self.rings.stretch_ended("outside", t, t + 1800)
        h = self.rings.history(3)
        self.assertEqual(len(h), 3)
        self.assertAlmostEqual(h[1]["outside"]["minutes"], 30.0)
        self.assertEqual(h[2]["outside"]["minutes"], 0)

    def test_closeup_summary(self):
        t = self.d0 + 3600
        self.db.add_closeup_session({"start": t, "end": t + 600, "object": "phone", "min_cm": 20, "avg_cm": 25})
        self.db.add_closeup_session({"start": t + 900, "end": t + 1500, "object": "laptop", "min_cm": 40, "avg_cm": 45})
        s = closeup_summary(self.db, self.d0, now=t + 2000,
                            open_session={"start": t + 1800, "object": "phone"})
        self.assertEqual(s["total_min"], 23.3)
        self.assertEqual(s["by_object"], {"phone": 13.3, "laptop": 10.0})
        self.assertTrue(s["sessions"][-1]["open"])


if __name__ == "__main__":
    unittest.main()
