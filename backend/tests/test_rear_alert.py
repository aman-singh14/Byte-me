"""RearAlert on lgmd.py's synthetic clips: fires and speaks on approach, respects cooldown."""

import unittest

import cv2

import lgmd
from backend.rear_alert import RearAlert


class FakeSpeaker:
    mode = "fake"

    def __init__(self):
        self.said = []

    def say(self, text):
        self.said.append(text)


def run(frames, cfg=None, dt=1 / 15):
    speaker = FakeSpeaker()
    alert = RearAlert(cfg or {"rear": {"cooldown_s": 4.0}}, speaker=speaker)
    events = []
    for i, f in enumerate(frames):
        big = cv2.resize(f, (640, 480), interpolation=cv2.INTER_NEAREST)   # preprocess brings it back
        events += alert.process(cv2.cvtColor(big, cv2.COLOR_GRAY2BGR), i * dt)[1]
    return alert, events, speaker


class RearAlertTests(unittest.TestCase):
    def test_approach_speaks_once_with_side(self):
        alert, events, speaker = run(lgmd.synth_approach())
        self.assertGreater(alert.fires, 0)
        self.assertEqual(len(events), 1)                      # cooldown: one warning per approach
        self.assertEqual(events[0][1]["side"], "C")           # centered square = straight behind
        self.assertEqual(speaker.said, ["Object approaching from behind"])

    def test_same_fire_frames_as_reference(self):
        frames = lgmd.synth_approach()
        ref = [o.fire for o in lgmd.run_clip(frames, lgmd.Params())]
        alert, _, _ = run(frames)
        self.assertEqual(alert.fires, sum(ref))

    def test_recede_and_sideways_silent(self):
        for frames in (lgmd.synth_recede(), lgmd.synth_sideways(), lgmd.synth_brightness_jump()):
            _, events, speaker = run(frames)
            self.assertEqual(events, [])
            self.assertEqual(speaker.said, [])

    def test_cooldown_expires(self):
        clip = list(lgmd.synth_approach())
        # Two approaches 10 s apart at 15 fps (pad with the background frame).
        frames = clip + [clip[0]] * 150 + clip
        _, events, _ = run(frames)
        self.assertEqual(len(events), 2)


if __name__ == "__main__":
    unittest.main()
