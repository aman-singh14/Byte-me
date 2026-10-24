"""Outside time from the FRONT camera, with the sensor's auto-exposure taken out.

The OV2640's auto-exposure keeps the image's mean brightness roughly constant, so a
sunny street and an office look alike in raw pixels. What changes is how hard the
sensor works: outdoors it uses a short exposure and low gain. So:

    scene brightness ~ mean_luma / (exposure_lines * gain)          (log10 below)

The ESP32 serves the live exposure (AEC) and gain (AGC) at http://<front-cam>/sensor
(firmware/esp32cam). Outdoors = brightness above a threshold for >= hold_s (60 s),
indoors again = below a lower threshold for >= hold_s (hysteresis). A blue, bright
upper third (sky) lowers the threshold a little. Without fresh sensor data there is
no outdoor call (raw luminance alone is not trusted).
"""

import json
import math
import threading
import time
import urllib.request

import cv2
import numpy as np

from backend.distance import load_calibration, save_calibration


def scene_brightness(mean_luma, exposure_lines, gain):
    """log10 of exposure-normalized brightness, or None without usable sensor values."""
    if exposure_lines is None or gain is None or exposure_lines <= 0 or gain <= 0:
        return None
    return math.log10(max(mean_luma, 1.0) / (exposure_lines * gain))


def sky_fraction(frame):
    """Fraction of the top third that looks like sky (blue-ish, bright)."""
    top = frame[: frame.shape[0] // 3]
    hsv = cv2.cvtColor(top, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    sky = ((h >= 90) & (h <= 130) & (s >= 40) & (v >= 120)) | ((s < 30) & (v >= 220))   # blue or bright overcast
    return float(sky.mean())


def gain_from_ov2640(reg):
    """OV2640 sensor-bank register 0x00 (GAIN) -> multiplier: (b7+1)(b6+1)(b5+1)(b4+1)(1 + b[3:0]/16)."""
    g = 1.0
    for bit in (7, 6, 5, 4):
        g *= 2.0 if reg & (1 << bit) else 1.0
    return g * (1 + (reg & 0x0F) / 16.0)


class OutdoorDetector:
    def __init__(self, cfg):
        o = cfg.get("outdoor", {})
        self.hold_s = o.get("hold_s", 60.0)
        self.band = o.get("hysteresis_log", 0.25)         # +- around the threshold, in log10 units
        self.sky_boost = o.get("sky_boost_log", 0.2)
        self.sky_min = o.get("sky_min_fraction", 0.3)
        cal = load_calibration().get("outdoor", {})
        self.indoor_ref = cal.get("indoor")
        self.outdoor_ref = cal.get("outdoor")
        self.threshold = self._threshold(o.get("threshold_log", 0.0))
        self.outside = False
        self._candidate_since = None      # when the opposite condition started
        self.since = None                 # start of the current outside stretch
        self.manual = None                # dev override: True / False / None
        self.last = {}

    def _threshold(self, default):
        if self.indoor_ref is not None and self.outdoor_ref is not None:
            return (self.indoor_ref + self.outdoor_ref) / 2
        return default

    def update(self, t, frame=None, sensor=None):
        """One sample. sensor: {"exposure_lines", "gain"} (fresh) or None.
        Returns ("outside_start", t0) / ("outside_end", stretch) / None."""
        luma = float(np.mean(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY))) if frame is not None else None
        b = (scene_brightness(luma, sensor.get("exposure_lines"), sensor.get("gain"))
             if sensor and luma is not None else None)
        sky = sky_fraction(frame) if frame is not None else 0.0
        thr = self.threshold - (self.sky_boost if sky >= self.sky_min else 0.0)
        hi, lo = thr + self.band, thr - self.band
        self.last = {"brightness_log": None if b is None else round(b, 3), "luma": None if luma is None else round(luma, 1),
                     "sky": round(sky, 2), "threshold_log": round(thr, 3), "sensor_ok": b is not None,
                     "manual": self.manual}

        if self.manual is not None:
            want = self.manual
            hold = 0.0
        elif b is None:
            return None                   # no trustworthy reading: keep the current state
        else:
            want = b > hi if not self.outside else not (b < lo)
            hold = self.hold_s

        if want == self.outside:
            self._candidate_since = None
            return None
        if self._candidate_since is None:
            self._candidate_since = t
        if t - self._candidate_since < hold:
            return None
        start = self._candidate_since
        self._candidate_since = None
        self.outside = want
        if want:
            self.since = start            # the stretch began when it first got bright
            return ("outside_start", start)
        stretch = {"start": self.since, "end": start}
        self.since = None
        return ("outside_end", stretch)

    def flush(self, t):
        if self.outside and self.since is not None:
            s, self.since, self.outside = self.since, None, False
            return {"start": s, "end": t}
        return None

    def calibrate(self, where):
        """Record the current brightness as typical 'indoor' or 'outdoor'."""
        b = self.last.get("brightness_log")
        if b is None:
            raise ValueError("no exposure data from the front camera yet")
        if where not in ("indoor", "outdoor"):
            raise ValueError("where must be indoor or outdoor")
        setattr(self, f"{where}_ref", b)
        save_calibration("outdoor", {"indoor": self.indoor_ref, "outdoor": self.outdoor_ref})
        self.threshold = self._threshold(self.threshold)
        return {"where": where, "brightness_log": b, "threshold_log": round(self.threshold, 3)}

    def state(self, t):
        return {"outside": self.outside, "outside_since": self.since, **self.last}


class SensorPoller:
    """Polls the FRONT camera's /sensor JSON once a second. get() -> fresh dict or None."""

    def __init__(self, base_url_fn, every_s=1.0, max_age_s=5.0):
        self.base_url_fn = base_url_fn    # callable -> "http://172.20.10.3" or None
        self.every_s, self.max_age_s = every_s, max_age_s
        self._latest = None
        self._t = 0.0
        self._stop = threading.Event()
        self.error = None

    @staticmethod
    def parse(d):
        """ESP32 /sensor JSON -> {"exposure_lines", "gain"}."""
        exp = d.get("aec_lines")
        gain = d.get("gain_x")
        if gain is None and "gain_reg" in d:
            gain = gain_from_ov2640(int(d["gain_reg"]))
        return {"exposure_lines": exp, "gain": gain, "raw": d}

    def get(self):
        if self._latest is None or time.time() - self._t > self.max_age_s:
            return None
        return self._latest

    def _loop(self):
        while not self._stop.wait(self.every_s):
            base = self.base_url_fn()
            if not base:
                continue
            try:
                with urllib.request.urlopen(f"{base}/sensor", timeout=1.0) as r:
                    self._latest, self._t, self.error = self.parse(json.load(r)), time.time(), None
            except (OSError, ValueError) as e:
                self.error = repr(e)

    def start(self):
        threading.Thread(target=self._loop, name="front-sensor", daemon=True).start()
        return self

    def stop(self):
        self._stop.set()
