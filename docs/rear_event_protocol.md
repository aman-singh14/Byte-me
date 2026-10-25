# Rear event protocol (FPGA → backend), version 1

This is the **only** coupling between the FPGA side (`fpga/`, owned by the FPGA
teammate) and the app side (`backend/`). Change it only by agreement, and bump
`VERSION` when the bytes change.

```
OV2640 ──► FPGA (Tang Nano 20K): LGMD in hardware + 3 s ring buffer
               │  on fire: EVENT, then the clip, then END
               ├─(a) USB-serial ─────────────────────────────► laptop backend
               └─(b) UART/SPI ─► ESP32 bridge ─ UDP / HTTP ──► laptop backend
                                                                 │ EVENT  → speak "Something approaching from behind" NOW
                                                                 │ clip   → YOLO + motion → "Bike approaching fast, on your left"
```

Reference implementation (encoder, decoder, stream parser, reassembly), pure Python:
`backend/rear/protocol.py`. Tests: `backend/tests/test_rear_protocol.py`. Test
sender: `tools/mock_fpga.py`.

## 1. Packet framing

Every packet has the same envelope. **All multi-byte fields are little-endian.**

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 2 | `SYNC` | `0xA5`, `0x5A` (in that byte order) |
| 2 | 1 | `VERSION` | `0x01` |
| 3 | 1 | `TYPE` | `0x01` EVENT, `0x02` FRAME_CHUNK, `0x03` END, `0x04` HEARTBEAT |
| 4 | 2 | `EVENT_ID` | u16. Same for every packet of one event; +1 per event, wraps at 65535 |
| 6 | 2 | `SEQ` | u16. Packet number within the event: EVENT = 0, then 1, 2, … END is last |
| 8 | 2 | `LEN` | u16. Payload length in bytes, ≤ 1280 |
| 10 | `LEN` | `PAYLOAD` | see below |
| 10+`LEN` | 2 | `CRC16` | over bytes 2 … 9+`LEN` (`VERSION` through the end of `PAYLOAD`) |

Packet size = 12 + `LEN` bytes.

**CRC16** is CRC-16/CCITT-FALSE: polynomial `0x1021`, initial value `0xFFFF`, no
input/output reflection, no final XOR. Check value: CRC of ASCII `"123456789"` = `0x29B1`.

```c
uint16_t crc16(const uint8_t *p, size_t n, uint16_t crc /* 0xFFFF to start */) {
  while (n--) {
    crc ^= (uint16_t)(*p++) << 8;
    for (int i = 0; i < 8; i++) crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1;
  }
  return crc;
}
```

(In hardware: the usual 16-bit LFSR, MSB first, one byte per clock with an 8-step unrolled update.)

**Receiver rules** (what the backend does, so the sender knows what is tolerated):

- Scan for `A5 5A`. A packet is accepted only if `VERSION` = 1, `TYPE` is known,
  `LEN` ≤ 1280 and the CRC matches. Otherwise it is dropped and scanning restarts
  one byte after that `SYNC`. One corrupt packet never costs more than itself.
- Packets of an event must arrive in `SEQ` order. Gaps are counted as dropped packets.
- FRAME_CHUNK / END packets whose `EVENT_ID` does not match the current EVENT are ignored.
- A new EVENT closes any unfinished clip (it is classified with whatever arrived).

## 2. Packet types

### 0x01 EVENT: 32-byte payload, sent the moment LGMD fires

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | `t_ms` | u32, FPGA clock in ms since power-on (for logs and latency measurement) |
| 4 | 4 | `k_peak` | u32, LGMD potential K at the fire (u21 range, as in `lgmd.py`) |
| 8 | 4 | `k_left` | u32, K over the **image** left third (0 if not computed) |
| 12 | 4 | `k_center` | u32, K over the image center third |
| 16 | 4 | `k_right` | u32, K over the image right third |
| 20 | 2 | `width` | u16, clip frame width in pixels (default 160) |
| 22 | 2 | `height` | u16, clip frame height (default 120) |
| 24 | 2 | `frame_count` | u16, number of frames that follow (default 30 = 3 s at 10 fps) |
| 26 | 2 | `trigger_index` | u16, index of the frame on which LGMD fired (default 29: the last one) |
| 28 | 1 | `fps` | u8, clip frame rate (default 10) |
| 29 | 1 | `pixel_format` | u8, `0` = GRAY8 (default), `1` = JPEG |
| 30 | 1 | `region` | u8, dominant region in **image** columns: `0` unknown, `1` left, `2` center, `3` right |
| 31 | 1 | `flags` | u8, bit 0 = a clip follows (`0x01`). `0x00` = event only, no clip |

