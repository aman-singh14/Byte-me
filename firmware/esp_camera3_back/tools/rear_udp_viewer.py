#!/usr/bin/env python3
"""
rear_udp_viewer.py - watch the Omni Glasses rear camera on the laptop.

    py rear_udp_viewer.py                 listen on UDP 4300 (laptop must be on the "espholder" Wi-Fi)
    py rear_udp_viewer.py --esp 10.0.0.42 also tell the ESP32-CAM to send straight to this laptop

Shows the live video (the ESP only streams while the FPGA is tracking something) with
CLEAR / TRACKING / COLLISION / HEAD TURNING, and prints every status change.
Windows may ask to allow Python through the firewall: allow it on private networks.
"""
import argparse
import json
import socket
import struct
import time

import cv2
import numpy as np

PORT = 4300


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--esp", help="ESP32-CAM IP (optional; otherwise learned from its first packet)")
    ap.add_argument("--port", type=int, default=PORT)
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 22)
    sock.bind(("0.0.0.0", args.port))
    sock.settimeout(0.02)
    esp = (args.esp, args.port) if args.esp else None
    print(f"listening on UDP {args.port} ...")

    parts, frame = {}, None
    status, last_flags, last_hello, last_video = {}, None, 0.0, 0.0
    shown, fps_t = 0, time.time()
    fps = 0.0
    while True:
        now = time.time()
        if esp and now - last_hello > 2.0:                 # keeps the ESP sending to us directly
            sock.sendto(b"hello", esp)
            last_hello = now
        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            data = None
        if data:
            if esp is None:
                esp = (addr[0], args.port)
                print(f"ESP32-CAM found at {addr[0]}")
            if data[:4] == b"OMNV" and len(data) >= 16:
                fid, chunk, n, total = struct.unpack_from("<IHHI", data, 4)
                entry = parts.setdefault(fid, {"n": n, "len": total, "chunks": {}})
                entry["chunks"][chunk] = data[16:]
                if len(entry["chunks"]) == entry["n"]:
                    jpg = b"".join(entry["chunks"][i] for i in range(entry["n"]))
                    img = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_GRAYSCALE)
                    if img is not None:
                        frame, last_video = img, now
                        shown += 1
                    for old in [k for k in parts if k <= fid]:
                        del parts[old]
                if len(parts) > 8:                          # drop stale incomplete frames
                    for old in sorted(parts)[:-4]:
                        del parts[old]
            elif data[:1] == b"{":
                try:
                    msg = json.loads(data.decode())
                except ValueError:
                    msg = {}
                if msg.get("t") == "rear":
                    status = msg
                    flags = (msg.get("tracking"), msg.get("collision"), msg.get("turning"), msg.get("fpga"))
                    if flags != last_flags:
                        print(f"{time.strftime('%H:%M:%S')}  tracking {msg.get('tracking')}  "
                              f"collision {msg.get('collision')}  turning {msg.get('turning')}  "
                              f"imu {msg.get('imu')}  fpga {msg.get('fpga')}  esp fps {msg.get('fps')}")
                        last_flags = flags
                elif msg.get("t") == "collision":
                    print(f"{time.strftime('%H:%M:%S')}  *** COLLISION (frame {msg.get('seq')}) ***")

        if now - fps_t > 1.0:
            fps, shown, fps_t = shown / (now - fps_t), 0, now
        img = cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR) if frame is not None and now - last_video < 3 \
            else np.full((480, 640, 3), 30, np.uint8)
        img = cv2.resize(img, (640, 480))
        if not status:
            text, color = "waiting for the ESP32-CAM...", (90, 90, 90)
        elif not status.get("fpga"):
            text, color = "FPGA NOT ANSWERING", (90, 90, 90)
        elif status.get("turning"):
            text, color = "HEAD TURNING - detection paused", (120, 120, 120)
        elif status.get("collision") or status.get("horn"):
            text, color = "COLLISION", (0, 0, 220)
        elif status.get("tracking"):
            text, color = "TRACKING", (0, 160, 230)
        else:
            text, color = "CLEAR", (40, 160, 40)
        cv2.rectangle(img, (0, 0), (639, 60), color, -1)
        cv2.putText(img, text, (14, 44), cv2.FONT_HERSHEY_SIMPLEX, 1.3, (255, 255, 255), 3, cv2.LINE_AA)
        if frame is None or now - last_video >= 3:
            cv2.putText(img, "no video (ESP streams only while tracking)", (110, 260),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (200, 200, 200), 1, cv2.LINE_AA)
        info = (f"video {fps:4.1f} fps   esp {status.get('fps', 0)} fps   size {status.get('size', 0)}   "
                f"yaw {status.get('yaw_dps', 0)} deg/s   imu {status.get('imu', 0)}")
        cv2.putText(img, info, (10, 470), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1, cv2.LINE_AA)
        cv2.imshow("Omni Glasses rear camera (UDP 4300)", img)
        if cv2.waitKey(1) & 0xFF in (ord("q"), 27):
            break
    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
