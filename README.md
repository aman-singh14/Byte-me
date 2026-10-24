# Byte-me: LGMD collision detector

Python reference model of a locust-inspired collision detector (LGMD, lobula
giant movement detector) for a wearable that warns about objects approaching
from behind. The math is integer only so it can be ported exactly to C on an
ESP32-CAM and to Verilog on an FPGA. `expected.csv` (from `--export`) is the
contract that all three versions must match bit for bit.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

On macOS the terminal app needs camera permission (System Settings > Privacy &
Security > Camera) for live mode.

## Usage

| Command | What it does |
|---|---|
| `python lgmd.py` | Live view from camera 0 (`--camera 1` or a stream URL for others) |
| `python lgmd.py --clip rec.npz` | Replay a recording (or any video file) frame by frame |
| `python lgmd.py --export rec.npz --out vectors` | Write test vectors for the C and Verilog ports |
| `python lgmd.py --eval clips/ -v` | Fire rate per label on labeled clips |
| `python lgmd.py --synth synth/` | Write the synthetic test clips as .npz |
| `python -m unittest -v test_lgmd` | Unit tests |

Parameters can be set in any mode: `--k-thresh 3000 --f-max 80000 --w-shift 1
--n-rise 3 --p-min 10`.

**Keys.** Live: `r` start/stop recording, `m` flip sides, `q` quit. Replay:
`space` pause, `n` step forward, `b` step back, `0` restart, `m` flip sides, `q`
quit. Stepping back recomputes from frame 0 with the current parameters, because
the state depends on history.

**Live view.** Shows the frame, P and S side by side at 8x (`--scale` to change),
a K bar and an F bar with their threshold lines, K per side, and a FIRE box with
the dominant side. The FIRE box stays lit for 8 frames so you can see it; that
hold is display only and is not part of the model.

**Sides.** The camera faces backward, so image-left is the wearer's right. The
view reports sides as the wearer feels them. Use `--no-flip` (or `m`) when the
camera faces forward, for example when testing at a desk. K_L/K_C/K_R in the CSV
are always image columns; the flip only changes the display.

**Trackbars.** K_THRESH (in steps of 100), F_MAX (in steps of 1000; the top of
the slider, 1,300,000, is above the largest possible F, so it disables the
gate), W_SHIFT, N_RISE, P_MIN. They change the running model at once.

**Recording.** `r` saves the 80x60 frames that were actually processed to
`recordings/rec_YYYYmmdd_HHMMSS.npz` (`frames`: N x 60 x 80 uint8, `fps`). The
capture thread keeps only the newest camera frame, so frames the model never saw
are not recorded either. A replay therefore reproduces the live run exactly.

## The model

Per 80x60 uint8 grayscale frame:

```
P    = |cur - prev|, set to 0 where P < P_MIN        excitation
I    = (sum of the 8 neighbors of prev_P) >> 3      lateral inhibition (one frame late)
S    = max(P - (I >> W_SHIFT), 0)                   summing layer
K    = sum(S);  K_L, K_C, K_R over column thirds    LGMD potential
F    = sum(P)                                       whole-scene change
rise = (K > prev_K) ? min(rise + 1, 15) : 0
fire = K > K_THRESH and F < F_MAX and rise >= N_RISE
```

Neighbors outside the frame count as 0. Column thirds: left 0..26, center
27..52, right 53..79 (27/26/27 wide). Reset state: `prev` = first frame,
`prev_P` = 0, `prev_K` = 0, `rise` = 0, so frame 0 always gives P = 0 and K = 0.

"K increased for N_RISE frames in a row" is kept as a 4-bit saturating counter
of consecutive increases instead of a buffer of past K values. `rise >= N` holds
exactly when the last N steps were all increases. You only need `prev_K` and the
counter, and N_RISE can change at run time without resizing anything.

### Bit widths

