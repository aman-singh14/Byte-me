#!/usr/bin/env python3
"""
omni_collision.py - laptop side of the Omni Glasses FPGA collision reflex (Tang Nano 20K).

    webcam -> 80x60 grayscale -> USB-C serial (onboard BL616) -> FPGA (omni_collision.v)

The FPGA does every LGMD calculation (P, I, S, K, F and the fire decision) and
blinks LED2. This script only captures, shrinks and sends frames, and shows
what the FPGA reports back in its ACKs. The Python LGMD model in here is used
only by `verify` / `selftest`, never while streaming.

    py omni_collision.py ports                         find the board's COM port, ping the FPGA
    py omni_collision.py bench                         find the fastest reliable baud
    py omni_collision.py stream                        webcam -> FPGA (2 Mbaud default)
    py omni_collision.py stream --synthetic expand     no webcam needed
    py omni_collision.py verify                        FPGA vs Python model, bit-exact
    py omni_collision.py selftest                      offline checks, no board needed

--port defaults to auto: the board appears as two COM ports (FTDI 0403:6010);
the one whose serial number ends in "B" is the UART to the FPGA, the "A" one
is JTAG for the Gowin Programmer. Pass --port COMx to override.

Install:   py -m pip install numpy opencv-python pyserial
Close this script before programming the FPGA: the programmer needs the USB device.

Baud rates: the FPGA always boots at 115200. The script asks it to switch to
--baud, then switches the PC side, then checks with a PING. If that rate does
not work through the BL616 bridge, the FPGA drops back to 115200 on its own
after 2 s of silence, and the script follows it back.
"""
from __future__ import annotations

import argparse
import binascii
import collections
import queue
import random
import struct
import sys
import threading
import time
from dataclasses import dataclass, field

# ----------------------------------------------------------------------------- shared constants
# These must match omni_collision.v.
W, H = 80, 60
NPIX = W * H
FRAME_LEN = 4 + 2 + NPIX + 2           # "OMNI" + seq + pixels + crc = 4808 bytes
RESP_LEN = 18
BOOT_BAUD = 115_200
MIN_BAUD, MAX_BAUD = 9_600, 3_000_000
REVERT_S = 2.0                          # FPGA falls back to BOOT_BAUD after this much silence
FPGA_CLK_HZ = 27_000_000
FPGA_CYCLES_PER_FRAME = H * (W + 1) + 5  # lgmd_engine: one pixel per clock + one edge fetch per row

DEFAULT_K_THRESHOLD = 15_000
DEFAULT_F_MAX = 120_000                # calibrated with `selftest`: expanding object fires at F <= 101k,
                                       # whole-scene brightness ramp reaches 3 rising frames at F = 144k
DEFAULT_RISE_FRAMES = 3
FULL_ROI = (0, W - 1, 0, H - 1)
BENCH_BAUDS = (115_200, 921_600, 1_000_000, 1_500_000, 2_000_000, 3_000_000)

CMD_PING, CMD_SET_BAUD, CMD_SET_PARAM, CMD_RESET_LGMD = 1, 2, 3, 4
PARAM_K_THRESHOLD, PARAM_F_MAX, PARAM_RISE_FRAMES, PARAM_ROI, PARAM_RISE_DELTA = 0, 1, 2, 3, 4
NAK_REASONS = {1: "crc", 2: "busy", 3: "timeout"}


def theory_fps(baud: int) -> float:
    """Wire-limited frames/s with 8N1 framing (10 bits per byte)."""
    return baud / 10 / FRAME_LEN


# ----------------------------------------------------------------------------- optional imports
def need_numpy():
    try:
        import numpy
    except ImportError:
        sys.exit("numpy is missing:  py -m pip install numpy")
    return numpy


def need_cv2():
    try:
        import cv2
    except ImportError:
        sys.exit("OpenCV is missing:  py -m pip install opencv-python")
    return cv2


def need_serial():
    try:
        import serial
        import serial.tools.list_ports  # noqa: F401
    except ImportError:
        sys.exit("pyserial is missing:  py -m pip install pyserial")
    return serial


# ----------------------------------------------------------------------------- protocol
def crc16(data: bytes, crc: int = 0xFFFF) -> int:
    """CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF), same as crc16_ccitt_byte in the Verilog."""
    return binascii.crc_hqx(data, crc)


def frame_packet(seq: int, pixels: bytes) -> bytes:
    body = struct.pack("<H", seq & 0xFFFF) + pixels
    return b"OMNI" + body + struct.pack("<H", crc16(body))


def command_packet(seq: int, cmd: int, sub: int = 0, arg: int = 0) -> bytes:
    body = struct.pack("<HBBI", seq & 0xFFFF, cmd, sub, arg & 0xFFFFFFFF)
    return b"OMNC" + body + struct.pack("<H", crc16(body))


def response_packet(kind: str, seq: int, flags: int, aux: int, w0: int, w1: int) -> bytes:
    """An FPGA-style reply. The FPGA builds these; here it is only used for tests."""
    body = struct.pack("<HBBII", seq & 0xFFFF, flags, aux, w0, w1)
    return b"OMN" + kind.encode() + body + struct.pack("<H", crc16(body))


@dataclass
class Response:
    kind: str       # 'A' frame processed, 'N' frame rejected, 'R' command reply
    seq: int
    flags: int
    aux: int
    w0: int
    w1: int
    t: float        # time.perf_counter() when it arrived

    # fields of an 'A' frame ACK
    @property
    def fire(self) -> bool:
        return bool(self.flags & 1)

    @property
    def k_valid(self) -> bool:
        return bool(self.flags & 2)

    @property
    def f_suppressed(self) -> bool:
        return bool(self.flags & 4)

    @property
    def k_above(self) -> bool:
        return bool(self.flags & 8)


class ResponseParser:
    """Finds 18-byte FPGA replies in the byte stream; resyncs on garbage."""

    def __init__(self):
        self.buf = bytearray()
        self.bad = 0

    def feed(self, data: bytes, t: float) -> list[Response]:
        self.buf += data
        out = []
        while True:
            i = self.buf.find(b"OMN")
            if i < 0:
                del self.buf[:-2]          # keep a possible partial magic
                break
            if i:
                del self.buf[:i]
            if len(self.buf) < RESP_LEN:
                break
            kind = chr(self.buf[3])
            body = bytes(self.buf[4:16])
            (crc,) = struct.unpack_from("<H", self.buf, 16)
            if kind in "ANR" and crc16(body) == crc:
                seq, flags, aux, w0, w1 = struct.unpack("<HBBII", body)
                out.append(Response(kind, seq, flags, aux, w0, w1, t))
                del self.buf[:RESP_LEN]
            else:
                self.bad += 1
                del self.buf[:1]
        return out


@dataclass
class Settings:
    k_threshold: int = DEFAULT_K_THRESHOLD
    f_max: int = DEFAULT_F_MAX
    rise_frames: int = DEFAULT_RISE_FRAMES
    rise_delta: int = 0
    roi: tuple = FULL_ROI      # x0, x1, y0, y1 (inclusive) used for K

    def roi_word(self) -> int:
        x0, x1, y0, y1 = self.roi
        return x0 | (x1 << 8) | (y0 << 16) | (y1 << 24)


# ----------------------------------------------------------------------------- serial link
class LinkError(Exception):
    pass


class BaudUnsupported(LinkError):
    pass


