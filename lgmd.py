#!/usr/bin/env python3
"""LGMD (locust lobula giant movement detector) reference model.

Integer-only collision detector for a wearable with a rear-facing camera. The
core, lgmd_step(), is written to be ported line for line to C (ESP32-CAM) and
Verilog (FPGA); expected.csv from --export is the bit-exact contract between
the three versions.

Per frame (80x60 uint8 grayscale):

    P    = |cur - prev|, zeroed where < P_MIN       excitation
    I    = (sum of 8 neighbors of prev_P) >> 3      lateral inhibition, 1 frame late
    S    = max(P - (I >> W_SHIFT), 0)               summing layer
    K    = sum(S); K_L, K_C, K_R per column third   LGMD potential
    F    = sum(P)                                   whole-scene change
    fire = K > K_THRESH and F < F_MAX and K rose on each of the last N_RISE frames

Bit widths (unsigned unless marked s; NumPy dtype used here in brackets):

    cur, prev              u8   0..255       [uint8]
    cur - prev             s9   -255..255    [int16]
    P, prev_P              u8   0..255       [int16 working, uint8 in state]
    8-neighbor sum         u11  0..2040      [int16]  8 * 255
    I, I >> W_SHIFT        u8   0..255       [int16]
    P - (I >> W_SHIFT)     s9   -255..255    [int16]
    S                      u8   0..255       [int16]
    K_L, K_R               u19  0..413100    [int32]  27 cols * 60 rows * 255
    K_C                    u19  0..397800    [int32]  26 cols * 60 rows * 255
    K, F, prev_K           u21  0..1224000   [int32]  4800 * 255 < 2^21
    rise                   u4   0..15        saturating counter
    P_MIN u8, W_SHIFT u3 (0..7), K_THRESH u21, F_MAX u21, N_RISE u4 (0..15)

Column thirds: left = columns 0..26, center = 27..52, right = 53..79. These are
image columns; mapping to the wearer's left/right happens only in the display.
"""

import argparse
import csv
import json
import sys
import threading
import time
from dataclasses import asdict, dataclass, fields
from pathlib import Path
from typing import NamedTuple

import cv2
import numpy as np

W, H = 80, 60
NPIX = W * H
COL_L_END = 27     # left third:   columns  0..26 (27 wide)
COL_R_START = 53   # center third: columns 27..52 (26 wide); right: 53..79 (27 wide)
RISE_SAT = 15      # rise counter saturates at 15 (4 bits), so N_RISE <= 15
U21_MAX = (1 << 21) - 1


# ---------------------------------------------------------------------------
# Core model (integer only, no OpenCV)
# ---------------------------------------------------------------------------

@dataclass
class Params:
    p_min: int = 10        # noise floor on P                       u8
    w_shift: int = 1       # inhibition weight W = 2^-W_SHIFT        u3
    k_thresh: int = 3000   # fire needs K > K_THRESH                 u21
    f_max: int = 80000     # fire needs F < F_MAX                    u21
    n_rise: int = 3        # fire needs this many K increases in a row  u4

    def check(self):
        limits = {"p_min": 255, "w_shift": 7, "k_thresh": U21_MAX,
                  "f_max": U21_MAX, "n_rise": RISE_SAT}
        for name, top in limits.items():
            v = getattr(self, name)
            if not (isinstance(v, int) and 0 <= v <= top):
                raise ValueError(f"{name} = {v!r}, must be an int in 0..{top}")


class State(NamedTuple):
    prev: np.ndarray     # (H, W) uint8  previous frame
    prev_P: np.ndarray   # (H, W) uint8  previous excitation
    prev_K: int          # u21           previous K
    rise: int            # u4            frames in a row with K > prev_K, saturating


class Outputs(NamedTuple):
    P: np.ndarray        # (H, W) int16, values 0..255
    S: np.ndarray        # (H, W) int16, values 0..255
    K: int
    K_L: int
    K_C: int
    K_R: int
    F: int
    rise: int
    fire: bool


