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

--eye / --front take a board's IP or a whole stream URL. With an IP the relay finds the video itself:
MJPEG at :81/stream (team firmware, stock CameraWebServer), /stream, /mjpeg/1, /video or /, the
team firmware's UDP video on 81 (WANT / CAMV), or else stills from /capture, /jpg or /cam-lo.jpg.
Frames go on as they come (no re-encoding), newest only, at most --eye-fps / --front-fps a second;
nothing is saved. Every 5 s it prints what each camera is sending.

--front webcam (or webcam:1 for the second one) uses a USB webcam on this laptop as the front
camera instead of a board, cropped to 4:3 like the boards (the app's distances assume it):

    .venv/bin/python tools/cam_relay.py --front webcam --front-fps 15 --serve 8030 --key k
    # laptop on the phone's hotspot: http://172.20.10.x:8030/relay/k in the app

--front-depth runs a depth model on this laptop (Depth Anything V2, metric indoor; needs
`pip install transformers`, ~100 MB downloaded the first time) on the front frames, and sends the
distance to what is ahead in the left, center and right of the picture a few times a second. The
app shows it live and uses the side the wearer looks at.
"""

import argparse
import asyncio
import json
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # for cloud.relay

MAX_FRAME = 512 * 1024


def stream_url(s):
    return s if "://" in s or s.startswith("webcam") else f"board://{s}"


MJPEG_PATHS = ("/stream", "/mjpeg/1", "/mjpeg", "/video", "/")
STILL_PATHS = ("/capture", "/jpg", "/cam-lo.jpg", "/cam.jpg")


def board_jpegs(ip, say, video_port=81, http_port=80):
    """A camera board's video, wherever its firmware puts it (see the module docstring)."""
    for port, path in [(video_port, "/stream"), *((http_port, p) for p in MJPEG_PATHS)]:
        url = f"http://{ip}:{port}{path}"
        try:
            r = urllib.request.urlopen(url, timeout=3)
        except Exception:
            continue
        kind = r.headers.get_content_type()
        if kind.startswith("multipart/"):
            say(f"video at {url}")
            yield from mjpeg_jpegs(r)
            return
        r.close()
    if (udp := udp_jpegs(ip, video_port)) is not None:
        say(f"video over UDP at {ip}:{video_port}")
        yield from udp
        return
    for path in STILL_PATHS:
        url = f"http://{ip}:{http_port}{path}"
        try:
            with urllib.request.urlopen(url, timeout=3) as r:
                first = r.read()
        except Exception:
            continue
        if first[:2] == b"\xff\xd8":
            say(f"stills from {url} (no video stream found)")
            yield first
            while True:
                with urllib.request.urlopen(url, timeout=3) as r:
                    yield r.read()
    raise OSError(f"no video found on {ip} (tried MJPEG on :{video_port}/stream and :{http_port}"
                  f"{', '.join(MJPEG_PATHS)}, UDP {video_port}, and stills)")


def udp_jpegs(ip, port=81):
    """The team firmware's UDP video: send WANT, get CAMV chunks. None if nothing answers in 2 s."""
    import socket
    import struct

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2)
    try:
        sock.sendto(b"WANT", (ip, port))
        first, _ = sock.recvfrom(2048)
    except OSError:
        sock.close()
        return None

    def frames(data):
        parts, last_want = {}, time.monotonic()
        while True:
            if time.monotonic() - last_want > 1:
                sock.sendto(b"WANT", (ip, port))
                last_want = time.monotonic()
            if len(data) > 16 and data[:4] in (b"CAMV", b"OMNV"):
                fid, chunk, n, total = struct.unpack_from("<IHHI", data, 4)
                entry = parts.setdefault(fid, {})
                entry[chunk] = data[16:]
                if len(entry) == n:
                    jpeg = b"".join(entry[i] for i in range(n))
                    for old in [k for k in parts if k <= fid]:
                        del parts[old]
                    if len(jpeg) == total:
                        yield jpeg
                if len(parts) > 8:
                    for old in sorted(parts)[:-4]:
                        del parts[old]
            data, _ = sock.recvfrom(2048)

    return frames(first)


def jpegs(url):
    """The JPEGs of an MJPEG stream at [url]."""
    with urllib.request.urlopen(url, timeout=5) as r:
        yield from mjpeg_jpegs(r)


def mjpeg_jpegs(r):
    """The JPEGs of an open MJPEG response: FF D8 .. FF D9, whatever the boundary."""
    with r:
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
        self.sensor, self.sensor_seq = None, 0  # --front-depth: {"left_cm":..,"center_cm":..,"right_cm":..}
        self.got = self.sent = self.sent_bytes = 0
        self.changed = threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        said = None
        while True:
            try:
                if self.url.startswith("webcam"):
                    source = webcam_jpegs(int(self.url.partition(":")[2] or 0), *self.webcam)
                elif self.url.startswith("board://"):
                    source = board_jpegs(self.url[len("board://"):], lambda m: print(f"{self.role}: {m}", flush=True))
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

    def frames(self, fps, count=True):
        """The newest frame each time there's a new one, at most [fps] a second."""
        seq, last = 0, 0.0
        while True:
            time.sleep(max(0.0, last + 1 / fps - time.monotonic()))
            with self.changed:
                self.changed.wait_for(lambda: self.seq != seq)
                seq, jpeg = self.seq, self.frame
            last = time.monotonic()
            if count:
                self.sent += 1
                self.sent_bytes += len(jpeg)
            yield jpeg


