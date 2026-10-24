# fpga/: rear collision detector in hardware

**Owner: the FPGA teammate.** This folder is theirs. The rest of the team does not
write or change anything in `fpga/`. The app side only depends on the protocol below.

## What it does

The REAR camera (OV2640) is wired to a **Sipeed Tang Nano 20K**. The FPGA:

1. reads the camera and reduces each frame for LGMD (80×60 grayscale, as in `lgmd.py`);
2. runs the LGMD / locust looming detector in hardware, every frame;
3. keeps a ring buffer of the last 3 seconds of video (default 160×120 GRAY8, 10 fps, 30 frames);
4. when LGMD fires, immediately sends an **EVENT**, then the buffered **clip**, then **END**
   to the laptop backend.

The backend speaks a generic warning the moment EVENT arrives, then runs YOLO and
motion analysis on the clip to say what it is and whether it is dangerous. The FPGA
is completely separate from the EYE and FRONT cameras (those are ESP32-CAMs that
stream straight to the backend).

## How it connects

```
OV2640 ─► Tang Nano 20K ─┬─ (a) USB-serial ───────────────────────► laptop backend (backend/rear/)
                         └─ (b) UART/SPI ─► ESP32 bridge ─ UDP/HTTP ─► laptop backend
```

**The interface contract is [`docs/rear_event_protocol.md`](../docs/rear_event_protocol.md)**
(framing, byte tables, CRC16, sequence, latency rule, transports, hex examples).
It is the only coupling between this folder and the app side.

## References (outside this folder, do not move)

- **Bit-exact LGMD reference:** `../lgmd.py`. The hardware must produce the same
  `K`, `K_L/K_C/K_R`, `F` and `fire` per frame as `lgmd.py`, given the same 80×60
  frames. Generate test vectors with
  `python lgmd.py --export CLIP --out DIR` (writes `frames.bin`, `expected.csv`,
  `params.json`); `python lgmd.py --synth DIR` writes synthetic clips to export.
  The README at the repo root documents the model and every bit width.
- **C port + checker:** `../firmware/lgmd_c/`, a line-for-line integer port that
  matches `expected.csv` bit for bit (`sh firmware/lgmd_c/check_all.sh`). It is a
  readable stepping stone toward RTL.
- **Protocol reference code:** `../backend/rear/protocol.py` (encoder/decoder, CRC16,
  stream parser) for checking captures from the board.
- **Test sender:** `../tools/mock_fpga.py` emits protocol-correct packets so the app
  side can run without the board.

## Layout

| Folder | For |
|---|---|
| `rtl/` | Verilog/SystemVerilog sources |
| `constraints/` | Tang Nano 20K pin constraints (`.cst`), timing (`.sdc`) |
| `sim/` | testbenches, `expected.csv` comparisons |
| `bridge/` | optional ESP32 UART/SPI → UDP/HTTP bridge firmware |
