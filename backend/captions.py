"""Live captions relay: the app streams microphone audio here, and this server relays it
to Meta's Muse Voice Transcribe (wss://api.meta.ai/v1/asr/realtime), holding the Model
API key so it never ships in the app. Transcripts come back the same way. Nothing is
stored: audio and text pass through memory only, and nothing is logged.

    WS /ws/captions        one captions session per socket

Relay protocol (app <-> this server). It stays close to Meta's own, so the app handles
Meta's events as documented (dev.meta.ai/docs/speech-to-text):

  1. app -> relay, first frame, JSON text, within 10 s:
       {"type": "start", "audioEncoding": "PCM_16KHZ" | "PCM_24KHZ",
        "mode": "DIARIZATION" | "ENDPOINTING",            (default DIARIZATION)
        "languageBias": ["English", ...],                    (optional, language names)
        "keywords": ["Maya", "eigenvalue", ...]}             (optional, vocabulary biasing)
  2. relay -> app: {"type": "ready", "sessionId": "...", "source": "meta" | "mock" | "wav"}
  3. app -> relay: binary frames of raw PCM, signed 16-bit little-endian mono, at the
     chosen rate, paced at about real time (Meta allows at most 5 s ahead).
  4. relay -> app: Meta's events unchanged, as JSON text: speechStart {turnId},
     transcript {transcript, final} (cumulative: replaces the open turn's partial),
     speaker {label} (DIARIZATION: labels the audio since the previous speechStart or
     speaker event), speechEnd {turnId}, speechComplete {turnId, transcript} (the
     turn's final text), audioProgress, error {message}. All carry audioProcessedMs.
  5. app -> relay: {"type": "endStream"} ends the session; the relay keeps sending
     until Meta closes, then closes with 1000.

Close codes: Meta's are passed through (1000 done, 1008 bad request or audio pacing,
1011 server failure or "Max session duration reached" after 60 min, 1013 rate
limited). The relay's own: 4400 bad start message, 4429 too many sessions here,
4503 captions not set up (no key). An {"type": "error"} message comes first.

Meta has no "continuous" mode: the modes are PUSH_TO_TALK (one turn, the default),
ENDPOINTING (the model finds each utterance) and DIARIZATION (ENDPOINTING's turns plus
speaker labels). Captions use DIARIZATION, or ENDPOINTING when speaker labels are off.

Run on its own, against Meta (key: MUSE_API_KEY / MODEL_API_KEY in .env), or as a
mock that needs no key or network:

    python -m backend.captions --port 8030
    python -m backend.captions --port 8030 --mock            canned turns, two speakers
    python -m backend.captions --port 8030 --wav talk.wav    real Meta captions of a WAV
                                                             file instead of the mic
"""

import argparse
import asyncio
import json
import ssl
import time
import wave

from fastapi import APIRouter, FastAPI, WebSocket, WebSocketDisconnect

from backend.helper import env


def load_key():
    """The Meta Model API key (the same one Muse Spark uses), from the environment or .env."""
    return env("MUSE_API_KEY") or env("MODEL_API_KEY")

META_URL = "wss://api.meta.ai/v1/asr/realtime"
MODEL = "muse-voice-transcribe-1.0"
ENCODINGS = {"PCM_16KHZ": 16000, "PCM_24KHZ": 24000}
MODES = ("DIARIZATION", "ENDPOINTING")
EVENTS = ("speechStart", "transcript", "speaker", "speechEnd", "speechComplete", "audioProgress", "error")
MAX_KEYWORDS, MAX_KEYWORD_CHARS, MAX_LANGUAGES = 200, 60, 5
MAX_SESSIONS = 4
START_TIMEOUT_S = 10

CLOSE_BAD_START = 4400
CLOSE_BUSY = 4429
CLOSE_NOT_SET_UP = 4503


class StartError(ValueError):
    """The app's start message isn't usable. str() is safe to show."""


def parse_start(msg):
    """The app's start message -> Meta's handshake settings (everything but the key)."""
    if not isinstance(msg, dict) or msg.get("type") != "start":
        raise StartError("the first message must be {\"type\": \"start\", ...}")
    encoding = msg.get("audioEncoding", "PCM_16KHZ")
    if encoding not in ENCODINGS:
        raise StartError(f"audioEncoding must be one of {sorted(ENCODINGS)}")
    mode = msg.get("mode", "DIARIZATION")
    if mode not in MODES:
        raise StartError(f"mode must be one of {list(MODES)}")
    settings = {"audioEncoding": encoding, "model": MODEL, "mode": mode, "partialMode": "CUMULATIVE",
                "emitAudioProgress": True}
    for field, limit, chars in (("keywords", MAX_KEYWORDS, MAX_KEYWORD_CHARS), ("languageBias", MAX_LANGUAGES, 40)):
        values = msg.get(field)
        if values is None:
            continue
        if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
            raise StartError(f"{field} must be a list of strings")
        values = list(dict.fromkeys(v.strip()[:chars] for v in values if v.strip()))[:limit]
        if values:
            settings[field] = values
    return settings


