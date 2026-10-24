"""Near-work from the FRONT camera: what screen/book is in front of the wearer, how
close, close-up sessions, and heads-up time.

    YOLO (laptop, cell phone, tv, keyboard, book) -> distance from apparent size
    -> CloseupTracker: sessions of near-work closer than a per-object threshold
    -> HeadsUpTracker: stretches with no near-work at all (while the glasses are worn)

Distance uses the object's longest side as a fraction of the frame width, so it works
at any stream resolution and in either orientation:

    distance_cm = k / (longest_px / frame_width)
    k = (0.5 / tan(hfov / 2)) * real_longest_cm        default, from the lens
    k = (longest_px / frame_width) * known_cm           after calibrating at a known distance
"""

import math
import time

from backend.distance import load_calibration, save_calibration

NEAR_CLASSES = {
    # COCO label -> (kind, real longest side in cm, too-close threshold in cm)
    "cell phone": ("phone", 15.0, 30.0),
    "book": ("book", 24.0, 30.0),
    "laptop": ("laptop", 32.0, 50.0),
    "tv": ("tv", 100.0, 50.0),
    "keyboard": ("keyboard", 44.0, 50.0),
}


class NearWorkEstimator:
    """Per front frame: the near-work objects in view, each with a distance."""

    def __init__(self, cfg, detector):
        n = cfg.get("nearwork", {})
        self.detector = detector
        self.hfov = cfg.get("distance", {}).get("hfov_deg", 65)
        self.thresholds = {**{k: v[2] for k, v in NEAR_CLASSES.items()}, **n.get("too_close_cm", {})}
        self.k = load_calibration().get("nearwork_k", {})        # label -> calibrated k
        self.last = []                                            # last frame's near-work detections
        self.all_detections = []                                  # last frame's detections of any kind
        self.state = {}

    def _k(self, label):
        if label in self.k:
            return self.k[label]
        return 0.5 / math.tan(math.radians(self.hfov) / 2) * NEAR_CLASSES[label][1]

    def measure(self, dets, frame_w):
        out = []
        for d in dets:
            if d.label not in NEAR_CLASSES:
                continue
            x0, y0, x1, y1 = d.box
            frac = max(x1 - x0, y1 - y0) / frame_w
            if frac <= 0:
                continue
            dist = self._k(d.label) / frac
            kind = NEAR_CLASSES[d.label][0]
            out.append({"label": d.label, "kind": kind, "distance_cm": dist, "frac": frac, "conf": d.conf,
                        "box": d.box,
                        "close": dist < self.thresholds.get(d.label, 50.0),
                        "threshold_cm": self.thresholds.get(d.label, 50.0)})
        out.sort(key=lambda o: o["distance_cm"])
        return out

    def process(self, frame, t):
        dets = self.detector.detect(frame)
        self.all_detections = dets           # everything YOLO saw, for the preview boxes
        objs = self.measure(dets, frame.shape[1])
        self.last = objs
        nearest = objs[0] if objs else None
        self.state = {
            "nearwork": bool(objs),
            "nearwork_object": nearest["kind"] if nearest else None,
            "nearwork_distance_cm": round(nearest["distance_cm"], 1) if nearest else None,
            "nearwork_close": bool(nearest and nearest["close"]),
            "nearwork_threshold_cm": nearest["threshold_cm"] if nearest else None,
            "nearwork_objects": [{"kind": o["kind"], "distance_cm": round(o["distance_cm"], 1), "close": o["close"]}
                                 for o in objs],
        }
        return self.state

    def calibrate(self, kind_or_label, known_cm):
        """Calibrate one object class with what is in view right now at a known distance."""
        label = next((lbl for lbl, v in NEAR_CLASSES.items() if kind_or_label in (lbl, v[0])), None)
        if label is None:
            raise ValueError(f"unknown object {kind_or_label!r}; use one of "
                             f"{sorted(v[0] for v in NEAR_CLASSES.values())}")
        seen = [o for o in self.last if o["label"] == label]
        if not seen:
            raise ValueError(f"no {NEAR_CLASSES[label][0]} in view right now")
        biggest = max(seen, key=lambda o: o["frac"])
        self.k[label] = biggest["frac"] * known_cm
        save_calibration("nearwork_k", self.k)
        return {"object": NEAR_CLASSES[label][0], "known_cm": known_cm, "k": round(self.k[label], 3)}

    def calibration(self):
        return {NEAR_CLASSES[lbl][0]: {"calibrated": lbl in self.k, "threshold_cm": self.thresholds[lbl]}
                for lbl in NEAR_CLASSES}


