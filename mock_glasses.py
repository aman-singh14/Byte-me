#!/usr/bin/env python3
"""Pretend to be the Omni Glasses so the app can be built before the hardware works.

Plays both devices:

    camA   MJPEG stream of the laptop webcam at http://<laptop>:81/stream (320x240)
    camB   the FPGA reflex camera: says hello too and shares camA's stream, so
           the app can name fires (fl / fr) from "Cam B's" video
    frame  UDP JSON: sends hello, sens (10/s) and fire; prints what the app sends

Protocol (one JSON message per UDP datagram):

    device -> app   {"t":"hello","id":"frame"|"camA"|"camB"}  every 2 s, always
    frame  -> app   {"t":"sens","dist":34,"blink":0,"yaw_rate":12,"lux":850,"batt":82}
    frame  -> app   {"t":"fire","side":"L","k":812}
    app -> frame    alert, tap, groupbreak, stop, hb (every 250 ms),
                    guide {"dir":"L"|"R"|"fwd"|"stop"} (Call a helper),
                    live {"on":true|false} (front LED while a helper watches),
                    nudge {"kind":"close"|"break"} (eye-health)
                    Each is printed with the buzz (or LED) the real frame plays.

The app listens on UDP port 4210 and learns each device's address from the
sender of its hello, so it replies to whatever address and port the hello came
from. "batt" (percent) is an optional field the app shows in its status strip.
Sides are always the wearer's left/right; the frame firmware flips Cam B's image
sides before sending.

Type a command and press Enter while it runs:

    fl / fr     fire on the wearer's left / right
    turn l / r  head turn toward the wearer's left / right (~75 deg over 1 s)
    read        close-up work, dist ~30 cm      up    looking up, dist ~250 cm
    out         daylight, lux ~20000            in    indoors, lux ~400
    drop        stop sending sens for 5 s (to test the link-lost banner)
    person [l|r|c]  someone walks up behind the wearer (left, right or center),
                stops for 8 s, then leaves: a social tap. Use "read" first for a
                "look up" tap. Needs ultralytics' bus.jpg (or --person-image).
    q           quit
"""

import argparse
import glob
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
from pathlib import Path

APP_PORT = 4210      # the app listens here
FRAME_PORT = 4211    # frame ESP32 sends from and listens on this port
CAMA_PORT = 4212     # camA and camB only send hellos, from this port
HTTP_PORT = 81       # camA MJPEG stream
HB_TIMEOUT = 1.0     # seconds without hb before the frame decides the phone is gone


# ---------------------------------------------------------------------------
# camA: webcam as MJPEG
# ---------------------------------------------------------------------------

class Camera:
    """Keeps only the newest 320x240 JPEG. Falls back to a test pattern."""

    def __init__(self, index, synthetic, person=None):
        self.person = person                            # PersonScene drawn over the picture
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
            if self.person is not None:
                img = self.person.draw(img, time.time())
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


def find_person_image(path=None):
    """A photo with a whole standing person: --person-image, or ultralytics' bus.jpg."""
    if path:
        return path
    try:
        import ultralytics
        candidates = [str(Path(ultralytics.__file__).parent / "assets" / "bus.jpg")]
    except ImportError:
        candidates = []
    candidates += glob.glob(str(Path.home() / ".cache" / "*" / "lib" / "python*" / "site-packages"
                                / "ultralytics" / "assets" / "bus.jpg"))
    return next((c for c in candidates if Path(c).exists()), None)


class PersonScene:
    """Someone walks up to the rear camera, stops close, waits, then leaves.

    The rear camera faces backward, so the wearer's LEFT is the RIGHT of the image.
    Approach 4 s (box height 30% -> 98% of the image, cut at the bottom like
    someone ~1 m away), stay 8 s, gone.
    """

    APPROACH_S, STAY_S = 4.0, 8.0
    BOX = (48, 399, 245, 903)       # the left-hand person in bus.jpg, (x0, y0, x1, y1)

    def __init__(self, image_path):
        img = cv2.imread(image_path) if image_path else None
        if img is None:
            self.crop = None
            return
        x0, y0, x1, y1 = self.BOX
        self.crop = img[y0:y1, x0:x1]
        self.start = None
        self.center = 0.5

    def begin(self, side):
        if self.crop is None:
            print("[camA] person: no picture of a person. Install ultralytics or pass --person-image")
            return
        self.center = {"l": 0.78, "r": 0.22}.get(side, 0.5)
        self.start = time.time()
        where = {"l": "behind left", "r": "behind right"}.get(side, "straight behind")
        print(f"[camA] person: walking up {where}, stopping for {self.STAY_S:.0f} s")

    def draw(self, img, now):
        if self.start is None:
            return img
        t = now - self.start
        if t > self.APPROACH_S + self.STAY_S:
            self.start = None
            print("[camA] person: gone")
            return img
        grow = min(1.0, t / self.APPROACH_S)
        h_img, w_img = img.shape[:2]
        h = int(h_img * (0.3 + 0.75 * grow))         # ends a little taller than the image: cut off
        w = int(h * self.crop.shape[1] / self.crop.shape[0])
        person = cv2.resize(self.crop, (w, h))
        x0 = int(self.center * w_img - w / 2)
        y0 = int(h_img * (0.55 - 0.5 * grow))        # feet drop out of view as they come closer
        out = img.copy()
        sx0, sy0 = max(0, -x0), max(0, -y0)
        dx0, dy0 = max(0, x0), max(0, y0)
        dx1, dy1 = min(w_img, x0 + w), min(h_img, y0 + h)
        if dx1 > dx0 and dy1 > dy0:
            out[dy0:dy1, dx0:dx1] = person[sy0:sy0 + dy1 - dy0, sx0:sx0 + dx1 - dx0]
        return out


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
        self.turn_sign = 1                              # +yaw_rate = toward the wearer's left
        self.drop_until = 0.0
        self.battery = 82

    def sens(self, now):
        self.dist += (self.dist_target - self.dist) * 0.2 + random.gauss(0, 1.5)
        yaw = random.gauss(0, 4)
        if now < self.turn_until:
            yaw += self.turn_sign * 120 * math.sin((self.turn_until - now) * math.pi)
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
        print(f"[frame] <- {describe(msg)}")