def _tls():
    """python.org's macOS Python has no CA certificates; use certifi's when it's installed."""
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


class UpstreamClosed(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code, self.message = code, message


class MetaUpstream:
    """One Muse Voice Transcribe session."""

    source = "meta"

    def __init__(self, key, url=META_URL):
        self.key, self.url = key, url
        self.ws = None
        self.close_code, self.close_reason = 1000, ""

    async def open(self, settings):
        from websockets.asyncio.client import connect  # websockets ships with uvicorn[standard]
        from websockets.exceptions import ConnectionClosed

        try:
            self.ws = await connect(self.url, ssl=_tls(), open_timeout=10, max_size=2**20)
            await self.ws.send(json.dumps({"authorization": {"accessToken": f"Bearer {self.key}"}, **settings}))
            ack = json.loads(await asyncio.wait_for(self.ws.recv(), 10))
        except ConnectionClosed as e:
            raise UpstreamClosed(e.rcvd.code if e.rcvd else 1011, (e.rcvd.reason if e.rcvd else "") or
                                 "Meta closed the connection") from e
        except (OSError, asyncio.TimeoutError, ValueError) as e:
            raise UpstreamClosed(1011, "Couldn't reach Meta's transcription service") from e
        if not isinstance(ack, dict) or "sessionId" not in ack:
            message = ack.get("message") if isinstance(ack, dict) else None
            raise UpstreamClosed(1008, message or "Meta refused the session")
        return ack["sessionId"]

    async def send_audio(self, pcm):
        await self.ws.send(pcm)

    async def end(self):
        await self.ws.send(json.dumps({"type": "endStream"}))

    async def events(self):
        from websockets.exceptions import ConnectionClosed

        try:
            async for message in self.ws:
                if isinstance(message, str):
                    yield json.loads(message)
        except ConnectionClosed:
            pass
        finally:
            self.close_code = self.ws.close_code or 1000
            self.close_reason = self.ws.close_reason or ""

    async def close(self):
        if self.ws is not None:
            await self.ws.close()


class WavUpstream(MetaUpstream):
    """Real Meta captions of a WAV file, played in real time instead of the app's mic
    (which is ignored), then silence. For building and measuring without talking."""

    source = "wav"

    def __init__(self, key, path, url=META_URL):
        super().__init__(key, url)
        with wave.open(path, "rb") as w:
            if w.getnchannels() != 1 or w.getsampwidth() != 2 or w.getframerate() not in ENCODINGS.values():
                raise ValueError("the WAV must be mono 16-bit PCM at 16 or 24 kHz")
            self.rate, self.pcm = w.getframerate(), w.readframes(w.getnframes())
        self._player = None

    async def open(self, settings):
        settings = {**settings, "audioEncoding": "PCM_16KHZ" if self.rate == 16000 else "PCM_24KHZ"}
        session = await super().open(settings)
        self._player = asyncio.create_task(self._play())
        return session

    async def _play(self):
        chunk = self.rate * 2 // 10                     # 100 ms
        start = time.monotonic()
        position = 0
        silence = bytes(chunk)
        while True:
            data = self.pcm[position:position + chunk] or silence
            position += chunk
            await self.ws.send(data)
            sent_s = position / (self.rate * 2)
            await asyncio.sleep(max(0.0, start + sent_s - time.monotonic()))

    async def send_audio(self, pcm):
        pass                                            # the file stands in for the mic

    async def end(self):
        if self._player:
            self._player.cancel()
        await super().end()


# Canned turns for the mock: (speaker label, words). Plain sentences, two speakers.
MOCK_TURNS = [
    ("A", "Hey, are you coming to the study group later?"),
    ("B", "Yes, after my lecture. It ends at three."),
    ("A", "Great. We're in room 204, next to the library."),
    ("B", "Can you save me a seat by the window?"),
]


class CannedUpstream:
    """No key, no network: scripted partial and final turns with speaker labels, timed
    like real speech (a word every 250 ms). The app's audio is ignored."""

    source = "mock"

    def __init__(self, turns=MOCK_TURNS, word_s=0.25, gap_s=1.2):
        self.turns, self.word_s, self.gap_s = turns, word_s, gap_s
        self.close_code, self.close_reason = 1000, ""
        self._ended = asyncio.Event()
        self._t0 = None

    def _ms(self):
        return int((time.monotonic() - self._t0) * 1000)

    async def open(self, settings):
        self._t0 = time.monotonic()
        self.speakers = settings.get("mode") == "DIARIZATION"
        return f"mock-{int(time.time())}"

    async def send_audio(self, pcm):
        pass

    async def end(self):
        self._ended.set()

    async def _wait(self, s):
        try:
            await asyncio.wait_for(self._ended.wait(), s)
        except asyncio.TimeoutError:
            pass
        return self._ended.is_set()

    async def events(self):
        turn_id = 0
        while True:
            for label, text in self.turns:
                if await self._wait(self.gap_s):
                    return
                turn_id += 1
                yield {"type": "speechStart", "turnId": turn_id, "audioProcessedMs": self._ms()}
                words = text.split()
                for i in range(1, len(words) + 1):
                    if await self._wait(self.word_s):
                        return
                    yield {"type": "transcript", "transcript": " ".join(words[:i]).rstrip(".,?!").lower(),
                           "final": False, "audioProcessedMs": self._ms()}
                if self.speakers:
                    yield {"type": "speaker", "label": label, "audioProcessedMs": self._ms()}
                yield {"type": "speechEnd", "turnId": turn_id, "audioProcessedMs": self._ms()}
                if await self._wait(0.3):
                    return
                yield {"type": "speechComplete", "turnId": turn_id, "transcript": text, "audioProcessedMs": self._ms()}

    async def close(self):
        self._ended.set()


def meta_upstream():
    key = load_key()
    return MetaUpstream(key) if key else None


def router(make_upstream=meta_upstream):
    r = APIRouter()
    sessions = {"open": 0}

    async def refuse(ws, code, message):
        await ws.send_json({"type": "error", "message": message})
        await ws.close(code=code)

    @r.websocket("/ws/captions")
    async def captions(ws: WebSocket):
        await ws.accept()
        try:
            settings = parse_start(json.loads(await asyncio.wait_for(ws.receive_text(), START_TIMEOUT_S)))
        except (StartError, ValueError) as e:
            await refuse(ws, CLOSE_BAD_START, str(e) if isinstance(e, StartError) else "bad start message")
            return
        except (asyncio.TimeoutError, WebSocketDisconnect, KeyError):
            await ws.close(code=CLOSE_BAD_START)
            return
        if sessions["open"] >= MAX_SESSIONS:
            await refuse(ws, CLOSE_BUSY, "Too many captions sessions on this server")
            return
        upstream = make_upstream()
        if upstream is None:
            await refuse(ws, CLOSE_NOT_SET_UP, "Captions aren't set up on this server (no Meta API key)")
            return
        sessions["open"] += 1
        try:
            try:
                session = await upstream.open(settings)
            except UpstreamClosed as e:
                await refuse(ws, e.code, e.message)
                return
            await ws.send_json({"type": "ready", "sessionId": session, "source": upstream.source})
            await _pump(ws, upstream)
        finally:
            sessions["open"] -= 1
            await upstream.close()

    return r


async def _pump(ws, upstream):
    """Audio up, events down, until either side is done."""
    ended = asyncio.Event()

    async def up():
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                return "gone"
            if msg.get("bytes"):
                if not ended.is_set():
                    await upstream.send_audio(msg["bytes"])
            elif msg.get("text"):
                try:
                    command = json.loads(msg["text"])
                except ValueError:
                    continue
                if isinstance(command, dict) and command.get("type") == "endStream" and not ended.is_set():
                    ended.set()
                    await upstream.end()

    async def down():
        async for event in upstream.events():
            if isinstance(event, dict) and event.get("type") in EVENTS:
                await ws.send_json(event)

    # up() only returns when the app has gone; after endStream it keeps reading (and
    # ignoring audio) while down() relays Meta's last events.
    up_task, down_task = asyncio.create_task(up()), asyncio.create_task(down())
    try:
        done, _ = await asyncio.wait({up_task, down_task}, return_when=asyncio.FIRST_COMPLETED)
        if down_task not in done:
            return                                 # the app left: drop the session
        down_task.result()
    except (WebSocketDisconnect, RuntimeError):
        return
    finally:
        for task in (up_task, down_task):
            task.cancel()
    code = upstream.close_code or 1000
    try:
        if code != 1000:
            await ws.send_json({"type": "error", "message": upstream.close_reason or "Transcription stopped",
                                "code": code})
        await ws.close(code=code if code in (1000, 1008, 1011, 1013) else 1011)
    except (RuntimeError, WebSocketDisconnect):
        pass


def create_app(make_upstream=meta_upstream):
    app = FastAPI(title="Omni captions relay")
    app.include_router(router(make_upstream))
    return app


def main():
    ap = argparse.ArgumentParser(description="Live captions relay (Muse Voice Transcribe)")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8030)
    ap.add_argument("--mock", action="store_true", help="canned captions: no key, no network")
    ap.add_argument("--wav", help="caption this WAV file (mono 16-bit, 16 or 24 kHz) instead of the mic")
    args = ap.parse_args()
    import uvicorn

    if args.mock:
        make = CannedUpstream
    elif args.wav:
        key = load_key()
        if not key:
            raise SystemExit("--wav needs MUSE_API_KEY in .env")
        WavUpstream(key, args.wav)  # check the file now, not on the first connection
        make = lambda: WavUpstream(key, args.wav)  # noqa: E731
    else:
        make = meta_upstream
        if load_key() is None:
            print("No MUSE_API_KEY: every session will be refused (try --mock)")
    source = "mock" if args.mock else f"WAV {args.wav}" if args.wav else "Meta"
    print(f"Captions relay ({source}) on ws://localhost:{args.port}/ws/captions")
    # No access log, and audio and text are never logged.
    uvicorn.run(create_app(make), host=args.host, port=args.port, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
