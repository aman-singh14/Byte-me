"""The Omni Glasses cloud server: everything the phone needs that isn't next to the
glasses, at one HTTPS address, so the app works on any network with no laptop.

    Together        /v1/..., /t/{id}, /healthz                       social/app.py
    Call a helper   /rooms, /h/{room}, /ws/wearer/{room}, /ws/helper/{room}, /livekit-token
                                                                     backend/helper.py
    Captions        WS /ws/captions                                  backend/captions.py
    Muse            POST /vlm/{feature}                              backend/vlm.py
    Camera relay    WS /relay/{key}/push/{role}, /relay/{key}/{role}/stream   cloud/relay.py

The laptop backend (backend/main.py) still does everything that needs the glasses'
cameras: eye tracking, near-work, rings, rear events, "Ask".

Keys come from the environment (on Fly: fly secrets set) and never go in the app:
MUSE_API_KEY, and optionally LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, and
RELAY_KEY for cameras on another network (off without it).

Anyone who finds the address can use it (the app has no passwords), so whatever
costs money is capped: Muse by muse.* in backend/config.yaml ($5 a day, $10 in all,
6 calls a minute, counted in DATA_DIR/muse.db, separately from the laptop's), and
captions by CAPTIONS_DAILY_MINUTES (default 120, about $0.36 a day) and 4 sessions
at once.

    uvicorn cloud.app:create_app --factory --port 8080       (DATA_DIR, default ./data)
"""

import os
import time
from pathlib import Path

from fastapi import HTTPException
from pydantic import BaseModel

from backend import captions, helper
from backend.config import load_config
from backend.db import DB as BackendDB
from backend.muse_client import MuseClient, MuseUnavailable
from backend.vlm import VlmError, VlmService
from cloud import relay
from social.app import create_app as social_app

LIMIT_REACHED = "Captions have used up today's time on this server. They work again tomorrow."


class CaptionMeter:
    """Captions audio seconds per UTC day. In memory: a restart starts the count over."""

    def __init__(self, daily_minutes, clock=time.time):
        self.limit_s = daily_minutes * 60
        self.clock = clock
        self.day, self.used_s = None, 0.0

    def left_s(self):
        day = int(self.clock() // 86400)
        if day != self.day:
            self.day, self.used_s = day, 0.0
        return self.limit_s - self.used_s

    def add(self, seconds):
        self.left_s()
        self.used_s += seconds


class MeteredUpstream:
    """A captions upstream that counts audio and ends the session when the day's time runs out."""

    def __init__(self, inner, meter):
        self.inner, self.meter = inner, meter
        self.bytes_per_s = captions.ENCODINGS["PCM_16KHZ"] * 2
        self.over = self.ended = False

    def __getattr__(self, name):  # source, events, close
        return getattr(self.inner, name)

    @property
    def close_code(self):
        return 1013 if self.over else self.inner.close_code

    @property
    def close_reason(self):
        return LIMIT_REACHED if self.over else self.inner.close_reason

    async def open(self, settings):
        if self.meter.left_s() <= 0:
            raise captions.UpstreamClosed(1013, LIMIT_REACHED)
        self.bytes_per_s = captions.ENCODINGS[settings["audioEncoding"]] * 2
        return await self.inner.open(settings)

    async def send_audio(self, pcm):
        if self.ended:
            return
        self.meter.add(len(pcm) / self.bytes_per_s)
        await self.inner.send_audio(pcm)
        if self.meter.left_s() <= 0:
            self.over = True
            await self.end()        # Meta sends the open turn's final text, then closes

    async def end(self):
        if not self.ended:
            self.ended = True
            await self.inner.end()


class VlmImage(BaseModel):
    camera: str
    jpeg: str


class VlmRequest(BaseModel):
    images: list[VlmImage] = []
    question: str | None = None


def create_app(data_dir=None, make_upstream=captions.meta_upstream, muse=None, relay_key=None):
    data = Path(data_dir or os.environ.get("DATA_DIR", "data"))
    data.mkdir(parents=True, exist_ok=True)
    app = social_app(str(data / "social.db"))
    app.title = "Omni Glasses"

    app.include_router(helper.router(helper.Rooms()))

    meter = CaptionMeter(float(os.environ.get("CAPTIONS_DAILY_MINUTES", "120")))

    def metered():
        inner = make_upstream()
        return MeteredUpstream(inner, meter) if inner else None

    app.include_router(captions.router(metered))
    app.include_router(relay.router(relay.Frames(), relay_key))

    # No front camera up here: the app sends the images it has.
    vlm = VlmService(muse or MuseClient(load_config(), BackendDB(str(data / "muse.db"))))

    @app.post("/vlm/{feature}")
    def run_vlm(feature: str, body: VlmRequest | None = None):
        try:
            body = body or VlmRequest()
            return vlm.run(feature, [(i.camera, i.jpeg) for i in body.images], question=body.question)
        except VlmError as e:
            raise HTTPException(400, str(e)) from e
        except MuseUnavailable as e:
            raise HTTPException(503, str(e)) from e

    @app.get("/")
    def home():
        return {"service": "Omni Glasses", "ok": True,
                "captions_minutes_left_today": round(max(meter.left_s(), 0) / 60, 1)}

    return app
