"""Rear event protocol: FPGA (or its ESP32 bridge) -> backend. Spec: docs/rear_event_protocol.md.

Every packet, little-endian:

    off  size  field
    0    2     SYNC      0xA5 0x5A
    2    1     VERSION   1
    3    1     TYPE      EVENT=0x01 FRAME_CHUNK=0x02 END=0x03 HEARTBEAT=0x04
    4    2     EVENT_ID  u16, same for every packet of one event (wraps)
    6    2     SEQ       u16, packet number within the event (EVENT is 0)
    8    2     LEN       u16, payload length, <= MAX_PAYLOAD
    10   LEN   PAYLOAD
    10+LEN 2   CRC16     CRC-16/CCITT-FALSE over bytes 2 .. 10+LEN-1 (VERSION through PAYLOAD)

This module is pure Python with no I/O, so the FPGA teammate can also use it to
check captures.
"""

import struct
from dataclasses import dataclass, field

SYNC = b"\xA5\x5A"
VERSION = 1
HEADER = struct.Struct("<2sBBHHH")   # sync, version, type, event_id, seq, len
HEADER_SIZE = HEADER.size           # 10
CRC_SIZE = 2
MAX_PAYLOAD = 1280
MAX_CHUNK_DATA = 1024

EVENT, FRAME_CHUNK, END, HEARTBEAT = 0x01, 0x02, 0x03, 0x04
TYPE_NAMES = {EVENT: "EVENT", FRAME_CHUNK: "FRAME_CHUNK", END: "END", HEARTBEAT: "HEARTBEAT"}

GRAY8, JPEG = 0, 1
REGION_UNKNOWN, REGION_LEFT, REGION_CENTER, REGION_RIGHT = 0, 1, 2, 3   # IMAGE columns, not wearer sides
END_OK, END_TRUNCATED, END_ABORTED = 0, 1, 2
FLAG_CLIP_FOLLOWS = 0x01

EVENT_FMT = struct.Struct("<IIIIIHHHHBBBB")   # 32 bytes
CHUNK_FMT = struct.Struct("<HHHI")            # 10-byte chunk header, then data
END_FMT = struct.Struct("<HHBB")              # 6 bytes
HEARTBEAT_FMT = struct.Struct("<IB3x")        # 8 bytes


def crc16(data, crc=0xFFFF):
    """CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, no reflection, no final XOR.
    crc16(b"123456789") == 0x29B1."""
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


class ProtocolError(ValueError):
    pass


# ---------------------------------------------------------------------------
# Payloads
# ---------------------------------------------------------------------------

@dataclass
class Event:
    t_ms: int                 # FPGA clock, ms since power-on (u32)
    k_peak: int               # LGMD potential K when it fired (u21 in a u32)
    k_left: int = 0           # K per IMAGE column third (u19 each); 0 if not computed
    k_center: int = 0
    k_right: int = 0
    width: int = 160
    height: int = 120
    frame_count: int = 30     # frames that will follow in FRAME_CHUNK packets
    trigger_index: int = 29   # index (0-based) of the frame on which LGMD fired
    fps: int = 10
    pixel_format: int = GRAY8
    region: int = REGION_UNKNOWN
    flags: int = FLAG_CLIP_FOLLOWS

    def pack(self):
        return EVENT_FMT.pack(self.t_ms, self.k_peak, self.k_left, self.k_center, self.k_right,
                              self.width, self.height, self.frame_count, self.trigger_index,
                              self.fps, self.pixel_format, self.region, self.flags)

    @classmethod
    def unpack(cls, b):
        if len(b) != EVENT_FMT.size:
            raise ProtocolError(f"EVENT payload is {len(b)} bytes, expected {EVENT_FMT.size}")
        return cls(*EVENT_FMT.unpack(b))


@dataclass
class FrameChunk:
    frame_index: int
    chunk_index: int
    chunk_count: int
    frame_size: int           # total bytes of this frame (GRAY8: width*height; JPEG: varies)
    data: bytes

    def pack(self):
        return CHUNK_FMT.pack(self.frame_index, self.chunk_index, self.chunk_count, self.frame_size) + self.data

    @classmethod
    def unpack(cls, b):
        if len(b) < CHUNK_FMT.size:
            raise ProtocolError("FRAME_CHUNK payload shorter than its header")
        fi, ci, cc, size = CHUNK_FMT.unpack_from(b)
        if cc == 0 or ci >= cc:
            raise ProtocolError(f"chunk {ci} of {cc} is out of range")
        return cls(fi, ci, cc, size, bytes(b[CHUNK_FMT.size:]))


