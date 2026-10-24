"""rear.mode: fpga. Receive FPGA events (docs/rear_event_protocol.md), warn at once,
then classify the clip and follow up.

    receivers (UDP :4300, USB-serial, HTTP POST /rear/packets)
      -> StreamParser per source -> ClipAssembler
      -> on EVENT: speak "Something approaching from behind" (urgent) IMMEDIATELY
      -> on END / timeout: save the clip, classify on a worker thread, speak the result

Packet reception never waits for classification or for Muse.
"""

import json
import queue
import socket
import threading
import time
from pathlib import Path

import numpy as np

from backend.rear import protocol as p
from backend.rear.classifier import SIDE_WORDS, RearClassifier, decode_frames, wearer_side

CLIPS_DIR = Path(__file__).resolve().parent.parent / "data" / "clips"
REGION_X = {p.REGION_LEFT: 0.15, p.REGION_CENTER: 0.5, p.REGION_RIGHT: 0.85}
SIDE_DOMINANCE = 0.6       # name a side in the instant warning only if one third has >= 60% of K


def event_side(ev, flip=True):
    """Wearer side for the instant warning, or None when it is not clear-cut. Uses the
    per-third K values when the FPGA sends them, else its region field."""
    thirds = (ev.k_left, ev.k_center, ev.k_right)
    if sum(thirds) > 0:
        i = max(range(3), key=lambda j: thirds[j])
        if thirds[i] / sum(thirds) < SIDE_DOMINANCE:
            return None
        return wearer_side((0.15, 0.5, 0.85)[i], flip)
    return wearer_side(REGION_X[ev.region], flip) if ev.region in REGION_X else None


