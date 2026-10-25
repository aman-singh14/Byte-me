#!/usr/bin/env python3
"""Pretend to be the camera boards (firmware/esp_camera_eye, esp_camera2_front, esp_camera3_back) on this laptop.

    python tools/fake_udp_camera.py                       # eye on UDP 8101 + front on UDP 8102
    python tools/fake_udp_camera.py --drop 0.02           # lose 2% of datagrams, like a bad Wi-Fi link
    python -m backend.main --eye udp://127.0.0.1:8101 --front udp://127.0.0.1:8102

    python tools/fake_udp_camera.py --phone 172.20.10.1   # for the phone app, with no laptop backend:
                                                          # hellos to the phone, plus the back camera + FPGA

(The real cameras both use UDP 81, each on its own IP. Here both fakes share this laptop's
address, so they need two different ports; their hellos say which.)

Each fake camera speaks the same protocol as the firmware: it waits for "WANT" datagrams and sends
every frame to whoever asked, cut into "CAMV" chunks of 1400 bytes. The pictures are the recorded
eye-camera frames (backend/data/eye_calibration_cropped) when present, else the synthetic eye, and
the synthetic front scene, at the real cameras' sizes, frame rates and colour/grey settings.
Every second it prints the frame rate and bandwidth it is sending.

With --phone it also does what the boards do for the phone:
  - eye and front say {"t":"cam_hello",...} to the phone's UDP 4310 every 2 s (BACKEND_HOST in secrets.h),
    and serve /capture, /status and /sensor over HTTP (the real ones use port 80)
  - a back camera on UDP 4300 sends the FPGA's status ~5 a second, {"t":"collision"} events and
    "OMNV" video while it "tracks", to whoever sent it a packet in the last 10 s (the phone pokes it).
    Like the firmware today, the status goes out as broadcast only, which an iPhone app doesn't
    receive; --back-status phone also sends it to the phone and the viewers, as the firmware should.
    Type track, collide, turn or q and Enter to play it.
  - --webcam: the front camera (or the back, or both) sends this laptop's webcam instead of a
    drawing, so YOLO and Muse see real things. The eye stays the synthetic eye: a webcam can't
    stand in for a camera 3 cm from the eye.
mock_glasses.py plays the older frame ESP32 (UDP 4210) instead; run one or the other.
"""

import argparse
import glob
import json
import os
import random
import socket
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

HEADER = struct.Struct("<4sIHHI")
CHUNK = 1400
HELLO_PORT = 4310          # firmware HELLO_PORT
HELLO_EVERY_S = 2.0        # firmware HELLO_EVERY_MS
VIEWER_TIMEOUT_S = 5.0     # firmware VIEWER_TIMEOUT_MS (eye, front)
BACK_PORT = 4300           # firmware esp_camera3_back UDP_PORT
BACK_VIEWER_TIMEOUT_S = 10.0
BACK_STATUS_EVERY_S = 0.2


