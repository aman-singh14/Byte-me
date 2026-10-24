"""FRONT camera analysis, run a few times a second: near-work + distance, close-up
sessions, heads-up stretches and outdoor detection. Muse is never called from here.

Results go to SQLite (closeup_sessions, intervals) and to the rings/points (rings.py).
"""

import time

from backend.nearwork import CloseupTracker, HeadsUpTracker, NearWorkEstimator
from backend.outdoor import OutdoorDetector


class FrontAnalyzer:
    def __init__(self, cfg, db, detector, rings, emit, worn_fn, sensor_fn):
        n = cfg.get("nearwork", {})
        self.db, self.rings, self.emit = db, rings, emit
        self.worn_fn = worn_fn            # callable -> True while the eye camera sees an eye
        self.sensor_fn = sensor_fn        # callable -> {"exposure_lines", "gain"} or None
        self.nearwork = NearWorkEstimator(cfg, detector)
        self.closeup = CloseupTracker(n.get("session_gap_s", 5.0), n.get("switch_s", 5.0), n.get("min_session_s", 10.0))
        self.headsup = HeadsUpTracker(cfg.get("rings", {}).get("heads_up_after_s", 20.0))
        self.outdoor = OutdoorDetector(cfg)
        self.state = {}

    def _session_done(self, s):
        self.db.add_closeup_session(s)
        self.emit("closeup_end", s, s["end"])

    def process(self, frame, t):
        nw = self.nearwork.process(frame, t)
        worn = self.worn_fn()

        done, started = self.closeup.update(t, nw["nearwork_object"], nw["nearwork_distance_cm"], nw["nearwork_close"])
        for s in done:
            self._session_done(s)
        if started:
            self.emit("closeup_start", {"object": nw["nearwork_object"], "distance_cm": nw["nearwork_distance_cm"]}, t)

        was_active = self.headsup.active_since is not None
        hu = self.headsup.update(t, nw["nearwork"], worn)
        if hu:
            self.rings.stretch_ended("heads_up", hu["start"], hu["end"])
            self.emit("heads_up_end", {**hu, "duration_s": round(hu["end"] - hu["start"], 1)}, t)
        if not was_active and self.headsup.active_since is not None:
            self.rings.stretch_started("heads_up", self.headsup.active_since)
            self.emit("heads_up_start", {"since": self.headsup.active_since}, t)

        if worn or self.outdoor.manual is not None:
            ev = self.outdoor.update(t, frame, self.sensor_fn())
        else:                             # glasses off: outside time stops counting
            out = self.outdoor.flush(t)
            ev = ("outside_end", out) if out else None
        if ev and ev[0] == "outside_start":
            self.rings.stretch_started("outside", ev[1])
            self.emit("outside_start", {"since": ev[1]}, t)
        elif ev and ev[0] == "outside_end":
            self.rings.stretch_ended("outside", ev[1]["start"], ev[1]["end"])
            self.emit("outside_end", ev[1], t)
        self.rings.check_goals(t)

        self.state = {**nw, "closeup_session": self.closeup.open_session(t),
                      "heads_up": self.headsup.active(t), **{f"outdoor_{k}": v for k, v in self.outdoor.state(t).items()}}
        return self.state

    def annotate(self, img):
        """Preview: a box on everything YOLO sees. Near-work objects are labelled with their
        distance (green = comfortable, orange = close-up); anything else is grey and ignored."""
        import cv2
        near = {tuple(o["box"]): o for o in self.nearwork.last}
        for d in self.nearwork.all_detections:
            x0, y0, x1, y1 = (int(v) for v in d.box)
            o = near.get(tuple(d.box))
            if o is None:
                cv2.rectangle(img, (x0, y0), (x1, y1), (150, 150, 150), 1)
                cv2.putText(img, f"{d.label} (ignored)", (x0 + 3, max(y0 - 5, 12)), cv2.FONT_HERSHEY_SIMPLEX, 0.45,
                            (150, 150, 150), 1)
                continue
            color = (0, 140, 255) if o["close"] else (0, 200, 0)
            cv2.rectangle(img, (x0, y0), (x1, y1), color, 2)
            text = f"{o['kind']} {o['distance_cm']:.0f} cm" + (" CLOSE" if o["close"] else "")
            cv2.putText(img, text, (x0 + 3, max(y0 - 6, 14)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, color, 2)
        s = self.state
        bits = []
        if s.get("closeup_session"):
            bits.append(f"close-up: {s['closeup_session']['object']} {s['closeup_session']['duration_s']:.0f}s")
        if s.get("heads_up"):
            bits.append(f"HEADS-UP {s['heads_up']['duration_s']:.0f}s")
        bits.append("outside" if s.get("outdoor_outside") else "inside")
        h = img.shape[0]
        cv2.putText(img, "   ".join(bits), (8, h - 34), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (255, 255, 255), 2)
        return img

    def flush(self, t=None):
        """FRONT camera offline (or shutdown): close open sessions/stretches."""
        t = t or time.time()
        for s in self.closeup.flush(t):
            self._session_done(s)
        hu = self.headsup.flush(t)
        if hu:
            self.rings.stretch_ended("heads_up", hu["start"], hu["end"])
        out = self.outdoor.flush(t)
        if out:
            self.rings.stretch_ended("outside", out["start"], out["end"])
