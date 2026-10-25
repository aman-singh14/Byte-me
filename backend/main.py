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
import os
import threading
import time

try:  # python.org's macOS Python has no CA certificates: model downloads (Face Mesh, YOLO) fail without this
    import certifi
    os.environ.setdefault("SSL_CERT_FILE", certifi.where())
except ImportError:
    pass

import cv2
import numpy as np

import lgmd
from backend.config import load_config
from backend.db import DB
from backend.distance import DistanceEstimator
from backend.discovery import CameraDirectory
from backend.eye_tracking import EyeTracker, FaceMeshEyes, LowBlinkMonitor
from backend.front import FrontAnalyzer
from backend.outdoor import SensorPoller
from backend.rings import Rings
from backend.gaze import GazeTracker
from backend.rear_alert import RearAlert
from backend.speech import Voice
from backend.assist import Assistant
from backend.muse_client import MuseClient
from backend.vlm import VlmService
from backend.vision import Detector
from backend.rear.service import RearService
from backend.streams import SYNTHETIC_FRONT, StreamManager, blank

STORED_EVENTS = {"blink", "squint_start", "squint_end", "too_close_start", "too_close_end",
                 "alert", "calibrated", "break", "facetime", "gaze_calibrated", "partial_blink",
                 "low_blink_start", "low_blink_end"}   # "assist" is stored by Assistant
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
        default_fps = cfg.get("pipelines", {}).get("fps", 15)
        cams = cfg.get("cameras", {})
        self.cam_fps = {c: cams.get(c, {}).get("fps", default_fps) for c in ("eye", "front", "rear")}
        self._lock = threading.Lock()
        self._live = {"started": time.time(), "mode": "dev" if cfg.get("dev") else "product"}
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
        # Product: distance comes from near-work objects (FrontAnalyzer). Dev face-width distance stays available.
        self.use_distance = cfg["distance"].get("method") in ("face", "object")
        self.rear_mode = cfg.get("rear", {}).get("mode", "fpga")
        # rear.mode: software runs lgmd.py on a rear stream; fpga mode gets events instead (backend/rear).
        v = cfg.get("vision", {})
        self.detector = Detector(v.get("model", "yolov8n.pt"), v.get("min_conf", 0.35))
        self.muse = MuseClient(cfg, self.db)
        front = self.streams.cameras.get("front")
        self.vlm = VlmService(self.muse, front_frame=lambda: (front.latest()[1] if front is not None
                                                              and front.status().get("ok") else None))
        self.assistant = Assistant(self.streams.cameras.get("front"), self.detector, self.muse, self.gaze,
                                   self.voice, self.emit, focal_px=self.distance._focal, db=self.db,
                                   still_fn=lambda: self.front_still())
        self.rear = (RearAlert(cfg, speaker=self.voice)
                     if self.rear_mode == "software" and "rear" in cfg.get("cameras", {}) else None)
        self.rear_service = (RearService(cfg, self.voice, self.emit, self.detector, self.muse, self.db)
                             if self.rear_mode == "fpga" else None)
        self.camera_state = {}                         # camera name -> "online" | "offline"

        self.rings = Rings(cfg, self.db)
        lb = cfg.get("eye", {})
        self.low_blink = LowBlinkMonitor(lb.get("low_blink_per_min", 10), lb.get("low_blink_min_s", 300))
        self.directory = CameraDirectory(cfg, on_change=self._camera_moved)
        front_src = cams.get("front", {}).get("source")
        if front_src == SYNTHETIC_FRONT:              # dev: scripted scenes + fake detections and exposure
            from backend.synth_front import ScriptedDetector, shared
            front_detector, sensor_fn, self.sensor_poller = ScriptedDetector(shared()), shared().sensor, None
        else:
            self.sensor_poller = SensorPoller(lambda: self.directory.http_base("front"))
            front_detector, sensor_fn = self.detector, self.sensor_poller.get
        self.front = FrontAnalyzer(cfg, self.db, front_detector, self.rings, self.emit,
                                   worn_fn=lambda: bool(self._live.get("eye_detected")), sensor_fn=sensor_fn)

    # -- state shared with the API --------------------------------------------

    def live(self):
        with self._lock:
            d = dict(self._live)
        now = time.time()
        d["session_min"] = round(self.session.minutes(now), 1)
        d["ts"] = now
        return d

    def front_still(self):
        """One higher-resolution FRONT still from the ESP32 (/capture?size=vga|svga), on demand
        only (for Muse). None if the camera can't be reached (callers fall back to the stream)."""
        import urllib.request
        base = self.directory.http_base("front")
        if not base:
            return None
        size = self.cfg["cameras"].get("front", {}).get("still_size", "vga")
        try:
            with urllib.request.urlopen(f"{base}/capture?size={size}", timeout=6) as r:   # uxga: ~0.5-1 s
                buf = np.frombuffer(r.read(), np.uint8)
            return cv2.imdecode(buf, cv2.IMREAD_COLOR)
        except (OSError, ValueError):
            return None

    def _camera_moved(self, role, url):
        """A camera announced a (new) IP: point its stream reader there."""
        reader = self.streams.cameras.get(role)
        if reader is not None and url:
            reader.set_source(url)

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
            else:                        # blink, partial_blink, squint_end
                data = {"duration_s": round(val, 3)}
            self.emit(kind, data, t)
        lb = self.low_blink.update(t, state.get("blink_rate"), state["eye_detected"])
        if lb and lb[0] == "low_blink_start":
            self.emit("low_blink_start", {"since": lb[1]}, t)
        elif lb:
            self.db.add_interval("low_blink", lb[1]["start"], lb[1]["end"])
            self.emit("low_blink_end", lb[1], t)
        self._update_live(low_blink=self.low_blink.active, low_blink_since=self.low_blink.since
                          if self.low_blink.active else None)
        reading = state.get("pupil_vector") or state.get("pupil")        # position + shape when we have it
        self._update_live(**self.gaze.update(tuple(reading) if reading else None, t))
        brk = self.session.update(state["eye_detected"], t)
        if brk:
            self.emit("break", {"duration_s": brk[1]}, t)

    def _front_step(self, frame, t):
        lux = float(np.mean(frame)) * 4   # very rough: the app wants a lux number
        if self.use_distance:              # dev: face-width distance
            lm = self.eye.extractor.last_landmarks if self.shared_face else None
            state, events = self.distance.process(frame, t, landmarks=lm)
            self._update_live(**state)
            for kind, val in events:
                self.emit(kind, {"distance_cm": val} if kind == "too_close_start" else {"duration_s": val}, t)
        fs = self.front.process(frame, t)
        self._update_live(**fs, lux_est=round(lux))
        if not self.use_distance:          # product: distance = nearest near-work object
            self._update_live(distance_cm=fs["nearwork_distance_cm"], too_close=fs["nearwork_close"],
                              threshold_cm=fs["nearwork_threshold_cm"], device=fs["nearwork_object"],
                              distance_method="nearwork")

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
                self.front.flush()
                self._update_live(distance_cm=None, too_close=False, too_close_for_s=0, nearwork=False,
                                  nearwork_object=None, nearwork_distance_cm=None, closeup_session=None, heads_up=None)
        self._update_live(cameras=dict(self.camera_state))
        for c in changed:
            self.emit(f"camera_{state}", {"camera": c, "source": source})

    def _front_annotators(self):
        """Preview overlays for the FRONT camera: object boxes + distances (and, in dev, the
        face-width line)."""
        return ([self.distance.annotate] if self.use_distance else []) + [self.front.annotate]

    def _loop(self, name, reader, steps, annotators):
        """steps: [(fn, fps)]. Each step runs at most at its own rate (eye ~25 fps, front ~3)."""
        cams = name.split("+")
        label = " + ".join(c.upper() for c in cams)
        seq = 0
        last = [0.0] * len(steps)
        while not self._stop.is_set():
            seq, frame, t = reader.wait_new(seq, timeout=0.5)
            st = reader.status()
            if frame is None or not st["ok"]:
                self._set_camera_state(cams, "offline", st["source"])
                self.frames[name] = blank(f"{label} camera offline - retrying {st['source']}")
                continue
            self._set_camera_state(cams, "online", st["active"])
            due = [i for i, (_, fps) in enumerate(steps) if t - last[i] >= 1.0 / fps]
            if not due:
                continue
            try:
                for i in due:
                    last[i] = t
                    steps[i][0](frame, t)
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
        f = self.cam_fps
        if s.get("eye") is s.get("front"):             # dev: one webcam feeds both
            loops.append(("eye+front", s.get("eye"), [(self._eye_step, f["eye"]), (self._front_step, f["front"])],
                          [self.eye.annotate, *self._front_annotators()]))
        else:
            loops.append(("eye", s.get("eye"), [(self._eye_step, f["eye"])], [self.eye.annotate]))
            loops.append(("front", s.get("front"), [(self._front_step, f["front"])], self._front_annotators()))
        if self.rear is not None:
            loops.append(("rear", s.get("rear"), [(self._rear_step, f["rear"])], [self.rear.annotate]))
        elif self.rear_service is not None:
            print("[rear] fpga mode: rear warnings come from FPGA events (docs/rear_event_protocol.md)")
            self.rear_service.start()
        for name, reader, steps, ann in loops:
            threading.Thread(target=self._loop, args=(name, reader, steps, ann), name=name, daemon=True).start()
        self.pipeline_names = [n for n, *_ in loops]
        threading.Thread(target=self._sampler, name="sampler", daemon=True).start()
        self.directory.start()
        if self.sensor_poller is not None:
            self.sensor_poller.start()
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
            if self.rear_service is not None:
                self.rear_service.bridge = self.bridge
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
        self.front.flush()
        self.directory.stop()
        if self.sensor_poller is not None:
            self.sensor_poller.stop()
        if self.rear_service is not None:
            self.rear_service.stop()
        if self.bridge:
            self.bridge.stop()
        self.streams.close()


