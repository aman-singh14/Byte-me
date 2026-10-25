"""Shared VLM service (backend/vlm.py): request shape, schema checks, errors.
The Muse API is always faked here: these tests never spend credits."""

import base64
import json
import unittest

import cv2
import numpy as np

from backend.db import DB
from backend.muse_client import MuseClient, MuseUnavailable
from backend.vlm import FEATURES, SYSTEM_PROMPT, VlmError, VlmService, check, parse_answer


def jpeg_b64(w=320, h=240):
    ok, buf = cv2.imencode(".jpg", np.zeros((h, w, 3), np.uint8))
    return base64.b64encode(buf.tobytes()).decode()


class Transport:
    def __init__(self, content):
        self.content, self.calls = content, []

    def __call__(self, url, body, headers, timeout):
        self.calls.append((body, timeout))
        return {"model": "muse-spark-1.3", "choices": [{"message": {"content": self.content}}],
                "usage": {"prompt_tokens": 300, "completion_tokens": 40}}


def service(content='{"engaging": true, "action": "waving"}', front=None):
    t = Transport(content)
    muse = MuseClient({"muse": {"max_calls_per_min": 100}}, DB(":memory:"), key="k", transport=t)
    return VlmService(muse, front_frame=lambda: front), t


class VlmTest(unittest.TestCase):
    def test_social_confirm_request_and_answer(self):
        vlm, t = service()
        out = vlm.run("social_confirm", [("rear", jpeg_b64())])
        self.assertEqual(out["result"], {"engaging": True, "action": "waving"})
        body, timeout = t.calls[0]
        self.assertEqual(timeout, 4.0)
        self.assertEqual(body["messages"][0]["content"], SYSTEM_PROMPT)
        self.assertEqual(body["response_format"]["json_schema"]["schema"], FEATURES["social_confirm"]["schema"])
        self.assertEqual(sum(p["type"] == "image_url" for p in body["messages"][1]["content"]), 1)
        for rule in ("Never identify people", "emotion", "safe to cross", "behind the wearer's RIGHT"):
            self.assertIn(rule, SYSTEM_PROMPT)

    def test_front_frame_is_added_on_request(self):
        vlm, t = service('{"summary": "A desk."}', front=np.zeros((480, 640, 3), np.uint8))
        vlm.run("describe", [("rear", jpeg_b64())], use_front=True)
        parts = t.calls[0][0]["messages"][1]["content"]
        self.assertEqual(sum(p["type"] == "image_url" for p in parts), 2)
        self.assertIn("image 1: rear camera; image 2: front camera", parts[0]["text"])

    def test_ask_sends_the_question_with_the_phone_photo(self):
        vlm, t = service('{"answer": "A red mug."}')
        out = vlm.run("ask", [("phone", jpeg_b64())], question="  What color is this mug? ")
        self.assertEqual(out["result"], {"answer": "A red mug."})
        body, timeout = t.calls[0]
        self.assertEqual(timeout, 8.0)
        text = body["messages"][1]["content"][0]["text"]
        self.assertIn("phone camera", text)
        self.assertIn('The wearer asked: "What color is this mug?"', text)
        vlm.run("ask", [("front", jpeg_b64())], question="And this?")  # the glasses' front camera works too
        for images, question in (([("phone", jpeg_b64())], " "), ([("rear", jpeg_b64())], "What is it?")):
            with self.assertRaises(VlmError):
                vlm.run("ask", images, question=question)

    def test_bad_requests(self):
        vlm, _ = service()
        for feature, images in (("nope", [("rear", jpeg_b64())]), ("social_confirm", []),
                                ("social_confirm", [("front", jpeg_b64())]),
                                ("social_confirm", [("rear", "not base64!")]),
                                ("social_confirm", [("rear", base64.b64encode(b"text").decode())])):
            with self.assertRaises(VlmError):
                vlm.run(feature, images)
        with self.assertRaises(MuseUnavailable):
            vlm.run("describe", use_front=True)  # no front frame

    def test_answers_must_match_the_schema(self):
        schema = FEATURES["social_confirm"]["schema"]
        self.assertEqual(parse_answer('```json\n{"engaging": false, "action": "walking past"}\n```', schema),
                         {"engaging": False, "action": "walking past"})
        for bad in ('{"engaging": "yes", "action": "x"}', '{"action": "x"}', "I think so", "[]"):
            with self.assertRaises(MuseUnavailable):
                parse_answer(bad, schema)
        self.assertTrue(check({"people": [{"where": "front"}]},
                              {"type": "object", "properties": {"people": {"type": "array", "items": {
                                  "type": "object", "properties": {"where": {"type": "string", "enum": ["front"]}},
                                  "required": ["where"]}}}, "required": ["people"]}))

    def test_nothing_but_usage_is_kept(self):
        vlm, _ = service()
        vlm.run("social_confirm", [("rear", jpeg_b64())])
        recent = json.dumps(vlm.muse.db.muse_recent(5))
        self.assertNotIn("waving", recent)


if __name__ == "__main__":
    unittest.main()
