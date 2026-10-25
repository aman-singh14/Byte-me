"""UDP camera video (backend/udp_camera.py) against a fake camera that speaks the firmware's protocol."""

import importlib.util
import json
import os
import time

import cv2
import numpy as np
import pytest

from backend.discovery import CameraDirectory
from backend.streams import FrameReader
from backend.udp_camera import HEADER, FrameAssembler, UdpCamera, parse_url

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_spec = importlib.util.spec_from_file_location("fake_udp_camera", os.path.join(ROOT, "tools", "fake_udp_camera.py"))
fake = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fake)


def packets(fid, jpeg, magic=b"CAMV", chunk=1400):
    n = (len(jpeg) + chunk - 1) // chunk
    return [HEADER.pack(magic, fid, c, n, len(jpeg)) + jpeg[c * chunk:(c + 1) * chunk] for c in range(n)]


def picture(seed=0, size=(640, 480)):
    rng = np.random.default_rng(seed)
    img = cv2.GaussianBlur(rng.integers(0, 255, (size[1], size[0], 3), np.uint8), (0, 0), 3)
    return img


def jpeg_of(img, q=80):
    return cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])[1].tobytes()


class TestAssembler:
    def test_in_order(self):
        a, j = FrameAssembler(), jpeg_of(picture())
        out = [a.feed(p) for p in packets(1, j)]
        assert out[-1] == j and all(o is None for o in out[:-1])

    def test_out_of_order(self):
        a, j = FrameAssembler(), jpeg_of(picture())
        ps = packets(1, j)
        assert len(ps) > 3
        done = [a.feed(p) for p in reversed(ps)]
        assert done[-1] == j

    def test_missing_chunk_skips_only_that_frame(self):
        a = FrameAssembler()
        j1, j2, j3 = (jpeg_of(picture(i)) for i in range(3))
        got = [a.feed(p) for p in packets(1, j1)]
        got += [a.feed(p) for p in packets(2, j2)[1:]]           # chunk 0 of frame 2 lost
        got += [a.feed(p) for p in packets(3, j3)]
        assert [g for g in got if g is not None] == [j1, j3]
        assert a.dropped == 1 and not a.partial

    def test_late_chunk_of_an_old_frame_is_ignored(self):
        a = FrameAssembler()
        j1, j2 = jpeg_of(picture(1)), jpeg_of(picture(2))
        p1 = packets(1, j1)
        for p in p1[:-1]:
            a.feed(p)
        for p in packets(2, j2):
            a.feed(p)
        assert a.feed(p1[-1]) is None                          # frame 2 was already shown

    def test_camera_restart(self):
        a = FrameAssembler()
        for p in packets(5000, jpeg_of(picture(1))):
            a.feed(p)
        assert [a.feed(p) for p in packets(1, jpeg_of(picture(2)))][-1] is not None

    def test_junk_and_back_camera_packets(self):
        a, j = FrameAssembler(), jpeg_of(picture())
        assert a.feed(b"hello") is None and a.feed(b'{"t":"rear"}' * 3) is None
        assert a.feed(HEADER.pack(b"XXXX", 1, 0, 1, 10) + b"0123456789") is None
        assert [a.feed(p) for p in packets(1, j, magic=b"OMNV")][-1] == j

    def test_url(self):
        assert parse_url("udp://172.20.10.3:81") == ("172.20.10.3", 81)
        assert parse_url("udp://eye-cam.local:81") == ("eye-cam.local", 81)
        with pytest.raises(ValueError):
            parse_url("udp://nohost")


class TestOverTheNetwork:
    def test_frames_arrive_and_stop_is_sent(self):
        img = picture(3)
        cam = fake.FakeCamera(0, lambda: img, 25, (320, 240), name="eye").start()
        try:
            rx = UdpCamera(f"udp://127.0.0.1:{cam.port}")
            assert rx.opened()
            frame = None
            for _ in range(20):
                frame = rx.read()
                if frame is not None:
                    break
            assert frame is not None and frame.shape == (240, 320, 3)
            assert float(np.abs(frame.astype(int) - cv2.resize(img, (320, 240)).astype(int)).mean()) < 8
            rx.release()
            time.sleep(0.1)
            assert not cam.viewers                              # STOP made the camera forget us
        finally:
            cam.stop()

    def test_unresolvable_host_is_not_opened(self):
        assert not UdpCamera("udp://no-such-camera.invalid:8101").opened()

    def test_lossy_link_still_delivers_most_frames(self):
        cam = fake.FakeCamera(0, lambda: picture(4), 20, (320, 240), drop=0.03).start()
        try:
            reader = FrameReader(f"udp://127.0.0.1:{cam.port}", reconnect_s=0.5)
            time.sleep(2.5)
            st = reader.status()
            reader.close()
            assert st["ok"] and st["fps"] >= 10, st             # 20 fps sent, 3% of datagrams lost
        finally:
            cam.stop()

    def test_three_streams_at_once(self):
        """Eye (25 fps 320x240 grey), front (5 fps 640x480) and a back-camera-sized stream together."""
        cams = [fake.FakeCamera(0, lambda: picture(5), 25, (320, 240), grey=True).start(),
                fake.FakeCamera(0, lambda: picture(6), 5, (640, 480)).start(),
                fake.FakeCamera(0, lambda: picture(7), 10, (640, 480), grey=True).start()]
        try:
            readers = [FrameReader(f"udp://127.0.0.1:{c.port}") for c in cams]
            time.sleep(3.0)
            fps = [r.status()["fps"] for r in readers]
            lag = [time.time() - r.latest()[2] for r in readers]
            for r in readers:
                r.close()
            assert fps[0] >= 18 and fps[1] >= 3.5 and fps[2] >= 7, fps
            assert max(lag) < 0.5, lag
        finally:
            for c in cams:
                c.stop()


class TestDiscovery:
    def hello(self, **kw):
        return json.dumps({"t": "cam_hello", "role": "eye", "ip": "172.20.10.3", "stream_port": 81,
                           "http_port": 80, **kw}).encode()

    def test_udp_hello_gives_udp_url(self):
        d = CameraDirectory({"cameras": {"eye": {"source": "udp://eye-cam.local:81"}}})
        d.handle(self.hello(stream="udp"))
        assert d.stream_url("eye") == "udp://172.20.10.3:81"
        assert d.http_base("eye") == "http://172.20.10.3"

    def test_old_hello_still_means_mjpeg(self):
        d = CameraDirectory({"cameras": {"eye": {"source": "udp://eye-cam.local:81"}}})
        d.handle(self.hello())
        assert d.stream_url("eye") == "http://172.20.10.3:81/stream"

    def test_static_ip_follows_the_source_type(self):
        d = CameraDirectory({"cameras": {"front": {"source": "udp://front-cam.local:81", "static_ip": "10.0.0.9",
                                                   "stream_port": 81}}})
        assert d.candidates("front") == ["udp://front-cam.local:81", "udp://10.0.0.9:81"]
        assert d.http_base("front") == "http://front-cam.local"
