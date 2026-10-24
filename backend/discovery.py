"""ESP32-CAM discovery on the phone hotspot.

Each camera broadcasts a hello every 2 s (firmware/esp32cam):

    {"t": "cam_hello", "role": "eye" | "front", "ip": "172.20.10.3", "stream_port": 81, "http_port": 80}

on UDP port 4310. Stream URL order for a camera: the IP it announced (if heard in the
last `fresh_s`), then the configured URL (an mDNS name like eye-cam.local, which iPhone
hotspots often don't resolve), then `static_ip` from config.
"""

import json
import socket
import threading
import time

ROLES = ("eye", "front")
HELLO_PORT = 4310


def parse_hello(data):
    """Bytes -> {"role", "ip", "stream_port", "http_port"} or None if it isn't a valid hello."""
    try:
        msg = json.loads(data)
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(msg, dict) or msg.get("t") != "cam_hello" or msg.get("role") not in ROLES:
        return None
    ip = msg.get("ip")
    parts = ip.split(".") if isinstance(ip, str) else []
    if len(parts) != 4 or not all(p.isdigit() and 0 <= int(p) <= 255 for p in parts):
        return None
    return {"role": msg["role"], "ip": ip, "stream_port": int(msg.get("stream_port", 81)),
            "http_port": int(msg.get("http_port", 80))}


class CameraDirectory:
    """Who is where. on_change(role, stream_url) fires when a camera's announced address changes."""

    def __init__(self, cfg, on_change=None, fresh_s=10.0, port=HELLO_PORT):
        self.cams = {r: c for r, c in cfg.get("cameras", {}).items() if r in ROLES}
        self.on_change = on_change
        self.fresh_s = fresh_s
        self.port = cfg.get("discovery", {}).get("port", port)
        self.seen = {}                     # role -> {"ip", "stream_port", "http_port", "t"}
        self._stop = threading.Event()
        self._lock = threading.Lock()

    def handle(self, data, sender_ip=None, now=None):
        """Feed one datagram. Returns the parsed hello or None."""
        hello = parse_hello(data)
        if hello is None:
            return None
        now = now or time.time()
        with self._lock:
            prev = self.seen.get(hello["role"])
            self.seen[hello["role"]] = {**hello, "t": now, "sender": sender_ip}
        changed = prev is None or prev["ip"] != hello["ip"] or prev["stream_port"] != hello["stream_port"]
        if changed:
            print(f"[discovery] {hello['role']} camera at {hello['ip']}")
            if self.on_change:
                self.on_change(hello["role"], self.stream_url(hello["role"], now))
        return hello

    def announced(self, role, now=None):
        now = now or time.time()
        with self._lock:
            s = self.seen.get(role)
        return s if s and now - s["t"] <= self.fresh_s else None

    def candidates(self, role, now=None):
        """Stream URLs to try, best first."""
        out = []
        a = self.announced(role, now)
        if a:
            out.append(f"http://{a['ip']}:{a['stream_port']}/stream")
        cam = self.cams.get(role, {})
        if isinstance(cam.get("source"), str):
            out.append(cam["source"])
        if cam.get("static_ip"):
            out.append(f"http://{cam['static_ip']}:81/stream")
        return list(dict.fromkeys(out))

    def stream_url(self, role, now=None):
        c = self.candidates(role, now)
        return c[0] if c else None

    def http_base(self, role, now=None):
        """http://<camera> for /capture and /sensor (port 80), or None if unknown."""
        a = self.announced(role, now)
        if a:
            return f"http://{a['ip']}" + ("" if a["http_port"] == 80 else f":{a['http_port']}")
        cam = self.cams.get(role, {})
        src = cam.get("source")
        if isinstance(src, str) and src.startswith("http://"):
            host = src[len("http://"):].split("/")[0].split(":")[0]
            return f"http://{host}"
        if cam.get("static_ip"):
            return f"http://{cam['static_ip']}"
        return None

    def status(self, now=None):
        now = now or time.time()
        with self._lock:
            seen = {r: {**s, "age_s": round(now - s["t"], 1)} for r, s in self.seen.items()}
        return {"port": self.port, "seen": seen, "candidates": {r: self.candidates(r, now) for r in self.cams}}

    # -- listener -------------------------------------------------------------

    def _loop(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", self.port))
        except OSError as e:
            print(f"[discovery] cannot listen on UDP {self.port}: {e}")
            return
        sock.settimeout(0.5)
        while not self._stop.is_set():
            try:
                data, addr = sock.recvfrom(2048)
            except socket.timeout:
                continue
            except OSError:
                return
            self.handle(data, addr[0])
        sock.close()

    def start(self):
        threading.Thread(target=self._loop, name="discovery", daemon=True).start()
        return self

    def stop(self):
        self._stop.set()
