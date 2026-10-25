#!/usr/bin/env python3
"""Relay the eye and front cameras from another Wi-Fi to the phone app (cloud/relay.py).

For when only the back camera + FPGA is on the phone's hotspot, and the eye and front boards run
stock firmware (CameraWebServer: MJPEG at http://<board>:81/stream) on some other Wi-Fi the phone
can't reach. Run this on a laptop on the cameras' Wi-Fi:

    .venv/bin/python tools/cam_relay.py --eye 192.168.1.50 --front 192.168.1.51 \\
        --to https://omni-glasses.fly.dev --key "$RELAY_KEY"
    # in the app: Settings > Cameras on another network > https://omni-glasses.fly.dev/relay/<key>

    .venv/bin/python tools/cam_relay.py --eye 192.168.1.50 --front 192.168.1.51 --serve 8030 --key k
    # the laptop serves the same paths itself, for a phone that can reach it (Tailscale, or the
    # same Wi-Fi): http://<laptop>:8030/relay/k

--eye / --front take a board's IP (its stream is then http://IP:81/stream) or a whole stream URL.
Frames go on as they come (no re-encoding), newest only, at most --eye-fps / --front-fps a second;
nothing is saved. Every 5 s it prints what each camera is sending.

--front webcam (or webcam:1 for the second one) uses a USB webcam on this laptop as the front
camera instead of a board, cropped to 4:3 like the boards (the app's distances assume it):

    .venv/bin/python tools/cam_relay.py --front webcam --front-fps 15 --serve 8030 --key k
    # laptop on the phone's hotspot: http://172.20.10.x:8030/relay/k in the app
"""

import argparse
import asyncio
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # for cloud.relay

MAX_FRAME = 512 * 1024


def stream_url(s):
    return s if "://" in s or s.startswith("webcam") else f"http://{s}:81/stream"


def jpegs(url):
    """The JPEGs of an MJPEG stream: FF D8 .. FF D9, whatever the boundary."""
    with urllib.request.urlopen(url, timeout=5) as r:
        buf = b""
        while chunk := r.read1(16384):
            buf += chunk
            while (s := buf.find(b"\xff\xd8")) >= 0 and (e := buf.find(b"\xff\xd9", s + 2)) >= 0:
                yield buf[s:e + 2]
                buf = buf[e + 2:]
            if len(buf) > MAX_FRAME:
                buf = b""  # lost sync: start over at the next frame


