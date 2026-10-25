"""Threaded camera readers that always hand out the newest frame.

In the product every source is an ESP32-CAM sending JPEG frames over UDP (udp://eye-cam.local:81,
backend/udp_camera.py). MJPEG URLs (http://...) still work.
Dev stand-ins: a webcam index (0), a video file (looped), an image file (repeated),
"sample:bus.jpg" (images bundled with ultralytics), "synthetic" (lgmd.py's looming
square) or "synthetic-eye" (a rendered close-up eye for the product's pupil tracker). For a fake ESP32 over the network, run mock_glasses.py and use its URL.

If a source dies, the reader uses its fallback (if any; the product config has none)
and keeps retrying the primary every reconnect_s. Cameras that name the same source
share one reader.

    python -m backend.streams 0                 # show one source
    python -m backend.streams --config          # show every camera in config.yaml
"""

import argparse
import threading
import time
from pathlib import Path

import cv2
import numpy as np

import lgmd

SYNTHETIC = "synthetic"
SYNTHETIC_EYE = "synthetic-eye"      # backend/synth_eye.py: close-up eye with blinks, squint, gaze
SYNTHETIC_FRONT = "synthetic-front"  # backend/synth_front.py: phone / laptop / heads-up / outdoor loop
SYNTH_FPS = 15
STREAM_PREFIXES = ("http://", "https://", "rtsp://")
UDP_PREFIX = "udp://"                 # ESP32-CAM UDP video (backend/udp_camera.py)
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}
STILL_FPS = 15


def synthetic_frames():
    """lgmd.synth_approach (a looming square) then 3 s of still background, upscaled
    to 640x480 BGR. Loops forever; the rear alert fires once per loop."""
    clip = list(lgmd.synth_approach()) + [lgmd.synth_approach()[0]] * (3 * SYNTH_FPS)
    big = [cv2.cvtColor(cv2.resize(f, (640, 480), interpolation=cv2.INTER_NEAREST), cv2.COLOR_GRAY2BGR)
           for f in clip]
    while True:
        yield from big


def normalize_source(src):
    """'0' -> 0, so config and CLI can give webcam indexes as strings."""
    if isinstance(src, str) and src.strip().isdigit():
        return int(src)
    return src


def describe(src):
    return f"webcam {src}" if isinstance(src, int) else str(src)


def resolve_sample(src):
    """'sample:bus.jpg' -> path of an image bundled with ultralytics (dev stand-in)."""
    if not (isinstance(src, str) and src.startswith("sample:")):
        return src
    try:
        import ultralytics
    except ImportError:
        return src
    return str(Path(ultralytics.__file__).parent / "assets" / src.split(":", 1)[1])


def is_stream(src):
    return isinstance(src, str) and src.startswith(STREAM_PREFIXES)


