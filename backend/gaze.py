"""Gaze direction (LEFT / CENTER / RIGHT) from the pupil position, mapped onto the FRONT frame.

The EYE and FRONT cameras are both fixed to the glasses, so where the eye points
inside its socket picks a part of what the front camera sees:

    pupil (x, y) from eye_tracking  ->  nearest calibrated centroid  ->  hysteresis
    ->  majority over the last 0.5 s  ->  "left" | "center" | "right"
    ->  the matching third of the FRONT frame (with ~15% overlap)

Calibration: "look left / straight ahead / right" for ~3 s each. The first 0.5 s
of every step is skipped (the eye is still moving) and frames without a pupil
(blinks) are ignored; the centroid is the median of what is left. Centroids are
stored per user AND eye method (profile "me@closeup", "me@facemesh") in
backend/data/calibration.json, because webcam and eye-camera pupil numbers mean different things. Without calibration, default
centroids from config are used and the state says calibrated: false.

The mapping from pupil x to gaze direction depends on how the eye camera is
mounted (mirrored or not); calibration learns it, so nothing here assumes a sign.
"""

import collections
import time

import numpy as np

from backend.distance import load_calibration, save_calibration
from backend.pupil import FEATURE_FLOORS, FEATURE_NAMES

REGIONS = ("left", "center", "right")
PROMPTS = {"left": "Look left", "center": "Look straight ahead", "right": "Look right"}