DEPTH_MODEL = "depth-anything/Depth-Anything-V2-Metric-Indoor-Small-hf"
COLUMNS = {"left": (0.0, 0.41), "center": (0.26, 0.74), "right": (0.59, 1.0)}  # the app's gaze columns


def depth(cam, fps):
    """Distance to what is ahead in [cam]'s picture, from a depth model: the nearer part (30th
    percentile) of the middle half of each gaze column, in cm, into cam.sensor."""
    import cv2
    import numpy as np
    import torch
    from transformers import AutoImageProcessor, AutoModelForDepthEstimation

    device = "mps" if torch.backends.mps.is_available() else "cuda" if torch.cuda.is_available() else "cpu"
    proc = AutoImageProcessor.from_pretrained(DEPTH_MODEL)
    model = AutoModelForDepthEstimation.from_pretrained(DEPTH_MODEL).to(device).eval()
    print(f"{cam.role}: depth model ready ({device})", flush=True)
    for jpeg in cam.frames(fps, count=False):
        img = cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            continue
        with torch.no_grad():
            d = model(**proc(images=cv2.cvtColor(img, cv2.COLOR_BGR2RGB), return_tensors="pt").to(device))
            m = d.predicted_depth[0].cpu().numpy()  # metres, at the model's size
        h, w = m.shape
        rows = m[h // 4:h * 3 // 4]
        reading = {f"{name}_cm": int(np.percentile(rows[:, int(a * w):max(int(b * w), int(a * w) + 1)], 30) * 100)
                   for name, (a, b) in COLUMNS.items()}
        with cam.changed:
            cam.sensor, cam.sensor_seq = reading, cam.sensor_seq + 1


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
                said, sensor_seq = None, 0
                for jpeg in cam.frames(fps):
                    ws.send(jpeg)
                    if cam.sensor_seq != sensor_seq:  # the newest distances ride along as text
                        sensor_seq = cam.sensor_seq
                        ws.send(json.dumps(cam.sensor))
        except Exception as e:
            if said != str(e):
                print(f"{cam.role}: {base}: {e}; retrying", flush=True)
                said = str(e)
            time.sleep(2)


def report(cams):
    while True:
        time.sleep(5)
        print("  ".join(f"{c.role} {c.sent / 5:.0f} fps {c.sent_bytes / 5 / 1024:.0f} KB/s"
                        f" (camera {c.got / 5:.0f} fps)" + (f" {c.sensor}" if c.sensor else "") for c in cams),
              flush=True)
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


def local_addresses():
    """This laptop's IPv4 addresses, from ifconfig (macOS), the hotspot's first."""
    import re
    import subprocess

    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True, timeout=3).stdout
    except (OSError, subprocess.SubprocessError):
        return ["<this laptop>"]
    found = [a for a in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out) if not a.startswith(("127.", "169.254."))]
    return sorted(found, key=lambda a: not a.startswith("172.20.10.")) or ["<this laptop>"]


async def serve(cams, rates, port, key):
    import uvicorn
    from fastapi import FastAPI

    from cloud import relay

    frames = relay.Frames()
    loop = asyncio.get_running_loop()
    for cam in cams:
        def forward(cam=cam):
            sensor_seq = 0
            for jpeg in cam.frames(rates[cam.role]):
                loop.call_soon_threadsafe(frames.put, cam.role, jpeg)
                if cam.sensor_seq != sensor_seq:
                    sensor_seq = cam.sensor_seq
                    loop.call_soon_threadsafe(frames.put_sensor, cam.role, cam.sensor)
        threading.Thread(target=forward, daemon=True).start()
    app = FastAPI()
    app.include_router(relay.router(frames, key))
    for addr in local_addresses():
        where = " (the phone's hotspot or its USB cable: type this one in the app)" if addr.startswith("172.20.10.") else ""
        print(f"serving http://{addr}:{port}/relay/{key}{where}", flush=True)
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
    ap.add_argument("--front-depth", action="store_true",
                    help="measure the distance ahead with a depth model on this laptop (live distance in the app)")
    ap.add_argument("--depth-fps", type=float, default=5)
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
    if a.front_depth:
        front = next((c for c in cams if c.role == "front"), None)
        if front is None:
            ap.error("--front-depth needs --front")
        threading.Thread(target=depth, args=(front, a.depth_fps), daemon=True).start()
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