def check_frame(frame):
    if frame.dtype != np.uint8 or frame.shape != (H, W):
        raise ValueError(f"expected ({H}, {W}) uint8 frame, got {frame.shape} {frame.dtype}")


def init_state(first):
    """Reset: prev = first frame, so the first lgmd_step gives P = 0 and K = 0."""
    check_frame(first)
    return State(first.copy(), np.zeros((H, W), np.uint8), 0, 0)


def lgmd_step(cur, state, params):
    """Advance one frame. Pure (inputs are not modified), integer math only.

    Returns (new_state, outputs).
    """
    check_frame(cur)

    # P: u8 excitation. The s9 difference needs int16.
    P = np.abs(cur.astype(np.int16) - state.prev.astype(np.int16))
    P[P < params.p_min] = 0

    # I: 8-neighbor sum of prev_P with zero padding (u11), >> 3 gives u8.
    pad = np.zeros((H + 2, W + 2), np.int16)
    pad[1:-1, 1:-1] = state.prev_P
    nsum = (pad[:-2, :-2] + pad[:-2, 1:-1] + pad[:-2, 2:]
            + pad[1:-1, :-2] + pad[1:-1, 2:]
            + pad[2:, :-2] + pad[2:, 1:-1] + pad[2:, 2:])
    I = nsum >> 3

    # S: u8, excitation minus weighted inhibition, clamped at 0.
    S = np.maximum(P - (I >> params.w_shift), 0)

    K_L = int(S[:, :COL_L_END].sum(dtype=np.int32))
    K_C = int(S[:, COL_L_END:COL_R_START].sum(dtype=np.int32))
    K_R = int(S[:, COL_R_START:].sum(dtype=np.int32))
    K = K_L + K_C + K_R
    F = int(P.sum(dtype=np.int32))

    # A saturating counter of consecutive increases stands in for a K history:
    # rise >= N means the last N steps were all increases.
    rise = min(state.rise + 1, RISE_SAT) if K > state.prev_K else 0
    fire = K > params.k_thresh and F < params.f_max and rise >= params.n_rise

    new_state = State(cur.copy(), P.astype(np.uint8), K, rise)
    return new_state, Outputs(P, S, K, K_L, K_C, K_R, F, rise, fire)


def run_clip(frames, params):
    """Yield Outputs for every frame of a clip, starting from a reset state."""
    state = init_state(frames[0])
    for cur in frames:
        state, out = lgmd_step(cur, state, params)
        yield out


# ---------------------------------------------------------------------------
# Capture and clips
# ---------------------------------------------------------------------------

def preprocess(img):
    """Camera frame -> 80x60 uint8 grayscale."""
    gray = img if img.ndim == 2 else cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    return cv2.resize(gray, (W, H), interpolation=cv2.INTER_AREA)


class LatestFrameReader:
    """Reads a camera in a thread and keeps only the newest preprocessed frame."""

    def __init__(self, src):
        self.cap = cv2.VideoCapture(src)
        if not self.cap.isOpened():
            raise SystemExit(f"cannot open camera {src!r}")
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        self.alive = True
        self._cond = threading.Condition()
        self._frame = None
        self._seq = 0
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        failures = 0
        while self.alive:
            ok, img = self.cap.read()
            if not ok:
                failures += 1
                if failures > 100:
                    break
                time.sleep(0.01)
                continue
            failures = 0
            small = preprocess(img)
            with self._cond:
                self._frame = small
                self._seq += 1
                self._cond.notify_all()
        with self._cond:
            self.alive = False
            self._cond.notify_all()

    def read(self, last_seq, timeout=1.0):
        """Wait for a frame newer than last_seq. Returns (seq, frame)."""
        with self._cond:
            self._cond.wait_for(lambda: self._seq != last_seq or not self.alive, timeout)
            return self._seq, self._frame

    def close(self):
        self.alive = False
        self._thread.join(timeout=1.0)
        self.cap.release()