class GazeTracker:
    def __init__(self, cfg, user="me", say=None):
        g = cfg.get("gaze", {})
        self.user = user
        self.profile = f"{user}@{cfg.get('eye', {}).get('method', 'closeup')}"
        self.y_weight = float(g.get("y_weight", 0.5))   # how much up/down counts next to left/right
        self.say = say                                  # Voice.say, for calibration prompts
        self.step_s = g.get("calibration_step_s", 3.0)
        self.settle_s = g.get("settle_s", 0.5)
        self.window_s = g.get("smoothing_s", 0.5)
        self.hysteresis = g.get("hysteresis", 0.15)     # fraction of the left-right span
        # Dev: a webcam facing the wearer shows a mirror image of their view, so "look left"
        # must pick the right side of its picture. The real FRONT camera faces forward: False.
        self.front_mirrored = bool(g.get("front_mirrored", False))
        self.regions = {k: tuple(v) for k, v in g.get("regions", {
            "left": (0.0, 0.41), "center": (0.26, 0.74), "right": (0.59, 1.0)}).items()}
        saved = load_calibration().get("gaze", {}).get(self.profile)
        # A saved profile is {"left": [...], "center": [...], "right": [...]} (position only: 2 numbers
        # each; position + shape: one number per feature) plus optionally "scale": how much each feature
        # normally wobbles for this wearer, and "features": their names.
        self.centroids = {k: tuple(float(x) for x in saved[k]) for k in REGIONS if saved and k in saved} or {
            k: tuple(v) for k, v in g.get("default_centroids", {
                "left": (-0.25, 0.0), "center": (0.0, 0.0), "right": (0.25, 0.0)}).items()}
        self.scale = tuple(float(x) for x in saved["scale"]) if saved and saved.get("scale") else None
        self.feature_names = tuple(saved["features"]) if saved and saved.get("features") else None
        self.calibrated = saved is not None
        self.current = None                              # hysteresis output
        self.history = collections.deque()               # (t, raw label)
        self.smoothed = None
        self.last_pupil = None
        self.observed_at = None
        self._steps = []                                 # remaining calibration steps
        self._step = None                                # (region, t_start, samples)
        self._cal = {}                                   # region -> samples from this calibration run
        self.on_calibrated = None                        # callback(centroids)

    # -- calibration -------------------------------------------------------

    def start_calibration(self, regions=REGIONS):
        """Run the given steps in order (the app can also run one step at a time)."""
        self._steps = list(regions)
        self._step = None
        self._cal = {}

    def cancel_calibration(self):
        self._steps, self._step = [], None

    @property
    def calibrating(self):
        return self._step is not None or bool(self._steps)

    def calibration_status(self, t=None):
        t = t or time.time()
        if self._step is None:
            return {"active": bool(self._steps), "step": self._steps[0] if self._steps else None,
                    "remaining_s": None, "prompt": PROMPTS.get(self._steps[0]) if self._steps else None}
        region, t0, samples = self._step
        return {"active": True, "step": region, "prompt": PROMPTS[region],
                "remaining_s": round(max(0.0, self.step_s - (t - t0)), 1), "samples": len(samples)}

    def _advance_calibration(self, pupil, t):
        if self._step is None:
            if not self._steps:
                return
            region = self._steps[0]
            self._step = (region, t, [])
            if self.say:
                self.say(PROMPTS[region])
            return
        region, t0, samples = self._step
        if pupil is not None and t - t0 >= self.settle_s:
            samples.append(pupil)
        if t - t0 >= self.step_s:
            self._steps.pop(0)
            self._step = None
            if len(samples) >= 3:
                # median of every number (position and shape alike): one odd frame can't move it
                self.centroids[region] = tuple(float(v) for v in np.median(np.array(samples, float), axis=0))
                self._cal[region] = samples
            if not self._steps:
                self._finish_calibration()

    @staticmethod
    def scale_from_samples(by_class):
        """How much each number wobbles within a direction, pooled over the three directions.
        Classification divides by this, so a steady feature counts for more than a jittery one.
        The floor stops a feature that happened to be perfectly still from dominating."""
        spreads = []
        for samples in by_class.values():
            a = np.array(samples, float)
            med = np.median(a, axis=0)
            spreads.append((np.median(np.abs(a - med), axis=0) * 1.4826) ** 2)       # robust variance
        pooled = np.sqrt(np.mean(spreads, axis=0))
        floor = (np.asarray(FEATURE_FLOORS) if len(pooled) == len(FEATURE_FLOORS)
                 else np.full(len(pooled), 0.5 * float(np.median(pooled)) + 1e-6))
        return tuple(float(v) for v in np.maximum(pooled, floor))

    def _finish_calibration(self):
        self.calibrated = True
        data = load_calibration().get("gaze", {})
        saved = {k: list(v) for k, v in self.centroids.items()}
        dims = {len(v) for v in self.centroids.values()}
        if len(dims) == 1 and dims.pop() > 2 and set(self._cal) == set(REGIONS):
            self.scale = self.scale_from_samples(self._cal)          # position + shape: weigh by steadiness
            saved["scale"] = list(self.scale)
            if len(self.scale) == len(FEATURE_NAMES):
                self.feature_names = FEATURE_NAMES
                saved["features"] = list(FEATURE_NAMES)
        elif set(self._cal) == set(REGIONS):
            self.scale, self.feature_names = None, None              # position only
        else:                                                        # a partial run keeps what was there
            if self.scale is not None:
                saved["scale"] = list(self.scale)
            if self.feature_names is not None:
                saved["features"] = list(self.feature_names)
        data[self.profile] = saved
        save_calibration("gaze", data)
        self.current, self.smoothed = None, None
        self.history.clear()
        if self.say:
            self.say("Gaze calibrated")
        if self.on_calibrated:
            self.on_calibrated(dict(self.centroids))

    # -- classification ------------------------------------------------------

    def _shaped(self, vec):
        """True when this reading carries position + shape and the calibration was made that way."""
        return (self.scale is not None and len(vec) == len(self.scale)
                and all(len(c) == len(self.scale) for c in self.centroids.values()))

    def _distance(self, vec, region, shaped):
        c = self.centroids[region]
        if shaped:                                        # every feature in units of its own wobble
            return float(np.sqrt((((np.asarray(vec) - np.asarray(c)) / np.asarray(self.scale)) ** 2).sum()))
        return ((vec[0] - c[0]) ** 2 + (self.y_weight * (vec[1] - c[1])) ** 2) ** 0.5   # position only

    def _span(self, shaped=False):
        """How far apart left and right are, in the same units as _distance."""
        if not all(r in self.centroids for r in ("left", "right")):
            return 0.5
        if shaped:
            return self._distance(self.centroids["left"], "right", True)
        return abs(self.centroids["left"][0] - self.centroids["right"][0])

    def classify_raw(self, pupil):
        """Nearest centroid, with hysteresis: the current label is kept unless another
        centroid is closer by more than `hysteresis` x the left-right span. `pupil` is (x, y),
        or position + shape (see backend/pupil.py FEATURE_NAMES) when calibrated that way."""
        shaped = self._shaped(pupil)
        dist = lambda r: self._distance(pupil, r, shaped)
        best = min(self.centroids, key=dist)
        if self.current is not None and best != self.current and self.current in self.centroids:
            if dist(self.current) - dist(best) < self.hysteresis * self._span(shaped):
                best = self.current
        self.current = best
        return best

    def update(self, pupil, t):
        """Feed every eye frame. pupil: (x, y), or position + shape, or None. Returns the state dict."""
        self.last_pupil = pupil
        if self.calibrating:
            self._advance_calibration(pupil, t)
        if pupil is not None and not self.calibrating:
            self.observed_at = t
            self.history.append((t, self.classify_raw(pupil)))
        while self.history and self.history[0][0] < t - self.window_s:
            self.history.popleft()
        if self.history:
            counts = collections.Counter(label for _, label in self.history)
            top = counts.most_common()
            # Keep the previous answer on a tie, so it does not flicker.
            if self.smoothed is None or counts[self.smoothed] < top[0][1]:
                self.smoothed = top[0][0]
        return self.state(t)

    def state(self, t=None):
        return {
            "gaze": self.smoothed,
            "gaze_calibrated": self.calibrated,
            "gaze_calibration": self.calibration_status(t) if self.calibrating else None,
        }

    # -- mapping onto the FRONT frame -----------------------------------------

    def region_bounds(self, region, width):
        """Pixel columns [x0, x1) of a region in a frame `width` wide."""
        if region in (None, "all"):
            return 0, width
        if self.front_mirrored and region in ("left", "right"):
            region = "right" if region == "left" else "left"
        a, b = self.regions[region]
        return int(round(a * width)), int(round(b * width))

    def crop(self, frame, region):
        """(crop, x_offset) of the FRONT frame for a region ("all" or None = whole frame)."""
        x0, x1 = self.region_bounds(region, frame.shape[1])
        return frame[:, x0:x1], x0
