#!/usr/bin/env python3
"""Pretend to be the Omni Glasses so the app can be built before the hardware works.

Plays both devices:

    camA   MJPEG stream of the laptop webcam at http://<laptop>:81/stream (320x240)
    frame  UDP JSON: sends hello, sens (10/s) and fire; prints what the app sends

Protocol (one JSON message per UDP datagram):

    device -> app   {"t":"hello","id":"frame"|"camA"}       every 2 s, always
    frame  -> app   {"t":"sens","dist":34,"blink":0,"yaw_rate":12,"lux":850,"batt":82}
    frame  -> app   {"t":"fire","side":"L","k":812}
    app -> frame    alert, tap, groupbreak, stop, hb (every 250 ms)

The app listens on UDP port 4210 and learns each device's address from the
sender of its hello, so it replies to whatever address and port the hello came
from. "batt" (percent) is an optional field the app shows in its status strip.
Sides are always the wearer's left/right; the frame firmware flips Cam B's image
sides before sending.

Type a command and press Enter while it runs:

    fl / fr     fire on the wearer's left / right
    turn        head turn (yaw_rate spike for 1 s)
    read        close-up work, dist ~30 cm      up    looking up, dist ~250 cm
    out         daylight, lux ~20000            in    indoors, lux ~400
    drop        stop sending sens for 5 s (to test the link-lost banner)
    q           quit
"""

import argparse
import http.server
import json
import math
import random
import socket
import socketserver
import sys
import threading
import time

import cv2
import numpy as np

APP_PORT = 4210      # the app listens here
FRAME_PORT = 4211    # frame ESP32 sends from and listens on this port
CAMA_PORT = 4212     # camA only sends hellos, from this port
HTTP_PORT = 81       # camA MJPEG stream
HB_TIMEOUT = 1.0     # seconds without hb before the frame decides the phone is gone


# ---------------------------------------------------------------------------
# camA: webcam as MJPEG
# ---------------------------------------------------------------------------

class Camera:
    """Keeps only the newest 320x240 JPEG. Falls back to a test pattern."""

    def __init__(self, index, synthetic):
        self.cap = None if synthetic else cv2.VideoCapture(index)
        if self.cap is not None and not self.cap.isOpened():
            print(f"[camA] camera {index} did not open, using a test pattern")
            self.cap = None
        self.jpeg = None
        self.lock = threading.Lock()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        t0 = time.time()
        while True:
            if self.cap is not None:
                ok, img = self.cap.read()
                if not ok:
                    time.sleep(0.05)
                    continue
                img = cv2.resize(img, (320, 240))
            else:
                img = test_pattern(time.time() - t0)
                time.sleep(1 / 15)
            ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 70])
            if ok:
                with self.lock:
                    self.jpeg = buf.tobytes()

    def latest(self):
        with self.lock:
            return self.jpeg


