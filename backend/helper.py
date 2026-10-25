"""Call a helper: a remote helper (friend, family, guide) sees through the
glasses' front or rear camera and guides the wearer with haptic arrows.

The wearer's app opens a room and shares a link. Video goes app -> server ->
helper browser over WebSockets as the glasses' original JPEGs; the server keeps
only the newest frame per helper and drops older ones if the helper is behind,
so delay never builds up. Helper commands go back the same way. Frames live in
memory only: never written to disk, never logged.

    POST /rooms                        -> room id, wearer token, helper link (30 min)
    GET  /h/{room}?t=<helper token>    the helper page
    WS   /ws/wearer/{room}?t=          app:    binary frames + JSON events up, commands down
    WS   /ws/helper/{room}?t=          helper: newest frame + events down, commands up
    GET  /livekit-token?room=&t=       a LiveKit token for two-way call audio (either side's token)

Audio goes through LiveKit Cloud, not this server: each side asks for a token here
(our room token proves it belongs to the room) and joins the LiveKit room
"omni-<room id>". Keys come from LIVEKIT_URL, LIVEKIT_API_KEY and LIVEKIT_API_SECRET
in the environment or the repo's .env. Without them calls work with video and
buzzes only. LiveKit doesn't record unless asked to, and we never ask.

Wearer -> server, binary: 1 byte camera ('F' front, 'R' rear, 'P' the phone's own camera
while no glasses camera is connected) + 8-byte big-endian
timestamp (ms since epoch) + the JPEG, forwarded byte for byte. The server
answers each frame with {"t":"ack"} so the app keeps at most a couple of frames
in flight. JSON: {"t":"alert",...}, {"t":"tap",...}, {"t":"status",...},
{"t":"end"} (ends the room).

Helper -> wearer: {"t":"guide","dir":"L"|"R"|"fwd"|"stop"}, {"t":"cam","which":"F"|"R"},
{"t":"end"} (asks the wearer's app to end the call).
Server -> wearer: {"t":"helper","on":true|false} when the helper joins or leaves.
Server -> helper: {"t":"wearer","on":true|false}, {"t":"ended"}.

Run on its own (no cameras or models needed), behind an HTTPS tunnel for a helper
on another network:

    python -m backend.helper --port 8020
"""

import asyncio
import collections
import datetime
import json
import os
import secrets
import time
from pathlib import Path

from fastapi import APIRouter, FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

ROOM_TTL_S = 30 * 60
MAX_FRAME_BYTES = 1024 * 1024
HEADER_BYTES = 9  # camera id + timestamp
CAMERAS = (b"F", b"R", b"P")  # glasses front, glasses rear, the phone's own camera (no glasses)
GUIDE_DIRS = ("L", "R", "fwd", "stop")

# WebSocket close codes (4000-4999 are ours).
CLOSE_BAD_TOKEN = 4401
CLOSE_TAKEN = 4409
CLOSE_ENDED = 4410

PAGE = Path(__file__).resolve().parent / "static" / "helper.html"
ENV_FILE = Path(__file__).resolve().parent.parent / ".env"


def env(name, env_file=None):
    """A setting from the environment, else from the repo's .env (gitignored)."""
    if os.environ.get(name):
        return os.environ[name]
    try:
        for line in Path(env_file or ENV_FILE).read_text().splitlines():
            key, _, value = line.strip().partition("=")
            if key.strip() == name and value.strip() and not line.lstrip().startswith("#"):
                return value.strip().strip('"').strip("'")
    except OSError:
        pass
    return None


def livekit_token(room, role, now, settings=env):
    """{"url", "token", "identity"} for [role] in [room]'s audio, or None if LiveKit isn't set up."""
    url, key, secret = (settings(n) for n in ("LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET"))
    if not (url and key and secret):
        return None
    from livekit import api  # optional: only needed for audio
    ttl = max(60, int(room.expires_at - now))
    jwt = (api.AccessToken(key, secret)
           .with_identity(role)
           .with_name("Wearer" if role == "wearer" else "Helper")
           .with_ttl(datetime.timedelta(seconds=ttl))
           .with_grants(api.VideoGrants(room_join=True, room=f"omni-{room.id}", can_publish=True,
                                        can_subscribe=True, can_publish_data=False,
                                        can_publish_sources=["microphone"]))
           .to_jwt())
    return {"url": url, "token": jwt, "identity": role}


