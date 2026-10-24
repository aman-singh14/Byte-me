"""Tests for Call a helper (backend/helper.py): room expiry, tokens, newest-frame-only
dropping, and command forwarding.

    python -m unittest -v backend.test_helper
"""

import asyncio
import json
import struct
import unittest

from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from backend import helper


def frame(cam=b"F", ts=1_700_000_000_000, body=b"jpeg"):
    return cam + struct.pack(">Q", ts) + b"\xff\xd8" + body + b"\xff\xd9"


class Clock:
    def __init__(self):
        self.now = 1_000_000.0

    def __call__(self):
        return self.now


class OutboxTest(unittest.TestCase):
    def test_keeps_only_the_newest_frame(self):
        async def go():
            box = helper.Outbox()
            for i in range(3):
                box.put_frame(frame(body=bytes([i])))
            self.assertEqual(await box.next(), frame(body=bytes([2])))
            self.assertEqual(box.dropped, 2)
            box.close()
            self.assertIsNone(await box.next())

        asyncio.run(go())

    def test_events_are_never_dropped_and_go_first(self):
        async def go():
            box = helper.Outbox()
            box.put_frame(frame())
            box.put_event({"t": "alert"})
            box.put_event({"t": "tap"})
            self.assertEqual([await box.next() for _ in range(3)], [{"t": "alert"}, {"t": "tap"}, frame()])

        asyncio.run(go())


class FilterTest(unittest.TestCase):
    def test_helper_commands(self):
        self.assertEqual(helper.command_from_helper({"t": "guide", "dir": "L", "x": 1}), {"t": "guide", "dir": "L"})
        self.assertEqual(helper.command_from_helper({"t": "cam", "which": "R"}), {"t": "cam", "which": "R"})
        self.assertEqual(helper.command_from_helper({"t": "end"}), {"t": "end"})
        for bad in ({"t": "guide", "dir": "up"}, {"t": "cam", "which": "X"}, {"t": "alert"}, [], "guide"):
            self.assertIsNone(helper.command_from_helper(bad))

    def test_frames_must_look_like_a_jpeg_from_a_known_camera(self):
        self.assertTrue(helper.valid_frame(frame()))
        self.assertFalse(helper.valid_frame(frame(cam=b"X")))
        self.assertFalse(helper.valid_frame(b"F" + b"\0" * 8 + b"not a jpeg"))
        self.assertFalse(helper.valid_frame(frame(body=b"\0" * helper.MAX_FRAME_BYTES)))


