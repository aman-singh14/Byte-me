"""FPGA rear path: warn on EVENT before any classification, then the specific follow-up.
Partial/dropped clips, CRC errors, cooldown, sides, and the UDP transport."""

import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from backend.db import DB
from backend.rear import protocol as p
from backend.rear import scenes
from backend.rear.service import RearService
from backend.vision import Detector

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import mock_fpga  # noqa: E402

DETECTOR = Detector()


class Log:
    def __init__(self):
        self.items, self.lock = [], threading.Lock()

    def add(self, *x):
        with self.lock:
            self.items.append((time.time(),) + x)

    def kinds(self):
        return [x[1] for x in self.items]

    def said(self):
        return [(x[2], x[3]) for x in self.items if x[1] == "say"]


class FakeVoice:
    def __init__(self, log):
        self.log = log

    def say(self, text, priority="normal", source=None):
        self.log.add("say", priority, text)


class CountingDetector:
    """Wraps the real detector and logs when classification starts."""

    def __init__(self, log):
        self.log = log

    def detect(self, frame, **kw):
        self.log.add("detect")
        return DETECTOR.detect(frame, **kw)


def service(log, **fpga):
    cfg = {"rear": {"cooldown_s": 4.0, "fpga": {"transports": [], "save_clips": False, "gap_timeout_s": 0.3,
                                                **fpga}}}
    svc = RearService(cfg, FakeVoice(log), lambda k, d: log.add("event", k, d), CountingDetector(log),
                      db=DB(":memory:"))
    return svc.start()


def packets(scene="person", side="left", event_id=1):
    fn = scenes.SCENES[scene]
    frames = fn(side) if scene in ("person", "recede") else fn()
    return mock_fpga.build_packets(frames, event_id)


def wait_for(cond, timeout=10.0):
    t = time.time() + timeout
    while time.time() < t:
        if cond():
            return True
        time.sleep(0.02)
    return False


def result(log):
    r = [x[3] for x in log.items if x[1] == "event" and x[2] == "rear_result"]
    return r[0] if r else None


class Ordering(unittest.TestCase):
    def test_warning_spoken_on_event_before_any_frame_or_classification(self):
        log = Log()
        svc = service(log)
        pk = packets()
        t0 = time.time()
        svc.feed_bytes(pk[0])                                   # EVENT only
        self.assertEqual(log.said()[0][0], "urgent")
        self.assertTrue(log.said()[0][1].startswith("Something approaching from behind"))
        self.assertLess(log.items[0][0] - t0, 0.05)              # spoken within 50 ms of the EVENT
        self.assertNotIn("detect", log.kinds())                  # nothing classified yet
        svc.feed_bytes(b"".join(pk[1:]))
        self.assertTrue(wait_for(lambda: result(log)))
        kinds = log.kinds()
        self.assertLess(kinds.index("say"), kinds.index("detect"))
        svc.stop()

    def test_dangerous_follow_up(self):
        log = Log()
        svc = service(log)
        svc.feed_bytes(b"".join(packets("person", "left")))
        self.assertTrue(wait_for(lambda: result(log)))
        r = result(log)
        self.assertTrue(r["dangerous"])
        self.assertEqual((r["label"], r["side"]), ("person", "L"))
        self.assertTrue(r["complete"] and r["crc_ok"])
        self.assertEqual(log.said()[-1], ("urgent", "Person approaching fast, on your left."))
        alerts = svc.db.events(["alert"])
        self.assertTrue(alerts[0]["data"]["dangerous"])
        svc.stop()

    def test_generic_warning_names_side_from_region(self):
        log = Log()
        svc = service(log)
        svc.feed_bytes(packets("person", "left")[0])            # LGMD fires in image-right = wearer left
        self.assertEqual(log.said()[0][1], "Something approaching from behind, on your left")
        svc.stop()


class EventSide(unittest.TestCase):
    def test_side_only_when_clear(self):
        from backend.rear.service import event_side
        clear = p.Event(t_ms=0, k_peak=10, k_left=900, k_center=100, k_right=0)
        mixed = p.Event(t_ms=0, k_peak=10, k_left=400, k_center=350, k_right=250)
        region_only = p.Event(t_ms=0, k_peak=10, region=p.REGION_RIGHT)
        self.assertEqual(event_side(clear), "R")          # image left -> wearer right
        self.assertIsNone(event_side(mixed))
        self.assertEqual(event_side(region_only), "L")