def test_pattern(t):
    """A gray scene with a square that grows like something approaching."""
    img = np.full((240, 320, 3), 90, np.uint8)
    phase = t % 4.0
    half = int(10 + 60 * phase / 4.0)
    cx = 110
    cv2.rectangle(img, (cx - half, 120 - half), (cx + half, 120 + half), (40, 40, 200), -1)
    cv2.putText(img, f"mock camA {t:6.1f}s", (8, 228), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
    return img


def make_stream_handler(camera):
    class StreamHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/stream":
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            print(f"[camA] stream opened by {self.client_address[0]}")
            last = None
            try:
                while True:
                    jpeg = camera.latest()
                    if jpeg is None or jpeg is last:
                        time.sleep(0.01)
                        continue
                    last = jpeg
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n")
                    self.wfile.write(f"Content-Length: {len(jpeg)}\r\n\r\n".encode())
                    self.wfile.write(jpeg + b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                print(f"[camA] stream closed by {self.client_address[0]}")

        def log_message(self, *args):
            pass

    return StreamHandler


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# ---------------------------------------------------------------------------
# frame: sensors over UDP
# ---------------------------------------------------------------------------

class FakeWearer:
    """Slowly varying sensor values, nudged by typed commands."""

    def __init__(self):
        self.dist_target = 35.0
        self.dist = 35.0
        self.lux = 400.0
        self.turn_until = 0.0
        self.drop_until = 0.0
        self.battery = 82

    def sens(self, now):
        self.dist += (self.dist_target - self.dist) * 0.2 + random.gauss(0, 1.5)
        yaw = random.gauss(0, 4)
        if now < self.turn_until:
            yaw += 120 * math.sin((self.turn_until - now) * math.pi)
        blink = 1 if random.random() < 0.025 else 0     # ~15 blinks per minute at 10 Hz
        lux = self.lux * random.uniform(0.95, 1.05)
        return {"t": "sens", "dist": max(5, round(self.dist)), "blink": blink,
                "yaw_rate": round(yaw), "lux": round(lux), "batt": self.battery}


def send(sock, msg, addr):
    sock.sendto(json.dumps(msg, separators=(",", ":")).encode(), addr)


def receive_loop(sock, state):
    hb_count = 0
    hb_window = time.time()
    while True:
        try:
            data, addr = sock.recvfrom(2048)
        except OSError:
            return
        try:
            msg = json.loads(data)
        except ValueError:
            print(f"[frame] bad datagram from {addr[0]}: {data[:60]!r}")
            continue
        state["last_hb"] = time.time()
        if msg.get("t") == "hb":
            if state.get("phone_lost", True):
                print(f"[frame] heartbeats from {addr[0]}:{addr[1]}, phone connected")
                state["phone_lost"] = False
            hb_count += 1
            if state["show_hb"] and time.time() - hb_window >= 5:
                print(f"[frame] hb x{hb_count} in the last {time.time() - hb_window:.0f} s")
                hb_count, hb_window = 0, time.time()
            continue
        print(f"[frame] <- {json.dumps(msg)}")


def watch_heartbeat(state):
    while True:
        time.sleep(0.2)
        last = state.get("last_hb")
        if last and not state.get("phone_lost", True) and time.time() - last > HB_TIMEOUT:
            print("[frame] no hb for 1 s: phone lost (real glasses would buzz here)")
            state["phone_lost"] = True


def read_commands(wearer, fire_queue, stop):
    for line in sys.stdin:
        cmd = line.strip().lower()
        now = time.time()
        if cmd in ("fl", "fr"):
            fire_queue.append({"t": "fire", "side": cmd[1].upper(), "k": random.randint(3500, 9000)})
        elif cmd == "turn":
            wearer.turn_until = now + 1.0
        elif cmd == "read":
            wearer.dist_target = 30
        elif cmd == "up":
            wearer.dist_target = 250
        elif cmd == "out":
            wearer.lux = 20000
        elif cmd == "in":
            wearer.lux = 400
        elif cmd == "drop":
            wearer.drop_until = now + 5
            print("[frame] sens paused for 5 s")
        elif cmd == "q":
            stop.set()
            return
        elif cmd:
            print("commands: fl fr turn read up out in drop q")
    # stdin closed (for example run in the background): keep running until Ctrl-C


def main(argv=None):
    ap = argparse.ArgumentParser(description="Pretend to be the Omni Glasses (camA + frame ESP32)")
    ap.add_argument("--phone", default="127.0.0.1",
                    help="IP of the phone running the app (default 127.0.0.1 for the iOS simulator; "
                         "the phone's hotspot gateway, e.g. 172.20.10.1, for a real phone)")
    ap.add_argument("--camera", type=int, default=0, help="webcam index (default 0)")
    ap.add_argument("--no-camera", action="store_true", help="serve a test pattern instead of the webcam")
    ap.add_argument("--http-port", type=int, default=HTTP_PORT, help="MJPEG port (default 81)")
    ap.add_argument("--auto-fire", type=float, default=0,
                    help="send a fire on a random side every N seconds (default off)")
    ap.add_argument("--show-hb", action="store_true", help="print a heartbeat count every 5 s")
    args = ap.parse_args(argv)

    try:
        frame_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        frame_sock.bind(("0.0.0.0", FRAME_PORT))
        cam_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        cam_sock.bind(("0.0.0.0", CAMA_PORT))
        camera = Camera(args.camera, args.no_camera)
        httpd = ThreadingHTTPServer(("0.0.0.0", args.http_port), make_stream_handler(camera))
    except OSError as e:
        sys.exit(f"{e}\nAnother mock_glasses.py is probably still running. Find it with:\n"
                 f"  lsof -nP -iUDP:{FRAME_PORT} -iTCP:{args.http_port}")
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    phone = (args.phone, APP_PORT)

    state = {"show_hb": args.show_hb}
    wearer = FakeWearer()
    fire_queue = []
    stop = threading.Event()
    threading.Thread(target=receive_loop, args=(frame_sock, state), daemon=True).start()
    threading.Thread(target=watch_heartbeat, args=(state,), daemon=True).start()
    threading.Thread(target=read_commands, args=(wearer, fire_queue, stop), daemon=True).start()

    print(f"[camA]  MJPEG on http://0.0.0.0:{args.http_port}/stream")
    print(f"[frame] UDP from port {FRAME_PORT} to {phone[0]}:{phone[1]}")
    print("commands: fl fr turn read up out in drop q")

    next_hello = next_auto_fire = time.time()
    if args.auto_fire:
        next_auto_fire += args.auto_fire
    try:
        while not stop.is_set():
            now = time.time()
            if now >= next_hello:
                send(frame_sock, {"t": "hello", "id": "frame"}, phone)
                send(cam_sock, {"t": "hello", "id": "camA"}, phone)
                next_hello = now + 2.0
            if args.auto_fire and now >= next_auto_fire:
                fire_queue.append({"t": "fire", "side": random.choice("LR"), "k": random.randint(3500, 9000)})
                next_auto_fire = now + args.auto_fire
            while fire_queue:
                msg = fire_queue.pop(0)
                send(frame_sock, msg, phone)
                print(f"[frame] -> {json.dumps(msg)}")
            if now >= wearer.drop_until:
                send(frame_sock, wearer.sens(now), phone)
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        httpd.shutdown()
        frame_sock.close()
        cam_sock.close()


if __name__ == "__main__":
    main()