# Guidance from a remote helper: long pulses, so it never feels like an
# approach alert (short pulses). An active alert always wins over guidance.
GUIDE_BUZZ = {
    "L": "<- LEFT     left motor: 2 long pulses (400 ms, gap 150 ms)",
    "R": "-> RIGHT    right motor: 2 long pulses (400 ms, gap 150 ms)",
    "fwd": "^  FORWARD  both motors: 2 medium pulses (250 ms, gap 150 ms)",
    "stop": "X  STOP     both motors: one steady 1 s buzz",
}


SIDES = {"L": "left motor", "R": "right motor", "B": "both motors"}

# Social and eye-health patterns are soft (about 40% strength) so they never
# feel like a warning. A safety alert always wins over all of them.
TAP_BUZZ = {
    "social": "two soft short taps (60 ms, gap 120 ms)",
    "lookup": "two soft short taps, then one soft 300 ms pulse on both motors (\"look up\")",
}
NUDGE_BUZZ = {
    "close": "one slow soft pulse (500 ms) on both motors",
    "break": "three slow soft pulses (300 ms, gap 300 ms) on both motors",
}


def describe(msg):
    """One readable line for a message from the app, with the buzz it means."""
    t = msg.get("t")
    side = SIDES.get(msg.get("side"), f"? side {msg.get('side')!r}")
    if t == "alert":
        level = msg.get("level")
        buzz = "three strong pulses (150 ms apart)" if level == 2 else "one pulse"
        return f"ALERT {'urgent' if level == 2 else 'gentle'} {msg.get('label', '?')}: {side}, {buzz}"
    if t == "stop":
        return "STOP: motors off"
    if t == "tap":
        kind = msg.get("kind", "social")
        return f"TAP {kind}: {side}, {TAP_BUZZ.get(kind, '? unknown kind')}"
    if t == "guide":
        return f"GUIDE {GUIDE_BUZZ.get(msg.get('dir'), '? unknown direction')}"
    if t == "live":
        return "LIVE: front LED ON (a helper is watching)" if msg.get("on") else "LIVE: front LED off"
    if t == "nudge":
        return f"NUDGE {msg.get('kind')}: {NUDGE_BUZZ.get(msg.get('kind'), '? unknown kind')}"
    if t == "groupbreak":
        return "GROUP BREAK: break reminder pattern"
    return json.dumps(msg)


def watch_heartbeat(state):
    while True:
        time.sleep(0.2)
        last = state.get("last_hb")
        if last and not state.get("phone_lost", True) and time.time() - last > HB_TIMEOUT:
            print("[frame] no hb for 1 s: phone lost (real glasses would buzz here)")
            state["phone_lost"] = True


def read_commands(wearer, fire_queue, stop, person):
    for line in sys.stdin:
        cmd = line.strip().lower()
        now = time.time()
        if cmd in ("fl", "fr"):
            fire_queue.append({"t": "fire", "side": cmd[1].upper(), "k": random.randint(3500, 9000)})
        elif cmd in ("turn", "turn l", "turn r"):
            wearer.turn_sign = -1 if cmd == "turn r" else 1
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
        elif cmd.split()[:1] == ["person"]:
            person.begin(cmd.split()[1] if len(cmd.split()) > 1 else "c")
        elif cmd == "q":
            stop.set()
            return
        elif cmd:
            print("commands: fl fr turn l|r read up out in drop person [l|r|c] q")
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
    ap.add_argument("--person-image", help="photo for the 'person' command (default: ultralytics' bus.jpg)")
    args = ap.parse_args(argv)

    try:
        frame_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        frame_sock.bind(("0.0.0.0", FRAME_PORT))
        cam_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        cam_sock.bind(("0.0.0.0", CAMA_PORT))
        person = PersonScene(find_person_image(args.person_image))
        camera = Camera(args.camera, args.no_camera, person)
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
    threading.Thread(target=read_commands, args=(wearer, fire_queue, stop, person), daemon=True).start()

    print(f"[camA]  MJPEG on http://0.0.0.0:{args.http_port}/stream")
    print(f"[frame] UDP from port {FRAME_PORT} to {phone[0]}:{phone[1]}")
    print("commands: fl fr turn l|r read up out in drop person [l|r|c] q")

    next_hello = next_auto_fire = time.time()
    if args.auto_fire:
        next_auto_fire += args.auto_fire
    try:
        while not stop.is_set():
            now = time.time()
            if now >= next_hello:
                send(frame_sock, {"t": "hello", "id": "frame"}, phone)
                send(cam_sock, {"t": "hello", "id": "camA"}, phone)
                send(cam_sock, {"t": "hello", "id": "camB"}, phone)
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