class FpgaLink:
    """Serial link to the FPGA. A background thread parses replies into a queue,
    so replies keep arriving while a long frame write is in progress."""

    def __init__(self, port: str, boot_baud: int = BOOT_BAUD, log=print):
        self.port = port
        self.boot_baud = boot_baud
        self.log = log
        self.ser = None
        self.baud = boot_baud
        self.rxq: queue.Queue = queue.Queue()
        self.backlog: collections.deque = collections.deque()
        self.parser = ResponseParser()
        self.cmd_seq = 0
        self.error = None
        self._io_lock = threading.Lock()
        self._stop = threading.Event()
        self._reader = None

    # ---- port handling
    def open(self, baud: int):
        serial = need_serial()
        self.close()
        try:
            self.ser = serial.Serial(self.port, baudrate=baud, timeout=0.01, write_timeout=3.0)
        except (serial.SerialException, ValueError) as e:
            raise LinkError(f"cannot open {self.port}: {e}") from e
        if hasattr(self.ser, "set_buffer_size"):          # Windows only
            try:
                self.ser.set_buffer_size(rx_size=1 << 16, tx_size=1 << 17)
            except Exception:
                pass
        self.baud = baud
        self.error = None
        self._stop.clear()
        self._reader = threading.Thread(target=self._read_loop, name="serial-rx", daemon=True)
        self._reader.start()

    def close(self):
        self._stop.set()
        if self._reader is not None:
            self._reader.join(timeout=1.0)
            self._reader = None
        if self.ser is not None:
            try:
                self.ser.close()
            except Exception:
                pass
            self.ser = None

    def _read_loop(self):
        ser = self.ser
        while not self._stop.is_set():
            try:
                with self._io_lock:
                    n = ser.in_waiting
                    data = ser.read(n if n else 1)
                    replies = self.parser.feed(data, time.perf_counter()) if data else ()
            except Exception as e:                          # unplugged, driver error, ...
                self.error = e
                return
            for r in replies:
                self.rxq.put(r)

    def set_baud(self, baud: int):
        """Changes the PC side (pyserial -> USB driver -> BL616 UART)."""
        with self._io_lock:
            self.ser.baudrate = baud
        self.baud = baud

    def flush_input(self):
        with self._io_lock:
            self.ser.reset_input_buffer()
            self.parser = ResponseParser()
        self.backlog.clear()
        while True:
            try:
                self.rxq.get_nowait()
            except queue.Empty:
                break

    def write(self, data: bytes):
        if self.error is not None:
            raise LinkError(f"serial port error: {self.error}")
        try:
            self.ser.write(data)
        except Exception as e:
            self.error = e
            raise LinkError(f"write failed: {e}") from e

    def poll(self, timeout: float = 0.0) -> list[Response]:
        """All replies received so far; waits up to `timeout` for the first one."""
        out = list(self.backlog)
        self.backlog.clear()
        if self.error is not None and self.rxq.empty() and not out:
            raise LinkError(f"serial port error: {self.error}")
        try:
            if not out and timeout > 0:
                out.append(self.rxq.get(timeout=timeout))
            while True:
                out.append(self.rxq.get_nowait())
        except queue.Empty:
            pass
        return out

    # ---- commands
    def command(self, cmd: int, sub: int = 0, arg: int = 0, timeout: float | None = None,
                retries: int = 2) -> Response | None:
        if timeout is None:   # room for up to two frames already queued ahead of us
            timeout = 0.3 + 2 * FRAME_LEN * 10 / self.baud
        for _ in range(retries + 1):
            self.cmd_seq = (self.cmd_seq + 1) & 0xFFFF
            seq = self.cmd_seq
            self.write(command_packet(seq, cmd, sub, arg))
            deadline = time.perf_counter() + timeout
            while True:
                left = deadline - time.perf_counter()
                if left <= 0:
                    break
                try:
                    r = self.rxq.get(timeout=left)
                except queue.Empty:
                    break
                if r.kind == "R" and r.seq == seq:
                    return r
                self.backlog.append(r)                    # frame ACKs etc. go to poll()
            if self.error is not None:
                raise LinkError(f"serial port error: {self.error}")
        return None

    def ping(self, retries: int = 1, timeout: float = 0.3) -> Response | None:
        return self.command(CMD_PING, timeout=timeout, retries=retries)

    def keepalive(self):
        """Fire-and-forget PING so the FPGA baud watchdog does not revert while idle."""
        self.cmd_seq = (self.cmd_seq + 1) & 0xFFFF
        self.write(command_packet(self.cmd_seq, CMD_PING))

    def set_param(self, param: int, value: int):
        r = self.command(CMD_SET_PARAM, param, value)
        if r is None:
            raise LinkError("no reply to SET_PARAM")
        if r.aux != 0:
            raise LinkError(f"FPGA rejected parameter {param} = {value}")

    def apply_settings(self, s: Settings):
        self.set_param(PARAM_K_THRESHOLD, min(s.k_threshold, 0xFFFFFF))
        self.set_param(PARAM_F_MAX, min(s.f_max, 0xFFFFFF))
        self.set_param(PARAM_RISE_FRAMES, s.rise_frames)
        self.set_param(PARAM_RISE_DELTA, min(s.rise_delta, 0xFFFF))
        self.set_param(PARAM_ROI, s.roi_word())

    def reset_lgmd(self):
        if self.command(CMD_RESET_LGMD) is None:
            raise LinkError("no reply to RESET_LGMD")

    # ---- baud negotiation
    def negotiate(self, target: int) -> Response:
        """Gets PC, BL616 and FPGA onto `target` baud. Returns the FPGA's PING reply there.
        Raises BaudUnsupported (link left at boot baud) if that rate does not work."""
        if self.ser is None:
            self.open(target)
        else:
            self.set_baud(target)
        self.flush_input()
        r = self.ping(retries=1)
        if r is not None and r.w0 == target:
            return r                                       # FPGA was already there

        if target != self.boot_baud:
            self.set_baud(self.boot_baud)
            self.flush_input()
        r = self.ping(retries=1)
        if r is None:
            self.log(f"  no reply at {self.boot_baud:,} baud, waiting {REVERT_S:.0f} s "
                     "for the FPGA baud watchdog...")
            time.sleep(REVERT_S + 0.4)
            self.flush_input()
            r = self.ping(retries=2)
            if r is None:
                raise LinkError(f"FPGA not answering on {self.port} at {self.boot_baud:,} baud. "
                                "Is omni_collision.v programmed, and is this the right COM port?")
        if target == self.boot_baud:
            return r

        r = self.command(CMD_SET_BAUD, arg=target)
        if r is None:
            raise LinkError("no reply to SET_BAUD")
        if r.aux != 0:
            raise BaudUnsupported(f"FPGA refuses {target:,} baud (allowed {MIN_BAUD:,}..{MAX_BAUD:,})")
        # The FPGA switched as soon as that reply left its UART, i.e. before we read it.
        self.set_baud(target)
        time.sleep(0.03)
        self.flush_input()
        r = self.ping(retries=2)
        if r is not None and r.w0 == target:
            return r

        # Did not work: go back to the boot rate; the FPGA watchdog does the same.
        self.set_baud(self.boot_baud)
        time.sleep(REVERT_S + 0.4)
        self.flush_input()
        back = self.ping(retries=2) is not None
        raise BaudUnsupported(f"no reply at {target:,} baud"
                              + ("" if back else " (and none at boot baud either)"))

    def return_to_boot(self):
        if self.ser is None or self.baud == self.boot_baud:
            return
        try:
            r = self.command(CMD_SET_BAUD, arg=self.boot_baud, retries=1)
        except LinkError:
            r = None
        self.set_baud(self.boot_baud)
        time.sleep(0.03)
        self.flush_input()
        if r is None or self.ping() is None:
            time.sleep(REVERT_S + 0.4)
            self.flush_input()