def webcam_jpegs(index, height, quality):
    """A webcam on this laptop as JPEGs: as many frames a second as it gives, centre-cropped to 4:3
    and [height] lines high."""
    import cv2

    cap = cv2.VideoCapture(index)
    if not cap.isOpened():
        raise OSError(f"can't open webcam {index} (allow Camera for your terminal in System Settings > "
                      "Privacy & Security > Camera)")
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
    cap.set(cv2.CAP_PROP_FPS, 30)
    try:
        while True:
            ok, img = cap.read()
            if not ok:
                raise OSError(f"webcam {index} stopped")
            h, w = img.shape[:2]
            cw = min(w, h * 4 // 3)
            img = img[:, (w - cw) // 2:(w + cw) // 2]
            if h != height:
                img = cv2.resize(img, (height * 4 // 3, height), interpolation=cv2.INTER_AREA)
            yield cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])[1].tobytes()
    finally:
        cap.release()


def check_webcam(index):
    """Opens the webcam once on the main thread: macOS only asks for camera permission from there."""
    import cv2

    cap = cv2.VideoCapture(index)
    ok = cap.isOpened()
    cap.release()
    if not ok:
        raise SystemExit(f"can't open webcam {index}: allow Camera for your terminal in System Settings > "
                         "Privacy & Security > Camera, then run this again")


class Camera:
    """Reads one camera (a board's stream, or webcam[:N] on this laptop) on its own thread and keeps
    the newest frame."""

    def __init__(self, role, url, webcam_height=720, webcam_quality=80):
        self.role, self.url = role, url
        self.webcam = (webcam_height, webcam_quality)
        self.frame, self.seq = None, 0
        self.got = self.sent = self.sent_bytes = 0
        self.changed = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        said = None
        while True:
            try:
                if self.url.startswith("webcam"):
                    source = webcam_jpegs(int(self.url.partition(":")[2] or 0), *self.webcam)
                else:
                    source = jpegs(self.url)
                for jpeg in source:
                    if said != "ok":
                        print(f"{self.role}: streaming from {self.url}", flush=True)
                        said = "ok"
                    with self.changed:
                        self.frame, self.seq = jpeg, self.seq + 1
                        self.got += 1
                        self.changed.notify_all()
                raise OSError("the stream ended")
            except Exception as e:
                if said != str(e):
                    print(f"{self.role}: {self.url}: {e}; retrying", flush=True)
                    said = str(e)
                time.sleep(1)

    def frames(self, fps):
        """The newest frame each time there's a new one, at most [fps] a second."""
        seq, last = 0, 0.0
        while True:
            time.sleep(max(0.0, last + 1 / fps - time.monotonic()))
            with self.changed:
                self.changed.wait_for(lambda: self.seq != seq)
                seq, jpeg = self.seq, self.frame
            last = time.monotonic()
            self.sent += 1
            self.sent_bytes += len(jpeg)
            yield jpeg


def push(cam, fps, base, key):
    """Sends [cam]'s frames to the cloud relay over a WebSocket, reconnecting as needed."""
    from websockets.sync.client import connect

    ws_base = base.rstrip("/").replace("https://", "wss://", 1).replace("http://", "ws://", 1)
    url = f"{ws_base}/relay/{urllib.parse.quote(key, safe='')}/push/{cam.role}"
    said = None
    while True:
        try:
            with connect(url, open_timeout=10, max_size=None) as ws:
                print(f"{cam.role}: pushing to {base}", flush=True)
                said = None
                for jpeg in cam.frames(fps):
                    ws.send(jpeg)
        except Exception as e:
            if said != str(e):
                print(f"{cam.role}: {base}: {e}; retrying", flush=True)
                said = str(e)
            time.sleep(2)


def report(cams):
    while True:
        time.sleep(5)
        print("  ".join(f"{c.role} {c.sent / 5:.0f} fps {c.sent_bytes / 5 / 1024:.0f} KB/s"
                        f" (camera {c.got / 5:.0f} fps)" for c in cams), flush=True)
        for c in cams:
            c.got = c.sent = c.sent_bytes = 0


def set_framesize(url, val):
    """Stock CameraWebServer: picture size on port 80's /control (8 = 640x480 on current esp32-camera)."""
    host = urllib.parse.urlsplit(url).hostname
    try:
        urllib.request.urlopen(f"http://{host}/control?var=framesize&val={val}", timeout=3).read()
        print(f"front: framesize {val}", flush=True)
    except Exception as e:
        print(f"front: couldn't set the framesize: {e}", flush=True)


async def serve(cams, rates, port, key):
    import uvicorn
    from fastapi import FastAPI

    from cloud import relay

    frames = relay.Frames()
    loop = asyncio.get_running_loop()
    for cam in cams:
        def forward(cam=cam):
            for jpeg in cam.frames(rates[cam.role]):
                loop.call_soon_threadsafe(frames.put, cam.role, jpeg)
        threading.Thread(target=forward, daemon=True).start()
    app = FastAPI()
    app.include_router(relay.router(frames, key))
    print(f"serving http://<this laptop>:{port}/relay/{key}", flush=True)
    await uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=port, log_level="warning")).serve()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--eye", metavar="IP|URL", help="the eye board (its IP, or its MJPEG stream URL)")
    ap.add_argument("--front", metavar="IP|URL|webcam[:N]",
                    help="the front board (its IP, or its MJPEG stream URL), or a webcam on this laptop")
    ap.add_argument("--key", required=True, help="the relay key (RELAY_KEY on the cloud server)")
    where = ap.add_mutually_exclusive_group(required=True)
    where.add_argument("--to", metavar="URL", help="the cloud server, e.g. https://omni-glasses.fly.dev")
    where.add_argument("--serve", metavar="PORT", type=int, help="serve the relay from this laptop instead")
    ap.add_argument("--eye-fps", type=float, default=15)
    ap.add_argument("--front-fps", type=float, default=5)
    ap.add_argument("--front-framesize", type=int, metavar="N",
                    help="set the stock front board's picture size first (8 = 640x480, sharper for Ask)")
    ap.add_argument("--webcam-height", type=int, default=720,
                    help="webcam picture height (4:3: 720 = 960x720; 480 for less data over cellular)")
    ap.add_argument("--webcam-quality", type=int, default=80, help="webcam JPEG quality, 1..100")
    a = ap.parse_args()
    if not (a.eye or a.front):
        ap.error("give --eye and/or --front")

    if a.front and a.front_framesize is not None and not a.front.startswith("webcam"):
        set_framesize(stream_url(a.front), a.front_framesize)
    if a.front and a.front.startswith("webcam"):
        check_webcam(int(a.front.partition(":")[2] or 0))
    cams = [Camera(role, stream_url(src), a.webcam_height, a.webcam_quality)
            for role, src in (("eye", a.eye), ("front", a.front)) if src]
    rates = {"eye": a.eye_fps, "front": a.front_fps}
    threading.Thread(target=report, args=(cams,), daemon=True).start()
    if a.serve:
        asyncio.run(serve(cams, rates, a.serve, a.key))
    else:
        for cam in cams:
            threading.Thread(target=push, args=(cam, rates[cam.role], a.to, a.key), daemon=True).start()
        while True:
            time.sleep(3600)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
