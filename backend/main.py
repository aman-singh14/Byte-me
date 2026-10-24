"""Runs every pipeline plus the API in one process.

    python -m backend.main                     # cameras from backend/config.yaml, API on :8000
    python -m backend.main --preview           # also show annotated camera windows
    python -m backend.main --eye 0 --front 0 --rear http://rear-cam.local:81/stream

Threads: one stream reader per distinct source, one pipeline per camera (eye and
front share one when they use the same source, so Face Mesh runs once per
frame), a 1 Hz sampler that writes to SQLite, the Mac app tracker, the app
bridge, and uvicorn.
"""

import argparse
import collections
import threading
import time

import cv2
import numpy as np

import lgmd
from backend.config import load_config
from backend.db import DB
from backend.distance import DistanceEstimator
from backend.eye_tracking import EyeTracker, FaceMeshEyes
from backend.rear_alert import RearAlert
from backend.streams import StreamManager, blank

STORED_EVENTS = {"blink", "squint_start", "squint_end", "too_close_start", "too_close_end",
                 "alert", "calibrated", "break", "facetime"}


class Session:
    """Screen session: continuous face presence. A gap of break_s or more is a break."""

    def __init__(self, break_s=20):
        self.break_s = break_s
        self.start = None
        self.last_face = None

    def update(self, face, t):
        """Returns ("break", seconds) when a break just ended, else None."""
        ev = None
        if face:
            if self.last_face is not None and t - self.last_face >= self.break_s:
                ev = ("break", round(t - self.last_face, 1))
                self.start = t
            if self.start is None:
                self.start = t
            self.last_face = t
        return ev

    def minutes(self, t):
        if self.start is None or self.last_face is None or t - self.last_face >= self.break_s:
            return 0.0
        return (t - self.start) / 60


class Runtime:
    def __init__(self, cfg):
        self.cfg = cfg
        self.db = DB(cfg["db"]["path"])
        self.streams = StreamManager(cfg)
        self.fps = cfg.get("pipelines", {}).get("fps", 15)
        self._lock = threading.Lock()
        self._live = {"started": time.time()}
        self.recent = collections.deque(maxlen=200)    # (id, event dict) for the WebSocket
        self._event_id = 0
        self.frames = {}                               # camera name -> latest annotated frame
        self.session = Session(cfg.get("recommendations", {}).get("break_s", 20))
        self.bridge = None
        self._stop = threading.Event()

        self.eye = EyeTracker(cfg)
        eye_reader, front_reader = self.streams.get("eye"), self.streams.get("front")
        self.shared_face = (eye_reader is front_reader and isinstance(self.eye.extractor, FaceMeshEyes)
                            and cfg["distance"].get("method", "face") == "face")
        self.distance = DistanceEstimator(cfg, face_mesh=self.eye.extractor.mesh if self.shared_face else None)
        self.rear = RearAlert(cfg)

    # -- state shared with the API --------------------------------------------

    def live(self):
        with self._lock:
            d = dict(self._live)
        now = time.time()
        d["session_min"] = round(self.session.minutes(now), 1)
        d["ts"] = now
        return d

    def _update_live(self, **kw):
        with self._lock:
            self._live.update(kw)

    def events_after(self, last_id):
        with self._lock:
            return [e for i, e in self.recent if i > last_id], self._event_id

    def emit(self, kind, data=None, t=None):
        t = t or time.time()
        if kind in STORED_EVENTS:
            self.db.add_event(t, kind, data)
        with self._lock:
            self._event_id += 1
            self.recent.append((self._event_id, {"id": self._event_id, "ts": t, "kind": kind, "data": data}))
        if kind != "blink":
            print(f"[event] {kind} {data if data is not None else ''}")
        if self.bridge:
            if kind == "blink":
                self.bridge.on_blink()
            elif kind == "alert":
                k_left, _, k_right = lgmd.wearer_sides(self.rear.out, self.rear.flip)
                self.bridge.on_alert(data["side"], data["k"], k_left, k_right)

    # -- pipelines ----------------------------------------------------------

    def _eye_step(self, frame, t):
        state, events = self.eye.process(frame, t)
        self._update_live(**state)
        for kind, val in events:
            if kind == "calibrated":
                data = {"baseline": round(val, 4)}
            elif val is None:            # squint_start
                data = None
            else:                        # blink, squint_end
                data = {"duration_s": round(val, 3)}
            self.emit(kind, data, t)
        brk = self.session.update(state["eye_detected"], t)
        if brk:
            self.emit("break", {"duration_s": brk[1]}, t)

    def _front_step(self, frame, t):
        lm = self.eye.extractor.last_landmarks if self.shared_face else None
        state, events = self.distance.process(frame, t, landmarks=lm)
        lux = float(np.mean(frame)) * 4   # very rough: the app wants a lux number
        self._update_live(**state, lux_est=round(lux))
        for kind, val in events:
            self.emit(kind, {"distance_cm": val} if kind == "too_close_start" else {"duration_s": val}, t)

    def _rear_step(self, frame, t):
        state, events = self.rear.process(frame, t)
        self._update_live(rear=state)
        for kind, data in events:
            self.emit(kind, data, t)

    def _loop(self, name, reader, steps, annotators):
        seq, min_dt, last = 0, 1.0 / self.fps, 0.0
        while not self._stop.is_set():
            seq, frame, t = reader.wait_new(seq, timeout=0.5)
            if frame is None:
                self.frames[name] = blank(f"{name}: waiting for {reader.status()['source']}")
                continue
            if t - last < min_dt:
                continue
            last = t
            try:
                for step in steps:
                    step(frame, t)
                img = frame.copy()
                for a in annotators:
                    a(img)
                self.frames[name] = img
            except Exception as e:   # one bad frame must not kill the pipeline
                print(f"[{name}] error: {e!r}")
                time.sleep(0.2)

    def _sampler(self):
        every = self.cfg.get("db", {}).get("sample_every_s", 1.0)
        while not self._stop.wait(every):
            d = self.live()
            face = bool(d.get("eye_detected") or d.get("distance_cm") is not None)
            self.db.add_sample(d["ts"], d.get("blink_rate"), d.get("openness"), d.get("squinting"),
                               d.get("distance_cm"), d.get("too_close"), face)

    def start(self):
        s = self.streams
        loops = []
        if self.shared_face:
            loops.append(("eye+front", s.get("eye"), [self._eye_step, self._front_step],
                          [self.eye.annotate, self.distance.annotate]))
        else:
            loops.append(("eye", s.get("eye"), [self._eye_step], [self.eye.annotate]))
            loops.append(("front", s.get("front"), [self._front_step], [self.distance.annotate]))
        loops.append(("rear", s.get("rear"), [self._rear_step], [self.rear.annotate]))
        for name, reader, steps, ann in loops:
            threading.Thread(target=self._loop, args=(name, reader, steps, ann), name=name, daemon=True).start()
        self.pipeline_names = [n for n, *_ in loops]
        threading.Thread(target=self._sampler, name="sampler", daemon=True).start()

        if self.cfg.get("screentime", {}).get("mac_tracker", True):
            from backend.screentime import MacAppTracker
            MacAppTracker(self.db, self.cfg["screentime"].get("poll_s", 5)).start()
        if self.cfg.get("app_bridge", {}).get("enabled"):
            from backend.app_bridge import AppBridge
            self.bridge = AppBridge(self.cfg, self.live, s.get("rear")).start()
        return self

    def frame(self, name):
        """Latest annotated frame for a camera name (eye, front, rear) or pipeline name."""
        if name in self.frames:
            return self.frames[name]
        for key, img in self.frames.items():
            if name in key.split("+"):
                return img
        return None

    def stop(self):
        self._stop.set()
        if self.bridge:
            self.bridge.stop()
        self.streams.close()


