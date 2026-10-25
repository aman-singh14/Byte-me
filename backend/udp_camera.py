"""Receive JPEG frames from an ESP32-CAM over UDP (firmware/esp_camera_eye, firmware/esp_camera2_front).

Source strings look like "udp://172.20.10.3:81" or "udp://eye-cam.local:81".

    laptop                                   camera (UDP 81, eye and front each on their own IP)
    "WANT" every second, from our port  ->   remembers our address:port for VIEWER_TIMEOUT_MS
                                        <-   every frame, cut into datagrams:
                                             "CAMV" frame_id u32  chunk u16  chunks u16  jpeg_len u32  + bytes
    "STOP" when we close                ->   forgets us

The reader binds a random local port, so several readers (or a second laptop) never fight over a
port. A frame is shown only when all of its chunks arrived; a frame with a missing chunk is skipped
and the next one replaces it, so a lost datagram costs one frame, never a stall. The back camera's
"OMNV" packets have the same layout and are accepted too.
"""

import socket
import struct
import time

import cv2
import numpy as np

HEADER = struct.Struct("<4sIHHI")          # magic, frame_id, chunk, chunks, jpeg_len  (16 bytes)
MAGICS = (b"CAMV", b"OMNV")
WANT_EVERY_S = 1.0
MAX_JPEG = 2_000_000                       # anything bigger is not one of our frames
KEEP_PARTIAL = 4                           # frames being assembled at once (older ones are dropped)


def parse_url(src):
    """'udp://host:port' -> (host, port)."""
    rest = src[len("udp://"):].split("/")[0]
    host, _, port = rest.rpartition(":")
    if not host or not port.isdigit():
        raise ValueError(f"bad UDP source {src!r}: expected udp://host:port")
    return host, int(port)


class FrameAssembler:
    """Datagrams in, complete JPEG bytes out. Pure logic (no sockets), so it can be tested."""

    def __init__(self):
        self.partial = {}                  # frame_id -> [chunks, jpeg_len, {chunk: bytes}, t_first]
        self.last_done = None              # id of the last frame handed out
        self.complete = 0
        self.dropped = 0

    def feed(self, data, now=None):
        """One datagram. Returns the JPEG bytes when this datagram completed a frame, else None."""
        if len(data) < HEADER.size:
            return None
        magic, fid, chunk, chunks, length = HEADER.unpack_from(data)
        if magic not in MAGICS or chunks == 0 or chunk >= chunks or not 0 < length <= MAX_JPEG:
            return None
        if self.last_done is not None and fid <= self.last_done:
            if self.last_done - fid < 1000:
                return None                # late chunk of a frame we already showed or skipped
            self.last_done = None          # the camera restarted and counts from 1 again
            self.partial.clear()
        entry = self.partial.get(fid)
        if entry is None:
            entry = self.partial[fid] = [chunks, length, {}, now or time.time()]
            while len(self.partial) > KEEP_PARTIAL:
                del self.partial[min(self.partial)]
                self.dropped += 1
        entry[2][chunk] = data[HEADER.size:]
        if len(entry[2]) < entry[0]:
            return None
        jpeg = b"".join(entry[2][i] for i in range(entry[0]))
        del self.partial[fid]
        for old in [k for k in self.partial if k < fid]:      # older unfinished frames will never be shown
            del self.partial[old]
            self.dropped += 1
        self.last_done = fid
        if len(jpeg) != entry[1]:
            self.dropped += 1
            return None
        self.complete += 1
        return jpeg


class UdpCamera:
    """One camera over UDP. read() returns the newest complete BGR frame, or None after `timeout_s`."""

    def __init__(self, src, timeout_s=0.5):
        self.src = src
        self.host, self.port = parse_url(src)
        self.timeout_s = timeout_s
        self.addr = None
        self.sock = None
        self.asm = FrameAssembler()
        self._last_want = 0.0
        try:
            self.addr = (socket.gethostbyname(self.host), self.port)
        except OSError:
            return                         # e.g. eye-cam.local not resolvable: opened() is False
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 21)
        self.sock.bind(("0.0.0.0", 0))
        self.sock.settimeout(0.05)
        self._want(force=True)

    def opened(self):
        return self.sock is not None

    def _want(self, force=False):
        now = time.monotonic()
        if force or now - self._last_want >= WANT_EVERY_S:
            self._last_want = now
            try:
                self.sock.sendto(b"WANT", self.addr)
            except OSError:
                pass                       # network down for a moment: try again next second

    def read(self):
        if self.sock is None:
            return None
        deadline = time.monotonic() + self.timeout_s
        jpeg = None
        while time.monotonic() < deadline:
            self._want()
            try:
                data, _ = self.sock.recvfrom(2048)
            except socket.timeout:
                if jpeg is not None:
                    break                  # nothing newer queued: hand out what we have
                continue
            except OSError:
                return None
            done = self.asm.feed(data)
            if done is not None:
                jpeg = done                # keep reading: a newer frame may already be waiting
                self.sock.settimeout(0.0005)
        self.sock.settimeout(0.05)
        if jpeg is None:
            return None
        return cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)

    def release(self):
        if self.sock is None:
            return
        try:
            self.sock.sendto(b"STOP", self.addr)
        except OSError:
            pass
        self.sock.close()
        self.sock = None
