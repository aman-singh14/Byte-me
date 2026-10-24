"""Gaze direction (LEFT / CENTER / RIGHT) from the pupil position, mapped onto the FRONT frame.

The EYE and FRONT cameras are both fixed to the glasses, so where the eye points
inside its socket picks a part of what the front camera sees:

    pupil (x, y) from eye_tracking  ->  nearest calibrated centroid  ->  hysteresis
    ->  majority over the last 0.5 s  ->  "left" | "center" | "right"
    ->  the matching third of the FRONT frame (with ~15% overlap)

Calibration: "look left / straight ahead / right" for ~3 s each. The first 0.5 s
of every step is skipped (the eye is still moving) and frames without a pupil
(blinks) are ignored; the centroid is the median of what is left. Centroids are
stored per user in backend/data/calibration.json. Without calibration, default
centroids from config are used and the state says calibrated: false.

The mapping from pupil x to gaze direction depends on how the eye camera is
mounted (mirrored or not); calibration learns it, so nothing here assumes a sign.
"""

import collections
import time

from backend.distance import load_calibration, save_calibration

REGIONS = ("left", "center", "right")
PROMPTS = {"left": "Look left", "center": "Look straight ahead", "right": "Look right"}


class GazeTracker:
    def __init__(self, cfg, user="me", say=None):
        g = cfg.get("gaze", {})
        self.user = user
        self.say = say                                  # Voice.say, for calibration prompts
        self.step_s = g.get("calibration_step_s", 3.0)
        self.settle_s = g.get("settle_s", 0.5)
        self.window_s = g.get("smoothing_s", 0.5)
        self.hysteresis = g.get("hysteresis", 0.15)     # fraction of the left-right span
        self.regions = {k: tuple(v) for k, v in g.get("regions", {
            "left": (0.0, 0.41), "center": (0.26, 0.74), "right": (0.59, 1.0)}).items()}
        saved = load_calibration().get("gaze", {}).get(user)
        self.centroids = {k: tuple(v) for k, v in (saved or g.get("default_centroids", {
            "left": (-0.25, 0.0), "center": (0.0, 0.0), "right": (0.25, 0.0)})).items()}
        self.calibrated = saved is not None
        self.current = None                              # hysteresis output
        self.history = collections.deque()               # (t, raw label)
        self.smoothed = None
        self.last_pupil = None
        self._steps = []                                 # remaining calibration steps
        self._step = None                                # (region, t_start, samples)
        self.on_calibrated = None                        # callback(centroids)

    # -- calibration -------------------------------------------------------

    def start_calibration(self, regions=REGIONS):
        """Run the given steps in order (the app can also run one step at a time)."""
        self._steps = list(regions)
        self._step = None

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
                xs = sorted(p[0] for p in samples)
                ys = sorted(p[1] for p in samples)
                self.centroids[region] = (xs[len(xs) // 2], ys[len(ys) // 2])
            if not self._steps:
                self._finish_calibration()

    def _finish_calibration(self):
        self.calibrated = True
        data = load_calibration().get("gaze", {})
        data[self.user] = {k: list(v) for k, v in self.centroids.items()}
        save_calibration("gaze", data)
        self.current, self.smoothed = None, None
        self.history.clear()
        if self.say:
            self.say("Gaze calibrated")
        if self.on_calibrated:
            self.on_calibrated(dict(self.centroids))

    # -- classification ------------------------------------------------------

    def _span(self):
        xs = [self.centroids[r][0] for r in ("left", "right") if r in self.centroids]
        return abs(xs[0] - xs[1]) if len(xs) == 2 else 0.5

    def classify_raw(self, pupil):
        """Nearest centroid, with hysteresis: the current label is kept unless another
        centroid is closer by more than `hysteresis` x the left-right span."""
        def dist(r):
            cx, cy = self.centroids[r]
            return ((pupil[0] - cx) ** 2 + (0.5 * (pupil[1] - cy)) ** 2) ** 0.5   # x matters most
        best = min(self.centroids, key=dist)
        if self.current is not None and best != self.current and self.current in self.centroids:
            if dist(self.current) - dist(best) < self.hysteresis * self._span():
                best = self.current
        self.current = best
        return best

    def update(self, pupil, t):
        """Feed every eye frame. pupil: (x, y) or None. Returns the state dict."""
        self.last_pupil = pupil
        if self.calibrating:
            self._advance_calibration(pupil, t)
        if pupil is not None and not self.calibrating:
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
        a, b = self.regions[region]
        return int(round(a * width)), int(round(b * width))

    def crop(self, frame, region):
        """(crop, x_offset) of the FRONT frame for a region ("all" or None = whole frame)."""
        x0, x1 = self.region_bounds(region, frame.shape[1])
        return frame[:, x0:x1], x0