def local_ip(toward):
    """This laptop's address on the way to `toward` (what a board would put in its hello)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((toward, 9))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


class FakeCamera:
    """One fake camera. frames: callable() -> BGR image. Runs in a background thread.
    hello_to: send its cam_hello there (UDP 4310) every 2 s, like BACKEND_HOST."""

    def __init__(self, port, frames, fps, size, grey=False, quality=80, drop=0.0, name="cam", host="127.0.0.1",
                 hello_to=None, hello_port=HELLO_PORT, http_port=None):
        self.frames, self.fps, self.size, self.grey = frames, fps, size, grey
        self.quality, self.drop, self.name = quality, drop, name
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.sock.bind((host, port))
        self.port = self.sock.getsockname()[1]
        self.sock.settimeout(0.002)
        self.hello_to, self.hello_port = hello_to, hello_port
        self.http = FakeCameraHttp(self, http_port) if http_port is not None else None
        self.viewers = {}                 # (ip, port) -> last WANT time
        self.frame_id = 0
        self.sent_bytes = 0
        self.sent_frames = 0
        self.last_jpeg = None
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.thread.start()
        if self.http:
            self.http.start()
        return self

    def stop(self):
        self.stopped.set()
        self.thread.join(timeout=2)
        if self.http:
            self.http.stop()
        self.sock.close()

    def hello(self):
        """The firmware's send_hello() message, field for field."""
        return {"t": "cam_hello", "role": self.name, "ip": local_ip(self.hello_to or "172.20.10.1"),
                "stream": "udp", "stream_port": self.port,
                "http_port": self.http.port if self.http else 80, "max_fps": self.fps}

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
        self.viewers = {a: t for a, t in self.viewers.items() if now - t < VIEWER_TIMEOUT_S}

    def encode(self, size=None):
        img = cv2.resize(self.frames(), size or self.size, interpolation=cv2.INTER_AREA)
        if self.grey:
            img = cv2.cvtColor(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), cv2.COLOR_GRAY2BGR)
        return cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, self.quality])[1].tobytes()

    def send(self, jpeg):
        self.frame_id += 1
        self.last_jpeg = jpeg
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
        next_hello = next_t
        while not self.stopped.is_set():
            self._poll()
            now = time.monotonic()
            if self.hello_to and now >= next_hello:
                next_hello = now + HELLO_EVERY_S
                try:
                    self.sock.sendto(json.dumps(self.hello(), separators=(",", ":")).encode(),
                                     (self.hello_to, self.hello_port))
                except OSError:
                    pass                  # not on the hotspot yet: the next hello tries again
            if now < next_t:
                time.sleep(min(0.002, next_t - now))
                continue
            next_t += 1.0 / self.fps
            if self.viewers:
                self.send(self.encode())


SIZES = {"qvga": (320, 240), "vga": (640, 480), "svga": (800, 600), "xga": (1024, 768),
         "sxga": (1280, 1024), "uxga": (1600, 1200)}


class FakeCameraHttp:
    """The boards' port-80 server: /capture?size=..., /status, /sensor."""

    def __init__(self, cam, port):
        cam_ref = cam

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                path, _, query = self.path.partition("?")
                if path == "/capture":
                    size = dict(p.partition("=")[::2] for p in query.split("&") if p).get("size", "vga")
                    self._send(cam_ref.encode(SIZES.get(size, SIZES["vga"])), "image/jpeg")
                elif path == "/status":
                    self._send(json.dumps({"role": cam_ref.name, "stream": "udp", "stream_port": cam_ref.port,
                                           "viewers": len(cam_ref.viewers),
                                           "frames_sent": cam_ref.sent_frames}).encode(), "application/json")
                elif path == "/sensor":
                    self._send(b'{"aec_lines":300,"gain_reg":4}', "application/json")
                else:
                    self.send_error(404)

            def _send(self, body, kind):
                self.send_response(200)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
        self.port = self.server.server_address[1]

    def start(self):
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()
        self.server.server_close()


