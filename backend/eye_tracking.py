"""Blink, squint and pupil tracking.

Two layers, so the eye camera can change without touching anything else:

  extractor  frame -> EyeFeatures(openness, pupil)      swappable per camera
             CloseupEye:   THE PRODUCT. EYE ESP32-CAM ~3 cm from one eye, dark-pupil
                           threshold + ellipse fit, openness = visible pupil height / width
                           (the lid covers it)
             FaceMeshEyes: DEV ONLY. A laptop webcam sees the whole face, openness = Eye
                           Aspect Ratio. Lets us test before the eye camera arrives.
  detector   openness over time -> blinks, blinks/min, squint      same for both

The detector only sees openness / baseline, where the baseline is the median
openness recorded during calibration (eyes open, looking normally). That ratio
means the same thing for both extractors, so the thresholds carry over.

    python -m backend.eye_tracking                         # EYE camera stream from config.yaml
    python -m backend.eye_tracking --dev                   # DEV: laptop webcam + face mesh
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
    """DEV ONLY: whole face in view on a laptop webcam. Openness = mean EAR of both eyes.
    The product's eye camera sees one eye up close; that is CloseupEye."""

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
    """THE PRODUCT's eye method: EYE ESP32-CAM ~3 cm from one eye, below and to the side.

    Dark-pupil tracking:
      1. search near the last pupil (or the whole frame when lost);
      2. threshold just above the darkest pixels (adaptive: a low percentile + offset),
         but never far above the pupil's own learned darkness, so when the lid hides
         the pupil the iris (round, but much brighter and bigger) is not mistaken for it;
      3. morphological opening removes thin eyelashes; filling each contour removes
         the holes an IR glint punches into the pupil, and the convex hull removes
         the notch a glint leaves on the edge;
      4. pick the candidate that is round, dark, big enough and close to the last pupil.

    Openness = visible pupil area / the pupil's full area (a high percentile of recent
    areas, so blinks and squints do not drag it down). About 1 when open; the upper
    lid covering the pupil lowers it (squint); 0 when no pupil is visible (blink, or the
    eye is closed). Tested on synthetic close-up eyes (backend/synth_eye.py); tune
    dark_offset and the area limits on the first real eye-camera footage.
    """

    name = "closeup"

    def __init__(self, dark_offset=22, dark_percentile=1.0, min_area_frac=0.002, max_area_frac=0.2,
                 min_circularity=0.55, ref_window=600):
        self.dark_offset = dark_offset
        self.dark_percentile = dark_percentile
        self.min_area_frac = min_area_frac
        self.max_area_frac = max_area_frac
        self.min_circularity = min_circularity
        self._areas = collections.deque(maxlen=ref_window)   # recent visible areas (~40 s at 15 fps)
        self.pupil_level = None      # learned mean gray level inside the pupil
        self.last_center = None      # pixel center of the last pupil
        self.last_radius = None
        self.debug = {}

    def ref_area(self):
        """Full (unoccluded) pupil area: 90th percentile of recent areas."""
        if not self._areas:
            return None
        return float(np.percentile(self._areas, 90))

    def _candidates(self, gray, roi):
        x0, y0, x1, y1 = roi
        sub = gray[y0:y1, x0:x1]
        thresh = float(np.percentile(sub, self.dark_percentile)) + self.dark_offset
        if self.pupil_level is not None:
            thresh = min(thresh, self.pupil_level + self.dark_offset)
        _, mask = cv2.threshold(sub, thresh, 255, cv2.THRESH_BINARY_INV)
        k = 5 if self.last_radius is None else int(np.clip(self.last_radius * 0.35, 3, 9)) | 1
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k)))
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        h, w = gray.shape
        out = []
        for c in contours:
            area = cv2.contourArea(c)        # filled contour: glint holes do not count against it
            if not (self.min_area_frac * h * w <= area <= self.max_area_frac * h * w) or len(c) < 5:
                continue
            hull = cv2.convexHull(c)
            hull_area = cv2.contourArea(hull)
            perim = cv2.arcLength(hull, True)
            circ = 4 * np.pi * hull_area / max(perim * perim, 1e-6)
            c_full = c + (x0, y0)
            m = np.zeros_like(gray)
            cv2.drawContours(m, [c_full], -1, 255, -1)
            level = float(cv2.mean(gray, mask=m)[0])
            out.append({"contour": c_full, "hull": hull + (x0, y0), "area": hull_area, "circ": circ,
                        "dark": 255 - level, "level": level})
        return out, thresh

    def extract(self, frame):
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY) if frame.ndim == 3 else frame
        gray = cv2.medianBlur(gray, 5)
        h, w = gray.shape
        roi = (0, 0, w, h)
        if self.last_center is not None and self.last_radius:
            r = int(self.last_radius * 4)
            cx, cy = self.last_center
            roi = (max(0, int(cx - r)), max(0, int(cy - r)), min(w, int(cx + r)), min(h, int(cy + r)))
        cands, thresh = self._candidates(gray, roi)
        if not cands and roi != (0, 0, w, h):
            cands, thresh = self._candidates(gray, (0, 0, w, h))     # lost it: search everywhere

        ref = self.ref_area()

        def score(c):
            s = c["circ"] * 2 + c["dark"] / 128
            if ref:
                s -= abs(np.log(max(c["area"], 1) / ref))           # about the size we expect
            if self.last_center is not None:
                d = np.hypot(*(np.mean(c["hull"].reshape(-1, 2), 0) - self.last_center))
                s -= d / max(self.last_radius or 20, 1) * 0.3
            return s

        # A partly covered pupil is a flattened disc, so roundness is judged against
        # what is left visible: allow lower circularity when the area is also reduced.
        good = [c for c in cands if c["circ"] >= self.min_circularity
                or (ref and c["area"] < 0.8 * ref and c["circ"] >= self.min_circularity * 0.6)]
        if ref:                          # the pupil cannot be much bigger than the pupil
            good = [c for c in good if c["area"] <= 1.6 * ref]
        if self.pupil_level is not None:  # ...or much brighter than the pupil
            good = [c for c in good if c["level"] <= self.pupil_level + 1.5 * self.dark_offset]
        self.debug = {"thresh": thresh, "candidates": len(cands), "roi": roi}
        if not good:
            return EyeFeatures(0.0)      # no pupil visible: closed (blink) or not in view
        best = max(good, key=score)
        pts = best["hull"].reshape(-1, 2).astype(np.float32)
        (cx, cy), radius = cv2.minEnclosingCircle(pts)
        mom = cv2.moments(best["hull"])
        if mom["m00"] > 0:
            cx, cy = mom["m10"] / mom["m00"], mom["m01"] / mom["m00"]
        self._areas.append(best["area"])
        if best["area"] >= 0.7 * (ref or best["area"]):      # learn darkness from a mostly visible pupil
            lvl = best["level"]
            self.pupil_level = lvl if self.pupil_level is None else 0.95 * self.pupil_level + 0.05 * lvl
        ref = self.ref_area()
        openness = min(best["area"] / ref, 1.5) if ref else 1.0
        self.last_center = np.array([cx, cy])
        self.last_radius = float(np.sqrt(ref / np.pi)) if ref else radius
        pupil = (float(2 * cx / w - 1), float(2 * cy / h - 1))
        return EyeFeatures(float(openness), pupil, pts)