| Signal | Width | Range | Why |
|---|---|---|---|
| cur, prev | u8 | 0..255 | pixels |
| cur - prev | s9 | -255..255 | before abs |
| P, prev_P | u8 | 0..255 | |
| 8-neighbor sum | u11 | 0..2040 | 8 x 255 |
| I, I >> W_SHIFT | u8 | 0..255 | |
| P - (I >> W_SHIFT) | s9 | -255..255 | before clamp |
| S | u8 | 0..255 | |
| K_L, K_R | u19 | 0..413,100 | 27 x 60 x 255 |
| K_C | u19 | 0..397,800 | 26 x 60 x 255 |
| K, F, prev_K | u21 | 0..1,224,000 | 4800 x 255 < 2^21 |
| rise | u4 | 0..15 | saturating |
| P_MIN / W_SHIFT / N_RISE | u8 / u3 / u4 | 0..255 / 0..7 / 0..15 | |
| K_THRESH, F_MAX | u21 | 0..2,097,151 | |

State memory: 4800 bytes for `prev` and 4800 bytes for `prev_P`.

### Defaults

`P_MIN=10, W_SHIFT=1, K_THRESH=3000, F_MAX=80000, N_RISE=3`. These were chosen
so the synthetic tests behave as intended. They are starting points for tuning
on real clips, not tuned values.

## Test vectors for the ports

`--export CLIP --out DIR` writes:

- `frames.bin`: the frames back to back, 4800 bytes each, row-major (row 0
  first, column 0 first within a row).
- `expected.csv`: `frame,sum_P,K,K_L,K_C,K_R,F,fire`, one row per frame,
  starting at frame 0. `sum_P` and `F` are both sum(P) after the noise floor,
  so the two columns are always equal.
- `params.json`: the parameters and geometry the CSV was made with.

The bit-exact check starts at `frames.bin`, after resizing. The ESP32 and FPGA
do not have to copy OpenCV's resize. They have to produce the same CSV from the
same frames.

Porting notes:

- Use unsigned integers for P and S and signed integers for the two
  subtractions. All right shifts are on non-negative values, so arithmetic and
  logical shifts give the same result.
- I reads the previous frame's P, while the current frame's P is being written.
  Use two P buffers (ping-pong) or write P to a different buffer than the one
  you read I from. On the FPGA, a streaming design needs a 3-line window over
  the stored `prev_P`.
- K, F and the thirds are 21-bit accumulators (`uint32_t` in C, `[20:0]` in
  Verilog). The comparisons are strict: `K > K_THRESH`, `F < F_MAX`,
  `K > prev_K`.
- `test_lgmd.reference_step` spells the model as per-pixel loops, close to how
  the C version will look. A test checks it against the vectorized
  `lgmd_step`.

## Evaluation

Put clips under a directory, labeled either by subdirectory or by filename
prefix:

```
clips/approach/bike_01.npz      or   clips/approach_bike_01.npz
clips/sideways/...                   clips/sideways_02.mp4
clips/recede/  clips/head-turn/  clips/walking/
```

`--eval clips/` reports, per label: the number of clips, how many fired at least
once, the fire rate, the mean number of firing frames per clip, and for
approaches the median lead time (frames from the first fire to the end of the
clip, divided by fps). The lead time assumes each approach clip ends at the
closest point. Targets: approach >= 90%, every other label <= 10%. The exit code
is 1 if any target is missed.

## Unit tests

Synthetic clips (`--synth` writes them out):

- **approach**: a centered square growing like 1/distance. Must fire before the
  last frame. It fires on frames 18-20; on frame 21 F goes over F_MAX.
- **sideways**: a constant-size square sliding right. K stays flat above
  K_THRESH, so the rise test is what keeps it from firing.
- **recede**: the approach played backward. Must not fire.
- **brightness jump**: the whole scene +80 in one frame. Must not fire.
- **brightness ramp**: the whole scene brightening in growing steps, so K rises
  3 frames in a row. Must not fire with F_MAX on, and must fire with F_MAX off,
  which proves the F_MAX gate is what suppresses it.

There are also tests for agreement with the per-pixel reference on random
frames, the maximum values against the bit widths, zero padding at the edges,
the noise floor, purity, rise-counter saturation, and an export round trip.

## Known limits

- The model has only been tested on synthetic clips. The defaults have not been
  tuned on real footage.
- With noisy real input, K can rise 3 frames in a row by chance. If sideways or
  walking clips fire too often, raise N_RISE or K_THRESH first.
- A very close object changes most of the frame, so F_MAX also silences the
  last frames of a real approach. The warning has to come earlier, which is how
  the synthetic approach behaves.
