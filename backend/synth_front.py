"""DEV stand-in for the FRONT camera: a 5-minute scripted day in miniature.

    0-40 s     phone at 25 cm         close-up (phone threshold 30 cm)
    40-100 s   laptop at 45 cm        close-up (laptop threshold 50 cm)
    100-160 s  nothing, indoors       heads-up after 20 s
    160-260 s  nothing, outdoors      heads-up continues; outside after 60 s
    260-300 s  laptop at 80 cm        near-work in view but not close

The "synthetic-front" camera source draws these scenes; ScriptedDetector returns the
matching YOLO-style detections (boxes sized from the distance, so the distance math
runs for real) and sensor() returns exposure/gain like the OV2640 would. Real YOLO is
not used here because drawn rectangles are not laptops.
"""

import math
import time

import cv2
import numpy as np

from backend.nearwork import NEAR_CLASSES
from backend.vision import Detection

W, H = 320, 240
PHASES = [  # (until_s, label or None, distance_cm, outdoor)
    (40, "cell phone", 25.0, False),
    (100, "laptop", 45.0, False),
    (160, None, None, False),
    (260, None, None, True),
    (300, "laptop", 80.0, False),
]
CYCLE_S = PHASES[-1][0]
HFOV = 65


class SynthFront:
    def __init__(self, t0=None, speed=1.0):
        self.t0 = t0 if t0 is not None else time.time()
        self.speed = speed

    def phase(self, t=None):
        s = ((t or time.time()) - self.t0) * self.speed % CYCLE_S
        for until, label, dist, outdoor in PHASES:
            if s < until:
                return {"label": label, "distance_cm": dist, "outdoor": outdoor, "phase_s": s}
        return {"label": None, "distance_cm": None, "outdoor": False, "phase_s": s}

    def box(self, label, dist):
        """Box (x0, y0, x1, y1) whose longest side matches `dist` with the default lens model."""
        k = 0.5 / math.tan(math.radians(HFOV) / 2) * NEAR_CLASSES[label][1]
        longest = min(W - 2, k / dist * W)
        if label == "cell phone":                       # portrait
            h, w = longest, longest * 0.5
        else:
            w, h = longest, longest * 0.65
        cx, cy = W / 2, H / 2 + 20
        return (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)

    def frame(self, t=None):
        p = self.phase(t)
        img = np.zeros((H, W, 3), np.uint8)
        if p["outdoor"]:
            img[: H // 2] = (235, 190, 120)             # sky (BGR)
            img[H // 2:] = (70, 140, 80)                # grass
        else:
            img[:] = (150, 170, 190)                    # indoor wall
        if p["label"]:
            x0, y0, x1, y1 = (int(v) for v in self.box(p["label"], p["distance_cm"]))
            cv2.rectangle(img, (x0, y0), (x1, y1), (40, 40, 40), -1)
            cv2.rectangle(img, (x0 + 4, y0 + 4), (x1 - 4, y1 - 4), (200, 160, 90), -1)   # screen
            cv2.putText(img, NEAR_CLASSES[p["label"]][0], (x0 + 6, y0 + 20), cv2.FONT_HERSHEY_SIMPLEX, 0.5,
                        (255, 255, 255), 1)
        cv2.putText(img, f"DEV front {p['phase_s']:5.0f}s", (6, H - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (0, 0, 0), 1)
        return img

    def sensor(self, t=None):
        """OV2640-like auto exposure: long exposure + gain indoors, short + none outdoors."""
        if self.phase(t)["outdoor"]:
            return {"exposure_lines": 30, "gain": 1.0}
        return {"exposure_lines": 600, "gain": 4.0}


class ScriptedDetector:
    """detect() -> the scripted near-work object as a YOLO-style Detection."""

    def __init__(self, synth):
        self.synth = synth

    def detect(self, frame, **_):
        p = self.synth.phase()
        if not p["label"]:
            return []
        box = self.synth.box(p["label"], p["distance_cm"])
        area = (box[2] - box[0]) * (box[3] - box[1]) / (W * H)
        return [Detection(p["label"], 0.9, box, "ahead", area, p["distance_cm"])]


_shared = None


def shared():
    """One SynthFront per process, so the stream, the detector and sensor() agree."""
    global _shared
    if _shared is None:
        _shared = SynthFront()
    return _shared


class SynthFrontSource:
    """Endless frames for streams.py's "synthetic-front" source."""

    def __next__(self):
        return shared().frame()