def _message_page(title, text, status=200):
    """A small readable page, for people who open a wrong link in a browser."""
    return HTMLResponse(
        f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{title}</title>
<style>body{{margin:0;font:18px/1.5 system-ui,sans-serif;background:#FFFBF5;color:#1C1B1F}}
main{{max-width:560px;margin:15vh auto;padding:0 16px}}h1{{font-size:28px}}
@media (prefers-color-scheme:dark){{body{{background:#121214;color:#F4F2EE}}}}</style></head>
<body><main><h1>{title}</h1><p>{text}</p></main></body></html>""",
        status_code=status,
    )


class Outbox:
    """What one socket still has to send: queued events (small, never dropped)
    and at most one frame, the newest. A new frame replaces an unsent one, so
    a slow helper sees fresh video instead of an ever longer delay."""

    def __init__(self, max_events=100):
        self.events = collections.deque(maxlen=max_events)
        self.frame = None
        self.dropped = 0  # frames replaced before they were sent
        self.closed = False
        self._ready = asyncio.Event()
        self._loop = None  # the loop waiting in next()

    def put_frame(self, frame):
        if self.closed:
            return
        if self.frame is not None:
            self.dropped += 1
        self.frame = frame
        self._wake()

    def put_event(self, event):
        if self.closed:
            return
        self.events.append(event)
        self._wake()

    def close(self):
        self.closed = True
        self._wake()

    def _wake(self):
        # The sockets of one room can be served on different event loops (the
        # test client runs one per socket); wake the reader on its own loop.
        loop = self._loop
        try:
            same = loop is None or loop is asyncio.get_running_loop()
        except RuntimeError:
            same = False
        if same:
            self._ready.set()
        else:
            loop.call_soon_threadsafe(self._ready.set)

    async def next(self):
        """The next thing to send: an event dict, or frame bytes. Events go
        first. Returns None once closed."""
        while True:
            if self.events:
                return self.events.popleft()
            if self.frame is not None:
                frame, self.frame = self.frame, None
                return frame
            if self.closed:
                return None
            self._loop = asyncio.get_running_loop()
            self._ready.clear()
            await self._ready.wait()


class Room:
    def __init__(self, now, wearer_name=None):
        self.wearer_name = wearer_name
        self.id = secrets.token_hex(16)  # 128 bits
        self.wearer_token = secrets.token_urlsafe(16)
        self.helper_token = secrets.token_urlsafe(16)
        self.expires_at = now + ROOM_TTL_S
        self.ended = False
        self.wearer = None  # Outbox while the wearer's app is connected
        self.helper = None  # Outbox while a helper is connected (one at a time)

    def alive(self, now):
        return not self.ended and now < self.expires_at

    def token_ok(self, role, token):
        expected = self.wearer_token if role == "wearer" else self.helper_token
        return bool(token) and secrets.compare_digest(token, expected)

    def end(self):
        if self.ended:
            return
        self.ended = True
        if self.helper:
            self.helper.put_event({"t": "ended"})
            self.helper.close()
        if self.wearer:
            self.wearer.close()


class Rooms:
    def __init__(self, clock=time.time):
        self.clock = clock
        self._rooms = {}

    def create(self, wearer_name=None):
        self.sweep()
        room = Room(self.clock(), wearer_name)
        self._rooms[room.id] = room
        return room

    def get(self, room_id):
        room = self._rooms.get(room_id)
        if room is None or not room.alive(self.clock()):
            return None
        return room

    def sweep(self):
        now = self.clock()
        for room_id, room in list(self._rooms.items()):
            if not room.alive(now):
                room.end()
                del self._rooms[room_id]


def valid_frame(data):
    return (HEADER_BYTES + 2 <= len(data) <= MAX_FRAME_BYTES and data[:1] in CAMERAS
            and data[HEADER_BYTES:HEADER_BYTES + 2] == b"\xff\xd8")


def command_from_helper(msg):
    """The helper's command to pass on to the wearer, cleaned up, or None."""
    t = msg.get("t") if isinstance(msg, dict) else None
    if t == "guide" and msg.get("dir") in GUIDE_DIRS:
        return {"t": "guide", "dir": msg["dir"]}
    if t == "cam" and msg.get("which") in ("F", "R"):
        return {"t": "cam", "which": msg["which"]}
    if t == "end":
        return {"t": "end"}
    return None


def event_from_wearer(msg):
    """The wearer's event to show the helper, or None. "end" is handled apart."""
    t = msg.get("t") if isinstance(msg, dict) else None
    if t in ("alert", "tap", "status"):
        return msg
    return None


async def _send_loop(ws, outbox):
    while (item := await outbox.next()) is not None:
        if isinstance(item, (bytes, bytearray)):
            await ws.send_bytes(item)
        else:
            await ws.send_text(json.dumps(item))


class RoomRequest(BaseModel):
    wearer_name: str | None = Field(default=None, max_length=80)


def router(rooms):
    r = APIRouter()

    @r.post("/rooms", status_code=201)
    def create_room(request: Request, body: RoomRequest | None = None):
        name = (body.wearer_name or "").strip() if body else ""
        room = rooms.create(name or None)
        base = str(request.base_url).rstrip("/")
        return {
            "room": room.id,
            "wearer_token": room.wearer_token,
            "helper_url": f"{base}/h/{room.id}?t={room.helper_token}",
            "expires_at": room.expires_at,
        }

    @r.get("/room-info/{room_id}")
    def room_info(room_id: str, t: str = ""):
        room = rooms.get(room_id)
        if room is None or not room.token_ok("helper", t):
            return _message_page("This call has ended", "Ask for a new link.", 404)
        return JSONResponse({"wearer_name": room.wearer_name, "expires_at": room.expires_at},
                            headers={"Cache-Control": "no-store"})

    @r.get("/livekit-token")
    def audio_token(room: str = "", t: str = ""):
        found = rooms.get(room)
        role = next((role for role in ("wearer", "helper") if found and found.token_ok(role, t)), None)
        if role is None:
            return JSONResponse({"detail": "This call has ended."}, status_code=404)
        token = livekit_token(found, role, rooms.clock())
        if token is None:
            return JSONResponse({"detail": "Call audio isn't set up on this server."}, status_code=503)
        return JSONResponse(token, headers={"Cache-Control": "no-store"})

    @r.get("/h/{room_id}", response_class=HTMLResponse)
    def helper_page(room_id: str, t: str = ""):
        room = rooms.get(room_id)
        if room is None or not room.token_ok("helper", t):
            return _message_page("This call has ended",
                                 "The call is over or the link is incomplete. Ask for a new link.", 404)
        return HTMLResponse(PAGE.read_text(), headers={"Cache-Control": "no-store",
                                                      "Referrer-Policy": "no-referrer"})

    async def connect(ws, room_id, role, token):
        """Accepts [ws] as [role] in the room, or closes it and returns None."""
        room = rooms.get(room_id)
        if room is None or not room.token_ok(role, token):
            await ws.close(code=CLOSE_BAD_TOKEN)
            return None
        if getattr(room, role) is not None:
            await ws.close(code=CLOSE_TAKEN)  # one helper (and one wearer app) per room
            return None
        await ws.accept()
        return room

    async def run(ws, room, outbox, on_message):
        """Sends from [outbox] while passing what arrives to [on_message], until
        either side closes or the room expires."""
        sender = asyncio.create_task(_send_loop(ws, outbox))
        receive = None
        try:
            while room.alive(rooms.clock()):
                receive = receive or asyncio.ensure_future(ws.receive())
                timeout = max(room.expires_at - rooms.clock(), 0.1)
                done, _ = await asyncio.wait({receive, sender}, timeout=timeout,
                                             return_when=asyncio.FIRST_COMPLETED)
                if sender in done or receive not in done:
                    break  # the room ended (outbox closed) or expired
                msg, receive = receive.result(), None
                if msg["type"] == "websocket.disconnect":
                    break
                await on_message(msg)
                if room.ended:
                    # Drain the final ended/end events before closing the sockets.
                    await asyncio.wait({sender}, timeout=1)
                    break
        except (WebSocketDisconnect, RuntimeError):
            pass
        finally:
            outbox.close()
            sender.cancel()
            if receive is not None:
                receive.cancel()
            if not room.alive(rooms.clock()):
                room.end()
                try:
                    await ws.close(code=CLOSE_ENDED)
                except RuntimeError:
                    pass

    @r.websocket("/ws/wearer/{room_id}")
    async def wearer_socket(ws: WebSocket, room_id: str, t: str = ""):
        room = await connect(ws, room_id, "wearer", t)
        if room is None:
            return
        outbox = room.wearer = Outbox()
        if room.helper:
            outbox.put_event({"t": "helper", "on": True})
            room.helper.put_event({"t": "wearer", "on": True})

        async def on_message(msg):
            if (data := msg.get("bytes")) is not None:
                if valid_frame(data) and room.helper:
                    room.helper.put_frame(data)
                outbox.put_event({"t": "ack"})
            elif (text := msg.get("text")) is not None:
                try:
                    event = json.loads(text)
                except ValueError:
                    return
                if isinstance(event, dict) and event.get("t") == "end":
                    room.end()
                elif (event := event_from_wearer(event)) and room.helper:
                    room.helper.put_event(event)

        try:
            await run(ws, room, outbox, on_message)
        finally:
            if room.wearer is outbox:
                room.wearer = None
                if room.helper and not room.ended:
                    room.helper.put_event({"t": "wearer", "on": False})

    @r.websocket("/ws/helper/{room_id}")
    async def helper_socket(ws: WebSocket, room_id: str, t: str = ""):
        room = await connect(ws, room_id, "helper", t)
        if room is None:
            return
        outbox = room.helper = Outbox()
        outbox.put_event({"t": "wearer", "on": room.wearer is not None})
        if room.wearer:
            room.wearer.put_event({"t": "helper", "on": True})

        async def on_message(msg):
            text = msg.get("text")
            if text is None:
                return
            try:
                command = command_from_helper(json.loads(text))
            except ValueError:
                return
            if command:
                if room.wearer:
                    room.wearer.put_event(command)
                if command["t"] == "end":
                    room.end()

        try:
            await run(ws, room, outbox, on_message)
        finally:
            if room.helper is outbox:
                room.helper = None
                if room.wearer and not room.ended:
                    room.wearer.put_event({"t": "helper", "on": False})

    return r


def create_app(rooms=None):
    app = FastAPI(title="Call a helper", version="1")
    app.include_router(router(rooms or Rooms()))

    @app.get("/", response_class=HTMLResponse)
    def home():
        return _message_page("Call a helper",
                             "The server is running. Start a call in the Omni Glasses app; "
                             "the helper opens the link the app shares (it looks like /h/…).")

    return app


def main():
    import argparse

    import uvicorn

    ap = argparse.ArgumentParser(description="Call a helper: room + video relay server")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8020)
    args = ap.parse_args()
    print(f"Call a helper on http://localhost:{args.port}  (POST /rooms to start)")
    # No access log: URLs carry room tokens. Frames are never logged either.
    uvicorn.run(create_app(), host=args.host, port=args.port, log_level="warning",
                access_log=False, proxy_headers=True, forwarded_allow_ips="*")


if __name__ == "__main__":
    main()