def start_mock_fpga(cfg, every):
    """Dev: send mock FPGA events (person / leaves / ...) to our own UDP receiver."""
    import itertools
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
    import mock_fpga
    from backend.rear import scenes

    port = cfg["rear"].get("fpga", {}).get("udp_port", 4300)
    sender = mock_fpga.Sender("udp", "127.0.0.1", port)

    def loop():
        time.sleep(min(every, 8.0))
        for event_id, (name, side) in zip(itertools.count(1), itertools.cycle(mock_fpga.CYCLE)):
            fn = scenes.SCENES[name]
            frames = fn(side) if name in ("person", "recede") else fn()
            sender.send(mock_fpga.build_packets(frames, event_id & 0xFFFF or 1))
            print(f"[mock_fpga] sent event {event_id}: {name}{f' ({side})' if side else ''}")
            time.sleep(every)

    print(f"[mock_fpga] DEV: a mock rear event every {every:.0f} s to UDP {port}")
    threading.Thread(target=loop, name="mock-fpga", daemon=True).start()


def main(argv=None):
    import uvicorn

    from backend.api import create_app

    ap = argparse.ArgumentParser(description="Glasses backend: pipelines + API")
    ap.add_argument("--config", default=None, help="config file (default backend/config.yaml)")
    ap.add_argument("--dev", action="store_true",
                    help="dev mode: merge backend/config.dev.yaml (webcam / still image / synthetic stand-ins)")
    ap.add_argument("--eye", help="override cameras.eye.source")
    ap.add_argument("--front", help="override cameras.front.source")
    ap.add_argument("--rear", help="override cameras.rear.source")
    ap.add_argument("--rear-mode", choices=("fpga", "software"), help="override rear.mode")
    ap.add_argument("--rear-serial", metavar="PORT", help="read FPGA packets from this serial port too")
    ap.add_argument("--mock-fpga", type=float, metavar="SECONDS", nargs="?", const=15.0,
                    help="dev: run tools/mock_fpga.py inside the backend, one event every N s (default 15)")
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
    if args.rear_mode:
        cfg["rear"]["mode"] = args.rear_mode
    if args.rear_serial:
        fp = cfg["rear"].setdefault("fpga", {})
        fp["transports"] = sorted(set(fp.get("transports", ["udp"])) | {"serial"})
        fp["serial_port"] = args.rear_serial
    if args.eye_method == "closeup":
        # Product eye settings, even on top of the dev overlay.
        cfg["eye"].update(method="closeup", default_baseline=1.0)
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
    if args.mock_fpga:
        start_mock_fpga(cfg, args.mock_fpga)
    app = create_app(rt)
    host, port = cfg["api"].get("host", "0.0.0.0"), cfg["api"].get("port", 8001)
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
