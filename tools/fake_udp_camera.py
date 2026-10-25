#!/usr/bin/env python3
"""Pretend to be the ESP32-CAMs' UDP video (firmware/esp_camera_eye, esp_camera2_front) on this laptop.

    python tools/fake_udp_camera.py                       # eye on UDP 8101 + front on UDP 8102
    python tools/fake_udp_camera.py --drop 0.02           # lose 2% of datagrams, like a bad Wi-Fi link
    python -m backend.main --eye udp://127.0.0.1:8101 --front udp://127.0.0.1:8102

(The real cameras both use UDP 81, each on its own IP. Here both fakes share this laptop's
address, so they need two different ports.)

Each fake camera speaks the same protocol as the firmware: it waits for "WANT" datagrams and sends
every frame to whoever asked, cut into "CAMV" chunks of 1400 bytes. The pictures are the recorded
eye-camera frames (backend/data/eye_calibration_cropped) when present, else the synthetic eye, and
the synthetic front scene, at the real cameras' sizes, frame rates and colour/grey settings.
Every second it prints the frame rate and bandwidth it is sending.
"""

import argparse
import glob
import os
import random
import socket
import struct
import sys
import threading
import time

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

HEADER = struct.Struct("<4sIHHI")
CHUNK = 1400


class FakeCamera:
    """One fake camera. frames: callable() -> BGR image. Runs in a background thread."""

    def __init__(self, port, frames, fps, size, grey=False, quality=80, drop=0.0, name="cam", host="127.0.0.1"):
        self.frames, self.fps, self.size, self.grey = frames, fps, size, grey
        self.quality, self.drop, self.name = quality, drop, name
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((host, port))
        self.port = self.sock.getsockname()[1]
        self.sock.settimeout(0.002)
        self.viewers = {}                 # (ip, port) -> last WANT time
        self.frame_id = 0
        self.sent_bytes = 0
        self.sent_frames = 0
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self.stopped.set()
        self.thread.join(timeout=2)
        self.sock.close()

    def _poll(self):
        while True:
            try:
                data, addr = self.sock.recvfrom(64)
            except (socket.timeout, BlockingIOError):
                break
            except OSError:
                return
            if data.startswith(b"WANT"):
                self.viewers[addr] = time.monotonic()
            elif data.startswith(b"STOP"):
                self.viewers.pop(addr, None)
        now = time.monotonic()
        self.viewers = {a: t for a, t in self.viewers.items() if now - t < 5.0}

    def encode(self):
        img = cv2.resize(self.frames(), self.size, interpolation=cv2.INTER_AREA)
        if self.grey:
            img = cv2.cvtColor(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), cv2.COLOR_GRAY2BGR)
        return cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, self.quality])[1].tobytes()

    def send(self, jpeg):
        self.frame_id += 1
        chunks = (len(jpeg) + CHUNK - 1) // CHUNK
        for addr in list(self.viewers):
            for c in range(chunks):
                if self.drop and random.random() < self.drop:
                    continue
                part = jpeg[c * CHUNK:(c + 1) * CHUNK]
                self.sock.sendto(HEADER.pack(b"CAMV", self.frame_id, c, chunks, len(jpeg)) + part, addr)
                self.sent_bytes += len(part) + HEADER.size
        self.sent_frames += 1

    def _run(self):
        next_t = time.monotonic()
        while not self.stopped.is_set():
            self._poll()
            now = time.monotonic()
            if now < next_t:
                time.sleep(min(0.002, next_t - now))
                continue
            next_t += 1.0 / self.fps
            if self.viewers:
                self.send(self.encode())


def eye_frames():
    paths = sorted(glob.glob(os.path.join("backend", "data", "eye_calibration_cropped", "*", "*.png")))
    imgs = [cv2.imread(p) for p in paths if os.path.basename(os.path.dirname(p)) in ("left", "center", "right")]
    imgs = [i for i in imgs if i is not None]
    if imgs:
        it = iter(range(10 ** 12))
        return lambda: imgs[(next(it) // 10) % len(imgs)]
    from backend.synth_eye import SynthEyeSource
    src = SynthEyeSource(25)
    return lambda: next(src)


def front_frames():
    from backend.synth_front import SynthFrontSource
    src = SynthFrontSource()
    return lambda: next(src)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--eye-port", type=int, default=8101)
    ap.add_argument("--front-port", type=int, default=8102)
    ap.add_argument("--drop", type=float, default=0.0, help="fraction of datagrams to lose")
    args = ap.parse_args()
    cams = [FakeCamera(args.eye_port, eye_frames(), 25, (320, 240), grey=True, drop=args.drop, name="eye").start(),
            FakeCamera(args.front_port, front_frames(), 5, (640, 480), drop=args.drop, name="front").start()]
    print("fake cameras: eye UDP %d (320x240 grey, 25 fps), front UDP %d (640x480 colour, 5 fps)"
          % (args.eye_port, args.front_port))
    last = {c.name: (0, 0) for c in cams}
    try:
        while True:
            time.sleep(1.0)
            parts = []
            for c in cams:
                f0, b0 = last[c.name]
                parts.append(f"{c.name}: {c.sent_frames - f0} fps {(c.sent_bytes - b0) * 8 / 1e6:.2f} Mbit/s "
                             f"({len(c.viewers)} viewer{'s' if len(c.viewers) != 1 else ''})")
                last[c.name] = (c.sent_frames, c.sent_bytes)
            print("   ".join(parts))
    except KeyboardInterrupt:
        pass
    finally:
        for c in cams:
            c.stop()


if __name__ == "__main__":
    main()