@dataclass
class End:
    frames_sent: int
    clip_crc: int             # crc16 over every frame's bytes, frame order, concatenated
    status: int = END_OK

    def pack(self):
        return END_FMT.pack(self.frames_sent, self.clip_crc, self.status, 0)

    @classmethod
    def unpack(cls, b):
        if len(b) != END_FMT.size:
            raise ProtocolError(f"END payload is {len(b)} bytes, expected {END_FMT.size}")
        frames, crc, status, _ = END_FMT.unpack(b)
        return cls(frames, crc, status)


@dataclass
class Heartbeat:
    t_ms: int
    status: int = 0           # bit0: camera ok, bit1: LGMD armed

    def pack(self):
        return HEARTBEAT_FMT.pack(self.t_ms, self.status)

    @classmethod
    def unpack(cls, b):
        if len(b) != HEARTBEAT_FMT.size:
            raise ProtocolError(f"HEARTBEAT payload is {len(b)} bytes, expected {HEARTBEAT_FMT.size}")
        return cls(*HEARTBEAT_FMT.unpack(b))


PAYLOAD_TYPES = {EVENT: Event, FRAME_CHUNK: FrameChunk, END: End, HEARTBEAT: Heartbeat}
TYPE_OF = {v: k for k, v in PAYLOAD_TYPES.items()}


@dataclass
class Packet:
    type: int
    event_id: int
    seq: int
    body: object              # Event | FrameChunk | End | Heartbeat


# ---------------------------------------------------------------------------
# Packets
# ---------------------------------------------------------------------------

def encode(body, event_id, seq):
    payload = body.pack()
    if len(payload) > MAX_PAYLOAD:
        raise ProtocolError(f"payload {len(payload)} > {MAX_PAYLOAD}")
    head = HEADER.pack(SYNC, VERSION, TYPE_OF[type(body)], event_id & 0xFFFF, seq & 0xFFFF, len(payload))
    return head + payload + struct.pack("<H", crc16(head[2:] + payload))


def decode(buf):
    """Decode exactly one packet. Raises ProtocolError on any problem."""
    if len(buf) < HEADER_SIZE + CRC_SIZE:
        raise ProtocolError("too short")
    sync, version, ptype, event_id, seq, length = HEADER.unpack_from(buf)
    if sync != SYNC:
        raise ProtocolError("bad sync")
    if version != VERSION:
        raise ProtocolError(f"unsupported version {version}")
    if length > MAX_PAYLOAD or len(buf) != HEADER_SIZE + length + CRC_SIZE:
        raise ProtocolError("length mismatch")
    payload = bytes(buf[HEADER_SIZE:HEADER_SIZE + length])
    (crc,) = struct.unpack_from("<H", buf, HEADER_SIZE + length)
    if crc != crc16(bytes(buf[2:HEADER_SIZE]) + payload):
        raise ProtocolError("bad CRC")
    if ptype not in PAYLOAD_TYPES:
        raise ProtocolError(f"unknown type 0x{ptype:02x}")
    return Packet(ptype, event_id, seq, PAYLOAD_TYPES[ptype].unpack(payload))


class StreamParser:
    """Byte stream (serial, or several packets per datagram) -> packets.

    Resynchronises on SYNC after garbage or a bad packet: a corrupt packet is
    dropped and scanning restarts one byte after its SYNC, so one bit error
    never loses more than that packet.
    """

    def __init__(self):
        self.buf = bytearray()
        self.errors = 0

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            i = self.buf.find(SYNC)
            if i < 0:
                del self.buf[:max(0, len(self.buf) - 1)]   # keep a trailing 0xA5
                return out
            if i:
                del self.buf[:i]
            if len(self.buf) < HEADER_SIZE:
                return out
            length = struct.unpack_from("<H", self.buf, 8)[0]
            # Reject a false SYNC as early as possible (bad version/type/length), so garbage
            # never makes us wait for a payload that is not coming.
            if length > MAX_PAYLOAD or self.buf[2] != VERSION or self.buf[3] not in PAYLOAD_TYPES:
                self.errors += 1
                del self.buf[:1]
                continue
            total = HEADER_SIZE + length + CRC_SIZE
            if len(self.buf) < total:
                return out
            try:
                out.append(decode(bytes(self.buf[:total])))
                del self.buf[:total]
            except ProtocolError:
                self.errors += 1
                del self.buf[:1]