class _Capture:
    """One opened source. read() returns a BGR frame or None."""

    def __init__(self, src, width, height):
        self.src = src
        self.cap = None
        self.still = None
        self.synth = None
        self.udp = None
        if isinstance(src, str) and src.startswith(UDP_PREFIX):
            from backend.udp_camera import UdpCamera
            self.udp = UdpCamera(src)
            self.is_file = False
            return
        if src == SYNTHETIC:
            self.synth = synthetic_frames()
        elif src == SYNTHETIC_EYE:
            from backend.synth_eye import SynthEyeSource
            self.synth = SynthEyeSource(SYNTH_FPS)
        elif src == SYNTHETIC_FRONT:
            from backend.synth_front import SynthFrontSource
            self.synth = SynthFrontSource()
        path = resolve_sample(src)
        self.is_file = isinstance(path, str) and self.synth is None and not is_stream(path) and Path(path).exists()
        if self.synth is not None:
            return
        if self.is_file and Path(path).suffix.lower() in IMAGE_EXTS:
            self.still = cv2.imread(path)   # OpenCV's capture gives an image only once
            return
        if is_stream(src):
            # Without timeouts a dead ESP32 can block read() for ~30 s.
            self.cap = cv2.VideoCapture(src, cv2.CAP_FFMPEG, [cv2.CAP_PROP_OPEN_TIMEOUT_MSEC, 4000,
                                                              cv2.CAP_PROP_READ_TIMEOUT_MSEC, 3000])
        else:
            self.cap = cv2.VideoCapture(path)
        if isinstance(src, int):
            self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
            self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        self.file_delay = 1.0 / (self.cap.get(cv2.CAP_PROP_FPS) or 30.0) if self.is_file else 0

    def opened(self):
        if self.udp is not None:
            return self.udp.opened()
        if self.synth is not None:
            return True
        if self.is_file and self.cap is None:
            return self.still is not None
        return self.cap is not None and self.cap.isOpened()

    def read(self):
        if self.udp is not None:
            return self.udp.read()
        if self.synth is not None:
            time.sleep(1 / SYNTH_FPS)
            return next(self.synth).copy()
        if self.still is not None:
            time.sleep(1 / STILL_FPS)
            return self.still.copy()
        ok, img = self.cap.read()
        if not ok and self.is_file:      # loop video files
            self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
            ok, img = self.cap.read()
        if self.is_file:
            time.sleep(self.file_delay)  # play files at their own speed
        return img if ok else None

    def release(self):
        if self.udp is not None:
            self.udp.release()
        if self.cap is not None:
            self.cap.release()


class FrameReader:
    """Reads one camera in a background thread. latest() never blocks for long."""

    def __init__(self, source, fallback=None, reconnect_s=3.0, stale_s=2.0, width=640, height=480, name=None):
        self.source = normalize_source(source)
        self.fallback = normalize_source(fallback)
        self.reconnect_s = reconnect_s
        self.stale_s = stale_s
        self.size = (width, height)
        self.name = name or describe(self.source)
        self.active = None           # source currently delivering frames
        self._cond = threading.Condition()
        self._frame = None
        self._seq = 0
        self._t_frame = 0.0
        self._fps = 0.0
        self._alive = True
        self._reopen = False
        self._thread = threading.Thread(target=self._run, name=f"reader-{self.name}", daemon=True)
        self._thread.start()

    # -- public ------------------------------------------------------------

    def latest(self):
        """(seq, frame, timestamp). frame is None until the first frame arrives."""
        with self._cond:
            return self._seq, self._frame, self._t_frame

    def wait_new(self, last_seq, timeout=1.0):
        """Block until a frame newer than last_seq arrives (or timeout). Returns (seq, frame, t)."""
        with self._cond:
            self._cond.wait_for(lambda: self._seq != last_seq or not self._alive, timeout)
            return self._seq, self._frame, self._t_frame

    def status(self):
        with self._cond:
            age = time.time() - self._t_frame if self._t_frame else None
        return {
            "name": self.name,
            "source": describe(self.source),
            "active": None if self.active is None else describe(self.active),
            "on_fallback": self.active is not None and self.active != self.source,
            "fps": round(self._fps, 1),
            "frame_age_s": None if age is None else round(age, 2),
            "ok": age is not None and age < self.stale_s,
        }

    def set_source(self, source):
        """Switch to a new primary source (e.g. the IP a camera just announced)."""
        source = normalize_source(source)
        if source != self.source:
            self.source = source
            self._reopen = True

    def close(self):
        self._alive = False
        self._thread.join(timeout=2.0)

    # -- thread ------------------------------------------------------------

    def _open(self, src):
        if src is None:
            return None
        cap = _Capture(src, *self.size)
        if cap.opened():
            return cap
        cap.release()
        return None

    def _run(self):
        cap = None
        next_primary_try = 0.0
        while self._alive:
            if self._reopen:
                self._reopen = False
                if cap is not None:
                    cap.release()
                cap = None
                next_primary_try = 0.0
            now = time.monotonic()
            # (Re)open: primary first, fallback while the primary is down.
            if cap is None or (cap.src != self.source and now >= next_primary_try):
                if cap is None or cap.src != self.source:
                    primary = self._open(self.source)
                    next_primary_try = now + self.reconnect_s
                    if primary is not None:
                        if cap is not None:
                            cap.release()
                        cap = primary
                        print(f"[streams] {self.name}: using {describe(self.source)}")
                if cap is None:
                    cap = self._open(self.fallback)
                    if cap is not None:
                        print(f"[streams] {self.name}: {describe(self.source)} down, "
                              f"falling back to {describe(self.fallback)}")
                if cap is None:
                    self.active = None
                    time.sleep(self.reconnect_s)
                    continue
                self.active = cap.src
                last_ok = time.monotonic()

            img = cap.read()
            if img is None:
                if time.monotonic() - last_ok > self.stale_s:
                    print(f"[streams] {self.name}: {describe(cap.src)} stopped delivering frames, reconnecting")
                    cap.release()
                    cap = None
                    next_primary_try = 0.0
                else:
                    time.sleep(0.02)
                continue
            last_ok = time.monotonic()
            t = time.time()
            with self._cond:
                if self._t_frame:
                    self._fps = 0.9 * self._fps + 0.1 / max(t - self._t_frame, 1e-3)
                self._frame = img
                self._seq += 1
                self._t_frame = t
                self._cond.notify_all()
        if cap is not None:
            cap.release()
        with self._cond:
            self._cond.notify_all()