class FakeBackCamera:
    """The back camera + FPGA (firmware/esp_camera3_back): status JSON, collision events and "OMNV"
    video on UDP 4300. Video goes to every address that sent it a packet in the last 10 s (to their
    port 4300, like the firmware), only while tracking unless stream_always. Status and events go out
    as broadcast (the firmware today); status_to_viewers also sends them to the viewers and to `phone`,
    the fix the firmware needs for an iPhone (which gets no broadcasts)."""

    def __init__(self, frames, port=BACK_PORT, peer_port=BACK_PORT, status_to_viewers=False, stream_always=False,
                 fps=10, host="0.0.0.0", broadcast=True, phone=None):
        self.frames, self.peer_port, self.fps, self.phone = frames, peer_port, fps, phone
        self.status_to_viewers, self.stream_always, self.broadcast = status_to_viewers, stream_always, broadcast
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.sock.bind((host, port))
        self.port = self.sock.getsockname()[1]
        self.sock.settimeout(0.002)
        self.viewers = {}                 # ip -> last packet time
        self.tracking = self.turning = False
        self.collision_until = self.turning_until = 0.0
        self.seq = self.video_id = 0
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

    # what you can make it do
    def collide(self, seconds=1.5):
        self.tracking = True
        self.collision_until = time.monotonic() + seconds
        self._send_json({"t": "collision", "seq": self.seq})

    def turn(self, seconds=1.0):
        self.turning_until = time.monotonic() + seconds

    def status(self):
        """The firmware's sendStatusJson() message, field for field."""
        now = time.monotonic()
        collision, turning = now < self.collision_until, now < self.turning_until
        return {"t": "rear", "seq": self.seq, "tracking": int(self.tracking and not turning),
                "collision": int(collision and not turning), "turning": int(turning), "imu": 1, "fpga": 1,
                "yaw_dps": 150.0 if turning else 3.0, "size": 900 if collision else 300,
                "size_smoothed": 850 if collision else 280, "k": 1800 if collision else 200, "in_row": 0,
                "bad_frames": 0, "streaming": int(self._streaming()), "horn": int(collision), "fps": float(self.fps)}

    def _streaming(self):
        return self.stream_always or self.tracking or time.monotonic() < self.collision_until

    def _targets(self):
        now = time.monotonic()
        self.viewers = {ip: t for ip, t in self.viewers.items() if now - t < BACK_VIEWER_TIMEOUT_S}
        return [(ip, self.peer_port) for ip in self.viewers]

    def _send_json(self, msg):
        data = json.dumps(msg, separators=(",", ":")).encode()
        targets = [("255.255.255.255", self.peer_port)] if self.broadcast else []
        if self.status_to_viewers:
            targets += self._targets()
            if self.phone and self.phone not in self.viewers:
                targets.append((self.phone, self.peer_port))
        for addr in targets:
            try:
                self.sock.sendto(data, addr)
            except OSError:
                pass

    def _poll(self):
        while True:
            try:
                _, (ip, _port) = self.sock.recvfrom(64)
            except (socket.timeout, BlockingIOError):
                return
            except OSError:
                return
            self.viewers[ip] = time.monotonic()      # any packet = "I want the video"

    def _send_video(self):
        img = cv2.resize(self.frames(), (640, 480), interpolation=cv2.INTER_AREA)
        jpeg = cv2.imencode(".jpg", cv2.cvtColor(img, cv2.COLOR_BGR2GRAY), [cv2.IMWRITE_JPEG_QUALITY, 70])[1].tobytes()
        self.video_id += 1
        chunks = (len(jpeg) + CHUNK - 1) // CHUNK
        for addr in self._targets():
            for c in range(chunks):
                part = jpeg[c * CHUNK:(c + 1) * CHUNK]
                self.sock.sendto(HEADER.pack(b"OMNV", self.video_id, c, chunks, len(jpeg)) + part, addr)
        self.sent_frames += 1

    def _run(self):
        next_status = next_frame = time.monotonic()
        while not self.stopped.is_set():
            self._poll()
            now = time.monotonic()
            if now >= next_status:
                next_status = now + BACK_STATUS_EVERY_S
                self.seq += 1
                self._send_json(self.status())
            if now >= next_frame:
                next_frame = now + 1.0 / self.fps
                if self._streaming():
                    self._send_video()
            time.sleep(0.002)


class Webcam:
    """This laptop's camera, read on its own thread; frames() returns the newest picture."""

    def __init__(self, index=0):
        self.cap = cv2.VideoCapture(index)
        if not self.cap.isOpened():
            raise SystemExit(f"can't open webcam {index} (allow Camera for your terminal in System Settings > "
                             "Privacy & Security > Camera)")
        self.latest = None
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        while True:
            ok, img = self.cap.read()
            if ok:
                self.latest = img
            else:
                time.sleep(0.05)

    def frames(self):
        img = self.latest
        if img is None:
            img = np.zeros((480, 640, 3), np.uint8)
            cv2.putText(img, "webcam starting", (180, 240), cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)
        return img


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


def back_frames():
    """People behind the wearer, so the app's YOLO has something to find: ultralytics' bus.jpg."""
    try:
        import ultralytics
        img = cv2.imread(os.path.join(os.path.dirname(ultralytics.__file__), "assets", "bus.jpg"))
    except ImportError:
        img = None
    if img is None:
        return front_frames()
    return lambda: img


