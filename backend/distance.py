"""Monocular distance to the screen, in cm, from a reference of known width.

    distance_cm = focal_px * real_width_cm / width_px

Two references (config distance.method):
  face    the camera sees the wearer's face (laptop webcam demo): cheek-to-cheek
          width from Face Mesh landmarks 234 and 454. Camera-to-face = face-to-screen.
  object  the camera sees the screen (glasses front camera): the largest bright
          quadrilateral in view, with a known real width (object_width_cm).

focal_px comes from the webcam's field of view until a one-time calibration:
stand at a known distance and call calibrate(known_cm) (POST /calibrate/distance).
The result is saved in backend/data/calibration.json.

    python -m backend.distance                  # live window, [k] calibrates at 50 cm
"""

import argparse
import json
import math
import time
from pathlib import Path

import cv2
import numpy as np

CHEEK_R, CHEEK_L = 234, 454
CALIB_PATH = Path(__file__).resolve().parent / "data" / "calibration.json"


def load_calibration(path=None):
    try:
        return json.loads(Path(path or CALIB_PATH).read_text())
    except (OSError, ValueError):
        return {}


def save_calibration(key, value, path=None):
    path = path or CALIB_PATH
    data = load_calibration(path)
    data[key] = value
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(data, indent=2) + "\n")


def find_screen(frame):
    """Largest bright, roughly rectangular region. Returns (width_px, box points) or None."""
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    gray = cv2.GaussianBlur(gray, (5, 5), 0)
    _, mask = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    h, w = gray.shape
    best = None
    for c in contours:
        area = cv2.contourArea(c)
        if area < 0.01 * h * w:
            continue
        (cx, cy), (rw, rh), _ = cv2.minAreaRect(c)
        if rw * rh <= 0 or area / (rw * rh) < 0.75:   # not rectangular enough
            continue
        long_side = max(rw, rh)
        if long_side >= 0.98 * w:                      # touches both edges: probably a wall, not a screen
            continue
        if best is None or area > best[0]:
            best = (area, long_side, cv2.boxPoints(((cx, cy), (rw, rh), _)))
    return None if best is None else (best[1], best[2])