def load_clip(path):
    """Return (frames (N, 60, 80) uint8, fps) from a .npz recording or a video file."""
    path = Path(path)
    if path.suffix.lower() == ".npz":
        with np.load(path) as z:
            frames = z["frames"]
            fps = float(z["fps"]) if "fps" in z.files else 30.0
    else:
        cap = cv2.VideoCapture(str(path))
        if not cap.isOpened():
            raise SystemExit(f"cannot open clip {path}")
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        frames = []
        while True:
            ok, img = cap.read()
            if not ok:
                break
            frames.append(preprocess(img))
        cap.release()
        frames = np.stack(frames) if frames else np.zeros((0, H, W), np.uint8)
    if frames.ndim != 3 or frames.shape[1:] != (H, W) or frames.dtype != np.uint8:
        raise SystemExit(f"{path}: expected (N, {H}, {W}) uint8 frames, got {frames.shape} {frames.dtype}")
    if len(frames) == 0:
        raise SystemExit(f"{path}: no frames")
    return frames, fps


def save_clip(path, frames, fps):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(path, frames=np.stack(frames).astype(np.uint8), fps=np.float64(fps))


# ---------------------------------------------------------------------------
# Synthetic clips (unit tests and hardware test vectors)
# ---------------------------------------------------------------------------

BG, FG = 60, 200