def main(argv=None):
    import uvicorn

    from backend.api import create_app

    ap = argparse.ArgumentParser(description="Mega Glasses backend: pipelines + API")
    ap.add_argument("--config", default=None, help="config file (default backend/config.yaml)")
    ap.add_argument("--eye", help="override cameras.eye.source")
    ap.add_argument("--front", help="override cameras.front.source")
    ap.add_argument("--rear", help="override cameras.rear.source")
    ap.add_argument("--port", type=int, help="override api.port")
    ap.add_argument("--phone", help="override app_bridge.phone_ip")
    ap.add_argument("--speech", choices=("auto", "say", "pyttsx3", "print", "off"),
                    help="override rear.speech (print = no sound)")
    ap.add_argument("--preview", action="store_true", help="show annotated camera windows")
    args = ap.parse_args(argv)

    cfg = load_config(args.config)
    for cam in ("eye", "front", "rear"):
        if getattr(args, cam) is not None:
            cfg["cameras"][cam]["source"] = getattr(args, cam)
    if args.port:
        cfg["api"]["port"] = args.port
    if args.phone:
        cfg["app_bridge"]["phone_ip"] = args.phone
    if args.speech:
        cfg["rear"]["speech"] = args.speech

    rt = Runtime(cfg).start()
    app = create_app(rt)
    host, port = cfg["api"].get("host", "0.0.0.0"), cfg["api"].get("port", 8000)
    print(f"[api] dashboard http://localhost:{port}/   docs http://localhost:{port}/docs")
    server = uvicorn.Server(uvicorn.Config(app, host=host, port=port, log_level="warning"))
    try:
        if args.preview:
            # macOS only allows windows on the main thread, so the API goes to a thread.
            threading.Thread(target=server.run, name="api", daemon=True).start()
            while True:
                for name in rt.pipeline_names:
                    img = rt.frames.get(name)
                    if img is not None:
                        cv2.imshow(name, img)
                key = cv2.waitKey(30) & 0xFF
                if key in (ord("q"), 27):
                    break
                if key == ord("c"):
                    rt.eye.calibrate()
        else:
            server.run()
    except KeyboardInterrupt:
        pass
    finally:
        server.should_exit = True
        rt.stop()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
