"""Local object detection (YOLO) shared by "what am I looking at?" and the rear classifier.

Runs on the laptop, ~25 ms per frame on CPU with yolov8n. Each detection gets a
position (left / ahead / right of the wearer) and, for objects of a typical size,
an approximate distance from the FRONT camera's focal length:

    distance_cm = focal_px * real_size_cm / size_px
"""

import threading
from dataclasses import asdict, dataclass
from pathlib import Path

MODEL_DIR = Path(__file__).resolve().parent / "models"

# Typical real sizes for a rough distance: (cm, "h" = box height | "w" = box width).
KNOWN_SIZES = {
    "person": (170, "h"), "laptop": (32, "w"), "cell phone": (14.5, "h"), "cup": (10, "h"),
    "bottle": (23, "h"), "chair": (90, "h"), "tv": (100, "w"), "keyboard": (44, "w"),
    "mouse": (11, "w"), "book": (22, "h"), "car": (180, "w"), "bus": (300, "h"), "truck": (300, "h"),
    "bicycle": (100, "h"), "motorcycle": (110, "h"), "dog": (55, "h"), "cat": (30, "h"),
    "door": (200, "h"), "stop sign": (75, "w"), "potted plant": (40, "h"), "bench": (150, "w"),
    "backpack": (45, "h"), "umbrella": (90, "w"), "clock": (30, "w"), "refrigerator": (170, "h"),
}


@dataclass
class Detection:
    label: str
    conf: float
    box: tuple                    # x0, y0, x1, y1 in the full frame's pixels
    position: str                 # "left" | "ahead" | "right" (of the wearer, from the full frame)
    area_frac: float              # box area / frame area
    distance_cm: float | None = None

    def as_dict(self):
        d = asdict(self)
        d["box"] = [round(v) for v in self.box]
        d["conf"] = round(self.conf, 2)
        d["area_frac"] = round(self.area_frac, 4)
        if self.distance_cm is not None:
            d["distance_cm"] = round(self.distance_cm)
        return d


class Detector:
    """Lazy-loaded YOLO. detect() is thread-safe (one inference at a time)."""

    def __init__(self, model="yolov8n.pt", min_conf=0.35):
        self.model_name = model
        self.min_conf = min_conf
        self._model = None
        self._lock = threading.Lock()
        self.available = True
        self.error = None

    def _load(self):
        if self._model is None and self.available:
            try:
                from ultralytics import YOLO
                path = MODEL_DIR / self.model_name
                MODEL_DIR.mkdir(parents=True, exist_ok=True)
                # Ultralytics downloads a missing model to the given path.
                self._model = YOLO(str(path))
            except Exception as e:      # missing package, no network for the first download, ...
                self.available, self.error = False, repr(e)
                print(f"[vision] YOLO unavailable: {e!r}")
        return self._model

    def detect(self, frame, x_offset=0, full_width=None, focal_px=None):
        """Detections in `frame` (which may be a crop starting at x_offset of a frame
        full_width wide). Positions and distances refer to the full frame."""
        model = self._load()
        if model is None:
            return []
        with self._lock:
            res = model(frame, verbose=False)[0]
        h, w = frame.shape[:2]
        full_w = full_width or w
        out = []
        for b in res.boxes:
            conf = float(b.conf)
            if conf < self.min_conf:
                continue
            label = res.names[int(b.cls)]
            x0, y0, x1, y1 = (float(v) for v in b.xyxy[0].tolist())
            cx = (x0 + x1) / 2 + x_offset
            position = "left" if cx < full_w / 3 else "right" if cx > 2 * full_w / 3 else "ahead"
            dist = None
            if focal_px and label in KNOWN_SIZES:
                real, axis = KNOWN_SIZES[label]
                px = (y1 - y0) if axis == "h" else (x1 - x0)
                # A box cut off by the frame edge is too small: no distance then.
                cut = y0 <= 1 or y1 >= h - 1 if axis == "h" else x0 <= 1 or x1 >= w - 1
                if px > 4 and not cut:
                    dist = focal_px * real / px
            out.append(Detection(label, conf, (x0 + x_offset, y0, x1 + x_offset, y1), position,
                                 (x1 - x0) * (y1 - y0) / (w * h), dist))
        out.sort(key=lambda d: -d.area_frac)
        return out


def _distance_words(cm):
    if cm is None:
        return ""
    if cm < 100:
        return f", about {int(round(cm / 10.0) * 10)} centimeters away"
    m = cm / 100
    return f", about {m:.0f} meter{'s' if round(m) != 1 else ''} away" if m >= 1.5 else ", about a meter away"


def _phrase(label, n):
    if n == 1:
        return ("an " if label[0] in "aeiou" else "a ") + label
    plural = {"person": "people", "bus": "buses", "knife": "knives", "mouse": "mice"}.get(label, label + "s")
    return f"{n} {plural}"


def quick_answer(dets, region=None, max_items=3):
    """Short spoken sentence from local detections, e.g. "Ahead: a laptop, about 60
    centimeters away, and a cup." Spoken immediately, before Muse answers."""
    where = {"left": "On your left", "right": "On your right", "center": "Ahead", "all": "I see",
             None: "I see"}[region]
    if not dets:
        return f"{where}, nothing I recognize." if region not in (None, "all") else "I don't see anything I recognize."
    groups = {}
    for d in dets:
        groups.setdefault(d.label, []).append(d)
    items = []
    for label, ds in list(groups.items())[:max_items]:
        first = ds[0]
        items.append(_phrase(label, len(ds)) + (_distance_words(first.distance_cm) if len(ds) == 1 else ""))
    if len(items) == 1:
        text = items[0]
    else:   # "a bus, about 4 meters away, and 3 people": the comma keeps it clear when spoken
        joiner = ", and " if any("," in i for i in items) or len(items) > 2 else " and "
        text = ", ".join(items[:-1]) + joiner + items[-1]
    sep = " " if where == "I see" else ": "
    return f"{where}{sep}{text}."
