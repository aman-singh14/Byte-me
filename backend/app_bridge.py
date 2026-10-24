"""Speaks mobile-app's UDP protocol (mobile-app/lib/net/protocol.dart) so Aman's
app shows the backend's real measurements without any change to the app.

The backend plays the "frame" device exactly like mock_glasses.py does:
  hello  {"t":"hello","id":"frame"} every 2 s (and "camA" if the rear MJPEG is served)
  sens   {"t":"sens","dist":cm,"blink":0|1,"yaw_rate":0,"lux":...} 10 times a second
  fire   {"t":"fire","side":"L"|"R","k":K} on every rear alert
and serves the rear camera as MJPEG on :81/stream, where the app's rear view looks.

Run either this (via backend.main) or mock_glasses.py, not both: they use the same ports.
"""

import json
import socket
import threading
import time

import cv2

from mock_glasses import APP_PORT, CAMA_PORT, FRAME_PORT, ThreadingHTTPServer, make_stream_handler


class JpegSource:
    """mock_glasses' stream handler wants an object with latest() -> JPEG bytes."""

    def __init__(self, reader, width=320):
        self.reader = reader
        self.width = width
        self._seq = -1
        self._jpeg = None

    def latest(self):
        seq, frame, _ = self.reader.latest()
        if frame is not None and seq != self._seq:
            h = int(frame.shape[0] * self.width / frame.shape[1])
            ok, buf = cv2.imencode(".jpg", cv2.resize(frame, (self.width, h)), [cv2.IMWRITE_JPEG_QUALITY, 70])
            if ok:
                self._seq, self._jpeg = seq, buf.tobytes()
        return self._jpeg


class AppBridge:
    def __init__(self, cfg, get_live, rear_reader=None):
        b = cfg.get("app_bridge", {})
        self.phone = (b.get("phone_ip", "127.0.0.1"), APP_PORT)
        self.mjpeg_port = b.get("mjpeg_port")
        self.get_live = get_live
        self.rear_reader = rear_reader
        self._blink_pending = False
        self._fires = []
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self.phone_seen = None
        self.httpd = None

    # Called from the pipelines.
    def on_blink(self):
        self._blink_pending = True

    def on_alert(self, side, k, k_left=0, k_right=0):
        # The app only knows L and R; "straight behind" goes to the louder side.
        if side == "C":
            side = "L" if k_left >= k_right else "R"
        with self._lock:
            self._fires.append({"t": "fire", "side": side, "k": int(k)})

    def start(self):
        try:
            self.frame_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.frame_sock.bind(("0.0.0.0", FRAME_PORT))
        except OSError:
            print(f"[bridge] UDP {FRAME_PORT} busy (is mock_glasses.py running?); using a random port")
            self.frame_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            self.frame_sock.bind(("0.0.0.0", 0))
        self.cam_sock = None
        if self.mjpeg_port and self.rear_reader is not None:
            try:
                self.httpd = ThreadingHTTPServer(("0.0.0.0", self.mjpeg_port),
                                                 make_stream_handler(JpegSource(self.rear_reader)))
                threading.Thread(target=self.httpd.serve_forever, name="bridge-mjpeg", daemon=True).start()
                self.cam_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                try:
                    self.cam_sock.bind(("0.0.0.0", CAMA_PORT))
                except OSError:
                    self.cam_sock.bind(("0.0.0.0", 0))
                print(f"[bridge] rear camera MJPEG on http://0.0.0.0:{self.mjpeg_port}/stream")
            except OSError as e:
                print(f"[bridge] cannot serve MJPEG on port {self.mjpeg_port}: {e}")
        threading.Thread(target=self._send_loop, name="bridge-send", daemon=True).start()
        threading.Thread(target=self._recv_loop, name="bridge-recv", daemon=True).start()
        print(f"[bridge] sending the app protocol to {self.phone[0]}:{self.phone[1]}")
        return self

    def stop(self):
        self._stop.set()
        if self.httpd:
            self.httpd.shutdown()

    def _send(self, sock, msg):
        try:
            sock.sendto(json.dumps(msg, separators=(",", ":")).encode(), self.phone)
        except OSError:
            pass   # hotspot briefly down; the next tick retries

    def _send_loop(self):
        next_hello = 0.0
        last_dist = 0
        while not self._stop.is_set():
            now = time.time()
            if now >= next_hello:
                self._send(self.frame_sock, {"t": "hello", "id": "frame"})
                if self.cam_sock:
                    self._send(self.cam_sock, {"t": "hello", "id": "camA"})
                next_hello = now + 2.0
            live = self.get_live()
            # "dist" = distance to what the wearer is looking at: the nearest phone / screen /
            # book from the FRONT camera (the dev face-width estimate only if there is none).
            dist = live.get("nearwork_distance_cm")
            if dist is None:
                dist = live.get("distance_cm")
            if dist is not None:
                last_dist = round(dist)
            blink, self._blink_pending = self._blink_pending, False
            self._send(self.frame_sock, {"t": "sens", "dist": last_dist, "blink": int(blink),
                                         "yaw_rate": 0, "lux": int(live.get("lux_est") or 0)})
            with self._lock:
                fires, self._fires = self._fires, []
            for f in fires:
                self._send(self.frame_sock, f)
            self._stop.wait(0.1)

    def _recv_loop(self):
        self.frame_sock.settimeout(1.0)
        while not self._stop.is_set():
            try:
                data, addr = self.frame_sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                return
            if self.phone_seen is None:
                print(f"[bridge] app connected from {addr[0]}")
            self.phone_seen = time.time()
            try:
                msg = json.loads(data)
            except ValueError:
                continue
            if msg.get("t") != "hb":
                print(f"[bridge] <- {msg}")