class RearService:
    def __init__(self, cfg, voice, emit, detector, muse=None, db=None, bridge=None, clips_dir=None):
        r = cfg.get("rear", {})
        f = r.get("fpga", {})
        self.flip = r.get("flip", True)
        self.cooldown_s = r.get("cooldown_s", 4.0)
        self.message = r.get("message", "Something approaching from behind")
        self.say_false_alarm = f.get("say_false_alarm", True)
        self.muse_followup = f.get("muse_followup", False)
        self.gap_timeout_s = f.get("gap_timeout_s", 1.0)
        self.clip_timeout_s = f.get("clip_timeout_s", 10.0)
        self.save_clips = f.get("save_clips", True)
        self.transports = f.get("transports", ["udp"])
        self.udp_port = f.get("udp_port", 4300)
        self.serial_port = f.get("serial_port")
        self.baud = f.get("baud", 921600)
        self.voice, self.emit, self.db, self.muse = voice, emit, db, muse
        self.bridge = bridge
        self.clips_dir = Path(clips_dir or CLIPS_DIR)
        self.classifier = RearClassifier(detector, self.flip, f.get("tau_danger_s", 4.0), f.get("min_growth", 1.3))
        self.assembler = p.ClipAssembler(self._on_event, self._on_clip, self._on_heartbeat)
        self._parsers = {}
        self._lock = threading.Lock()          # one packet at a time into the assembler
        self._work = queue.Queue()
        self._stop = threading.Event()
        self._last_warn = -1e9
        self._event_t = {}                     # event_id -> receive time
        self._last_packet = 0.0
        self.last_heartbeat = None
        self.stats = {"packets": 0, "parse_errors": 0, "events": 0, "clips": 0, "incomplete_clips": 0,
                      "dropped_packets": 0}
        self.last_result = None
        self.history = []

    # -- input ---------------------------------------------------------------

    def feed_bytes(self, data, source="default"):
        """Raw bytes from any transport. Returns the number of packets decoded."""
        parser = self._parsers.setdefault(source, p.StreamParser())
        before = parser.errors
        packets = parser.feed(data)
        with self._lock:
            self.stats["parse_errors"] += parser.errors - before
            for pkt in packets:
                self.stats["packets"] += 1
                self._last_packet = time.time()
                self.assembler.feed(pkt)
        return len(packets)

    # -- assembler callbacks (packet thread: keep them fast) -------------------

    def _on_event(self, ev, event_id):
        t = time.time()
        self._event_t[event_id] = t
        self.stats["events"] += 1
        side = event_side(ev, self.flip)
        data = {"event_id": event_id, "k": ev.k_peak, "side": side, "fpga_t_ms": ev.t_ms,
                "frames_expected": ev.frame_count if ev.flags & p.FLAG_CLIP_FOLLOWS else 0}
        if t - self._last_warn >= self.cooldown_s:
            self._last_warn = t
            text = self.message + (f", {SIDE_WORDS[side]}" if side in ("L", "R") else "")
            self.voice.say(text, "urgent", source="rear")         # BEFORE any frame arrives
            data["spoken"] = text
        if self.bridge is not None:
            self.bridge.on_alert(side or "C", ev.k_peak, ev.k_right, ev.k_left)   # image -> wearer
        self.emit("rear_event", data)
        if not ev.flags & p.FLAG_CLIP_FOLLOWS:
            self.assembler.flush()

    def _on_clip(self, clip):
        self.stats["clips"] += 1
        self.stats["dropped_packets"] += clip.dropped_packets
        if not clip.complete:
            self.stats["incomplete_clips"] += 1
        self._work.put(clip)                                       # classify off the packet thread

    def _on_heartbeat(self, hb):
        self.last_heartbeat = (time.time(), hb.status)

    # -- worker ---------------------------------------------------------------

    def _worker(self):
        while not self._stop.is_set():
            try:
                clip = self._work.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                self.process_clip(clip)
            except Exception as e:                                 # never kill the worker
                print(f"[rear] classification error: {e!r}")

    def process_clip(self, clip):
        t_event = self._event_t.pop(clip.event_id, time.time())
        frames_ok = sum(f is not None for f in clip.frames)
        if frames_ok == 0 and not clip.event.flags & p.FLAG_CLIP_FOLLOWS:
            return None                                            # event only: the warning was all
        result = self.classifier.classify(clip)
        path = self._save(clip, result) if self.save_clips and frames_ok else None
        speak = result.kind != "nothing" or self.say_false_alarm
        if speak:
            self.voice.say(result.text, "urgent" if result.dangerous else "normal", source="rear")
        info = {"event_id": clip.event_id, "k": clip.event.k_peak, **result.as_dict(),
                "crc_ok": clip.crc_ok, "complete": clip.complete, "frames": frames_ok,
                "latency_s": round(time.time() - t_event, 2), "clip": str(path) if path else None}
        self.last_result = info
        self.history = (self.history + [info])[-20:]
        self.emit("rear_result", info)
        if self.db is not None:                                    # the dashboard's alerts list
            self.db.add_event(t_event, "alert", {"side": result.side or "C", "k": clip.event.k_peak,
                                                 "label": result.label, "text": result.text,
                                                 "dangerous": result.dangerous, "kind": result.kind,
                                                 "ttc_s": info["ttc_s"], "source": "fpga"})
        if self.muse_followup and self.muse is not None and result.dangerous:
            threading.Thread(target=self._describe, args=(clip, info), daemon=True).start()
        return info

    def _describe(self, clip, info):
        """Optional: one frame to Muse for a richer description (dashboard only, never blocks)."""
        from backend.muse_client import MuseUnavailable
        frames = [f for f in decode_frames(clip) if f is not None]
        try:
            r = self.muse.ask("In one short sentence: what is approaching the camera, and how fast does it look?",
                              image=frames[-1], purpose="rear")
            self.emit("rear_description", {"event_id": clip.event_id, "text": r.text})
        except MuseUnavailable as e:
            self.emit("rear_description", {"event_id": clip.event_id, "text": None, "error": str(e)})

    def _save(self, clip, result):
        self.clips_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d_%H%M%S")
        path = self.clips_dir / f"event_{stamp}_{clip.event_id}.npz"
        imgs = decode_frames(clip)
        h, w = clip.event.height, clip.event.width
        stack = np.stack([(i[:, :, 0] if i is not None and i.shape[:2] == (h, w) else np.zeros((h, w), np.uint8))
                          for i in imgs])
        np.savez_compressed(path, frames=stack, fps=np.float64(clip.event.fps),
                            present=np.array([i is not None for i in imgs]),
                            meta=json.dumps({"event": clip.event.__dict__, "result": result.as_dict(),
                                             "crc_ok": clip.crc_ok}))
        return path

    # -- receivers ---------------------------------------------------------------

    def _watchdog(self):
        """Deliver a clip whose END never came (no packet for gap_timeout_s, or too long overall)."""
        while not self._stop.wait(0.2):
            with self._lock:
                cur = self.assembler.current
                if cur is None:
                    continue
                t_ev = self._event_t.get(cur.event_id, time.time())
                now = time.time()
                if now - self._last_packet > self.gap_timeout_s or now - t_ev > self.clip_timeout_s:
                    self.assembler.flush()

    def _udp_loop(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)   # a whole clip in flight
        try:
            sock.bind(("0.0.0.0", self.udp_port))
        except OSError as e:
            print(f"[rear] cannot listen on UDP {self.udp_port}: {e}")
            return
        sock.settimeout(0.5)
        print(f"[rear] listening for FPGA packets on UDP {self.udp_port}")
        while not self._stop.is_set():
            try:
                data, addr = sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                return
            self.feed_bytes(data, source=f"udp:{addr[0]}:{addr[1]}")

    def _open_serial(self):
        import serial
        try:
            return serial.Serial(self.serial_port, self.baud, timeout=0.2)
        except OSError as e:
            if e.errno != 25:                       # ENOTTY: a virtual port (pty) rejects custom baud rates
                raise
            return serial.Serial(self.serial_port, 115200, timeout=0.2)   # ptys ignore the rate anyway

    def _serial_loop(self):
        import serial
        while not self._stop.is_set():
            try:
                with self._open_serial() as ser:
                    print(f"[rear] reading FPGA packets from {self.serial_port} at {self.baud} baud")
                    while not self._stop.is_set():
                        data = ser.read(4096)
                        if data:
                            self.feed_bytes(data, source="serial")
            except (OSError, serial.SerialException) as e:
                print(f"[rear] serial {self.serial_port}: {e}; retrying in 3 s")
                self._stop.wait(3)

    def start(self):
        threading.Thread(target=self._worker, name="rear-classify", daemon=True).start()
        threading.Thread(target=self._watchdog, name="rear-watchdog", daemon=True).start()
        if "udp" in self.transports:
            threading.Thread(target=self._udp_loop, name="rear-udp", daemon=True).start()
        if "serial" in self.transports and self.serial_port:
            threading.Thread(target=self._serial_loop, name="rear-serial", daemon=True).start()
        return self

    def stop(self):
        self._stop.set()

    def status(self):
        hb = self.last_heartbeat
        return {
            "mode": "fpga",
            "transports": self.transports,
            "udp_port": self.udp_port if "udp" in self.transports else None,
            "serial_port": self.serial_port if "serial" in self.transports else None,
            "fpga_online": hb is not None and time.time() - hb[0] < 3.0,
            "last_heartbeat_age_s": None if hb is None else round(time.time() - hb[0], 1),
            "stats": dict(self.stats),
            "last_result": self.last_result,
        }