class DistanceEstimator:
    def __init__(self, cfg, face_mesh=None):
        d = cfg.get("distance", {})
        self.method = d.get("method", "face")
        self.device = d.get("device", "laptop")
        self.thresholds = d.get("too_close_cm", {"laptop": 50, "phone": 30})
        self.real_cm = d.get("face_width_cm", 14.0) if self.method == "face" else d.get("object_width_cm", 30.0)
        self.hfov = d.get("hfov_deg", 65)
        self.alpha = d.get("smoothing", 0.3)
        self.focal = d.get("focal_px") or load_calibration().get(f"focal_px_{self.method}")
        self.calibrated = self.focal is not None
        self._mesh = face_mesh
        self.width_px = None
        self.cm = None
        self.too_close = False
        self.too_close_since = None
        self.box = None
        self.state = {}

    @property
    def threshold_cm(self):
        return self.thresholds.get(self.device, 50)

    def _focal(self, img_w):
        if self.focal is None:
            return (img_w / 2) / math.tan(math.radians(self.hfov) / 2)
        return self.focal

    def measure_px(self, frame, landmarks=None):
        """Reference width in pixels, or None. Pass landmarks to reuse a Face Mesh run."""
        if self.method == "object":
            found = find_screen(frame)
            self.box = None if found is None else found[1]
            return None if found is None else found[0]
        if landmarks is None:
            if self._mesh is None:
                from backend.face import FaceMesh
                self._mesh = FaceMesh()
            landmarks = self._mesh.detect(frame)
        if landmarks is None:
            self.box = None
            return None
        self.box = landmarks[[CHEEK_R, CHEEK_L]]
        return float(np.linalg.norm(landmarks[CHEEK_R] - landmarks[CHEEK_L]))

    def calibrate(self, known_cm, width_px=None):
        """Set focal_px from the current reference width at a known distance."""
        width_px = width_px or self.width_px
        if not width_px:
            raise ValueError("no face/screen in view to calibrate against")
        self.focal = width_px * known_cm / self.real_cm
        self.calibrated = True
        self.cm = known_cm
        save_calibration(f"focal_px_{self.method}", self.focal)
        return self.focal

    def set_device(self, device):
        if device not in self.thresholds:
            raise ValueError(f"device must be one of {sorted(self.thresholds)}")
        self.device = device

    def process(self, frame, t, landmarks=None):
        """Returns (state dict, events). Events: ("too_close_start", cm), ("too_close_end", seconds)."""
        px = self.measure_px(frame, landmarks)
        self.width_px = px
        events = []
        if px:
            raw = self._focal(frame.shape[1]) * self.real_cm / px
            self.cm = raw if self.cm is None else self.cm + self.alpha * (raw - self.cm)
        else:
            self.cm = None
        close = self.cm is not None and self.cm < self.threshold_cm
        if close and not self.too_close:
            self.too_close_since = t
            events.append(("too_close_start", round(self.cm, 1)))
        elif not close and self.too_close:
            events.append(("too_close_end", round(t - self.too_close_since, 1)))
            self.too_close_since = None
        self.too_close = close
        self.state = {
            "distance_cm": None if self.cm is None else round(self.cm, 1),
            "too_close": close,
            "too_close_for_s": round(t - self.too_close_since, 1) if close else 0,
            "threshold_cm": self.threshold_cm,
            "device": self.device,
            "distance_method": self.method,
            "distance_calibrated": self.calibrated,
        }
        return self.state, events

    def annotate(self, img):
        s = self.state
        if self.box is not None:
            pts = self.box.astype(int)
            if len(pts) == 2:
                cv2.line(img, tuple(pts[0]), tuple(pts[1]), (255, 128, 0), 2)
            else:
                cv2.polylines(img, [pts], True, (255, 128, 0), 2)
        color = (0, 0, 255) if s.get("too_close") else (255, 128, 0)
        label = "no reference" if s.get("distance_cm") is None else f"{s['distance_cm']:.0f} cm"
        if s.get("too_close"):
            label += "  TOO CLOSE"
        h = img.shape[0]
        cv2.putText(img, f"{label} ({s.get('device')} < {s.get('threshold_cm')} cm)"
                         f"{'' if s.get('distance_calibrated') else '  uncalibrated'}",
                    (8, h - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)
        return img


def main(argv=None):
    from backend.config import load_config
    from backend.streams import FrameReader

    ap = argparse.ArgumentParser(description="Live distance to screen")
    ap.add_argument("--source", default=None, help="camera source (default: cameras.front in config)")
    ap.add_argument("--method", choices=("face", "object"), default=None)
    ap.add_argument("--calib-cm", type=float, default=50.0, help="known distance used by [k]")
    ap.add_argument("--image", help="run once on a still image and print the result")
    args = ap.parse_args(argv)
    cfg = load_config()
    if args.method:
        cfg["distance"]["method"] = args.method
    est = DistanceEstimator(cfg)

    if args.image:
        print(est.process(cv2.imread(args.image), time.time())[0], f"width_px={est.width_px}")
        return

    reader = FrameReader(args.source if args.source is not None else cfg["cameras"]["front"]["source"])
    seq = 0
    print(f"keys: [k] calibrate at {args.calib_cm} cm  [q] quit")
    try:
        while True:
            seq, frame, t = reader.wait_new(seq)
            if frame is None:
                continue
            _, events = est.process(frame, t)
            for ev in events:
                print(ev)
            cv2.imshow("distance", est.annotate(frame.copy()))
            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            if key == ord("k"):
                try:
                    print(f"focal_px = {est.calibrate(args.calib_cm):.1f}")
                except ValueError as e:
                    print(e)
    finally:
        reader.close()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