class FalseAlarms(unittest.TestCase):
    def test_leaves_never_mind(self):
        log = Log()
        svc = service(log)
        svc.feed_bytes(b"".join(packets("leaves")))
        self.assertTrue(wait_for(lambda: result(log)))
        self.assertEqual(result(log)["kind"], "nothing")
        self.assertEqual(log.said()[-1], ("normal", "Never mind, nothing dangerous behind you."))
        svc.stop()

    def test_false_alarm_can_stay_quiet(self):
        log = Log()
        svc = service(log, say_false_alarm=False)
        svc.feed_bytes(b"".join(packets("leaves")))
        self.assertTrue(wait_for(lambda: result(log)))
        self.assertEqual(len(log.said()), 1)                     # only the generic warning
        svc.stop()

    def test_receding_not_dangerous(self):
        log = Log()
        svc = service(log)
        svc.feed_bytes(b"".join(packets("recede", "right")))
        self.assertTrue(wait_for(lambda: result(log)))
        self.assertFalse(result(log)["dangerous"])
        svc.stop()


class Robustness(unittest.TestCase):
    def test_missing_end_and_dropped_chunks_still_classified(self):
        log = Log()
        svc = service(log)
        pk = packets("person", "right")
        kept = [x for i, x in enumerate(pk[:-1]) if i % 7 != 3]  # lose ~1 in 7 chunks and the END
        svc.feed_bytes(b"".join(kept))
        self.assertTrue(wait_for(lambda: result(log), 5))        # gap timeout delivers it
        r = result(log)
        self.assertFalse(r["complete"])
        self.assertIsNone(r["crc_ok"])
        self.assertGreater(svc.stats["dropped_packets"], 0)
        self.assertEqual(r["label"], "person")                   # enough frames survived
        svc.stop()

    def test_corrupt_packets_dropped_event_still_warns(self):
        log = Log()
        svc = service(log)
        pk = packets()
        bad = [bytearray(x) for x in pk]
        for i in range(5, len(bad), 11):
            bad[i][-1] ^= 0xFF                                  # break the CRC of some chunks
        svc.feed_bytes(b"".join(bytes(b) for b in bad))
        self.assertTrue(wait_for(lambda: result(log)))
        self.assertGreater(svc.stats["parse_errors"], 0)
        self.assertEqual(log.said()[0][0], "urgent")
        self.assertFalse(result(log)["complete"])
        svc.stop()

    def test_cooldown_one_generic_warning(self):
        log = Log()
        svc = service(log, say_false_alarm=False)
        svc.feed_bytes(packets("leaves", event_id=1)[0])
        svc.feed_bytes(packets("leaves", event_id=2)[0])
        generic = [s for s in log.said() if s[1].startswith("Something approaching")]
        self.assertEqual(len(generic), 1)
        svc.stop()

    def test_event_only(self):
        log = Log()
        svc = service(log)
        frames = scenes.person("left")
        svc.feed_bytes(mock_fpga.build_packets(frames, 9, event_only=True)[0])
        time.sleep(0.5)
        self.assertEqual(len(log.said()), 1)
        self.assertIsNone(result(log))
        svc.stop()


class ClassifierScenes(unittest.TestCase):
    def test_unknown_looming_object(self):
        from backend.rear.classifier import RearClassifier
        frames = scenes.square()
        clip = p.Clip(1, p.Event(t_ms=0, k_peak=9000, frame_count=len(frames)), scenes.to_payload(frames))
        r = RearClassifier(DETECTOR).classify(clip)
        self.assertEqual((r.kind, r.dangerous, r.side), ("unknown", None, "C"))
        self.assertIn("can't tell", r.text)

    def test_wearer_side_is_mirrored(self):
        from backend.rear.classifier import wearer_side
        self.assertEqual(wearer_side(0.1), "R")          # image left = wearer right (rear camera)
        self.assertEqual(wearer_side(0.9), "L")
        self.assertEqual(wearer_side(0.5), "C")
        self.assertEqual(wearer_side(0.1, flip=False), "L")


class UDPTransport(unittest.TestCase):
    def test_mock_fpga_over_udp(self):
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            probe.bind(("127.0.0.1", 0))
        except OSError:
            self.skipTest("cannot bind UDP sockets here")
        port = probe.getsockname()[1]
        probe.close()
        log = Log()
        svc = service(log, transports=["udp"], udp_port=port)
        time.sleep(0.2)
        mock_fpga.Sender("udp", "127.0.0.1", port).send(packets("person", "left"))
        self.assertTrue(wait_for(lambda: result(log)))
        self.assertTrue(result(log)["complete"])
        self.assertTrue(result(log)["dangerous"])
        svc.stop()


class Saving(unittest.TestCase):
    def test_clip_saved(self):
        import numpy as np
        log = Log()
        with tempfile.TemporaryDirectory() as tmp:
            cfg = {"rear": {"fpga": {"transports": [], "save_clips": True}}}
            svc = RearService(cfg, FakeVoice(log), lambda k, d: log.add("event", k, d), DETECTOR,
                              clips_dir=tmp).start()
            svc.feed_bytes(b"".join(packets()))
            self.assertTrue(wait_for(lambda: result(log)))
            path = Path(result(log)["clip"])
            with np.load(path) as z:
                self.assertEqual(z["frames"].shape, (30, 120, 160))
            svc.stop()


if __name__ == "__main__":
    unittest.main()