**Sides:** `region` and `k_left/center/right` are **image** columns, exactly like
`lgmd.py` (columns 0–26 / 27–52 / 53–79 at 80×60; scale proportionally for other sizes).
The rear camera faces backward, so the **backend** flips image-left to the wearer's
right. The FPGA never flips.

### 0x02 FRAME_CHUNK: 10-byte header + up to 1024 data bytes

Frames are split into chunks so every packet fits in one UDP datagram.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 2 | `frame_index` | u16, 0 … `frame_count`−1, oldest frame first |
| 2 | 2 | `chunk_index` | u16, 0 … `chunk_count`−1 |
| 4 | 2 | `chunk_count` | u16, chunks in this frame |
| 6 | 4 | `frame_size` | u32, total bytes of this frame |
| 10 | n | `data` | 1 … 1024 bytes |

- **GRAY8:** `frame_size` = `width × height`, row-major (row 0 first, column 0 first
  in a row), one byte per pixel, the same layout as `frames.bin` from `lgmd.py --export`.
  160×120 = 19,200 bytes = 18 chunks of 1024 + 1 of 768.
- **JPEG:** `frame_size` is that frame's JPEG length. Chunk it the same way.
- Send frames in order, and the chunks of a frame in order.

### 0x03 END: 6-byte payload

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 2 | `frames_sent` | u16 |
| 2 | 2 | `clip_crc` | u16, CRC16 (same algorithm, init `0xFFFF`) over every frame's bytes concatenated in frame order. Chunk headers are not included |
| 4 | 1 | `status` | u8, `0` ok, `1` truncated (ring buffer overwritten), `2` aborted |
| 5 | 1 | reserved | `0` |

### 0x04 HEARTBEAT: 8-byte payload, about once per second (optional, recommended)

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 4 | `t_ms` | u32 |
| 4 | 1 | `status` | bit 0 = camera ok, bit 1 = LGMD armed |
| 5 | 3 | reserved | `0` |

Use `EVENT_ID` = 0 and `SEQ` = 0. The dashboard shows "REAR (FPGA) online" while
heartbeats arrive.

## 3. Sequence and latency

```
t=0      LGMD fires on frame 29          FPGA sends EVENT (SEQ 0)          ≤ 1 frame (100 ms) after the fire
         backend receives EVENT          speaks "Something approaching      ≤ 100 ms, before any frame arrives
                                          from behind"
         FRAME_CHUNK × 30·19 (SEQ 1…570)  the ring buffer, oldest first
         END (SEQ 571)                    backend checks clip_crc, classifies, speaks the specific result
```

**Latency rule:** the backend speaks the generic warning as soon as a valid EVENT
arrives, **before** the clip finishes and before any classification. The specific
follow-up ("Car approaching fast, on your left", or "Never mind, nothing dangerous")
comes after END, or after a timeout (no packet for 1 s, or 10 s total) with whatever
frames arrived.

**Throughput.** A default clip is 30 × 19,200 = 576,000 bytes, or 588,602 bytes with
framing. The warning is instant either way. Link speed only decides how long the
follow-up takes:

| Link | Payload rate | Default clip (160×120 GRAY8 ×30) | 80×60 GRAY8 ×30 |
|---|---|---|---|
| UART 921,600 baud (8N1) | ~92 KB/s | ~6.4 s | ~1.6 s |
| UART 2,000,000 baud | ~200 KB/s | ~2.9 s | ~0.8 s |
| UART 3,000,000 baud | ~300 KB/s | ~2.0 s | ~0.5 s |
| SPI → ESP32 → Wi-Fi UDP | ~1 MB/s | ~0.6 s | ~0.2 s |