def commands(back):
    print("back camera: type track, collide, turn or q, then Enter")
    for line in sys.stdin:
        word = line.strip().lower()
        if word in ("q", "quit"):
            os._exit(0)
        elif word == "track":
            back.tracking = not back.tracking
            print(f"back camera: tracking {'on (video flows)' if back.tracking else 'off'}")
        elif word == "collide":
            back.collide()
            print("back camera: COLLISION")
        elif word == "turn":
            back.turn()
            print("back camera: head turning")
        elif word:
            print("track | collide | turn | q")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--eye-port", type=int, default=8101)
    ap.add_argument("--front-port", type=int, default=8102)
    ap.add_argument("--drop", type=float, default=0.0, help="fraction of datagrams to lose")
    ap.add_argument("--phone", metavar="IP", help="the phone app's address (172.20.10.1 on its own hotspot): "
                                                  "hellos go there, and the back camera + FPGA runs too")
    ap.add_argument("--eye-http", type=int, default=8181, help="eye /capture, /status, /sensor (real: 80)")
    ap.add_argument("--front-http", type=int, default=8182, help="front /capture, /status, /sensor (real: 80)")
    ap.add_argument("--back-port", type=int, default=BACK_PORT,
                    help="where the fake back camera listens (4301 if the laptop backend already has 4300)")
    ap.add_argument("--back-status", choices=("broadcast", "phone"), default="broadcast",
                    help="broadcast: like the firmware today (an iPhone app hears none of it); "
                         "phone: also to the phone and whoever asked for video, as the firmware should")
    ap.add_argument("--stream-always", action="store_true", help="back video even when not tracking (STREAM_ALWAYS 1)")
    ap.add_argument("--webcam", nargs="?", const="front", choices=("front", "back", "both"),
                    help="send this laptop's webcam as the front camera (default), the back camera, or both")
    ap.add_argument("--webcam-index", type=int, default=0, help="which webcam (0 = the built-in one)")
    args = ap.parse_args()
    webcam = Webcam(args.webcam_index).frames if args.webcam else None
    front_src = webcam if args.webcam in ("front", "both") else front_frames()
    back_src = webcam if args.webcam in ("back", "both") else None
    phone = dict(hello_to=args.phone) if args.phone else {}
    cams = [FakeCamera(args.eye_port, eye_frames(), 25, (320, 240), grey=True, drop=args.drop, name="eye",
                       host="0.0.0.0" if args.phone else "127.0.0.1",
                       http_port=args.eye_http if args.phone else None, **phone).start(),
            FakeCamera(args.front_port, front_src, 5, (640, 480), drop=args.drop, name="front",
                       host="0.0.0.0" if args.phone else "127.0.0.1",
                       http_port=args.front_http if args.phone else None, **phone).start()]
    print("fake cameras: eye UDP %d (320x240 grey, 25 fps), front UDP %d (640x480 colour, 5 fps)"
          % (args.eye_port, args.front_port)
          + (f"; webcam as the {'front and back' if args.webcam == 'both' else args.webcam} camera" if args.webcam else ""))
    back = None
    if args.phone:
        print(f"hellos to {args.phone}:{HELLO_PORT} every 2 s; stills on HTTP {args.eye_http} (eye), "
              f"{args.front_http} (front)")
        back = FakeBackCamera(back_src or back_frames(), port=args.back_port, status_to_viewers=args.back_status == "phone",
                              stream_always=args.stream_always, phone=args.phone).start()
        print(f"fake back camera + FPGA on UDP {back.port}: status as {args.back_status}"
              + ("" if args.back_status == "phone" else " (an iPhone won't hear it: --back-status phone)"))
        threading.Thread(target=commands, args=(back,), daemon=True).start()
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
            if back:
                parts.append(f"back: {len(back.viewers)} viewer{'s' if len(back.viewers) != 1 else ''}"
                             f"{', streaming' if back._streaming() else ''}")
            print("   ".join(parts))
    except KeyboardInterrupt:
        pass
    finally:
        for c in cams:
            c.stop()
        if back:
            back.stop()


if __name__ == "__main__":
    main()
