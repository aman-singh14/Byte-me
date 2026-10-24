"""Blink, squint and pupil tracking.

Two layers, so the eye camera can change without touching anything else:

  extractor  frame -> EyeFeatures(openness, pupil)      swappable per camera
             FaceMeshEyes: webcam sees the whole face, openness = Eye Aspect Ratio
             CloseupEye:   ESP32 ~3 cm from one eye, dark-pupil threshold + ellipse fit,
                           openness = visible pupil height / width (the lid covers it)
  detector   openness over time -> blinks, blinks/min, squint      same for both

The detector only sees openness / baseline, where the baseline is the median
openness recorded during calibration (eyes open, looking normally). That ratio
means the same thing for both extractors, so the thresholds carry over.

    python -m backend.eye_tracking                 # webcam 0, live window
    python -m backend.eye_tracking --source clip.mp4 --method closeup
"""

import argparse
import collections
import statistics
import time
from dataclasses import dataclass

import cv2
import numpy as np

# Face Mesh indexes. "Right"/"left" are the subject's.
RIGHT_EYE = (33, 160, 158, 133, 153, 144)    # p1 outer corner, p2 p3 upper lid, p4 inner corner, p5 p6 lower lid
LEFT_EYE = (362, 385, 387, 263, 373, 380)
RIGHT_IRIS, LEFT_IRIS = 468, 473             # iris centers (needs the 478-point model)


@dataclass
class EyeFeatures:
    openness: float              # EAR (facemesh) or pupil h/w (closeup); 0 = closed
    pupil: tuple | None = None   # (x, y) in -1..1: x + = toward the subject's left, y + = down
    points: np.ndarray | None = None   # pixel points to draw


def ear(pts, idx):
    """Eye Aspect Ratio (Soukupova & Cech 2016): mean lid gap over eye width."""
    p1, p2, p3, p4, p5, p6 = (pts[i] for i in idx)
    width = np.linalg.norm(p1 - p4)
    if width < 1e-6:
        return 0.0
    return float((np.linalg.norm(p2 - p6) + np.linalg.norm(p3 - p5)) / (2.0 * width))


def iris_offset(pts, idx, iris):
    """Iris center relative to the eye box, each axis in -1..1."""
    corner_a, corner_b = pts[idx[0]], pts[idx[3]]
    top = (pts[idx[1]] + pts[idx[2]]) / 2
    bottom = (pts[idx[4]] + pts[idx[5]]) / 2
    c = pts[iris]
    left, right = sorted((corner_a[0], corner_b[0]))
    x = 2 * (c[0] - left) / max(right - left, 1e-6) - 1
    y = 2 * (c[1] - top[1]) / max(bottom[1] - top[1], 1e-6) - 1
    return float(np.clip(x, -1, 1)), float(np.clip(y, -1, 1))


class FaceMeshEyes:
    """Whole face in view (laptop webcam). Openness = mean EAR of both eyes."""

    name = "facemesh"

    def __init__(self, face_mesh=None):
        from backend.face import FaceMesh
        self.mesh = face_mesh or FaceMesh()
        self.last_landmarks = None   # distance.py can reuse these

    def extract(self, frame):
        pts = self.mesh.detect(frame)
        self.last_landmarks = pts
        if pts is None:
            return None
        e = (ear(pts, RIGHT_EYE) + ear(pts, LEFT_EYE)) / 2
        rx, ry = iris_offset(pts, RIGHT_EYE, RIGHT_IRIS)
        lx, ly = iris_offset(pts, LEFT_EYE, LEFT_IRIS)
        draw = pts[list(RIGHT_EYE + LEFT_EYE) + [RIGHT_IRIS, LEFT_IRIS]]
        return EyeFeatures(e, ((rx + lx) / 2, (ry + ly) / 2), draw)