TANG_VID_PID = (0x0403, 0x6010)   # BL616 debugger firmware poses as an FTDI FT2232:
                                   # channel A (serial no. ends in "A") = JTAG for the Gowin Programmer,
                                   # channel B (ends in "B") = UART to FPGA pins 69/70


def classify_port(p) -> str:
    """'uart' / 'jtag' for the two Tang Nano 20K channels, 'usb' for other USB serial, 'other' otherwise."""
    if p.vid is None:
        return "other"                       # Bluetooth and built-in ports
    sn = (p.serial_number or "").upper()
    if (p.vid, p.pid) == TANG_VID_PID and sn.endswith("B"):
        return "uart"
    if (p.vid, p.pid) == TANG_VID_PID and sn.endswith("A"):
        return "jtag"
    return "usb"


def resolve_port(port: str | None) -> str:
    if port and port.lower() != "auto":
        return port
    need_serial()
    from serial.tools import list_ports
    ports = list(list_ports.comports())
    uart = [p for p in ports if classify_port(p) == "uart"]
    if len(uart) == 1:
        print(f"using {uart[0].device} (Tang Nano 20K UART channel)")
        return uart[0].device
    usb = [p for p in ports if classify_port(p) == "usb"]
    if not uart and len(usb) == 1:
        print(f"using {usb[0].device} ({usb[0].description})")
        return usb[0].device
    if not ports:
        sys.exit("No COM ports found. Plug the Tang Nano 20K in with a USB-C *data* cable.")
    for p in ports:
        print(f"  {p.device:8s} {p.description}")
    sys.exit("Can't tell which COM port is the board; pass --port COMx (see `py omni_collision.py ports`).")


class RateMeter:
    """Events per second over the last `span` seconds."""

    def __init__(self, span: float = 2.0):
        self.span = span
        self.t: collections.deque = collections.deque(maxlen=4000)

    def tick(self, t: float | None = None):
        self.t.append(time.perf_counter() if t is None else t)

    def rate(self) -> float:
        now = time.perf_counter()
        while self.t and now - self.t[0] > self.span:
            self.t.popleft()
        return len(self.t) / self.span


# ----------------------------------------------------------------------------- reference LGMD (verification only)
@dataclass
class LGMDResult:
    P: object
    I: object
    S: object
    k: int
    f: int
    fire: bool
    k_valid: bool
    f_supp: bool
    k_above: bool
    rise: int
    frame_count: int


class LGMDReference:
    """Bit-exact model of lgmd_engine + collision_detector in omni_collision.v,
    including the warm-up rules (frame 1: P = 0, frame 2: no inhibition, K used
    from frame 3) and the 4-bit saturating counters."""

    def __init__(self, settings: Settings | None = None):
        self.np = need_numpy()
        self.s = settings or Settings()
        self.reset()

    def reset(self):
        np = self.np
        self.frame_count = 0
        self.prev_gray = np.zeros((H, W), np.int32)
        self.prev_p = np.zeros((H, W), np.int32)
        self.k_last = 0
        self.hist_valid = False
        self.rise = 0

    def step(self, frame) -> LGMDResult:
        np, s = self.np, self.s
        cur = np.asarray(frame, dtype=np.int32).reshape(H, W)
        prv = self.prev_gray if self.frame_count >= 1 else cur
        P = np.abs(cur - prv)                                    # P = |cur - prev|
        if self.frame_count >= 2:
            q = np.pad(self.prev_p, 1)                           # outside the image = 0
            n8 = (q[:-2, :-2] + q[:-2, 1:-1] + q[:-2, 2:] +
                  q[1:-1, :-2] + q[1:-1, 2:] +
                  q[2:, :-2] + q[2:, 1:-1] + q[2:, 2:])
            I = n8 >> 3                                          # I = sum(8 prev-P neighbours) >> 3
        else:
            I = np.zeros_like(P)
        S = np.maximum(P - (I >> 1), 0)                          # S = max(P - I/2, 0)
        x0, x1, y0, y1 = s.roi
        k = int(S[y0:y1 + 1, x0:x1 + 1].sum())                   # K = sum S (ROI)
        f = int(P.sum())                                         # F = sum P

        self.frame_count = min(self.frame_count + 1, 15)
        f_supp = f >= s.f_max
        k_above = k > s.k_threshold
        if self.frame_count < 3:
            k_valid, fire = False, False
            self.hist_valid, self.rise = False, 0
        else:
            rising = self.hist_valid and k > self.k_last + s.rise_delta
            self.rise = min(self.rise + 1, 15) if rising else 0
            self.k_last, self.hist_valid, k_valid = k, True, True
            fire = k_above and f < s.f_max and self.rise >= s.rise_frames
        self.prev_gray, self.prev_p = cur, P
        return LGMDResult(P, I, S, k, f, fire, k_valid, f_supp, k_above, self.rise, self.frame_count)


def lgmd_naive(cur, prev, prev_p, frame_count):
    """Independent per-pixel implementation (plain loops) used to cross-check LGMDReference."""
    P = [[0] * W for _ in range(H)]
    I = [[0] * W for _ in range(H)]
    S = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            c = int(cur[y][x])
            p = int(prev[y][x]) if frame_count >= 1 else c
            P[y][x] = abs(c - p)
    for y in range(H):
        for x in range(W):
            total = 0
            if frame_count >= 2:
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        yy, xx = y + dy, x + dx
                        if (dy or dx) and 0 <= yy < H and 0 <= xx < W:
                            total += int(prev_p[yy][xx])
            I[y][x] = total >> 3
            S[y][x] = max(P[y][x] - (I[y][x] >> 1), 0)
    return P, I, S


# ----------------------------------------------------------------------------- synthetic video
SCENARIOS = ("static", "expand", "slide", "flash", "shrink", "noise")
EXPAND_HALF = (2, 3, 4, 5, 6, 8, 10, 12, 14, 17, 20, 23, 26, 30)  # looming: growth accelerates
BG_LEVEL, FG_LEVEL = 40, 220