Recommendation: use the fastest stable link. Over a slow UART, send 80×60 (the LGMD
resolution) or fewer frames. Note that YOLO on a 160×120 grayscale image reliably
names only close or large objects (a person or a car a few meters away), not distant ones.

## 4. Transports

All three carry the same packets, byte for byte. The backend can run any of them
(`rear.transport` in `backend/config.yaml`).

### (a) USB-serial: FPGA → laptop

- Raw packet stream, 8N1, no flow control. Default 921,600 baud (configurable;
  faster is better, see the table).
- No delimiters besides `SYNC`. The backend's stream parser handles arbitrary
  read boundaries and resynchronises after garbage.

### (b) UDP: ESP32 bridge → laptop

- The bridge reads packets from the FPGA over UART or SPI and forwards them
  **unchanged** to the laptop, UDP port **4300**.
- Recommended: one packet per datagram (a FRAME_CHUNK is at most 1,046 bytes, under
  the Wi-Fi MTU). The backend also accepts several packets in one datagram, or a
  packet split across datagrams, from the same sender.
- The bridge needs the laptop's address: configure its IP or mDNS name
  (`<laptop-name>.local`).

### (c) HTTP: ESP32 bridge → laptop

- `POST http://<laptop>:8001/rear/packets` with `Content-Type: application/octet-stream`.
  The body is one or more packets concatenated.
- POST the EVENT **by itself first** (so the warning is not delayed), then the clip
  packets in one or more POSTs.
- Response: `200 {"accepted": n, "errors": m}`.

## 5. Worked examples (hex, exactly as on the wire)

EVENT, `EVENT_ID` 7: `t_ms` = 123456, `k_peak` = 22600, K left/center/right = 1000 /
20600 / 1000, 160×120, 30 frames, trigger 29, 10 fps, GRAY8, region center, clip follows:

```
a5 5a | 01 | 01 | 07 00 | 00 00 | 20 00 |
40 e2 01 00  48 58 00 00  e8 03 00 00  78 50 00 00  e8 03 00 00 |
a0 00  78 00  1e 00  1d 00  0a  00  02  01 |
02 33                                                    ← CRC16 = 0x3302
```

First FRAME_CHUNK of that event (`SEQ` 1, frame 0, chunk 0 of 19, `frame_size`
19200), shown with only 8 data bytes `00 01 … 07` so it fits:

```
a5 5a | 01 | 02 | 07 00 | 01 00 | 12 00 | 00 00  00 00  13 00  00 4b 00 00 | 00 01 02 03 04 05 06 07 | e5 0c
```

END (`SEQ` 571, 30 frames, `clip_crc` 0x1234, status ok):

```
a5 5a | 01 | 03 | 07 00 | 3b 02 | 06 00 | 1e 00  34 12  00  00 | 6a 54
```

HEARTBEAT (`t_ms` 5000, camera ok + LGMD armed):

```
a5 5a | 01 | 04 | 00 00 | 00 00 | 08 00 | 88 13 00 00  03  00 00 00 | a9 84
```

`backend/tests/test_rear_protocol.py` checks the EVENT bytes above against the encoder.

## 6. Checking your side

- **Bit-exact LGMD:** the hardware must match `lgmd.py`. `python lgmd.py --export CLIP --out DIR`
  writes `frames.bin` + `expected.csv`, and the C port shows how to check against them
  (`firmware/lgmd_c/check_vectors.c`).
- **Protocol:** capture what the FPGA sends (serial: `cat /dev/tty.usbserial-* > cap.bin`)
  and decode it with `backend/rear/protocol.py` (`StreamParser().feed(open("cap.bin","rb").read())`).
- **Without the FPGA:** `python tools/mock_fpga.py` sends correct EVENT + clip packets
  from a synthetic looming sequence or a video file, over UDP or a virtual serial port.