def synth_approach(n=22, h0=3, t_hit=24):
    """Centered square whose half-size grows like 1/distance (looming)."""
    frames = np.full((n, H, W), BG, np.uint8)
    for t in range(n):
        h = h0 * t_hit // (t_hit - t)
        frames[t, max(H // 2 - h, 0):H // 2 + h, max(W // 2 - h, 0):W // 2 + h] = FG
    return frames


def synth_recede(n=22):
    """The approach played backward: a shrinking square."""
    return synth_approach(n)[::-1].copy()


def synth_sideways(n=25, h=8, x0=15, v=2):
    """Square of constant size sliding right at v pixels per frame."""
    frames = np.full((n, H, W), BG, np.uint8)
    for t in range(n):
        cx = x0 + v * t
        frames[t, H // 2 - h:H // 2 + h, cx - h:cx + h] = FG
    return frames


def _scene():
    """Static textured background, values 40..74."""
    return (np.add.outer(np.arange(H), np.arange(W)) // 4 + 40).astype(np.uint8)


def synth_brightness_jump(n=20, t_jump=10, delta=80):
    """Whole scene brightens by delta in one frame (lights on, exposure change)."""
    offsets = [0] * t_jump + [delta] * (n - t_jump)
    return np.stack([_scene() + np.uint8(o) for o in offsets])


def synth_brightness_ramp():
    """Whole scene brightens in growing steps (12, 24, 48, 96), so K rises for
    several frames in a row and only F_MAX can suppress it."""
    offsets = [0] * 8 + [12, 36, 84, 180] + [180] * 4
    return np.stack([_scene() + np.uint8(o) for o in offsets])


SYNTH_CLIPS = {
    "approach_synth": synth_approach,
    "recede_synth": synth_recede,
    "sideways_synth": synth_sideways,
    "brightness_jump": synth_brightness_jump,
    "brightness_ramp": synth_brightness_ramp,
}


# ---------------------------------------------------------------------------
# Test vector export
# ---------------------------------------------------------------------------

CSV_COLUMNS = ("frame", "sum_P", "K", "K_L", "K_C", "K_R", "F", "fire")


def export_vectors(frames, params, out_dir):
    """Write frames.bin, expected.csv and params.json for bit-exact checks.

    frames.bin: N frames of 4800 bytes, row-major (row 0 first, column 0 first).
    expected.csv: one row per frame. sum_P and F are both sum(P) after the
    noise floor; the column is kept so the format matches the spec.
    """
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    np.ascontiguousarray(frames, dtype=np.uint8).tofile(out / "frames.bin")
    with open(out / "expected.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(CSV_COLUMNS)
        for i, o in enumerate(run_clip(frames, params)):
            w.writerow((i, o.F, o.K, o.K_L, o.K_C, o.K_R, o.F, int(o.fire)))
    meta = {name.upper(): v for name, v in asdict(params).items()}
    meta.update(WIDTH=W, HEIGHT=H, COL_L_END=COL_L_END, COL_R_START=COL_R_START,
                RISE_SAT=RISE_SAT, FRAMES=len(frames))
    (out / "params.json").write_text(json.dumps(meta, indent=2) + "\n")
    return out


# ---------------------------------------------------------------------------
# Evaluation on labeled clips
# ---------------------------------------------------------------------------

LABELS = ("approach", "sideways", "recede", "head-turn", "walking")
CLIP_EXTS = {".npz", ".mp4", ".avi", ".mov", ".mkv", ".m4v"}
APPROACH_TARGET = 0.9   # fire on at least 9 of 10 approaches
OTHER_LIMIT = 0.1       # "rarely" on everything else


def label_of(path, root):
    """Label from the first directory under root (approach/x.npz) or the
    filename prefix before '_' (approach_01.npz)."""
    rel = path.relative_to(root)
    if len(rel.parts) > 1 and rel.parts[0] in LABELS:
        return rel.parts[0]
    prefix = path.stem.split("_")[0]
    return prefix if prefix in LABELS else None


def evaluate(root, params, verbose=False):
    """Print fire rate per label. Returns True if every target is met."""
    root = Path(root)
    results = {label: [] for label in LABELS}
    for path in sorted(root.rglob("*")):
        if path.suffix.lower() not in CLIP_EXTS:
            continue
        label = label_of(path, root)
        if label is None:
            print(f"skip (no label): {path}")
            continue
        frames, fps = load_clip(path)
        fires = [i for i, o in enumerate(run_clip(frames, params)) if o.fire]
        results[label].append((path, len(frames), fps, fires))
        if verbose:
            first = fires[0] if fires else "-"
            print(f"  {label:10s} {str(path):50s} frames {len(frames):4d}  "
                  f"fire frames {len(fires):3d}  first {first}")

    print(f"\nparams: {asdict(params)}\n")
    print(f"{'label':10s} {'clips':>5s} {'fired':>5s} {'rate':>6s} "
          f"{'fire frames/clip':>17s} {'median lead s':>14s}  target")
    all_ok = True
    for label in LABELS:
        clips = results[label]
        if not clips:
            print(f"{label:10s} {0:5d}     -      -                 -              -  (no clips)")
            continue
        fired = [c for c in clips if c[3]]
        rate = len(fired) / len(clips)
        per_clip = sum(len(c[3]) for c in clips) / len(clips)
        # Lead time assumes an approach clip ends at the closest point.
        leads = sorted((n - 1 - fires[0]) / fps for _, n, fps, fires in fired)
        lead = f"{leads[len(leads) // 2]:.2f}" if label == "approach" and leads else "-"
        if label == "approach":
            ok = rate >= APPROACH_TARGET
            verdict = f">= {APPROACH_TARGET:.0%}: {'OK' if ok else 'MISS'}"
        else:
            ok = rate <= OTHER_LIMIT
            verdict = f"<= {OTHER_LIMIT:.0%}: {'OK' if ok else 'HIGH'}"
        all_ok &= ok
        print(f"{label:10s} {len(clips):5d} {len(fired):5d} {rate:6.0%} "
              f"{per_clip:17.1f} {lead:>14s}  {verdict}")
    return all_ok


# ---------------------------------------------------------------------------
# Live view
# ---------------------------------------------------------------------------

WIN = "LGMD"
FONT = cv2.FONT_HERSHEY_SIMPLEX
DASH_H = 200
HOLD_FRAMES = 8   # display only: keep FIRE visible this many frames

TRACKBARS = (  # (label, Params field, unit, slider max)
    ("K_THRESH x100", "k_thresh", 100, 500),
    ("F_MAX x1000", "f_max", 1000, 1300),
    ("W_SHIFT", "w_shift", 1, 7),
    ("N_RISE", "n_rise", 1, RISE_SAT),
    ("P_MIN", "p_min", 1, 100),
)


def wearer_sides(o, flip):
    """(left, center, right) K as the wearer feels it. With flip (rear camera),
    image-left is the wearer's right."""
    return (o.K_R, o.K_C, o.K_L) if flip else (o.K_L, o.K_C, o.K_R)


def fire_side(o, flip):
    sides = wearer_sides(o, flip)
    return ("<< LEFT", "BEHIND", "RIGHT >>")[sides.index(max(sides))]


def _hbar(img, x, y, w, h, value, full, thresh, label):
    full = max(full, 1)
    cv2.rectangle(img, (x, y), (x + w, y + h), (90, 90, 90), 1)
    fill = w * min(value, full) // full
    over = value > thresh
    cv2.rectangle(img, (x, y), (x + fill, y + h), (0, 140, 255) if over else (0, 200, 0), -1)
    tx = x + w * min(thresh, full) // full
    cv2.line(img, (tx, y - 6), (tx, y + h + 6), (0, 0, 255), 2)
    cv2.putText(img, f"{label} {value}   (line {thresh})", (x, y - 10), FONT, 0.55, (230, 230, 230), 1)


def _vbar(img, x, y, w, h, value, full, label):
    full = max(full, 1)
    cv2.rectangle(img, (x, y), (x + w, y + h), (90, 90, 90), 1)
    fill = h * min(value, full) // full
    cv2.rectangle(img, (x, y + h - fill), (x + w, y + h), (0, 200, 200), -1)
    cv2.putText(img, label, (x, y - 8), FONT, 0.5, (230, 230, 230), 1)
    cv2.putText(img, str(value), (x, y + h + 18), FONT, 0.45, (200, 200, 200), 1)


def render(frame, o, params, flip, scale, fire_on, side, status):
    pw, ph = W * scale, H * scale

    def up(img):
        return cv2.resize(img, (pw, ph), interpolation=cv2.INTER_NEAREST)

    panels = [
        (cv2.cvtColor(up(frame), cv2.COLOR_GRAY2BGR), "frame"),
        (cv2.cvtColor(up(o.P.astype(np.uint8)), cv2.COLOR_GRAY2BGR), "P = |cur - prev|"),
        (cv2.applyColorMap(up(o.S.astype(np.uint8)), cv2.COLORMAP_INFERNO), "S = P - (I >> W)"),
    ]
    thirds = ("R", "C", "L") if flip else ("L", "C", "R")   # wearer side of each image third
    starts = (0, COL_L_END, COL_R_START)
    for img, title in panels:
        for c in (COL_L_END, COL_R_START):
            cv2.line(img, (c * scale, 0), (c * scale, ph), (0, 160, 160), 1)
        cv2.putText(img, title, (8, 26), FONT, 0.7, (0, 255, 0), 2)
        for c, name in zip(starts, thirds):
            cv2.putText(img, f"wearer {name}", (c * scale + 6, ph - 10), FONT, 0.45, (0, 200, 200), 1)
    top = np.hstack([p for p, _ in panels])

    dw = top.shape[1]
    dash = np.full((DASH_H, dw, 3), 25, np.uint8)
    bar_w = dw * 50 // 100
    _hbar(dash, 16, 40, bar_w, 26, o.K, 2 * params.k_thresh, params.k_thresh, "K")
    _hbar(dash, 16, 108, bar_w, 26, o.F, 2 * params.f_max, params.f_max, "F")
    cv2.putText(dash, status, (16, DASH_H - 16), FONT, 0.5, (200, 200, 200), 1)

    # K per region in wearer order, full scale = max(K, K_THRESH) so the bars
    # show how K splits across sides.
    vx, vw = dw * 55 // 100, dw * 18 // 100
    gap = vw // 3
    names = ("L", "C", "R")
    regions = ("K_R", "K_C", "K_L") if flip else ("K_L", "K_C", "K_R")
    full = max(o.K, params.k_thresh)
    for i, (value, name, reg) in enumerate(zip(wearer_sides(o, flip), names, regions)):
        _vbar(dash, vx + i * gap, 30, gap * 2 // 3, 120, value, full, f"{name}={reg}")

    # FIRE indicator.
    fx0, fx1 = dw * 76 // 100, dw - 16
    if fire_on:
        cv2.rectangle(dash, (fx0, 16), (fx1, DASH_H - 16), (0, 0, 230), -1)
        cv2.putText(dash, "FIRE", (fx0 + 16, 100), FONT, 2.6, (255, 255, 255), 6)
        cv2.putText(dash, side, (fx0 + 16, 150), FONT, 1.1, (255, 255, 255), 3)
    else:
        cv2.rectangle(dash, (fx0, 16), (fx1, DASH_H - 16), (60, 60, 60), -1)
        cv2.putText(dash, "clear", (fx0 + 16, 110), FONT, 1.6, (150, 150, 150), 3)
    return np.vstack([top, dash])


class Viewer:
    def __init__(self, params, flip, scale):
        self.params, self.flip, self.scale = params, flip, scale
        self.hold = 0
        self.side = ""
        cv2.namedWindow(WIN, cv2.WINDOW_AUTOSIZE)
        for label, field, unit, top in TRACKBARS:
            def on_change(v, field=field, unit=unit):
                setattr(self.params, field, v * unit)
            cv2.createTrackbar(label, WIN, min(getattr(params, field) // unit, top), top, on_change)

    def update(self, o):
        """Call once per new frame."""
        if o.fire:
            self.hold = HOLD_FRAMES
            self.side = fire_side(o, self.flip)
        elif self.hold:
            self.hold -= 1

    def draw(self, frame, o, status, delay_ms):
        mode = "flip: image-left = wearer R" if self.flip else "no flip: image-left = wearer L"
        img = render(frame, o, self.params, self.flip, self.scale, self.hold > 0,
                     self.side, f"{status}   rise {o.rise}/{self.params.n_rise}   {mode}")
        cv2.imshow(WIN, img)
        key = cv2.waitKey(delay_ms) & 0xFF
        if key == ord("m"):
            self.flip = not self.flip
        return key


def run_live(args, params):
    src = int(args.camera) if args.camera.isdigit() else args.camera
    reader = LatestFrameReader(src)
    viewer = Viewer(params, not args.no_flip, args.scale)
    state, seq, idx = None, 0, 0
    fps, t_prev = 0.0, time.monotonic()
    rec, rec_t0 = None, 0.0

    def save_recording():
        path = Path(args.rec_dir) / time.strftime("rec_%Y%m%d_%H%M%S.npz")
        rec_fps = len(rec) / max(time.monotonic() - rec_t0, 1e-6)
        save_clip(path, rec, rec_fps)
        print(f"saved {len(rec)} frames at {rec_fps:.1f} fps to {path}")

    print("keys: [r] record  [m] flip  [q] quit")
    try:
        while True:
            new_seq, frame = reader.read(seq)
            if new_seq == seq:
                if not reader.alive:
                    print("camera stopped")
                    break
                if cv2.waitKey(1) & 0xFF in (ord("q"), 27):
                    break
                continue
            seq = new_seq
            if state is None:
                state = init_state(frame)
            state, o = lgmd_step(frame, state, params)
            now = time.monotonic()
            fps = 0.9 * fps + 0.1 / max(now - t_prev, 1e-6)
            t_prev = now
            if rec is not None:
                rec.append(frame)
            viewer.update(o)
            status = f"live  frame {idx}  {fps:5.1f} fps" + ("   REC" if rec is not None else "")
            key = viewer.draw(frame, o, status, 1)
            idx += 1
            if key in (ord("q"), 27):
                break
            if key == ord("r"):
                if rec is None:
                    rec, rec_t0 = [], time.monotonic()
                    print("recording...")
                else:
                    save_recording()
                    rec = None
    finally:
        if rec:
            save_recording()
        reader.close()
        cv2.destroyAllWindows()


def run_replay(args, params):
    frames, fps = load_clip(args.clip)
    last = len(frames) - 1
    viewer = Viewer(params, not args.no_flip, args.scale)
    delay = max(1, int(1000 / fps))

    def replay_to(i):
        # State depends on history, so stepping back recomputes from frame 0.
        state = init_state(frames[0])
        for k in range(i + 1):
            state, o = lgmd_step(frames[k], state, params)
        viewer.hold = 0
        viewer.update(o)
        return state, o

    print("keys: [space] pause  [n] step  [b] back  [0] restart  [m] flip  [q] quit")
    idx, paused = 0, False
    state, o = replay_to(0)
    while True:
        status = f"{Path(args.clip).name}  frame {idx}/{last}" + ("   PAUSED" if paused else "")
        key = viewer.draw(frames[idx], o, status, 30 if paused else delay)
        if key in (ord("q"), 27):
            break
        if key == ord(" "):
            paused = not paused
        elif key == ord("b") and idx > 0:
            idx -= 1
            state, o = replay_to(idx)
        elif key == ord("0"):
            idx = 0
            state, o = replay_to(0)
        elif key == ord("n") or not paused:
            if idx < last:
                idx += 1
                state, o = lgmd_step(frames[idx], state, params)
                viewer.update(o)
            else:
                paused = True
    cv2.destroyAllWindows()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description="LGMD collision detector reference model")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--camera", default="0", help="camera index or stream URL for live mode (default 0)")
    mode.add_argument("--clip", help="replay a .npz recording or a video file frame by frame")
    mode.add_argument("--export", metavar="CLIP", help="write frames.bin, expected.csv, params.json for CLIP")
    mode.add_argument("--eval", metavar="DIR", help="fire rate per label for labeled clips under DIR")
    mode.add_argument("--synth", metavar="DIR", help="write the synthetic test clips to DIR")
    ap.add_argument("--out", default="vectors", help="output directory for --export (default vectors)")
    ap.add_argument("--rec-dir", default="recordings", help="where 'r' saves clips (default recordings)")
    ap.add_argument("--no-flip", action="store_true",
                    help="camera faces forward: image-left = wearer's left "
                         "(default: rear camera, image-left = wearer's right)")
    ap.add_argument("--scale", type=int, default=8, help="display upscale (default 8)")
    ap.add_argument("-v", "--verbose", action="store_true", help="per-clip lines in --eval")
    for f in fields(Params):
        ap.add_argument(f"--{f.name.replace('_', '-')}", type=int, default=f.default,
                        help=f"{f.name.upper()} (default {f.default})")
    args = ap.parse_args(argv)

    params = Params(**{f.name: getattr(args, f.name) for f in fields(Params)})
    try:
        params.check()
    except ValueError as e:
        ap.error(str(e))

    if args.synth:
        for name, make in SYNTH_CLIPS.items():
            save_clip(Path(args.synth) / f"{name}.npz", make(), 30.0)
        print(f"wrote {len(SYNTH_CLIPS)} clips to {args.synth}")
    elif args.export:
        frames, _ = load_clip(args.export)
        out = export_vectors(frames, params, args.out)
        print(f"wrote {len(frames)} frames to {out}/frames.bin, expected.csv, params.json")
    elif args.eval:
        return 0 if evaluate(args.eval, params, args.verbose) else 1
    elif args.clip:
        run_replay(args, params)
    else:
        run_live(args, params)
    return 0


if __name__ == "__main__":
    sys.exit(main())