def _background(np):
    x = np.arange(W)[None, :]
    y = np.arange(H)[:, None]
    return (BG_LEVEL + x // 8 + y // 8).astype(np.int32)       # gentle gradient, 40..56


def _square(np, half, cx=W // 2, cy=H // 2):
    img = _background(np)
    img[max(0, cy - half):min(H, cy + half), max(0, cx - half):min(W, cx + half)] = FG_LEVEL
    return img


def scenario_frames(name: str) -> list:
    """One cycle of a synthetic scenario as a list of (60, 80) uint8 frames."""
    np = need_numpy()
    frames = []
    if name == "static":            # Test A: nothing moves, small sensor-like noise
        for i in range(30):
            rng = np.random.default_rng(1000 + i)
            frames.append(_background(np) + rng.integers(-2, 3, (H, W)))
    elif name == "expand":          # Test B: object approaching (square grows faster and faster)
        frames += [_square(np, 2)] * 6
        frames += [_square(np, h) for h in EXPAND_HALF]
        frames += [_square(np, EXPAND_HALF[-1])] * 4
    elif name == "slide":           # Test C: same-size object moving sideways
        xs = list(range(12, 69, 2)) + list(range(66, 13, -2))
        frames += [_square(np, 8, cx=x) for x in xs]
    elif name == "flash":           # Test D: whole scene brightens, faster every frame
        frames += [_background(np)] * 6
        frames += [_background(np) + off for off in (10, 30, 60, 100, 150)]
        frames += [_background(np) + 150] * 4
    elif name == "shrink":          # Test E: object moving away
        frames += [_square(np, EXPAND_HALF[-1])] * 6
        frames += [_square(np, h) for h in reversed(EXPAND_HALF)]
        frames += [_square(np, 2)] * 4
    elif name == "noise":           # full-range random pixels (exercises every bit of the math)
        for i in range(20):
            frames.append(np.random.default_rng(2000 + i).integers(0, 256, (H, W)))
    else:
        raise ValueError(f"unknown scenario {name!r}; choose from {', '.join(SCENARIOS)}")
    return [np.clip(f, 0, 255).astype(np.uint8) for f in frames]


# ----------------------------------------------------------------------------- frame sources
def to_small(frame_bgr):
    """BGR camera frame -> 80x60 8-bit grayscale (area averaging also cuts sensor noise)."""
    cv2 = need_cv2()
    gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
    return cv2.resize(gray, (W, H), interpolation=cv2.INTER_AREA)


class CameraSource:
    """Grabs frames on its own thread and keeps only the newest one, so the
    link always sends the latest picture instead of working through a backlog."""

    label = "webcam"

    def __init__(self, index: int = 0, backend: str = "dshow", width: int = 640, height: int = 480):
        cv2 = need_cv2()
        api = {"dshow": cv2.CAP_DSHOW, "msmf": cv2.CAP_MSMF, "any": cv2.CAP_ANY}[backend]
        self.cap = cv2.VideoCapture(index, api)
        if not self.cap.isOpened():
            raise RuntimeError(f"cannot open camera {index} with backend {backend}; "
                               "try --camera 1 or --backend msmf")
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        self.lock = threading.Lock()
        self.frame = None
        self.id = 0
        self.fps = RateMeter()
        self.failures = 0
        self.running = True
        self.thread = threading.Thread(target=self._loop, name="camera", daemon=True)
        self.thread.start()

    def _loop(self):
        while self.running:
            ok, frame = self.cap.read()        # blocks until the next frame arrives
            if not ok:
                self.failures += 1
                time.sleep(0.02)
                continue
            with self.lock:
                self.frame = frame
                self.id += 1
            self.fps.tick()

    def get_new(self, after_id: int):
        with self.lock:
            fid, frame = self.id, self.frame
        if frame is None or fid <= after_id:
            return None
        return fid, to_small(frame)

    def preview(self):
        with self.lock:
            return self.frame

    def stop(self):
        self.running = False
        self.thread.join(timeout=1.0)
        self.cap.release()


class SyntheticSource:
    """Plays a synthetic scenario on a loop. fps <= 0 means as fast as the link allows."""

    def __init__(self, name: str, fps: float):
        self.label = f"synthetic: {name}"
        self.frames = scenario_frames(name)
        self.fps_target = fps
        self.t0 = time.perf_counter()
        self.fps = RateMeter()
        self.current = self.frames[0]
        self.failures = 0

    def get_new(self, after_id: int):
        if self.fps_target > 0:
            fid = int((time.perf_counter() - self.t0) * self.fps_target)
            if fid <= after_id:
                return None
        else:
            fid = after_id + 1
        self.current = self.frames[fid % len(self.frames)]
        self.fps.tick()
        return fid, self.current

    def preview(self):
        cv2 = need_cv2()
        return cv2.cvtColor(self.current, cv2.COLOR_GRAY2BGR)

    def stop(self):
        pass


# ----------------------------------------------------------------------------- streaming
class LinkWorker(threading.Thread):
    """Owns the serial link while streaming: (re)connects, keeps up to `window`
    frames un-ACKed, reads ACKs, counts losses, recovers from unplugging."""

    def __init__(self, port, baud, boot_baud, source, settings: Settings, window, log=print):
        super().__init__(name="link", daemon=True)
        self.port, self.baud, self.boot_baud = port, baud, boot_baud
        self.source, self.settings, self.window, self.log = source, settings, window, log
        self.link: FpgaLink | None = None
        self.connected = False
        self.active_baud = None
        self.status = "starting"
        self.stop_evt = threading.Event()
        self.ui_cmds: queue.Queue = queue.Queue()
        self.paused = False
        self.inflight: dict[int, float] = {}
        self.seq = 0
        self.last_src_id = -1
        self.last_tx = 0.0
        self.last_rx = 0.0
        self.sent = RateMeter()
        self.acked = RateMeter()
        self.counts: collections.Counter = collections.Counter()
        self.lat: collections.deque = collections.deque(maxlen=120)
        self.lock = threading.Lock()
        self.k_hist: collections.deque = collections.deque(maxlen=200)
        self.last_ack: Response | None = None
        self.last_fire_t = -1e9
        self.last_small = None
        self.last_error = ""

    # ---- thread body
    def run(self):
        while not self.stop_evt.is_set():
            if not self.connected:
                self._connect()
                continue
            try:
                self._service()
            except LinkError as e:
                self._drop(f"link lost: {e}")
        if self.link is not None:
            try:
                if self.connected:
                    self.link.return_to_boot()
            except LinkError:
                pass
            self.link.close()

    def _connect(self):
        self.status = "connecting..."
        try:
            if self.link is None:
                self.link = FpgaLink(self.port, self.boot_baud, log=self.log)
            candidates = [self.baud] + [b for b in sorted(BENCH_BAUDS, reverse=True) if b < self.baud]
            for b in candidates:
                try:
                    self.link.negotiate(b)
                    break
                except BaudUnsupported as e:
                    self.log(f"{b:,} baud failed ({e}); trying a lower rate")
            else:
                raise LinkError("no baud rate worked")
            self.link.apply_settings(self.settings)
            self.link.reset_lgmd()
            self.active_baud = self.link.baud
            self.inflight.clear()
            self.connected = True
            self.last_tx = self.last_rx = time.perf_counter()
            self.status = "connected"
            self.log(f"connected on {self.port} at {self.active_baud:,} baud "
                     f"(wire limit {theory_fps(self.active_baud):.1f} fps)")
        except LinkError as e:
            self.status = f"not connected: {e}"
            self.log(self.status)
            if self.link is not None:
                self.link.close()               # frees the COM port between attempts
            self.stop_evt.wait(1.5)

    def _drop(self, why: str):
        self.counts["disconnects"] += 1
        self.status = why
        self.last_error = why
        self.log(why)
        self.connected = False
        self.inflight.clear()
        if self.link is not None:
            self.link.close()
        self.stop_evt.wait(1.0)

    def _service(self):
        link = self.link
        while True:                              # requests from the UI (thresholds, reset)
            try:
                fn = self.ui_cmds.get_nowait()
            except queue.Empty:
                break
            fn(link)

        for r in link.poll(timeout=0.002):
            self.last_rx = r.t
            self._handle(r)

        now = time.perf_counter()
        frame_s = FRAME_LEN * 10 / link.baud
        timeout = max(0.3, 4 * frame_s + 0.15)
        for seq, t in list(self.inflight.items()):
            if now - t > timeout:
                del self.inflight[seq]
                self.counts["timeout"] += 1
        if self.inflight and now - self.last_rx > REVERT_S + 0.5:
            raise LinkError(f"no reply from the FPGA for {REVERT_S + 0.5:.1f} s")
        if now - self.last_tx > 0.5 and not self.inflight:
            link.keepalive()                     # stops the FPGA reverting to boot baud while idle
            self.last_tx = now

        if self.paused or len(self.inflight) >= self.window:
            return
        item = self.source.get_new(self.last_src_id)
        if item is None:
            return
        self.last_src_id, small = item
        self.seq = (self.seq + 1) & 0xFFFF
        pkt = frame_packet(self.seq, small.tobytes())
        self.inflight[self.seq] = time.perf_counter()
        link.write(pkt)
        self.last_tx = time.perf_counter()
        self.sent.tick()
        self.counts["sent"] += 1
        self.last_small = small

    def _handle(self, r: Response):
        if r.kind == "A":
            t = self.inflight.pop(r.seq, None)
            if t is None:
                self.counts["late_ack"] += 1
            else:
                self.lat.append(r.t - t)
            self.acked.tick(r.t)
            self.counts["acked"] += 1
            with self.lock:
                self.last_ack = r
                self.k_hist.append((r.w0, r.k_valid))
            if r.fire:
                self.last_fire_t = r.t
                self.counts["fires"] += 1
        elif r.kind == "N":
            self.inflight.pop(r.seq, None)
            reason = NAK_REASONS.get(r.flags, f"code{r.flags}")
            self.counts["nak_" + reason] += 1
            self.last_error = f"FPGA rejected frame {r.seq}: {reason}"

    # ---- called from the UI thread
    def snapshot(self) -> dict:
        with self.lock:
            last = self.last_ack
            khist = list(self.k_hist)
        lat = sorted(self.lat)
        return {
            "status": self.status,
            "baud": self.active_baud if self.connected else None,
            "sent_fps": self.sent.rate(),
            "ack_fps": self.acked.rate(),
            "counts": dict(self.counts),
            "lat_ms": lat[len(lat) // 2] * 1000 if lat else None,
            "last": last,
            "khist": khist,
            "warning": time.perf_counter() - self.last_fire_t < 1.0,
            "small": self.last_small,
            "paused": self.paused,
            "error": self.last_error,
        }

    def update_settings(self, **changes):
        for k, v in changes.items():
            setattr(self.settings, k, v)
        s = self.settings
        self.ui_cmds.put(lambda link: link.apply_settings(s))

    def request_reset(self):
        self.ui_cmds.put(lambda link: link.reset_lgmd())

    def stop(self):
        self.stop_evt.set()
        self.join(timeout=6.0)


def render(source, snap: dict, settings: Settings):
    cv2, np = need_cv2(), need_numpy()
    canvas = np.zeros((240 + 180, 640, 3), np.uint8)
    cam = source.preview()
    if cam is not None:
        canvas[0:240, 0:320] = cv2.resize(cam, (320, 240), interpolation=cv2.INTER_AREA)
    small = snap["small"]
    if small is not None:
        big = cv2.resize(small, (320, 240), interpolation=cv2.INTER_NEAREST)
        canvas[0:240, 320:640] = cv2.cvtColor(big, cv2.COLOR_GRAY2BGR)
    font = cv2.FONT_HERSHEY_SIMPLEX
    cv2.putText(canvas, source.label, (6, 16), font, 0.45, (0, 255, 255), 1, cv2.LINE_AA)
    cv2.putText(canvas, "sent to FPGA (80x60)", (326, 16), font, 0.45, (0, 255, 255), 1, cv2.LINE_AA)

    c = snap["counts"]
    last = snap["last"]
    baud = snap["baud"]
    lost = c.get("timeout", 0) + sum(v for k, v in c.items() if k.startswith("nak_"))
    lat = f"{snap['lat_ms']:.1f} ms" if snap["lat_ms"] is not None else "-"
    lines = [
        (f"link: {snap['status']}" + (f" @ {baud:,} baud (max {theory_fps(baud):.1f} fps)" if baud else "")
         + ("  [PAUSED]" if snap["paused"] else ""), (200, 200, 200)),
        (f"camera {source.fps.rate():5.1f} fps   sent {snap['sent_fps']:5.1f} fps   "
         f"ACKed {snap['ack_fps']:5.1f} fps   {snap['ack_fps'] * FRAME_LEN / 1000:6.1f} kB/s", (200, 200, 200)),
        (f"lost {lost}  (crc {c.get('nak_crc', 0)}, busy {c.get('nak_busy', 0)}, "
         f"timeout {c.get('timeout', 0)})  reconnects {c.get('disconnects', 0)}  ACK latency {lat}",
         (0, 165, 255) if lost else (200, 200, 200)),
    ]
    if last is not None:
        state = "WARMING UP" if not last.k_valid else ("FIRE" if last.fire else
                ("F too high (whole-scene change)" if last.f_suppressed else "watching"))
        lines.append((f"FPGA  K {last.w0:>9,} (T {settings.k_threshold:,})   "
                      f"F {last.w1:>9,} (Fmax {settings.f_max:,})   rise {last.aux}   {state}",
                      (0, 0, 255) if last.fire else (120, 255, 120)))
    if snap["error"]:
        lines.append((snap["error"], (0, 165, 255)))
    lines.append(("q quit  r reset LGMD  t/g K-threshold up/down  f/v Fmax up/down  p pause",
                  (150, 150, 150)))
    for i, (text, color) in enumerate(lines):
        cv2.putText(canvas, text, (6, 258 + 22 * i), font, 0.42, color, 1, cv2.LINE_AA)

    # K history strip along the bottom, threshold as a red line
    hist = snap["khist"][-200:]
    if hist:
        x0, y0, pw, ph = 6, 392, 628, 24
        top = max(settings.k_threshold * 2, max(k for k, _ in hist), 1)
        pts = [(x0 + int(i * pw / 200), y0 + ph - int(ph * min(k, top) / top)) for i, (k, _) in enumerate(hist)]
        ty = y0 + ph - int(ph * settings.k_threshold / top)
        cv2.line(canvas, (x0, ty), (x0 + pw, ty), (0, 0, 255), 1)
        if len(pts) > 1:
            cv2.polylines(canvas, [np.array(pts, np.int32)], False, (120, 255, 120), 1)

    if snap["warning"]:
        cv2.rectangle(canvas, (0, 0), (639, 239), (0, 0, 255), 8)
        cv2.putText(canvas, "COLLISION WARNING", (150, 130), font, 1.0, (0, 0, 255), 3, cv2.LINE_AA)
    return canvas


def run_stream(args):
    settings = settings_from_args(args)
    port = resolve_port(args.port)
    if args.synthetic:
        source = SyntheticSource(args.synthetic, args.synthetic_fps)
    else:
        try:
            source = CameraSource(args.camera, args.backend)
        except RuntimeError as e:
            sys.exit(str(e))
    worker = LinkWorker(port, args.baud, args.boot_baud, source, settings, args.window)
    worker.start()
    preview = not args.no_preview
    cv2 = need_cv2() if preview else None
    t_end = time.perf_counter() + args.duration if args.duration > 0 else float("inf")
    next_print = time.perf_counter() + 2.0
    try:
        while time.perf_counter() < t_end:
            snap = worker.snapshot()
            now = time.perf_counter()
            if now >= next_print:
                next_print = now + 2.0
                c = snap["counts"]
                last = snap["last"]
                kf = f"K {last.w0:,} F {last.w1:,} rise {last.aux}{' FIRE' if last.fire else ''}" if last else ""
                print(f"[{snap['status']}] sent {snap['sent_fps']:.1f} fps, ACKed {snap['ack_fps']:.1f} fps, "
                      f"timeouts {c.get('timeout', 0)}, crc {c.get('nak_crc', 0)}, fires {c.get('fires', 0)}  {kf}")
            if not preview:
                time.sleep(0.05)
                continue
            cv2.imshow("Omni Glasses -> Tang Nano 20K", render(source, snap, settings))
            key = cv2.waitKey(15) & 0xFF
            if key in (ord("q"), 27):
                break
            if key == ord("r"):
                worker.request_reset()
            elif key == ord("p"):
                worker.paused = not worker.paused
            elif key in (ord("t"), ord("g")):
                k = int(settings.k_threshold * (1.25 if key == ord("t") else 0.8))
                worker.update_settings(k_threshold=max(1, min(k, 0xFFFFFF)))
            elif key in (ord("f"), ord("v")):
                f = int(settings.f_max * (1.25 if key == ord("f") else 0.8))
                worker.update_settings(f_max=max(1, min(f, 0xFFFFFF)))
            if cv2.getWindowProperty("Omni Glasses -> Tang Nano 20K", cv2.WND_PROP_VISIBLE) < 1:
                break
    except KeyboardInterrupt:
        pass
    finally:
        print("stopping (returning FPGA to boot baud)...")
        worker.stop()
        source.stop()
        if preview:
            cv2.destroyAllWindows()
        c = worker.counts
        print(f"sent {c.get('sent', 0)}, ACKed {c.get('acked', 0)}, timeouts {c.get('timeout', 0)}, "
              f"NAK crc/busy/timeout {c.get('nak_crc', 0)}/{c.get('nak_busy', 0)}/{c.get('nak_timeout', 0)}, "
              f"fires {c.get('fires', 0)}")


# ----------------------------------------------------------------------------- benchmark
@dataclass
class BenchResult:
    baud: int
    status: str = "not run"
    note: str = ""
    fpga_baud: int = 0
    sent: int = 0
    ok: int = 0
    retx: int = 0
    timeouts: int = 0
    naks: collections.Counter = field(default_factory=collections.Counter)
    injected: int = 0
    inj_detected: int = 0
    undetected: int = 0
    stray: int = 0
    elapsed: float = 0.0
    wire_bytes: int = 0
    lat: list = field(default_factory=list)

    @property
    def fps(self):
        return self.ok / self.elapsed if self.elapsed > 0 else 0.0

    @property
    def stable(self):
        return (self.status == "ok" and self.ok >= 10 and self.timeouts == 0 and not self.naks
                and self.undetected == 0 and self.inj_detected == self.injected)

    def latency(self, q):
        if not self.lat:
            return float("nan")
        s = sorted(self.lat)
        return s[min(len(s) - 1, int(q * len(s)))] * 1000


def bench_one(link: FpgaLink, baud: int, seconds: float, window: int, inject_every: int,
              max_frames: int) -> BenchResult:
    res = BenchResult(baud)
    try:
        r = link.negotiate(baud)
        res.fpga_baud = r.w0
    except BaudUnsupported as e:
        res.status, res.note = "no link", str(e)
        return res

    pool = [random.Random(2026 + i).randbytes(NPIX) for i in range(8)]   # repeatable payloads
    frame_s = FRAME_LEN * 10 / baud
    timeout = max(0.3, 4 * frame_s + 0.15)
    inflight: dict[int, tuple] = {}          # seq -> (t_sent, logical frame, injected)
    retx_q: collections.deque = collections.deque()
    next_lid = 0
    seq = 0
    t0 = time.perf_counter()
    deadline = t0 + seconds
    t_last = t0
    while True:
        now = time.perf_counter()
        more = now < deadline and res.ok + len(inflight) < max_frames
        if not inflight and not retx_q and not more:
            break
        if now > deadline + 10:
            res.note = "gave up waiting for the last replies"
            break
        while len(inflight) < window and (retx_q or more):
            injected = False
            if retx_q:
                lid = retx_q.popleft()
                res.retx += 1
            else:
                lid = next_lid
                next_lid += 1
                injected = inject_every > 0 and next_lid % inject_every == 0
            seq = (seq + 1) & 0xFFFF
            pkt = frame_packet(seq, pool[lid % len(pool)])
            if injected:                       # flip bits after the CRC was computed
                pkt = bytearray(pkt)
                pkt[6 + 1234] ^= 0x5A
                pkt = bytes(pkt)
                res.injected += 1
            inflight[seq] = (time.perf_counter(), lid, injected)
            link.write(pkt)
            res.sent += 1
            res.wire_bytes += len(pkt)
            more = time.perf_counter() < deadline and res.ok + len(inflight) < max_frames
        for r in link.poll(timeout=0.002):
            if r.kind not in "AN":
                continue
            entry = inflight.pop(r.seq, None)
            if entry is None:
                res.stray += 1
                continue
            t_sent, lid, injected = entry
            t_last = r.t
            if r.kind == "A":
                if injected:
                    res.undetected += 1        # corrupted frame was accepted: CRC check broken
                else:
                    res.ok += 1
                    res.lat.append(r.t - t_sent)
            else:
                reason = NAK_REASONS.get(r.flags, f"code{r.flags}")
                if injected and reason == "crc":
                    res.inj_detected += 1
                else:
                    res.naks[reason] += 1
                    if not injected:
                        retx_q.append(lid)
        now = time.perf_counter()
        for s, (t_sent, lid, injected) in list(inflight.items()):
            if now - t_sent > timeout:
                del inflight[s]
                res.timeouts += 1
                if not injected:
                    retx_q.append(lid)
    res.elapsed = max(t_last - t0, 1e-9)
    res.status = "ok"
    return res


def print_bench_table(results: list[BenchResult]):
    hdr = (f"{'baud':>10} {'wire max':>8} {'result':>8} {'frames':>6} {'fps':>6} {'eff%':>5} "
           f"{'payload':>9} {'crc':>4} {'busy':>4} {'tmo':>4} {'retx':>4} {'inject':>7} {'ack p50/p95 ms':>15}")
    print()
    print(hdr)
    print("-" * len(hdr))
    for r in results:
        if r.status != "ok":
            print(f"{r.baud:>10,} {theory_fps(r.baud):>8.1f} {r.status:>8}   {r.note}")
            continue
        verdict = "STABLE" if r.stable else "ERRORS"
        inj = f"{r.inj_detected}/{r.injected}" + ("!" if r.undetected else "")
        print(f"{r.baud:>10,} {theory_fps(r.baud):>8.1f} {verdict:>8} {r.ok:>6} {r.fps:>6.1f} "
              f"{100 * r.fps / theory_fps(r.baud):>5.0f} {r.ok * NPIX / r.elapsed / 1000:>7.1f}kB "
              f"{r.naks.get('crc', 0):>4} {r.naks.get('busy', 0):>4} {r.timeouts:>4} {r.retx:>4} "
              f"{inj:>7} {r.latency(0.5):>7.1f}/{r.latency(0.95):<7.1f}")
    print()
    print("wire max = 4808-byte packets at 10 bits/byte; fps = frames ACKed per second;")
    print("payload = verified pixel bytes/s; inject = deliberately corrupted frames caught by the CRC.")
    print(f"FPGA processing per frame: {FPGA_CYCLES_PER_FRAME} clocks = "
          f"{FPGA_CYCLES_PER_FRAME / FPGA_CLK_HZ * 1000:.2f} ms (overlaps with receiving the next frame).")


def run_bench(args):
    port = resolve_port(args.port)
    bauds = [int(b) for b in args.bauds.split(",")]
    link = FpgaLink(port, args.boot_baud)
    results: list[BenchResult] = []
    print(f"Benchmarking {port}: {args.seconds:g} s per rate, window {args.window}"
          + (f", corrupting every {args.inject_every}th frame on purpose" if args.inject_every else ""))
    try:
        for baud in bauds:
            print(f"--- {baud:,} baud ...", flush=True)
            res = bench_one(link, baud, args.seconds, args.window, args.inject_every, args.max_frames)
            results.append(res)
            if res.status == "ok":
                print(f"    {res.ok} frames OK in {res.elapsed:.2f} s = {res.fps:.1f} fps; "
                      f"crc {res.naks.get('crc', 0)}, timeouts {res.timeouts}, retx {res.retx}")
            else:
                print(f"    {res.status}: {res.note}")
            link.return_to_boot()
    except LinkError as e:
        print(f"stopped: {e}")
    except KeyboardInterrupt:
        print("interrupted")
    finally:
        try:
            link.return_to_boot()
        except LinkError:
            pass
        link.close()
    print_bench_table(results)
    stable = [r for r in results if r.stable]
    if stable:
        best = max(stable, key=lambda r: r.baud)
        print(f"Fastest verified stable rate: {best.baud:,} baud, {best.fps:.1f} fps measured.")
        print(f"Use it with:  py omni_collision.py stream --port {port} --baud {best.baud}")
        print("Run the bench a couple of times (and with --seconds 30) before trusting a rate for a demo.")
    else:
        print("No rate passed without errors. Check the cable/port, then try --bauds 115200,921600.")


# ----------------------------------------------------------------------------- hardware-in-the-loop verification
def send_and_wait(link: FpgaLink, seq: int, frame, timeout: float) -> Response | None:
    pkt = frame_packet(seq, frame.tobytes())
    for _ in range(3):
        link.write(pkt)
        deadline = time.perf_counter() + timeout
        while time.perf_counter() < deadline:
            for r in link.poll(timeout=0.01):
                if r.kind in "AN" and r.seq == seq:
                    if r.kind == "A":
                        return r
                    deadline = 0              # NAK: the FPGA did not process it, send again
                    break
        if deadline != 0:
            return None                         # no reply at all: state unknown
    return None


def run_verify(args):
    settings = settings_from_args(args)
    port = resolve_port(args.port)
    names = [n.strip() for n in args.scenarios.split(",") if n.strip()]
    link = FpgaLink(port, args.boot_baud)
    failed = 0
    try:
        link.negotiate(args.baud)
        link.apply_settings(settings)
        print(f"verifying on {port} at {link.baud:,} baud, K>{settings.k_threshold:,}, "
              f"F<{settings.f_max:,}, rise {settings.rise_frames}, ROI {settings.roi}")
        ref = LGMDReference(settings)
        timeout = max(0.5, 3 * FRAME_LEN * 10 / link.baud + 0.2)
        seq = 0
        for name in names:
            frames = scenario_frames(name)
            link.reset_lgmd()
            ref.reset()
            bad, fires_hw, fires_ref = 0, 0, 0
            for i, frame in enumerate(frames):
                seq = (seq + 1) & 0xFFFF
                r = send_and_wait(link, seq, frame, timeout)
                if r is None:
                    print(f"  {name}: frame {i} got no ACK, scenario aborted")
                    bad += 1
                    break
                exp = ref.step(frame)
                got = (r.w0, r.w1, r.fire, r.k_valid, r.f_suppressed, r.k_above, r.aux)
                want = (exp.k, exp.f, exp.fire, exp.k_valid, exp.f_supp, exp.k_above, exp.rise)
                fires_hw += r.fire
                fires_ref += exp.fire
                if got != want:
                    bad += 1
                    if bad <= 3:
                        print(f"  {name} frame {i}: FPGA K={r.w0} F={r.w1} fire={r.fire} rise={r.aux} | "
                              f"model K={exp.k} F={exp.f} fire={exp.fire} rise={exp.rise}")
            failed += bad
            print(f"{name:8s} {len(frames):3d} frames  mismatches {bad:3d}  "
                  f"fires FPGA {fires_hw} / model {fires_ref}  {'PASS' if bad == 0 else 'FAIL'}")
    except LinkError as e:
        print(f"link error: {e}")
        failed += 1
    finally:
        try:
            link.return_to_boot()
        except LinkError:
            pass
        link.close()
    print("ALL PASS: FPGA matches the Python model bit for bit." if failed == 0 else "VERIFY FAILED")
    sys.exit(0 if failed == 0 else 1)


# ----------------------------------------------------------------------------- offline self-test
SCENARIO_EXPECT = {"static": False, "expand": True, "slide": False, "flash": False, "shrink": False}


def run_scenario(name: str, settings: Settings):
    ref = LGMDReference(settings)
    return [ref.step(f) for f in scenario_frames(name)]


def run_selftest(args):
    np = need_numpy()
    settings = settings_from_args(args)
    failures: list[str] = []

    def check(ok: bool, what: str):
        print(("  ok    " if ok else "  FAIL  ") + what)
        if not ok:
            failures.append(what)

    print("protocol")
    check(crc16(b"123456789") == 0x29B1, "CRC-16/CCITT-FALSE check value 0x29B1")
    check(len(frame_packet(1, bytes(NPIX))) == FRAME_LEN == 4808, "frame packet is 4808 bytes")
    check(len(command_packet(1, CMD_PING)) == 14, "command packet is 14 bytes")
    a = response_packet("A", 7, 0x0B, 3, 123_456, 654_321)
    b = response_packet("R", 9, CMD_PING, 0, 2_000_000, 5)
    bad = bytearray(response_packet("N", 8, 1, 0, 0, 0))
    bad[10] ^= 1
    p = ResponseParser()
    got = p.feed(b"\x00\xffOM" + a + bytes(bad) + b[:7], 0.0) + p.feed(b[7:], 0.0)
    check([(r.kind, r.seq) for r in got] == [("A", 7), ("R", 9)], "reply parser resyncs and drops a bad CRC")
    check(got[0].fire and got[0].k_valid and got[0].k_above and got[0].w0 == 123_456, "ACK flag decoding")

    print("reference model vs. independent per-pixel loops")
    rng = np.random.default_rng(7)
    frames = [rng.integers(0, 256, (H, W)).astype(np.uint8) for _ in range(3)]
    frames += scenario_frames("expand")[8:11]
    ref = LGMDReference(settings)
    prev = np.zeros((H, W), np.int32)
    prev_p = np.zeros((H, W), np.int32)
    same = True
    for n, f in enumerate(frames):
        P, I, S = lgmd_naive(f, prev, prev_p, n)
        r = ref.step(f)
        same &= (np.array_equal(r.P, P) and np.array_equal(r.I, I) and np.array_equal(r.S, S)
                 and r.f == int(np.sum(P)) and r.k == int(np.sum(S)))
        prev, prev_p = f.astype(np.int32), np.array(P)
    check(same, "P, I, S, K, F identical on 6 frames (random + expanding), edges included")

    print(f"scenarios  (K > {settings.k_threshold:,}, F < {settings.f_max:,}, "
          f"rise {settings.rise_frames} frames, ROI {settings.roi})")
    print(f"  {'scenario':8s} {'frames':>6} {'max K':>9} {'max F':>9} {'fires':>5}  {'first':>5}  expected")
    for name, want_fire in SCENARIO_EXPECT.items():
        res = run_scenario(name, settings)
        fires = [i for i, r in enumerate(res) if r.fire]
        print(f"  {name:8s} {len(res):>6} {max(r.k for r in res):>9,} {max(r.f for r in res):>9,} "
              f"{len(fires):>5}  {fires[0] if fires else '-':>5}  {'fire' if want_fire else 'no fire'}")
        check(bool(fires) == want_fire, f"Test {'ABCDE'['static expand slide flash shrink'.split().index(name)]} "
                                        f"({name}): {'fires' if want_fire else 'no false alarm'}")
    no_fmax = Settings(**{**settings.__dict__, "f_max": 0xFFFFFF})
    check(any(r.fire for r in run_scenario("flash", no_fmax)),
          "Test D control: the brightness ramp WOULD fire without the F limit (so F did the suppressing)")

    print("expanding square, frame by frame")
    print(f"  {'frame':>5} {'K':>8} {'F':>8} {'rise':>4}  state")
    for i, r in enumerate(run_scenario("expand", settings)):
        state = "warm-up" if not r.k_valid else ("FIRE" if r.fire else "")
        print(f"  {i:>5} {r.k:>8,} {r.f:>8,} {r.rise:>4}  {state}")

    print()
    print(f"FPGA: {FPGA_CYCLES_PER_FRAME} clocks/frame = {FPGA_CYCLES_PER_FRAME / FPGA_CLK_HZ * 1e3:.2f} ms at 27 MHz")
    for b in BENCH_BAUDS:
        print(f"  {b:>9,} baud: {FRAME_LEN * 10 / b * 1e3:6.1f} ms on the wire per frame, "
              f"wire limit {theory_fps(b):5.1f} fps")
    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED")
        sys.exit(1)
    print("all self-tests passed")


# ----------------------------------------------------------------------------- misc commands
def run_ports(args):
    need_serial()
    from serial.tools import list_ports
    ports = sorted(list_ports.comports(), key=lambda p: p.device)
    if not ports:
        print("No COM ports. Use a USB-C data cable; check Device Manager > Ports (COM & LPT).")
    notes = {"uart": "<- Tang Nano 20K UART (FPGA pins 69/70): USE THIS ONE",
             "jtag": "<- Tang Nano 20K JTAG (Gowin Programmer uses it): not for data",
             "usb": "", "other": "(not USB, ignore)"}
    for p in ports:
        vidpid = f"{p.vid:04X}:{p.pid:04X}" if p.vid is not None else "---------"
        print(f"{p.device:6s} {vidpid}  {p.description[:34]:34s} {notes[classify_port(p)]}")

    uart = [p for p in ports if classify_port(p) == "uart"]
    if not uart:
        print("\nNo Tang Nano 20K found. Unplug/replug it and watch which ports appear.")
        return
    port = uart[0].device
    print(f"\nPinging {port} at {args.boot_baud:,} baud...")
    link = FpgaLink(port, args.boot_baud, log=lambda *_: None)
    try:
        link.open(args.boot_baud)
        r = link.ping(retries=2)
    except LinkError as e:
        print(f"  could not open {port}: {e}\n  (close any other program using it, e.g. a running stream)")
        return
    finally:
        link.close()
    if r is not None:
        print(f"  omni_collision.v answered: FPGA at {r.w0:,} baud, "
              f"{r.w1 & 0xFFFF} good / {r.w1 >> 16} bad frames since power-up.")
        print(f"  Use:  py omni_collision.py stream --port {port}")
    else:
        jtag = [p.device for p in ports if classify_port(p) == "jtag"]
        print("  no reply. Most likely the FPGA isn't running omni_collision.v yet: program it with "
              "the Gowin Programmer, then run this again.")
        if jtag:
            print(f"  If it still doesn't answer after programming, try --port {jtag[0]} "
                  "(the other channel).")


def parse_roi(text: str) -> tuple:
    try:
        x0, x1, y0, y1 = (int(v) for v in text.split(","))
    except ValueError:
        raise argparse.ArgumentTypeError("ROI is x0,x1,y0,y1 e.g. 20,59,15,44")
    if not (0 <= x0 <= x1 <= W - 1 and 0 <= y0 <= y1 <= H - 1):
        raise argparse.ArgumentTypeError(f"ROI must fit inside 0..{W - 1}, 0..{H - 1}")
    return x0, x1, y0, y1


def settings_from_args(args) -> Settings:
    return Settings(k_threshold=args.k_threshold, f_max=args.f_max, rise_frames=args.rise_frames,
                    rise_delta=args.rise_delta, roi=args.roi)


def main():
    ap = argparse.ArgumentParser(description="Omni Glasses webcam -> Tang Nano 20K LGMD collision detector")
    sub = ap.add_subparsers(dest="cmd")

    def common(p, baud_default=2_000_000, hw=True):
        if hw:
            p.add_argument("--port", default="auto", help="COM port, e.g. COM5 (default: auto if only one)")
            p.add_argument("--baud", type=int, default=baud_default, help="target baud rate")
            p.add_argument("--boot-baud", type=int, default=BOOT_BAUD, help="FPGA power-up baud (BOOT_BAUD)")
        p.add_argument("--k-threshold", type=int, default=DEFAULT_K_THRESHOLD, help="fire needs K above this")
        p.add_argument("--f-max", type=int, default=DEFAULT_F_MAX, help="fire needs F below this")
        p.add_argument("--rise-frames", type=int, default=DEFAULT_RISE_FRAMES, choices=range(1, 16),
                       metavar="1..15", help="consecutive rising-K frames needed")
        p.add_argument("--rise-delta", type=int, default=0, help="K must grow by more than this to count")
        p.add_argument("--roi", type=parse_roi, default=FULL_ROI, help="x0,x1,y0,y1 region used for K")

    p = sub.add_parser("stream", help="stream webcam (or synthetic) video to the FPGA")
    common(p)
    p.add_argument("--camera", type=int, default=0, help="webcam index")
    p.add_argument("--backend", choices=("dshow", "msmf", "any"), default="dshow", help="OpenCV camera backend")
    p.add_argument("--synthetic", choices=SCENARIOS, help="send a synthetic scenario instead of the webcam")
    p.add_argument("--synthetic-fps", type=float, default=30.0, help="synthetic frame rate (0 = link speed)")
    p.add_argument("--window", type=int, default=2, help="frames allowed un-ACKed (2 = FPGA buffers)")
    p.add_argument("--no-preview", action="store_true", help="no OpenCV window, console status only")
    p.add_argument("--duration", type=float, default=0, help="stop after this many seconds (0 = run)")
    p.set_defaults(func=run_stream)

    p = sub.add_parser("bench", help="measure real throughput at several baud rates")
    common(p)
    p.add_argument("--bauds", default=",".join(str(b) for b in BENCH_BAUDS), help="comma-separated list")
    p.add_argument("--seconds", type=float, default=6.0, help="test length per baud rate")
    p.add_argument("--max-frames", type=int, default=100_000, help="cap on frames per rate")
    p.add_argument("--window", type=int, default=2, help="frames allowed un-ACKed")
    p.add_argument("--inject-every", type=int, default=25, help="corrupt every Nth frame to test the CRC (0 = off)")
    p.set_defaults(func=run_bench)

    p = sub.add_parser("verify", help="check FPGA K/F/fire against the Python model, bit-exact")
    common(p)
    p.add_argument("--scenarios", default="static,expand,slide,flash,shrink,noise")
    p.set_defaults(func=run_verify)

    p = sub.add_parser("selftest", help="offline tests of protocol + reference model (no board)")
    common(p, hw=False)
    p.set_defaults(func=run_selftest)

    p = sub.add_parser("ports", help="list serial ports, find the board and ping the FPGA")
    p.add_argument("--boot-baud", type=int, default=BOOT_BAUD, help="FPGA power-up baud (BOOT_BAUD)")
    p.set_defaults(func=run_ports)

    args = ap.parse_args()
    if not args.cmd:
        ap.print_help()
        return
    args.func(args)


if __name__ == "__main__":
    main()