class StreamManager:
    """One FrameReader per distinct (source, fallback), looked up by camera name."""

    def __init__(self, cfg):
        s = cfg.get("stream", {})
        self._opts = dict(reconnect_s=s.get("reconnect_s", 3.0), stale_s=s.get("stale_s", 2.0),
                          width=s.get("width", 640), height=s.get("height", 480))
        self._by_source = {}
        self.cameras = {}
        for name, cam in cfg.get("cameras", {}).items():
            key = (normalize_source(cam["source"]), normalize_source(cam.get("fallback")))
            if key not in self._by_source:
                self._by_source[key] = FrameReader(*key, name=name, **self._opts)
            else:
                self._by_source[key].name += f"+{name}"
            self.cameras[name] = self._by_source[key]

    def get(self, name):
        return self.cameras[name]

    def status(self):
        return {name: r.status() for name, r in self.cameras.items()}

    def close(self):
        for r in self._by_source.values():
            r.close()


def blank(text, size=(640, 480)):
    img = np.zeros((size[1], size[0], 3), np.uint8)
    cv2.putText(img, text, (20, size[1] // 2), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (200, 200, 200), 2)
    return img


def main(argv=None):
    from backend.config import load_config

    ap = argparse.ArgumentParser(description="Show camera sources through the stream layer")
    ap.add_argument("source", nargs="?", help="webcam index, URL, file or 'synthetic'")
    ap.add_argument("--fallback", default=None)
    ap.add_argument("--config", action="store_true", help="open every camera in config.yaml")
    ap.add_argument("--dev", action="store_true", help="with --config: use the config.dev.yaml stand-ins")
    ap.add_argument("--headless", type=float, metavar="SECONDS",
                    help="no window: print status for this many seconds")
    args = ap.parse_args(argv)

    if args.config or args.source is None:
        mgr = StreamManager(load_config(dev=args.dev))
        readers = mgr.cameras
    else:
        readers = {"cam": FrameReader(args.source, args.fallback)}

    t_end = time.time() + (args.headless or 0)
    try:
        while True:
            if args.headless:
                time.sleep(1.0)
                for name, r in readers.items():
                    seq, frame, _ = r.latest()
                    shape = None if frame is None else frame.shape
                    print(f"{name}: frames {seq} shape {shape} {r.status()}")
                if time.time() >= t_end:
                    break
                continue
            for name, r in readers.items():
                _, frame, _ = r.latest()
                st = r.status()
                img = blank(f"{name}: waiting for {st['source']}") if frame is None else frame.copy()
                cv2.putText(img, f"{name} {st['active']} {st['fps']} fps", (8, 20),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)
                cv2.imshow(name, img)
            if cv2.waitKey(30) & 0xFF in (ord("q"), 27):
                break
    finally:
        for r in set(readers.values()):
            r.close()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
