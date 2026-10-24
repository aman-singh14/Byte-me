"""DB history buckets, recommendation rules, and app/eye correlation on seeded data."""

import unittest

from backend import screentime
from backend.db import DB
from backend.main import Session
from backend.recommendations import recommend

CFG = {"recommendations": {"low_blink_per_min": 10, "too_close_minutes": 5, "session_minutes": 20}}
NOW = 1_800_000_000.0


def seeded(close=False, rate=15.0, minutes=10):
    db = DB(":memory:")
    for i in range(minutes * 60):
        db.add_sample(NOW - minutes * 60 + i, rate, 0.3, False, 40.0 if close else 60.0, close, True)
    return db


def ids(recs):
    return [r["id"] for r in recs]


class Storage(unittest.TestCase):
    def test_history_buckets(self):
        db = seeded(minutes=10)
        db.add_event(NOW - 30, "blink")
        db.add_event(NOW - 20, "blink")
        h = db.history("hour", now=NOW)
        self.assertEqual(h["bucket_s"], 60)
        self.assertIn(len(h["points"]), (10, 11))
        self.assertEqual(sum(p["blinks"] for p in h["points"]), 2)
        self.assertEqual(h["points"][0]["distance_cm"], 60.0)

    def test_summary(self):
        db = seeded(close=True, minutes=6)
        db.add_event(NOW - 5, "alert", {"side": "L"})
        s = db.summary(NOW - 3600)
        self.assertEqual(s["too_close_min"], 6.0)
        self.assertEqual(s["rear_alerts"], 1)

    def test_events_filter_and_json(self):
        db = DB(":memory:")
        db.add_event(NOW, "alert", {"side": "R", "k": 5000})
        db.add_event(NOW, "blink")
        rows = db.events(["alert"])
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["data"]["side"], "R")


class Recommendations(unittest.TestCase):
    def live(self, **kw):
        d = {"blink_rate": 16, "eye_detected": True, "too_close": False, "session_min": 5, "threshold_cm": 50}
        d.update(kw)
        return d

    def test_all_good(self):
        self.assertEqual(ids(recommend(self.live(), seeded(), CFG, NOW)), ["all_good"])

    def test_low_blink(self):
        self.assertIn("blink_more", ids(recommend(self.live(blink_rate=6), seeded(), CFG, NOW)))

    def test_too_close_for_minutes(self):
        recs = recommend(self.live(), seeded(close=True, minutes=6), CFG, NOW)
        self.assertEqual(recs[0]["id"], "move_back")

    def test_20_20_20(self):
        self.assertIn("20_20_20", ids(recommend(self.live(session_min=25), seeded(), CFG, NOW)))

    def test_squints(self):
        db = seeded()
        for i in range(3):
            db.add_event(NOW - 60 * i, "squint_start")
        self.assertIn("squinting", ids(recommend(self.live(), db, CFG, NOW)))


class Correlation(unittest.TestCase):
    def test_blink_rate_per_app(self):
        db = DB(":memory:")
        t0 = NOW - 600
        db.add_app_usage(t0, t0 + 299, "Xcode", "coding", "mac")
        db.add_app_usage(t0 + 300, t0 + 599, "Slack", "messaging", "mac")
        for i in range(600):
            db.add_sample(t0 + i, 6.0 if i < 300 else 18.0, 0.3, False, 55.0, False, True)
        c = screentime.correlate(db, t0 - 1)
        by_app = {r["name"]: r for r in c["by_app"]}
        self.assertAlmostEqual(by_app["Xcode"]["avg_blink_rate"], 6.0)
        self.assertAlmostEqual(by_app["Slack"]["avg_blink_rate"], 18.0)
        self.assertEqual(c["by_app"][0]["name"], "Xcode")     # lowest blink rate first
        self.assertIn("Xcode", c["insight"])

    def test_ios_mock_is_labelled(self):
        m = screentime.ios_mock_today()
        self.assertTrue(m["mock"])
        self.assertTrue(any(f["category"] == "social" for f in m["flags"]))


class SessionTracking(unittest.TestCase):
    def test_break_resets_session(self):
        s = Session(break_s=20)
        for t in range(0, 600, 1):
            s.update(True, t)
        self.assertAlmostEqual(s.minutes(600), 10, delta=0.1)
        self.assertEqual(s.update(True, 630), ("break", 31))
        self.assertAlmostEqual(s.minutes(631), 1 / 60, delta=0.01)


if __name__ == "__main__":
    unittest.main()
