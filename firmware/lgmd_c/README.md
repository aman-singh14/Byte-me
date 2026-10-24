# LGMD in C (ESP32 port)

`lgmd.c` is a line-for-line port of `lgmd_step()` in `../../lgmd.py`: integer only,
no malloc, about 14 KB of state (two frames plus ping-pong P buffers).
`check_vectors.c` replays `frames.bin` and compares every row of `expected.csv`.

```bash
sh firmware/lgmd_c/check_all.sh          # from the repo root
```

Status: bit-exact on all five synthetic clips, on a random-noise clip, and with
non-default parameters (`--w-shift 3 --p-min 0 --n-rise 1`). Exit code 1 on any mismatch.

To use it on the rear ESP32-CAM: copy `lgmd.h` and `lgmd.c` next to the sketch,
capture in `PIXFORMAT_GRAYSCALE` at `FRAMESIZE_QQVGA` (160x120), average 2x2 blocks
down to 80x60, and call `lgmd_step` per frame. The on-board downscale does not have
to match OpenCV's `INTER_AREA`. The contract starts at the 80x60 frames. The Verilog
port for the Tang Nano 20K is not written yet.
