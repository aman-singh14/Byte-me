#!/usr/bin/env python3
"""Pretend to be the rear FPGA: send protocol-correct EVENT + clip + END packets
(docs/rear_event_protocol.md) so the app side runs with no hardware.

    python tools/mock_fpga.py                         # one "person approaching on your left" over UDP :4300
    python tools/mock_fpga.py --scene leaves          # false alarm: leaf shadows
    python tools/mock_fpga.py --every 12 --scene cycle   # person / leaves / recede / square, forever
    python tools/mock_fpga.py --video clip.mp4        # last 3 s of a video file
    python tools/mock_fpga.py --transport serial --serial pty   # virtual serial port (prints its path)
    python tools/mock_fpga.py --transport http        # POST to http://localhost:8001/rear/packets
    python tools/mock_fpga.py --baud 921600           # pace the bytes like a real UART

The EVENT's K values and region come from running lgmd.py over the clip, as the FPGA would.
"""

import argparse
import itertools
import os
import socket
import sys
import time
import tty
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from backend.rear import protocol as p          # noqa: E402
from backend.rear import scenes                 # noqa: E402

CYCLE = [("person", "left"), ("leaves", None), ("person", "right"), ("recede", "left"), ("square", None)]


def build_packets(frames, event_id, fmt="gray8", t_ms=None, event_only=False):
    stats = scenes.lgmd_stats(frames)
    h, w = frames[0].shape[:2]
    ev = p.Event(t_ms=int((t_ms if t_ms is not None else time.monotonic() * 1000)) & 0xFFFFFFFF,
                 k_peak=stats["k_peak"], k_left=stats["k_left"], k_center=stats["k_center"],
                 k_right=stats["k_right"], width=w, height=h, frame_count=0 if event_only else len(frames),
                 trigger_index=len(frames) - 1, fps=scenes.FPS,
                 pixel_format=p.GRAY8 if fmt == "gray8" else p.JPEG, region=stats["region"],
                 flags=0 if event_only else p.FLAG_CLIP_FOLLOWS)
    if event_only:
        return [p.encode(ev, event_id, 0)]
    return p.encode_event(ev, scenes.to_payload(frames, fmt), event_id)


class Sender:
    def __init__(self, transport, host="127.0.0.1", port=4300, serial_path=None, http_url=None, baud=None):
        self.transport, self.baud = transport, baud
        self.addr = (host, port)
        self.http_url = http_url
        if transport == "udp":
            self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        elif transport == "serial":
            if serial_path in (None, "pty"):
                self.fd, slave = os.openpty()
                tty.setraw(slave)                       # binary-safe: no echo, no line editing
                tty.setraw(self.fd)
                self.serial_name = os.ttyname(slave)
                self._slave = slave                     # keep it open so the device stays alive
                print(f"[mock_fpga] virtual serial port: {self.serial_name}")
                print(f"[mock_fpga] run the backend with: rear.fpga.transports [serial], serial_port "
                      f"{self.serial_name} (or --rear-serial {self.serial_name})")
                self.ser = None
            else:
                import serial
                self.ser = serial.Serial(serial_path, baud or 921600)
                self.fd = None

    def close(self):
        if self.transport == "udp":
            self.sock.close()

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    def _pace(self, n):
        if self.baud:
            time.sleep(n * 10 / self.baud)           # 8N1: 10 bits per byte

    def send(self, packets):
        if self.transport == "udp":
            for i, pkt in enumerate(packets):
                self.sock.sendto(pkt, self.addr)
                self._pace(len(pkt))
                if not self.baud and i % 64 == 63:
                    time.sleep(0.002)                # don't flood the receiver's socket buffer
        elif self.transport == "serial":
            for pkt in packets:
                if self.ser is not None:
                    self.ser.write(pkt)
                else:
                    os.write(self.fd, pkt)
                self._pace(len(pkt))
        elif self.transport == "http":
            # EVENT alone first so the warning is not delayed, then the clip.
            for body in (packets[:1], packets[1:]):
                if body:
                    req = urllib.request.Request(self.http_url, b"".join(body),
                                                 {"Content-Type": "application/octet-stream"})
                    urllib.request.urlopen(req, timeout=10).read()


def main(argv=None):
    ap = argparse.ArgumentParser(description="Send mock rear-FPGA events")
    ap.add_argument("--scene", default="person", choices=list(scenes.SCENES) + ["cycle"])
    ap.add_argument("--side", default="left", choices=("left", "center", "right"),
                    help="wearer side for person/recede scenes")
    ap.add_argument("--video", help="use the last 3 s of this video file instead of a scene")
    ap.add_argument("--format", default="gray8", choices=("gray8", "jpeg"))
    ap.add_argument("--transport", default="udp", choices=("udp", "serial", "http"))
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=4300)
    ap.add_argument("--serial", default="pty", help="serial device, or 'pty' for a virtual one")
    ap.add_argument("--http", default="http://localhost:8001/rear/packets")
    ap.add_argument("--baud", type=int, help="pace bytes like a UART at this baud rate")
    ap.add_argument("--every", type=float, help="repeat every N seconds")
    ap.add_argument("--count", type=int, help="stop after N events (default 1, or forever with --every)")
    ap.add_argument("--event-only", action="store_true", help="send only the EVENT (no clip)")
    ap.add_argument("--heartbeat", action="store_true", help="send a HEARTBEAT every second between events")
    args = ap.parse_args(argv)

    sender = Sender(args.transport, args.host, args.port, args.serial, args.http, args.baud)
    count = args.count or (None if args.every else 1)
    scene_iter = itertools.cycle(CYCLE) if args.scene == "cycle" else itertools.repeat((args.scene, args.side))
    event_id = 1
    if args.transport == "serial" and args.serial in (None, "pty"):
        time.sleep(2.0)                              # time to start the backend on the printed port
    try:
        for n in itertools.count():
            if count is not None and n >= count:
                break
            if args.video:
                frames, label = scenes.from_video(args.video), Path(args.video).name
            else:
                name, side = next(scene_iter)
                fn = scenes.SCENES[name]
                frames = fn(side) if name in ("person", "recede") else fn()
                label = name + (f" ({side})" if side and name in ("person", "recede") else "")
            pkts = build_packets(frames, event_id, args.format, event_only=args.event_only)
            t0 = time.time()
            sender.send(pkts)
            size = sum(map(len, pkts))
            print(f"[mock_fpga] event {event_id}: {label}, {len(pkts)} packets, {size / 1024:.0f} KB "
                  f"in {time.time() - t0:.2f} s via {args.transport}")
            event_id = (event_id + 1) & 0xFFFF or 1
            if args.every and (count is None or n + 1 < count):
                t_next = time.time() + args.every
                while time.time() < t_next:
                    if args.heartbeat:
                        sender.send([p.encode(p.Heartbeat(int(time.monotonic() * 1000) & 0xFFFFFFFF, 3), 0, 0)])
                    time.sleep(min(1.0, max(0.0, t_next - time.time())))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