class BlinkSquintDetector:
    """Openness over time -> blinks, blink rate, squint. Pure logic, no OpenCV."""

    def __init__(self, calibration_s=5.0, default_baseline=0.28, blink_ratio=0.65,
                 blink_min_s=0.05, blink_max_s=0.5, blink_min_frames=None, blink_max_frames=None,
                 squint_low=0.65, squint_high=0.85, squint_min_s=1.5, rate_window_s=60, **_ignored):
        self.calibration_s = calibration_s
        self.baseline = default_baseline
        self.blink_ratio = blink_ratio
        self.blink_min_s, self.blink_max_s = blink_min_s, blink_max_s
        # Frame counts win when set (the product: 2-7 frames at the eye camera's rate);
        # otherwise blinks are timed in seconds (dev webcam at 30 fps).
        self.blink_min_frames, self.blink_max_frames = blink_min_frames, blink_max_frames
        self._closed_frames = 0
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
        if self._calib_until is not None and openness > 0:   # no pupil = nothing to learn from
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
                self._closed_frames = 0
            self._closed_frames += 1
        elif self._closed_since is not None:
            dur = t - self._closed_since
            n = self._closed_frames
            self._closed_since = None
            if self.blink_min_frames is not None:
                ok = self.blink_min_frames <= n <= (self.blink_max_frames or 10 ** 9)
            else:
                ok = self.blink_min_s <= dur <= self.blink_max_s
            if ok:
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
            extractor = FaceMeshEyes() if e.get("method") == "facemesh" else CloseupEye()
        self.extractor = extractor
        self.detector = BlinkSquintDetector(**e)
        self.presence_s = e.get("presence_s", 2.0)
        self.last_seen = None        # last time a pupil/eye was actually seen
        self.features = None
        self.state = {}

    def calibrate(self):
        self.detector.start_calibration()

    def process(self, frame, t):
        f = self.extractor.extract(frame)
        self.features = f
        seen = f is not None and (f.pupil is not None or f.openness > 0)
        if seen:
            self.last_seen = t
        present = self.last_seen is not None and t - self.last_seen <= self.presence_s
        # No pupil right after seeing one = the lid is closed (counts toward a blink).
        # No pupil for longer = the eye is not in view (glasses off): not a closure.
        openness = f.openness if seen else (0.0 if present and f is not None else None)
        events = self.detector.update(openness, t)
        d = self.detector
        rate = d.blink_rate(t)
        self.state = {
            "eye_detected": present,
            "openness": None if openness is None else round(openness, 4),
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
    ap.add_argument("--method", choices=("closeup", "facemesh"), default=None, help="facemesh is DEV ONLY")
    ap.add_argument("--dev", action="store_true", help="use config.dev.yaml stand-ins (webcam + face mesh)")
    ap.add_argument("--image", help="run once on a still image and print the features")
    args = ap.parse_args(argv)
    cfg = load_config(dev=args.dev)
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