class CloseupTracker:
    """Close-up sessions: near-work closer than its threshold, with smoothing.

    A session starts on the first close sighting and ends `gap_s` after the last one,
    so a few missed detections don't split it. If a different object stays the close
    one for `switch_s`, the session is split there. Sessions shorter than `min_s` are
    dropped (a glance at a phone). Each finished session: start, end, object,
    min/avg distance.
    """

    def __init__(self, gap_s=5.0, switch_s=5.0, min_s=10.0):
        self.gap_s, self.switch_s, self.min_s = gap_s, switch_s, min_s
        self.current = None          # {"start", "last", "object", "dists": [], "other": (kind, since)}

    def update(self, t, obj=None, distance_cm=None, close=False):
        """One front sample. obj/distance: the nearest near-work object (or None).
        Returns finished sessions (list of dicts) and whether a session started."""
        done, started = [], False
        cur = self.current
        if cur is not None and t - cur["last"] > self.gap_s:
            done += self._close(cur["last"])
            cur = None
        if close and obj is not None:
            if cur is None:
                cur = self.current = {"start": t, "last": t, "object": obj, "dists": [], "other": None}
                started = True
            elif obj != cur["object"]:
                if cur["other"] is None or cur["other"][0] != obj:
                    cur["other"] = (obj, t)
                elif t - cur["other"][1] >= self.switch_s:
                    split_t = cur["other"][1]
                    done += self._close(split_t)
                    cur = self.current = {"start": split_t, "last": t, "object": obj, "dists": [], "other": None}
                    started = True
            else:
                cur["other"] = None
            cur["last"] = t
            if obj == cur["object"]:
                cur["dists"].append(distance_cm)
        return done, started

    def _close(self, end):
        cur, self.current = self.current, None
        if cur is None or end - cur["start"] < self.min_s:
            return []
        d = [x for x in cur["dists"] if x is not None]
        return [{"start": cur["start"], "end": end, "object": cur["object"],
                 "min_cm": round(min(d), 1) if d else None, "avg_cm": round(sum(d) / len(d), 1) if d else None,
                 "samples": len(d)}]

    def flush(self, t):
        """Camera went offline / shutting down: end the open session."""
        return self._close(min(t, self.current["last"])) if self.current else []

    def open_session(self, t):
        cur = self.current
        if cur is None:
            return None
        return {"start": cur["start"], "object": cur["object"], "duration_s": round(t - cur["start"], 1)}


class HeadsUpTracker:
    """Heads-up = no near-work in view for at least `min_s` while the glasses are worn.

    The whole near-work-free stretch counts once it reaches min_s (it started at the
    last near-work sighting). It ends at the next near-work sighting or when the
    glasses come off. Each finished stretch is one heads-up break.
    """

    def __init__(self, min_s=20.0):
        self.min_s = min_s
        self.last_nearwork = None    # last time near-work was seen (or worn started)
        self.active_since = None     # start of the current heads-up stretch, once it counts

    def update(self, t, nearwork, worn=True):
        """Returns a finished stretch {"start", "end"} or None."""
        finished = None
        if not worn:
            finished = self._end(t)
            self.last_nearwork = None
            return finished
        if self.last_nearwork is None:
            self.last_nearwork = t                 # just put on: start counting from now
        if nearwork:
            finished = self._end(t)
            self.last_nearwork = t
        elif self.active_since is None and t - self.last_nearwork >= self.min_s:
            self.active_since = self.last_nearwork
        return finished

    def _end(self, t):
        if self.active_since is None:
            return None
        s, self.active_since = self.active_since, None
        return {"start": s, "end": t}

    def flush(self, t):
        return self._end(t)

    def active(self, t):
        return None if self.active_since is None else {"start": self.active_since,
                                                      "duration_s": round(t - self.active_since, 1)}