class CloseupEye:
    """Camera ~3 cm from one eye (IR or plain). The pupil is the darkest blob.

    Openness is the visible pupil's height / width from an ellipse fit: about 1
    for an open eye, dropping as the lid covers the pupil, 0 when no pupil is
    found. Untested on the real eye camera yet; tune dark_offset and the area
    limits on the first footage.
    """

    name = "closeup"

    def __init__(self, dark_offset=25, min_area_frac=0.002, max_area_frac=0.25):
        self.dark_offset = dark_offset
        self.min_area_frac = min_area_frac
        self.max_area_frac = max_area_frac

    def extract(self, frame):
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
        gray = cv2.GaussianBlur(gray, (7, 7), 0)
        h, w = gray.shape
        thresh = int(gray.min()) + self.dark_offset
        _, mask = cv2.threshold(gray, thresh, 255, cv2.THRESH_BINARY_INV)
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        area_min, area_max = self.min_area_frac * h * w, self.max_area_frac * h * w
        blobs = [c for c in contours if area_min <= cv2.contourArea(c) <= area_max and len(c) >= 5]
        if not blobs:
            return EyeFeatures(0.0)   # no pupil visible: treat as closed
        # Prefer round, large blobs (eyelashes and shadows are long and thin).
        def score(c):
            (_, _), (a, b), _ = cv2.fitEllipse(c)
            return cv2.contourArea(c) * min(a, b) / max(a, b, 1e-6)
        best = max(blobs, key=score)
        (cx, cy), (a, b), angle = cv2.fitEllipse(best)
        x, y, bw, bh = cv2.boundingRect(best)
        openness = bh / max(bw, 1)
        pupil = (float(2 * cx / w - 1), float(2 * cy / h - 1))
        return EyeFeatures(float(min(openness, 1.5)), pupil, best.reshape(-1, 2).astype(np.float32))


