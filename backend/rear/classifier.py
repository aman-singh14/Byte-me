"""What came at the wearer from behind, and is it dangerous? Runs on a rear clip.

    frames -> YOLO on the last few frames -> track the biggest relevant object
           -> how fast it grows (time to contact) + where it is (wearer's left/behind/right)

Box size s = sqrt(area) grows like 1/distance for something approaching, so
time to contact tau = s / (ds/dt). Rules:

  danger class (person, bike, car, ...) and tau < tau_danger_s (or it grew > min_growth)
      -> DANGEROUS: "Bike approaching fast, on your left"
  danger class but not growing                 -> not dangerous: "A person behind you, not coming closer"
  no detection, one coherent growing blob      -> unknown: "Something is coming closer, I can't tell what"
  no detection, scattered / no motion          -> nothing: leaf, shadow, light change

Sides: the rear camera faces backward, so image-left is the wearer's right (flip).
"""

from dataclasses import asdict, dataclass

import cv2
import numpy as np

from backend.rear.protocol import GRAY8, JPEG

DANGER_LABELS = {"person", "bicycle", "car", "motorcycle", "bus", "truck", "dog", "skateboard", "horse"}
SPOKEN = {"bicycle": "bike", "motorcycle": "motorcycle", "person": "person", "car": "car", "bus": "bus",
          "truck": "truck", "dog": "dog", "skateboard": "skateboarder", "horse": "horse"}
SIDE_WORDS = {"L": "on your left", "C": "right behind you", "R": "on your right"}


@dataclass
class RearResult:
    dangerous: bool | None        # True / False / None (unknown object approaching)
    kind: str                     # "danger" | "not_approaching" | "unknown" | "nothing"
    label: str | None             # YOLO label of the tracked object
    side: str | None              # wearer side: "L" | "C" | "R"
    ttc_s: float | None           # time to contact estimate
    growth: float | None          # size ratio last / first tracked frame
    text: str                     # follow-up sentence to speak
    frames_used: int
    frames_missing: int

    def as_dict(self):
        d = asdict(self)
        for k in ("ttc_s", "growth"):
            if d[k] is not None:
                d[k] = round(d[k], 2)
        return d


def decode_frames(clip):
    """Clip frames -> list of BGR images (None where a frame is missing or corrupt)."""
    ev = clip.event
    out = []
    for f in clip.frames:
        img = None
        if f is not None:
            if ev.pixel_format == GRAY8 and len(f) == ev.width * ev.height:
                img = cv2.cvtColor(np.frombuffer(f, np.uint8).reshape(ev.height, ev.width), cv2.COLOR_GRAY2BGR)
            elif ev.pixel_format == JPEG:
                img = cv2.imdecode(np.frombuffer(f, np.uint8), cv2.IMREAD_COLOR)
        out.append(img)
    return out


def wearer_side(x_frac, flip=True):
    """Horizontal position in the image (0..1) -> wearer side."""
    third = "L" if x_frac < 1 / 3 else "R" if x_frac > 2 / 3 else "C"
    if flip and third != "C":
        third = "R" if third == "L" else "L"
    return third


def _ttc(times, sizes):
    """Time to contact from box sizes over time (least squares on 1/size, which falls
    linearly to 0 at contact for constant approach speed)."""
    if len(sizes) < 2:
        return None
    t = np.asarray(times, float)
    inv = 1.0 / np.asarray(sizes, float)
    slope, intercept = np.polyfit(t, inv, 1)
    if slope >= 0:
        return None                     # not getting closer
    return float((0 - (slope * t[-1] + intercept)) / slope)