# ---------------------------------------------------------------------------
# Whole events (what the FPGA sends; what tools/mock_fpga.py uses)
# ---------------------------------------------------------------------------

def frame_chunks(frame_bytes, frame_index, max_data=MAX_CHUNK_DATA):
    n = max(1, -(-len(frame_bytes) // max_data))
    return [FrameChunk(frame_index, c, n, len(frame_bytes), frame_bytes[c * max_data:(c + 1) * max_data])
            for c in range(n)]


def encode_event(event, frames, event_id, status=END_OK):
    """EVENT, then every frame as FRAME_CHUNKs, then END. frames: list of bytes."""
    packets, seq = [encode(event, event_id, 0)], 1
    clip_crc = 0xFFFF
    for i, f in enumerate(frames):
        clip_crc = crc16(f, clip_crc)
        for ch in frame_chunks(f, i):
            packets.append(encode(ch, event_id, seq))
            seq += 1
    packets.append(encode(End(len(frames), clip_crc, status), event_id, seq))
    return packets


@dataclass
class Clip:
    """Reassembled event. frames[i] is None if any of its chunks never arrived."""
    event_id: int
    event: Event
    frames: list = field(default_factory=list)
    end: End | None = None
    crc_ok: bool | None = None          # None until END arrives
    dropped_packets: int = 0

    @property
    def complete(self):
        return self.end is not None and all(f is not None for f in self.frames) and bool(self.crc_ok)


class ClipAssembler:
    """Packets in, events out. on_event fires on EVENT (warn NOW); on_clip on END or timeout."""

    def __init__(self, on_event, on_clip, on_heartbeat=None):
        self.on_event, self.on_clip, self.on_heartbeat = on_event, on_clip, on_heartbeat
        self.current = None
        self._chunks = {}       # frame_index -> {chunk_index: bytes}
        self._counts = {}       # frame_index -> chunk_count
        self._last_seq = 0

    def feed(self, pkt):
        if pkt.type == HEARTBEAT:
            if self.on_heartbeat:
                self.on_heartbeat(pkt.body)
            return
        if pkt.type == EVENT:
            if self.current is not None:          # previous clip never ended
                self._finish()
            ev = pkt.body
            self.current = Clip(pkt.event_id, ev, [None] * ev.frame_count)
            self._chunks, self._counts, self._last_seq = {}, {}, 0
            self.on_event(ev, pkt.event_id)
            return
        if self.current is None or pkt.event_id != self.current.event_id:
            return                                # chunk of an event we never saw start
        if pkt.seq > self._last_seq + 1:
            self.current.dropped_packets += pkt.seq - self._last_seq - 1
        self._last_seq = max(self._last_seq, pkt.seq)
        if pkt.type == FRAME_CHUNK:
            ch = pkt.body
            if ch.frame_index >= len(self.current.frames):
                return
            parts = self._chunks.setdefault(ch.frame_index, {})
            parts[ch.chunk_index] = ch.data
            self._counts[ch.frame_index] = ch.chunk_count
            if len(parts) == ch.chunk_count:
                data = b"".join(parts[i] for i in range(ch.chunk_count))
                if len(data) == ch.frame_size:
                    self.current.frames[ch.frame_index] = data
        elif pkt.type == END:
            self.current.end = pkt.body
            crc = 0xFFFF
            for f in self.current.frames:
                if f is None:
                    crc = None
                    break
                crc = crc16(f, crc)
            self.current.crc_ok = crc is not None and crc == pkt.body.clip_crc
            self._finish()

    def flush(self):
        """Give up on the current clip (timeout): deliver whatever arrived."""
        if self.current is not None:
            self._finish()

    def _finish(self):
        clip, self.current = self.current, None
        self.on_clip(clip)
