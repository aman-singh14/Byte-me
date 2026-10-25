"""Captions relay (backend/captions.py): start-message checks, the relay protocol with
the mock upstream, errors and close codes. Never touches Meta.

    PYTHONPATH=. social/.venv/bin/python -m unittest -v backend.test_captions
"""

import unittest

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from backend import captions


class FastCanned(captions.CannedUpstream):
    def __init__(self):
        super().__init__(turns=[("A", "Hello there."), ("B", "Hi, how are you?")], word_s=0.01, gap_s=0.01)


class Failing:
    source = "meta"

    async def open(self, settings):
        raise captions.UpstreamClosed(1013, "rate limited")

    async def close(self):
        pass


class Recording(captions.CannedUpstream):
    """Records the audio and settings it was given."""
    last = None

    def __init__(self):
        super().__init__(turns=[], word_s=0.01, gap_s=0.01)
        self.audio, self.settings = [], None
        Recording.last = self

    async def open(self, settings):
        self.settings = settings
        return await super().open(settings)

    async def send_audio(self, pcm):
        self.audio.append(pcm)

    async def events(self):
        await self._ended.wait()
        if False:
            yield {}


def client(make):
    return TestClient(captions.create_app(make))


class StartTest(unittest.TestCase):
    def test_settings_are_whitelisted_and_trimmed(self):
        s = captions.parse_start({"type": "start", "keywords": ["Maya", " Maya ", "", "x" * 99],
                                  "languageBias": ["English"], "authorization": "nope", "model": "other"})
        self.assertEqual(s["model"], captions.MODEL)
        self.assertEqual(s["mode"], "DIARIZATION")
        self.assertEqual((s["audioEncoding"], s["partialMode"]), ("PCM_16KHZ", "CUMULATIVE"))
        self.assertEqual(s["keywords"], ["Maya", "x" * captions.MAX_KEYWORD_CHARS])
        self.assertEqual(s["languageBias"], ["English"])
        self.assertNotIn("authorization", s)

    def test_bad_start_messages(self):
        for bad in ({"type": "go"}, {"type": "start", "mode": "PUSH_TO_TALK"},
                    {"type": "start", "audioEncoding": "MP3"}, {"type": "start", "keywords": "Maya"}, []):
            with self.assertRaises(captions.StartError):
                captions.parse_start(bad)


class RelayTest(unittest.TestCase):
    def test_mock_turns_partial_then_final_with_speakers(self):
        with client(FastCanned).websocket_connect("/ws/captions") as ws:
            ws.send_json({"type": "start", "audioEncoding": "PCM_16KHZ"})
            ready = ws.receive_json()
            self.assertEqual((ready["type"], ready["source"]), ("ready", "mock"))
            events = [ws.receive_json() for _ in range(12)]
            kinds = [e["type"] for e in events]
            self.assertEqual(kinds[:4], ["speechStart", "transcript", "transcript", "speaker"])
            self.assertEqual(events[2]["transcript"], "hello there")    # cumulative partial
            self.assertEqual(events[3]["label"], "A")
            complete = next(e for e in events if e["type"] == "speechComplete")
            self.assertEqual((complete["turnId"], complete["transcript"]), (1, "Hello there."))
            ws.send_json({"type": "endStream"})
            with self.assertRaises(WebSocketDisconnect) as closed:
                while True:
                    ws.receive_json()
            self.assertEqual(closed.exception.code, 1000)

    def test_audio_goes_up_and_endstream_finishes(self):
        with client(Recording).websocket_connect("/ws/captions") as ws:
            ws.send_json({"type": "start", "mode": "ENDPOINTING", "keywords": ["Maya"]})
            ws.receive_json()
            ws.send_bytes(b"\x00\x01" * 800)
            ws.send_bytes(b"\x02\x03" * 800)
            ws.send_json({"type": "endStream"})
            with self.assertRaises(WebSocketDisconnect):
                ws.receive_json()
        self.assertEqual(Recording.last.audio, [b"\x00\x01" * 800, b"\x02\x03" * 800])
        self.assertEqual(Recording.last.settings["mode"], "ENDPOINTING")
        self.assertEqual(Recording.last.settings["keywords"], ["Maya"])

    def assert_refused(self, make, start, code, text):
        with client(make).websocket_connect("/ws/captions") as ws:
            ws.send_json(start)
            error = ws.receive_json()
            self.assertEqual(error["type"], "error")
            self.assertIn(text, error["message"])
            with self.assertRaises(WebSocketDisconnect) as closed:
                ws.receive_json()
            self.assertEqual(closed.exception.code, code)

    def test_refusals(self):
        self.assert_refused(FastCanned, {"type": "start", "mode": "PUSH_TO_TALK"}, captions.CLOSE_BAD_START, "mode")
        self.assert_refused(lambda: None, {"type": "start"}, captions.CLOSE_NOT_SET_UP, "no Meta API key")
        self.assert_refused(Failing, {"type": "start"}, 1013, "rate limited")


if __name__ == "__main__":
    unittest.main()