def motion_summary(frames):
    """For clips YOLO can't explain: is the motion one coherent, growing blob?"""
    imgs = [cv2.cvtColor(f, cv2.COLOR_BGR2GRAY) for f in frames if f is not None]
    if len(imgs) < 4:
        return {"coherent": False, "growth": None, "x_frac": None}
    areas, xs, spreads = [], [], []
    for a, b in zip(imgs[:-1], imgs[1:]):
        d = cv2.absdiff(a, b)
        _, m = cv2.threshold(d, 25, 255, cv2.THRESH_BINARY)
        m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
        n, labels, stats, cents = cv2.connectedComponentsWithStats(m)
        total = int(m.sum() // 255)
        if n <= 1 or total == 0:
            areas.append(0)                 # no motion: says nothing about coherence
            continue
        biggest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
        areas.append(int(stats[biggest, cv2.CC_STAT_AREA]))
        spreads.append(1 - stats[biggest, cv2.CC_STAT_AREA] / total)     # 0 = one blob, 1 = scattered
        xs.append(cents[biggest][0] / a.shape[1])
    half = len(areas) // 2
    early, late = np.mean(areas[:half]) + 1, np.mean(areas[half:]) + 1
    growth = late / early
    coherent = bool(spreads) and float(np.median(spreads)) < 0.4 and late > 0.01 * imgs[0].size
    return {"coherent": coherent, "growth": float(growth), "x_frac": float(np.median(xs)) if xs else None}


class RearClassifier:
    def __init__(self, detector, flip=True, tau_danger_s=4.0, min_growth=1.3, sample_frames=6):
        self.detector = detector
        self.flip = flip
        self.tau_danger_s = tau_danger_s
        self.min_growth = min_growth
        self.sample_frames = sample_frames

    def classify(self, clip):
        frames = decode_frames(clip)
        missing = sum(f is None for f in frames)
        fps = max(clip.event.fps, 1)
        idx = [i for i, f in enumerate(frames) if f is not None]
        if not idx:
            return RearResult(None, "unknown", None, None, None, None,
                              "I couldn't get the video from behind. Stay alert.", 0, missing)
        # The newest frames matter most: sample from the last ~2 s.
        recent = idx[-min(len(idx), int(2 * fps)):]
        step = max(1, len(recent) // self.sample_frames)
        sample = recent[::step][-self.sample_frames:]
        if sample[-1] != idx[-1]:
            sample.append(idx[-1])

        tracks = {}                                     # label -> [(t, size, x_frac)]
        for i in sample:
            f = frames[i]
            h, w = f.shape[:2]
            for d in self.detector.detect(f):
                if d.label not in DANGER_LABELS:
                    continue
                x0, y0, x1, y1 = d.box
                tracks.setdefault(d.label, {})
                size = float(np.sqrt(max((x1 - x0) * (y1 - y0), 1.0)))
                prev = tracks[d.label].get(i)
                if prev is None or size > prev[1]:      # biggest instance of that label per frame
                    tracks[d.label][i] = (i / fps, size, ((x0 + x1) / 2) / w)

        if tracks:
            # The object that is biggest in the newest frame it appears in.
            label = max(tracks, key=lambda k: tracks[k][max(tracks[k])][1])
            pts = [tracks[label][i] for i in sorted(tracks[label])]
            times, sizes, xs = zip(*pts)
            ttc = _ttc(times, sizes)
            growth = sizes[-1] / sizes[0] if len(sizes) > 1 else None
            side = wearer_side(xs[-1], self.flip)
            word = SPOKEN.get(label, label)
            approaching = (ttc is not None and ttc < self.tau_danger_s) or (growth or 0) >= self.min_growth
            if approaching:
                speed = "fast" if ttc is not None and ttc < self.tau_danger_s / 2 else "closer"
                verb = "approaching fast" if speed == "fast" else "coming closer"
                text = f"{word.capitalize()} {verb}, {SIDE_WORDS[side]}."
                return RearResult(True, "danger", label, side, ttc, growth, text, len(sample), missing)
            text = f"A {word} behind you, not coming closer."
            return RearResult(False, "not_approaching", label, side, ttc, growth, text, len(sample), missing)

        m = motion_summary([frames[i] for i in recent])
        if m["coherent"] and (m["growth"] or 0) >= self.min_growth:
            side = wearer_side(m["x_frac"], self.flip) if m["x_frac"] is not None else None
            where = f", {SIDE_WORDS[side]}" if side else ""
            return RearResult(None, "unknown", None, side, None, m["growth"],
                              f"Something is coming closer{where}. I can't tell what it is.", len(sample), missing)
        return RearResult(False, "nothing", None, None, None, m["growth"],
                          "Never mind, nothing dangerous behind you.", len(sample), missing)
