"""Runs every pipeline plus the API in one process.

    python -m backend.main                     # the product: ESP32-CAM streams + FPGA rear events
    python -m backend.main --dev               # no hardware: webcam / still images / synthetic stand-ins
    python -m backend.main --dev --preview     # also show annotated camera windows
    python -m backend.main --dev --front sample:bus.jpg

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
from backend.gaze import GazeTracker
from backend.rear_alert import RearAlert
from backend.speech import Voice
from backend.assist import Assistant
from backend.muse_client import MuseClient
from backend.vision import Detector
from backend.streams import StreamManager, blank

STORED_EVENTS = {"blink", "squint_start", "squint_end", "too_close_start", "too_close_end",
                 "alert", "calibrated", "break", "facetime", "gaze_calibrated"}   # "assist" is stored by Assistant
QUIET_EVENTS = {"blink", "speak"}      # not printed (speak is printed by the voice itself)


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
        self.voice = Voice(cfg, emit=self.emit)

        self.eye = EyeTracker(cfg)
        self.gaze = GazeTracker(cfg, say=self.voice.say)
        self.gaze.on_calibrated = lambda c: self.emit("gaze_calibrated", {k: list(v) for k, v in c.items()})
        eye_reader, front_reader = self.streams.get("eye"), self.streams.get("front")
        self.shared_face = (eye_reader is front_reader and isinstance(self.eye.extractor, FaceMeshEyes)
                            and cfg["distance"].get("method", "face") == "face")
        self.distance = DistanceEstimator(cfg, face_mesh=self.eye.extractor.mesh if self.shared_face else None)
        self.rear_mode = cfg.get("rear", {}).get("mode", "fpga")
        # rear.mode: software runs lgmd.py on a rear stream; fpga mode gets events instead (backend/rear).
        v = cfg.get("vision", {})
        self.detector = Detector(v.get("model", "yolov8n.pt"), v.get("min_conf", 0.35))
        self.muse = MuseClient(cfg, self.db)
        self.assistant = Assistant(self.streams.cameras.get("front"), self.detector, self.muse, self.gaze,
                                   self.voice, self.emit, focal_px=self.distance._focal, db=self.db)
        self.rear = (RearAlert(cfg, speaker=self.voice)
                     if self.rear_mode == "software" and "rear" in cfg.get("cameras", {}) else None)
        self.camera_state = {}                         # camera name -> "online" | "offline"

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
        if kind not in QUIET_EVENTS:
            print(f"[event] {kind} {data if data is not None else ''}\n", end="")   # one write: no interleaving
        if self.bridge:
            if kind == "blink":
                self.bridge.on_blink()
            elif kind == "alert" and self.rear is not None:
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
        pupil = state.get("pupil")
        self._update_live(**self.gaze.update(tuple(pupil) if pupil else None, t))
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

    def _set_camera_state(self, cams, state, source):
        """Track online/offline per camera; on offline, clear that camera's live values
        so the dashboard never shows numbers from a dead stream."""
        changed = [c for c in cams if self.camera_state.get(c) != state]
        if not changed:
            return
        for c in changed:
            self.camera_state[c] = state
        if state == "offline":
            if "eye" in changed:
                self._update_live(eye_detected=False, openness=None, openness_ratio=None, pupil=None)
            if "front" in changed:
                self._update_live(distance_cm=None, too_close=False, too_close_for_s=0)
        self._update_live(cameras=dict(self.camera_state))
        for c in changed:
            self.emit(f"camera_{state}", {"camera": c, "source": source})

    def _loop(self, name, reader, steps, annotators):
        cams = name.split("+")
        label = " + ".join(c.upper() for c in cams)
        seq, min_dt, last = 0, 1.0 / self.fps, 0.0
        while not self._stop.is_set():
            seq, frame, t = reader.wait_new(seq, timeout=0.5)
            st = reader.status()
            if frame is None or not st["ok"]:
                self._set_camera_state(cams, "offline", st["source"])
                self.frames[name] = blank(f"{label} camera offline - retrying {st['source']}")
                continue
            self._set_camera_state(cams, "online", st["active"])
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
        if self.rear is not None:
            loops.append(("rear", s.get("rear"), [self._rear_step], [self.rear.annotate]))
        elif self.rear_mode == "fpga":
            print("[rear] fpga mode: rear warnings come from FPGA events (docs/rear_event_protocol.md)")
        for name, reader, steps, ann in loops:
            threading.Thread(target=self._loop, args=(name, reader, steps, ann), name=name, daemon=True).start()
        self.pipeline_names = [n for n, *_ in loops]
        threading.Thread(target=self._sampler, name="sampler", daemon=True).start()
        threading.Thread(target=self.detector._load, name="yolo-load", daemon=True).start()   # warm up
        m = self.muse.usage()
        print(f"[muse] {m['model']}: {'key found' if m['has_key'] else 'NO KEY (local answers only)'}, "
              f"spent ${m['total_usd']:.4f} of ${m['lifetime_cap_usd']:.2f}")

        if self.cfg.get("screentime", {}).get("mac_tracker", True):
            from backend.screentime import MacAppTracker
            MacAppTracker(self.db, self.cfg["screentime"].get("poll_s", 5)).start()
        if self.cfg.get("app_bridge", {}).get("enabled"):
            from backend.app_bridge import AppBridge
            rear_reader = s.get("rear") if self.rear is not None else None
            self.bridge = AppBridge(self.cfg, self.live, rear_reader).start()
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
    ap.add_argument("--dev", action="store_true",
                    help="dev mode: merge backend/config.dev.yaml (webcam / still image / synthetic stand-ins)")
    ap.add_argument("--eye", help="override cameras.eye.source")
    ap.add_argument("--front", help="override cameras.front.source")
    ap.add_argument("--rear", help="override cameras.rear.source")
    ap.add_argument("--eye-method", choices=("closeup", "facemesh"),
                    help="override eye.method (e.g. --dev --eye synthetic-eye --eye-method closeup)")
    ap.add_argument("--port", type=int, help="override api.port")
    ap.add_argument("--phone", help="override app_bridge.phone_ip")
    ap.add_argument("--speech", choices=("auto", "say", "pyttsx3", "print", "off"),
                    help="override speech.laptop (print = no sound on the laptop)")
    ap.add_argument("--preview", action="store_true", help="show annotated camera windows")
    args = ap.parse_args(argv)

    cfg = load_config(args.config, dev=args.dev)
    for cam in ("eye", "front", "rear"):
        if getattr(args, cam) is not None:
            cfg["cameras"].setdefault(cam, {})["source"] = getattr(args, cam)
    if args.eye_method == "closeup":
        # Product eye settings, even on top of the dev overlay.
        cfg["eye"].update(method="closeup", default_baseline=1.0, blink_min_frames=2, blink_max_frames=7)
    elif args.eye_method:
        cfg["eye"]["method"] = args.eye_method
    print(f"[mode] {'DEV (stand-in cameras, not the product)' if args.dev else 'product'}: "
          + ", ".join(f"{k}={v.get('source')}" for k, v in cfg["cameras"].items())
          + f", rear.mode={cfg['rear'].get('mode')}")
    if not args.dev and (cfg["eye"].get("method") == "facemesh" or cfg["distance"].get("method") == "face"):
        print("[mode] warning: facemesh eye tracking / face-width distance are DEV ONLY methods")
    if args.port:
        cfg["api"]["port"] = args.port
    if args.phone:
        cfg["app_bridge"]["phone_ip"] = args.phone
    if args.speech:
        cfg.setdefault("speech", {})["laptop"] = args.speech
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
