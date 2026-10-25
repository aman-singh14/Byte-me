"""Cameras on another network: the eye and front boards on stock firmware (CameraWebServer,
MJPEG at http://<board>:81/stream) joined some other Wi-Fi, so the phone on its hotspot
can't reach them. A laptop on that Wi-Fi reads their streams (tools/cam_relay.py) and
pushes the frames here; the app pulls them back as MJPEG, the same as from a board.

    WS  /relay/{key}/push/{role}      the laptop: one binary message per JPEG, and text (JSON) for
                                      its readings (distance ahead: left_cm, center_cm, right_cm)
    GET /relay/{key}/{role}/stream    the app: MJPEG, newest frame only
    GET /relay/{key}/{role}/capture   the app: the newest frame (Ask)
    GET /relay/{key}/{role}/sensor    the app: the newest readings
    GET /relay/{key}                  seconds since each camera's last frame

role is "eye" or "front". Every path needs RELAY_KEY (on Fly: fly secrets set RELAY_KEY=...);
without it the relay is off. Only the newest frame per camera is held, in memory, and
each one replaces the last: nothing is written anywhere.
"""

import asyncio
import hmac
import json
import os
import time

from fastapi import APIRouter, HTTPException, WebSocket
from fastapi.responses import Response, StreamingResponse

ROLES = ("eye", "front")
MAX_FRAME = 512 * 1024
STALE_S = 3.0


class Frames:
    """The newest JPEG per camera, and a way to wait for the next one."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.latest = {}  # role -> (t, jpeg)
        self.readings = {}  # role -> (t, dict)
        self._new = {}  # role -> asyncio.Event set by the next frame

    def put(self, role, jpeg):
        self.latest[role] = (self.clock(), jpeg)
        event = self._new.pop(role, None)
        if event:
            event.set()

    def put_sensor(self, role, reading):
        self.readings[role] = (self.clock(), reading)

    def sensor(self, role):
        t, reading = self.readings.get(role, (None, None))
        return reading if t is not None and self.clock() - t <= STALE_S else None

    def fresh(self, role):
        t, jpeg = self.latest.get(role, (None, None))
        return jpeg if t is not None and self.clock() - t <= STALE_S else None

    async def next(self, role, timeout):
        event = self._new.setdefault(role, asyncio.Event())
        try:
            await asyncio.wait_for(event.wait(), timeout)
        except asyncio.TimeoutError:
            return None
        return self.latest[role][1]


def router(frames, key=None):
    key = key if key is not None else os.environ.get("RELAY_KEY", "")
    r = APIRouter()

    def allowed(k, role=None):
        return bool(key) and hmac.compare_digest(k.encode(), key.encode()) and role in (None, *ROLES)

    def check(k, role=None):
        if not allowed(k, role):
            raise HTTPException(404, "No such camera relay.")

    @r.websocket("/relay/{k}/push/{role}")
    async def push(ws: WebSocket, k: str, role: str):
        if not allowed(k, role):
            await ws.close(code=1008)
            return
        await ws.accept()
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                return
            jpeg, text = msg.get("bytes"), msg.get("text")
            if jpeg and len(jpeg) <= MAX_FRAME and jpeg[:2] == b"\xff\xd8":
                frames.put(role, jpeg)
            elif text and len(text) <= 4096:
                try:
                    reading = json.loads(text)
                except ValueError:
                    continue
                if isinstance(reading, dict):
                    frames.put_sensor(role, reading)

    @r.get("/relay/{k}/{role}/stream")
    async def stream(k: str, role: str):
        check(k, role)

        async def parts():
            jpeg = frames.fresh(role)
            while True:
                if jpeg is not None:
                    yield (b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(jpeg)
                           + jpeg + b"\r\n")
                jpeg = await frames.next(role, timeout=10)

        return StreamingResponse(parts(), media_type="multipart/x-mixed-replace; boundary=frame",
                                 headers={"Cache-Control": "no-store"})

    @r.get("/relay/{k}/{role}/capture")
    def capture(k: str, role: str):
        check(k, role)
        jpeg = frames.fresh(role)
        if jpeg is None:
            raise HTTPException(503, f"No {role} camera frames are arriving.")
        return Response(jpeg, media_type="image/jpeg", headers={"Cache-Control": "no-store"})

    @r.get("/relay/{k}/{role}/sensor")
    def sensor(k: str, role: str):
        check(k, role)
        reading = frames.sensor(role)
        if reading is None:
            raise HTTPException(503, f"No {role} camera readings are arriving.")
        return reading

    @r.get("/relay/{k}")
    def status(k: str):
        check(k)
        now = frames.clock()
        return {role: round(now - frames.latest[role][0], 1) if role in frames.latest else None for role in ROLES}

    return r
