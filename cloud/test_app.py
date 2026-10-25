"""The cloud server (cloud/app.py): every service answers at one address, and captions
stop at the day's limit. Never touches Meta or LiveKit.

    PYTHONPATH=. .venv/bin/python -m unittest -v cloud.test_app
"""

import base64
import os
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

import cv2
import numpy as np
from fastapi.testclient import TestClient

from backend import captions
from cloud.app import LIMIT_REACHED, CaptionMeter, create_app


class Silent(captions.CannedUpstream):
    """Takes audio, says nothing, finishes when asked to."""

    def __init__(self):
        super().__init__(turns=[], word_s=0.01, gap_s=0.01)

    async def send_audio(self, pcm):
        pass

    async def events(self):
        await self._ended.wait()
        if False:
            yield {}


class FakeMuse:
    context = None

    def ask(self, question, **kw):
        self.context = kw.get("context")
        return SimpleNamespace(text='{"summary": "A desk.", "answer": "A desk."}', latency_s=0.1, model="fake")


def jpeg_b64():
    ok, buf = cv2.imencode(".jpg", np.zeros((8, 8, 3), np.uint8))
    return base64.b64encode(buf.tobytes()).decode()


class CloudTest(unittest.TestCase):
    def client(self, minutes="120"):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.muse = FakeMuse()
        with mock.patch.dict(os.environ, {"CAPTIONS_DAILY_MINUTES": minutes}):
            return TestClient(create_app(tmp.name, make_upstream=Silent, muse=self.muse, relay_key="k3y"))

    def test_together_and_helper_share_the_address(self):
        c = self.client()
        self.assertEqual(c.get("/healthz").status_code, 200)
        self.assertIn("token", c.post("/v1/users", json={"name": "Aman"}).json())
        room = c.post("/rooms", json={}).json()
        self.assertTrue(room["helper_url"].startswith("http://testserver/h/"))
        self.assertEqual(c.get(room["helper_url"]).status_code, 200)

    def test_vlm_answers_from_the_images_sent(self):
        c = self.client()
        r = c.post("/vlm/describe", json={"images": [{"camera": "rear", "jpeg": jpeg_b64()}]})
        self.assertEqual(r.json()["result"]["summary"], "A desk.")
        self.assertEqual(c.post("/vlm/describe", json={"images": []}).status_code, 400)
        r = c.post("/vlm/ask", json={"images": [{"camera": "phone", "jpeg": jpeg_b64()}], "question": "What is this?"})
        self.assertEqual(r.json()["result"]["answer"], "A desk.")
        self.assertIn('The wearer asked: "What is this?"', self.muse.context)

    def test_captions_stop_at_the_daily_limit(self):
        c = self.client(minutes="0.001")                # 0.06 s of 16 kHz audio
        with c.websocket_connect("/ws/captions") as ws:
            ws.send_json({"type": "start", "audioEncoding": "PCM_16KHZ"})
            self.assertEqual(ws.receive_json()["type"], "ready")
            ws.send_bytes(bytes(3200))                  # 0.1 s
            self.assertEqual(ws.receive_json(), {"type": "error", "message": LIMIT_REACHED, "code": 1013})
        with c.websocket_connect("/ws/captions") as ws:
            ws.send_json({"type": "start"})
            self.assertEqual(ws.receive_json()["message"], LIMIT_REACHED)
        self.assertEqual(c.get("/").json()["captions_minutes_left_today"], 0)

    def test_relay_passes_the_newest_camera_frame_with_the_key_only(self):
        c = self.client()
        jpeg = base64.b64decode(jpeg_b64())
        self.assertEqual(c.get("/relay/k3y/eye/capture").status_code, 503)    # nothing pushed yet
        self.assertEqual(c.get("/relay/k3y/front/sensor").status_code, 503)
        with c.websocket_connect("/relay/k3y/push/eye") as ws:
            ws.send_bytes(b"not a jpeg")
            ws.send_bytes(jpeg)
            c.get("/relay/k3y")                                               # let the push land
        with c.websocket_connect("/relay/k3y/push/front") as ws:
            ws.send_text("not json")
            ws.send_text('{"left_cm": 240, "center_cm": 62, "right_cm": 300}')
            c.get("/relay/k3y")
        self.assertEqual(c.get("/relay/k3y/front/sensor").json()["center_cm"], 62)
        self.assertEqual(c.get("/relay/k3y/eye/capture").content, jpeg)
        self.assertEqual(c.get("/relay/k3y").json()["front"], None)
        with c.stream("GET", "/relay/k3y/eye/stream") as r:
            self.assertIn("multipart/x-mixed-replace", r.headers["content-type"])
            first = next(r.iter_bytes())
        self.assertIn(jpeg, first)
        self.assertEqual(c.get("/relay/wrong/eye/capture").status_code, 404)
        self.assertEqual(c.get("/relay/k3y/back/capture").status_code, 404)
        with self.assertRaises(Exception), c.websocket_connect("/relay/wrong/push/eye") as ws:
            ws.receive_bytes()

    def test_relay_is_off_without_a_key(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        with mock.patch.dict(os.environ, {"RELAY_KEY": ""}):
            c = TestClient(create_app(tmp.name, make_upstream=Silent, muse=FakeMuse()))
        self.assertEqual(c.get("/relay//eye/capture").status_code, 404)
        self.assertEqual(c.get("/relay/x").status_code, 404)

    def test_meter_starts_over_each_day(self):
        now = [0.0]
        m = CaptionMeter(1, clock=lambda: now[0])
        m.add(90)
        self.assertLess(m.left_s(), 0)
        now[0] = 86400.0
        self.assertEqual(m.left_s(), 60)


if __name__ == "__main__":
    unittest.main()