class RoomsTest(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.rooms = helper.Rooms(clock=self.clock)
        self.client = TestClient(helper.create_app(self.rooms))
        r = self.client.post("/rooms")
        self.assertEqual(r.status_code, 201)
        self.room = r.json()
        self.helper_token = self.room["helper_url"].split("t=")[1]

    def wearer(self):
        return self.client.websocket_connect(f"/ws/wearer/{self.room['room']}?t={self.room['wearer_token']}")

    def helper(self):
        return self.client.websocket_connect(f"/ws/helper/{self.room['room']}?t={self.helper_token}")

    def test_room_ids_and_tokens(self):
        self.assertEqual(len(self.room["room"]), 32)  # 128 bits, hex
        self.assertIn(f"/h/{self.room['room']}?t=", self.room["helper_url"])
        self.assertNotEqual(self.room["wearer_token"], self.helper_token)
        self.assertEqual(self.client.get(f"/h/{self.room['room']}?t={self.helper_token}").status_code, 200)

    def test_named_room_metadata_requires_helper_token(self):
        response = self.client.post('/rooms', json={'wearer_name': '  Aman <test>  '})
        room = response.json()
        token = room['helper_url'].split('t=')[1]
        path = f"/room-info/{room['room']}"
        info = self.client.get(f"{path}?t={token}")
        self.assertEqual(info.json()['wearer_name'], 'Aman <test>')
        self.assertEqual(info.headers['cache-control'], 'no-store')
        self.assertEqual(self.client.get(path).status_code, 404)
        self.assertEqual(self.client.get(f"{path}?t={room['wearer_token']}").status_code, 404)
        self.assertEqual(self.client.post('/rooms', json={'wearer_name': 'x' * 81}).status_code, 422)

    def test_helper_can_end_without_wearer_connected(self):
        with self.helper() as ws:
            ws.receive_text()
            ws.send_json({'t': 'end'})
            self.assertEqual(ws.receive_json(), {'t': 'ended'})
        self.assertIsNone(self.rooms.get(self.room['room']))

    def test_wrong_tokens_are_refused(self):
        self.assertEqual(self.client.get(f"/h/{self.room['room']}?t=nope").status_code, 404)
        self.assertEqual(self.client.get(f"/h/{self.room['room']}?t={self.room['wearer_token']}").status_code, 404)
        for url in (f"/ws/helper/{self.room['room']}?t={self.room['wearer_token']}",
                    f"/ws/wearer/{self.room['room']}?t={self.helper_token}",
                    f"/ws/wearer/{'0' * 32}?t={self.room['wearer_token']}"):
            with self.assertRaises(WebSocketDisconnect) as e:
                with self.client.websocket_connect(url) as ws:
                    ws.receive_text()
            self.assertEqual(e.exception.code, helper.CLOSE_BAD_TOKEN)

    def test_rooms_expire_after_30_minutes(self):
        self.clock.now += helper.ROOM_TTL_S - 1
        self.assertIsNotNone(self.rooms.get(self.room["room"]))
        self.clock.now += 2
        self.assertIsNone(self.rooms.get(self.room["room"]))
        self.assertEqual(self.client.get(f"/h/{self.room['room']}?t={self.helper_token}").status_code, 404)
        with self.assertRaises(WebSocketDisconnect):
            with self.wearer() as ws:
                ws.receive_text()

    def test_frames_events_and_commands_are_relayed(self):
        with self.wearer() as wearer, self.helper() as helper_ws:
            self.assertEqual(json.loads(helper_ws.receive_text()), {"t": "wearer", "on": True})
            self.assertEqual(json.loads(wearer.receive_text()), {"t": "helper", "on": True})

            wearer.send_bytes(frame(cam=b"R"))
            self.assertEqual(helper_ws.receive_bytes(), frame(cam=b"R"))  # byte for byte
            self.assertEqual(json.loads(wearer.receive_text()), {"t": "ack"})

            wearer.send_text(json.dumps({"t": "alert", "side": "L", "level": 2, "label": "car"}))
            self.assertEqual(json.loads(helper_ws.receive_text())["label"], "car")

            helper_ws.send_text(json.dumps({"t": "guide", "dir": "up"}))  # not a direction: dropped
            helper_ws.send_text(json.dumps({"t": "guide", "dir": "L"}))
            helper_ws.send_text(json.dumps({"t": "cam", "which": "R"}))
            self.assertEqual(json.loads(wearer.receive_text()), {"t": "guide", "dir": "L"})
            self.assertEqual(json.loads(wearer.receive_text()), {"t": "cam", "which": "R"})

            wearer.send_text(json.dumps({"t": "end"}))
            self.assertEqual(json.loads(helper_ws.receive_text()), {"t": "ended"})
            with self.assertRaises(WebSocketDisconnect) as e:
                helper_ws.receive_text()  # the server hangs up on the helper at once
            self.assertEqual(e.exception.code, helper.CLOSE_ENDED)
        self.assertIsNone(self.rooms.get(self.room["room"]))  # ended for good

    def test_one_helper_per_room(self):
        with self.helper() as first:
            self.assertEqual(json.loads(first.receive_text()), {"t": "wearer", "on": False})
            with self.assertRaises(WebSocketDisconnect) as e:
                with self.helper() as second:
                    second.receive_text()
            self.assertEqual(e.exception.code, helper.CLOSE_TAKEN)


if __name__ == "__main__":
    unittest.main()
