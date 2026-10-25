"""The phone simulator (tools/fake_udp_camera.py) against the real firmware: same ports, same chunk
header, the same JSON fields as the sketches' own message formats, and it works over UDP.
(mobile-app/test/firmware_contract_test.dart holds the app to the same sketches.)"""

import importlib.util
import json
import os
import re
import socket
import time
import urllib.request

import numpy as np
import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_spec = importlib.util.spec_from_file_location("fake_udp_camera", os.path.join(ROOT, "tools", "fake_udp_camera.py"))
fake = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fake)


def sketch(name):
    with open(os.path.join(ROOT, "firmware", name, name + ".ino")) as f:
        return f.read()


EYE, FRONT, BACK = sketch("esp_camera_eye"), sketch("esp_camera2_front"), sketch("esp_camera3_back")


def number(src, name):
    m = re.search(rf"#define\s+{name}\s+(\d+)|\b{name}\s*=\s*(\d+)\s*;", src)
    assert m, name
    return int(m.group(1) or m.group(2))


def message(src, start):
    """The C string starting with `start`, adjacent literals joined and printf filled in."""
    i = src.index(start)
    text, at = "", i
    for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', src[i:]):
        if src[at:i + m.start()].strip():
            break
        text += m.group(1)
        at = i + m.end()
    text = text.replace('\\"', '"')
    text = re.sub(r"%[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h)?([sdiuxf])",
                  lambda m: {"s": "x", "f": "1.5"}.get(m.group(1), "1"), text)
    return json.loads(text)


def udp(port=0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", port))
    s.settimeout(2)
    return s


def picture():
    return np.full((480, 640, 3), 120, np.uint8)


class TestSameAsTheFirmware:
    def test_ports_and_timeouts(self):
        for src in (EYE, FRONT):
            assert number(src, "HELLO_PORT") == fake.HELLO_PORT
            assert number(src, "HELLO_EVERY_MS") == fake.HELLO_EVERY_S * 1000
            assert number(src, "VIEWER_TIMEOUT_MS") == fake.VIEWER_TIMEOUT_S * 1000
            assert number(src, "CHUNK_BYTES") == fake.CHUNK
        assert number(BACK, "UDP_PORT") == fake.BACK_PORT
        assert number(BACK, "VIEWER_TIMEOUT_MS") == fake.BACK_VIEWER_TIMEOUT_S * 1000

    def test_chunk_header(self):
        assert fake.HEADER.size == 16
        for src, magic in ((EYE, "CAMV"), (FRONT, "CAMV"), (BACK, "OMNV")):
            assert "uint8_t hdr[16] = {%s}" % ", ".join(f"'{c}'" for c in magic) in src

    def test_hello_and_status_have_the_firmware_fields(self):
        cam = fake.FakeCamera(0, picture, 5, (640, 480), name="front")
        try:
            assert set(cam.hello()) == set(message(FRONT, r'"{\"t\":\"cam_hello\"'))
        finally:
            cam.sock.close()
        back = fake.FakeBackCamera(picture, port=0)
        try:
            assert set(back.status()) == set(message(BACK, r'"{\"t\":\"rear\"'))
        finally:
            back.sock.close()


class TestOverUdp:
    def test_hellos_reach_the_phone_and_stills_are_served(self):
        phone = udp()
        cam = fake.FakeCamera(0, picture, 5, (640, 480), name="front", hello_to="127.0.0.1",
                              hello_port=phone.getsockname()[1], http_port=0).start()
        try:
            hello = json.loads(phone.recv(512))
            assert (hello["role"], hello["stream_port"], hello["http_port"]) == ("front", cam.port, cam.http.port)
            with urllib.request.urlopen(f"http://127.0.0.1:{cam.http.port}/capture?size=qvga", timeout=2) as r:
                assert r.read(2) == b"\xff\xd8"
        finally:
            cam.stop()
            phone.close()

    def test_back_camera_status_collision_and_video_go_to_the_phone_that_asked(self):
        phone = udp()
        back = fake.FakeBackCamera(picture, port=0, peer_port=phone.getsockname()[1], status_to_viewers=True,
                                   broadcast=False, host="127.0.0.1").start()
        try:
            phone.sendto(b"WANT", ("127.0.0.1", back.port))          # any packet makes us a viewer
            status = json.loads(phone.recv(2048))
            assert (status["t"], status["tracking"], status["fpga"]) == ("rear", 0, 1)
            back.collide()
            got = set()
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and not {b"OMNV", b"collision"} <= got:
                data = phone.recv(2048)
                got.add(data[:4] if data[:4] == b"OMNV" else json.loads(data)["t"].encode())
            assert {b"OMNV", b"collision"} <= got
        finally:
            back.stop()
            phone.close()

    def test_like_the_firmware_today_status_is_broadcast_only(self):
        phone = udp()
        back = fake.FakeBackCamera(picture, port=0, peer_port=phone.getsockname()[1], status_to_viewers=False,
                                   broadcast=False, host="127.0.0.1").start()
        try:
            phone.sendto(b"WANT", ("127.0.0.1", back.port))
            phone.settimeout(0.6)
            with pytest.raises(socket.timeout):                       # nothing unicast: the phone hears nothing
                phone.recv(2048)
        finally:
            back.stop()
            phone.close()