class BlinkSquintDetector:
    """Openness over time -> blinks, blink rate, squint. Pure logic, no OpenCV."""

    def __init__(self, calibration_s=5.0, default_baseline=0.28, blink_ratio=0.65,
                 blink_min_s=0.05, blink_max_s=0.5, squint_low=0.65, squint_high=0.85,
                 squint_min_s=1.5, rate_window_s=60, **_ignored):
        self.calibration_s = calibration_s
        self.baseline = default_baseline
        self.blink_ratio = blink_ratio
        self.blink_min_s, self.blink_max_s = blink_min_s, blink_max_s
        self.squint_low, self.squint_high, self.squint_min_s = squint_low, squint_high, squint_min_s
        self.rate_window_s = rate_window_s
        self.calibrated = False
        self._calib = []
        self._calib_until = None
        self._calib_pending = True     # calibrate as soon as an eye shows up
        self._closed_since = None
        self._squint_since = None
        self.squinting = False
        self.blinks = collections.deque()   # timestamps
        self.total_blinks = 0
        self.t_start = None
        self.ratio = None

    def start_calibration(self):
        """The calibration window starts at the next sample with an eye in view."""
        self._calib = []
        self._calib_until = None
        self._calib_pending = True

    @property
    def calibrating(self):
        return self._calib_pending or self._calib_until is not None

    def update(self, openness, t):
        """Feed one sample (openness None = no face/eye). Returns a list of events:
        ("blink", duration_s), ("squint_start", None), ("squint_end", seconds)."""
        if self.t_start is None:
            self.t_start = t
        events = []
        if openness is None:
            self._closed_since = None   # a lost face is not a blink
            self.ratio = None
            return self._end_squint(t, events)

        if self._calib_pending:
            self._calib_pending = False
            self._calib_until = t + self.calibration_s
        if self._calib_until is not None:
            self._calib.append(openness)
            if t >= self._calib_until:
                self._calib_until = None
                if len(self._calib) >= 10:
                    # Drop the lowest quarter: blinks during calibration should not lower the baseline.
                    vals = sorted(self._calib)
                    self.baseline = statistics.median(vals[len(vals) // 4:])
                    self.calibrated = True
                    events.append(("calibrated", self.baseline))
                else:                   # eye was mostly out of view: try again
                    self.start_calibration()

        ratio = openness / max(self.baseline, 1e-6)
        self.ratio = ratio
        closed = ratio < self.blink_ratio
        if closed:
            if self._closed_since is None:
                self._closed_since = t
        elif self._closed_since is not None:
            dur = t - self._closed_since
            self._closed_since = None
            if self.blink_min_s <= dur <= self.blink_max_s:
                self.blinks.append(t)
                self.total_blinks += 1
                events.append(("blink", dur))

        if self.calibrating:            # the baseline is a guess until calibrated: no squint calls
            return self._end_squint(t, events)
        if self.squint_low <= ratio < self.squint_high:
            if self._squint_since is None:
                self._squint_since = t
            if not self.squinting and t - self._squint_since >= self.squint_min_s:
                self.squinting = True
                events.append(("squint_start", None))
        elif not closed:   # a blink in the middle of a squint does not end it
            self._end_squint(t, events)
        return events

    def _end_squint(self, t, events):
        if self.squinting:
            events.append(("squint_end", t - self._squint_since))
        self.squinting = False
        self._squint_since = None
        return events

    def blink_rate(self, t):
        """Blinks per minute over the last rate_window_s (scaled up early in a session)."""
        while self.blinks and self.blinks[0] < t - self.rate_window_s:
            self.blinks.popleft()
        if self.t_start is None:
            return None
        span = min(t - self.t_start, self.rate_window_s)
        if span < 10:
            return None   # too early to say
        return len(self.blinks) * 60.0 / span


class EyeTracker:
    """Extractor + detector. process(frame, t) -> (state dict, events)."""

    def __init__(self, cfg, extractor=None):
        e = cfg.get("eye", {})
        if extractor is None:
            extractor = CloseupEye() if e.get("method") == "closeup" else FaceMeshEyes()
        self.extractor = extractor
        self.detector = BlinkSquintDetector(**e)
        self.features = None
        self.state = {}

    def calibrate(self):
        self.detector.start_calibration()

    def process(self, frame, t):
        f = self.extractor.extract(frame)
        self.features = f
        events = self.detector.update(None if f is None else f.openness, t)
        d = self.detector
        rate = d.blink_rate(t)
        self.state = {
            "eye_detected": f is not None,
            "openness": None if f is None else round(f.openness, 4),
            "openness_ratio": None if d.ratio is None else round(d.ratio, 3),
            "baseline": round(d.baseline, 4),
            "calibrated": d.calibrated,
            "calibrating": d.calibrating,
            "blinks_total": d.total_blinks,
            "blink_rate": None if rate is None else round(rate, 1),
            "squinting": d.squinting,
            "pupil": None if f is None or f.pupil is None else [round(v, 3) for v in f.pupil],
            "method": self.extractor.name,
        }
        return self.state, events

    def annotate(self, img):
        f, s = self.features, self.state
        if f is not None and f.points is not None:
            for x, y in f.points.astype(int):
                cv2.circle(img, (int(x), int(y)), 1, (0, 255, 255), -1)
        lines = [
            f"EAR {s.get('openness')}  ratio {s.get('openness_ratio')}  base {s.get('baseline')}",
            f"blinks {s.get('blinks_total')}  rate {s.get('blink_rate')}/min",
            f"squint {'YES' if s.get('squinting') else 'no'}  pupil {s.get('pupil')}",
        ]
        if s.get("calibrating"):
            lines.insert(0, "CALIBRATING: eyes open, look at the screen")
        for i, line in enumerate(lines):
            cv2.putText(img, line, (8, 22 + 20 * i), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 255, 0), 2)
        return img


def main(argv=None):
    from backend.config import load_config
    from backend.streams import FrameReader

    ap = argparse.ArgumentParser(description="Live blink / squint / pupil tracking")
    ap.add_argument("--source", default=None, help="camera source (default: cameras.eye in config)")
    ap.add_argument("--method", choices=("facemesh", "closeup"), default=None)
    ap.add_argument("--image", help="run once on a still image and print the features")
    args = ap.parse_args(argv)
    cfg = load_config()
    if args.method:
        cfg["eye"]["method"] = args.method
    tracker = EyeTracker(cfg)

    if args.image:
        img = cv2.imread(args.image)
        state, _ = tracker.process(img, time.time())
        print(state)
        return

    reader = FrameReader(args.source if args.source is not None else cfg["cameras"]["eye"]["source"])
    seq = 0
    print("keys: [c] recalibrate  [q] quit")
    try:
        while True:
            seq, frame, t = reader.wait_new(seq)
            if frame is None:
                continue
            state, events = tracker.process(frame, t)
            for ev in events:
                print(ev, state["blink_rate"])
            cv2.imshow("eye", tracker.annotate(frame.copy()))
            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            if key == ord("c"):
                tracker.calibrate()
    finally:
        reader.close()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
