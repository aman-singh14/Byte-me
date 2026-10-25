#!/usr/bin/env python3
"""
lgmd_tuner.py - tune the Omni Glasses collision detector on SIMULATED video.

    py lgmd_tuner.py              open the tuner
    py lgmd_tuner.py --selftest   headless checks (simulator, detector, optimizer, GUI, ../../lgmd.py match)

Two outcomes only: COLLISION or no collision.

A collision = a big object (bus, car, bike, person, box/chair) coming TOWARD the camera:
its silhouette keeps getting bigger, faster and faster. If it stays about the same size
(within GROW_PCT, default 5 %), slides sideways, enters from the side, moves away, or the
whole view changes (head turn, lights), it is NOT a collision.

Detector (integer only, so it ports straight to the FPGA):
    P  = |cur - prev|, 0 where P < P_MIN                       (LGMD excitation)
    I  = (sum of 8 neighbours of previous P) >> 3               (LGMD inhibition)
    S  = max(P - (I >> W_SHIFT), 0)                             (LGMD summing layer)
    K  = sum S,   F = sum P                                     (same as ../../lgmd.py)
    moving pixels = S > S_MIN;  box around them (trimmed 1/16 on each side);  E = box area
    Es = Es + ((E - Es) >> SMOOTH)
    grow   = Es[t]*100 > Es[t-GROW_FR]*(100 + GROW_PCT)          bigger by more than GROW_PCT %
    expand = over GROW_FR frames the box got wider AND taller and no edge moved inward
    candidate = K > K_MIN and F < F_MAX and grow and expand
    COLLISION = IN_A_ROW candidates within the last WINDOW frames

Training data is generated: approaching objects (collision) and eight kinds of
non-collision motion. A second simulated set with another random seed is the honest
check. "Live webcam" runs the same detector on the laptop camera (green CLEAR / red COLLISION).
"Save JSON" writes everything the FPGA build needs.
"""
from __future__ import annotations

import argparse
import base64
import itertools
import json
import math
import queue
import sys
import threading
import time
import traceback
from dataclasses import asdict, dataclass, fields
from pathlib import Path

try:
    import cv2
    import numpy as np
except ImportError:
    sys.exit("needs numpy and OpenCV:  py -m pip install numpy opencv-python")

HERE = Path(__file__).resolve().parent
REPO_LGMD = HERE.parent.parent / "lgmd.py"
SCHEMA = "omni-looming-tuning/2"
RESOLUTIONS = {"80x60 (FPGA)": (80, 60), "160x120": (160, 120)}
NEG_KINDS = ("sideways", "same_size", "tiny_growth", "moving_away", "enters_side", "head_turn", "lights", "nothing")
OBJECTS = ("bus", "car", "bike", "person", "box")


def kf_bits(w, h):
    return int(math.ceil(math.log2(w * h * 255 + 1)))


def no_limit(w, h):
    return (1 << kf_bits(w, h)) - 1


@dataclass
class Params:
    # defaults = Auto-optimize result on the simulation (new-seed check: 90 % caught, 0 % false alarms)
    p_min: int = 20          # LGMD noise floor
    w_shift: int = 3         # LGMD inhibition weight 1/2^W
    s_min: int = 12          # a pixel "moves" when S > S_MIN
    k_min: int = 230         # need at least this much motion (K)
    f_max: int = 2097151     # ignore whole-view changes (F); 2097151 = no limit at 80x60
    smooth: int = 0          # box-size smoothing
    grow_frames: int = 4     # compare the box with GROW_FR frames ago ...
    grow_pct: int = 15       # ... it must be bigger by more than this %  (same size within 5 % never fires)
    expand: int = 1          # 1 = widens AND heightens around its own centre, no edge moving inward
    in_a_row: int = 3        # COLLISION after this many growing frames ...
    window: int = 4          # ... within this many frames

    def fixed(self):
        self.p_min = int(min(max(self.p_min, 0), 255))
        self.w_shift = int(min(max(self.w_shift, 0), 7))
        self.s_min = int(min(max(self.s_min, 0), 255))
        self.k_min = int(max(self.k_min, 0))
        self.f_max = int(max(self.f_max, 1))
        self.smooth = int(min(max(self.smooth, 0), 7))
        self.grow_frames = int(min(max(self.grow_frames, 1), 15))
        self.grow_pct = int(min(max(self.grow_pct, 0), 200))
        self.expand = int(bool(self.expand))
        self.in_a_row = int(min(max(self.in_a_row, 1), 16))
        self.window = int(min(max(self.window, self.in_a_row), 16))
        return self


PIPELINE = [
    "P = |cur - prev| (frame 0: P = 0); P = 0 where P < P_MIN",
    "I = (sum of the 8 neighbours of the previous frame's P, outside = 0) >> 3",
    "S = max(P - (I >> W_SHIFT), 0);  K = sum S;  F = sum P   (identical to ../../lgmd.py)",
    "moving pixel = S > S_MIN;  A = count;  column/row histograms of moving pixels",
    "box: cut = max(1, A >> 4); x0 = first column where running sum >= cut, x1 = first column where it >= A-cut+1 "
    "(rows the same); box only if A >= 8, else none",
    "E = (x1-x0+1)*(y1-y0+1) (0 if no box);  Es = Es + ((E - Es) >> SMOOTH)  (arithmetic shift, Es starts 0)",
    "grow = t >= GROW_FR and Es[t-GROW_FR] > 0 and Es[t]*100 > Es[t-GROW_FR]*(100+GROW_PCT)",
    "expand (if EXPAND) = boxes at t and t-GROW_FR exist, width and height both larger, "
    "x0,y0 not > old+1, x1,y1 not < old-1, and |(x0+x1) - (old_x0+old_x1)| * 2 <= width - old_width "
    "(grows around its own centre, not sliding in from a side)",
    "candidate = K > K_MIN and F < F_MAX and grow and expand",
    "COLLISION = at least IN_A_ROW candidates among the last WINDOW frames (including this one)",
]


# ============================================================================ simulator
@dataclass
class Clip:
    name: str
    kind: str            # "approach" or a NEG_KINDS entry
    obj: str
    label: int           # 1 collision, 0 no collision
    fps: float
    frames: np.ndarray

    @property
    def n(self):
        return len(self.frames)


@dataclass
class SimSettings:
    per_kind: int = 12           # clips per non-collision kind; collisions get the same total
    fps: float = 15.0
    width: int = 80
    height: int = 60
    noise: float = 2.0           # sensor noise (grey levels)
    shake: float = 1.0           # camera shake (pixels at 320x240)
    seed: int = 1


def _background(rng, hw):
    H2, W2 = hw[0] * 2, hw[1] * 2
    low = rng.integers(40, 190, (int(rng.integers(4, 9)), int(rng.integers(5, 12)))).astype(np.uint8)
    bg = cv2.GaussianBlur(cv2.resize(low, (W2, H2), interpolation=cv2.INTER_CUBIC), (0, 0), 4).astype(np.float32)
    if rng.random() < 0.6:                          # floor / horizon
        y = int(H2 * rng.uniform(0.45, 0.65))
        bg[y:] = bg[y:] * rng.uniform(0.55, 0.85)
    return bg


def _draw(img, obj, cx, cy, s, val, detail):
    """Draw an object of size s (about its height in pixels) centred at cx, cy."""
    def rect(x0, y0, x1, y1, v):
        cv2.rectangle(img, (int(x0), int(y0)), (int(x1), int(y1)), float(v), -1)
    dark = val * 0.55
    if obj == "bus":
        w = 1.5 * s
        rect(cx - w / 2, cy - s / 2, cx + w / 2, cy + s / 2, val)
        for k in range(4):                             # windows
            x = cx - w / 2 + w * (0.08 + 0.22 * k)
            rect(x, cy - s * 0.35, x + w * 0.16, cy - s * 0.05, dark)
        rect(cx - w * 0.3, cy + s * 0.1, cx + w * 0.3, cy + s * 0.25, detail)
    elif obj == "car":
        w = 1.8 * s
        rect(cx - w / 2, cy - s * 0.1, cx + w / 2, cy + s / 2, val)
        rect(cx - w * 0.3, cy - s / 2, cx + w * 0.3, cy - s * 0.1, val)
        rect(cx - w * 0.25, cy - s * 0.42, cx + w * 0.25, cy - s * 0.15, dark)
        for side in (-1, 1):
            cv2.circle(img, (int(cx + side * w * 0.3), int(cy + s / 2)), max(int(s * 0.18), 1), float(dark * 0.5), -1)
    elif obj == "bike":
        r = max(int(s * 0.28), 1)
        th = max(int(s * 0.07), 1)
        for side in (-1, 1):
            cv2.circle(img, (int(cx + side * s * 0.45), int(cy + s * 0.2)), r, float(val), th)
            cv2.line(img, (int(cx + side * s * 0.45), int(cy + s * 0.2)), (int(cx), int(cy - s * 0.2)), float(val), th)
        cv2.ellipse(img, (int(cx), int(cy - s * 0.35)), (max(int(s * 0.12), 1), max(int(s * 0.25), 1)), 0, 0, 360,
                    float(dark), -1)
    elif obj == "person":
        cv2.ellipse(img, (int(cx), int(cy + s * 0.08)), (max(int(s * 0.17), 1), max(int(s * 0.4), 1)), 0, 0, 360,
                    float(val), -1)
        cv2.circle(img, (int(cx), int(cy - s * 0.4)), max(int(s * 0.11), 1), float(dark), -1)
    else:                                              # box / chair
        rect(cx - s * 0.45, cy - s / 2, cx + s * 0.45, cy + s * 0.15, val)
        for side in (-1, 1):
            rect(cx + side * s * 0.4 - s * 0.05, cy + s * 0.15, cx + side * s * 0.4 + s * 0.05, cy + s / 2, dark)


def _contrast_value(rng, bg_level=120.0):
    v = bg_level + rng.choice([-1, 1]) * rng.uniform(55, 115)
    return float(np.clip(v, 5, 250))


def _render_clip(rng, ss: SimSettings, n, objects_at, pan_at=None, gain_at=None):
    """objects_at(t) -> list of (obj, cx, cy, size, val, detail) in 320x240 coordinates."""
    hw = (240, 320)
    bg = _background(rng, hw)
    frames = []
    for t in range(n):
        ox = hw[1] // 2 + (int(pan_at(t)) if pan_at else 0) + int(round(rng.normal(0, ss.shake)))
        oy = hw[0] // 2 + int(round(rng.normal(0, ss.shake)))
        ox = int(np.clip(ox, 0, bg.shape[1] - hw[1]))
        oy = int(np.clip(oy, 0, bg.shape[0] - hw[0]))
        img = bg[oy:oy + hw[0], ox:ox + hw[1]].copy()
        for obj, cx, cy, s, val, det in objects_at(t):
            _draw(img, obj, cx, cy, s, val, det)
        if gain_at:
            img = img * gain_at(t)
        img = img + rng.normal(0, ss.noise, img.shape)
        frames.append(cv2.resize(np.clip(img, 0, 255).astype(np.uint8), (ss.width, ss.height),
                                 interpolation=cv2.INTER_AREA))
    return np.stack(frames)


def simulate(ss: SimSettings, log=print):
    """Collision clips (objects coming toward the camera, size ~ 1/distance) and non-collision clips."""
    rng = np.random.default_rng(ss.seed)
    clips = []
    fps = ss.fps
    n_pos = ss.per_kind * len(NEG_KINDS)

    # ---------------- collisions: the object approaches along the view axis and ends close to the camera
    for i in range(n_pos):
        obj, det = str(rng.choice(OBJECTS)), float(rng.uniform(0, 255))
        n = max(int(rng.uniform(1.5, 4.0) * fps), 12)
        s0, s_end = rng.uniform(10, 40), rng.uniform(150, 320)
        d1 = s0 / s_end                                   # distance 1 -> d1, size = s0 / distance
        cx0, cy0 = rng.uniform(90, 230), rng.uniform(80, 170)
        cx1, cy1 = cx0 + rng.uniform(-40, 40), cy0 + rng.uniform(-20, 40)
        val = _contrast_value(rng)
        lead = int(rng.integers(2, 6))                    # a few still frames first

        def at(t, s0=s0, d1=d1, cx0=cx0, cy0=cy0, cx1=cx1, cy1=cy1, obj=obj, val=val, det=det, n=n, lead=lead):
            u = min(max((t - lead) / max(n - 1, 1), 0.0), 1.0)
            d = 1 - (1 - d1) * u
            return [(obj, cx0 + (cx1 - cx0) * u, cy0 + (cy1 - cy0) * u, s0 / d, val, det)]
        clips.append(Clip(f"approach/{obj}_{i:03d}", "approach", obj, 1, fps, _render_clip(rng, ss, n + lead, at)))

    # ---------------- non-collisions
    for kind in NEG_KINDS:
        for i in range(ss.per_kind):
            obj, det = str(rng.choice(OBJECTS)), float(rng.uniform(0, 255))
            n = max(int(rng.uniform(2.0, 4.0) * fps), 12)
            val = _contrast_value(rng)
            s = rng.uniform(30, 140)
            pan = gain = None
            if kind == "sideways":                       # constant size, crosses the view
                ang = rng.uniform(-0.6, 0.6) + (0 if rng.random() < 0.5 else math.pi)
                v = rng.uniform(40, 220) / fps
                x0, y0 = 160 - math.cos(ang) * (190 + s), rng.uniform(80, 170)
                at = (lambda t, a=ang, v=v, x=x0, y=y0, s=s, o=obj, val=val, d=det:
                      [(o, x + math.cos(a) * v * t, y + math.sin(a) * v * t, s, val, d)])
            elif kind == "same_size":                    # wobbles within +-4 %, drifts a little
                ph, x0, y0, dx = rng.uniform(0, 6.3), rng.uniform(100, 220), rng.uniform(90, 160), rng.uniform(-30, 30) / fps
                at = (lambda t, s=s, ph=ph, x=x0, y=y0, dx=dx, o=obj, val=val, d=det:
                      [(o, x + dx * t, y, s * (1 + 0.04 * math.sin(ph + t * 0.7)), val, d)])
            elif kind == "tiny_growth":                  # gets bigger, but by less than 5 % in total
                g, x0, y0 = rng.uniform(0.0, 0.04), rng.uniform(100, 220), rng.uniform(90, 160)
                at = (lambda t, s=s, g=g, n=n, x=x0, y=y0, o=obj, val=val, d=det:
                      [(o, x, y, s * (1 + g * t / n), val, d)])
            elif kind == "moving_away":                  # the approach played backwards
                big, small = rng.uniform(120, 300), rng.uniform(15, 40)
                x0, y0 = rng.uniform(100, 220), rng.uniform(90, 160)
                at = (lambda t, a=big, b=small, n=n, x=x0, y=y0, o=obj, val=val, d=det:
                      [(o, x, y, b / (1 - (1 - b / a) * (1 - t / max(n - 1, 1))), val, d)])
            elif kind == "enters_side":                  # constant size, slides in from an edge and stops
                side = rng.choice([-1, 1])
                xe, y0, stop = 160 + side * rng.uniform(0, 70), rng.uniform(90, 160), rng.uniform(0.4, 0.8)
                xs = 160 + side * (220 + s)
                at = (lambda t, a=xs, b=xe, n=n, st=stop, y=y0, s=s, o=obj, val=val, d=det:
                      [(o, a + (b - a) * min(t / (st * n), 1.0), y, s, val, d)])
            elif kind == "head_turn":                    # the whole view slides (camera rotates)
                v = rng.choice([-1, 1]) * rng.uniform(60, 300) / fps
                show, x0, y0 = rng.random() < 0.5, rng.uniform(100, 220), rng.uniform(90, 160)
                pan = lambda t, v=v: v * t
                at = (lambda t, show=show, v=v, x=x0, y=y0, s=s, o=obj, val=val, d=det:
                      [(o, x - v * t, y, s, val, d)] if show else [])
            elif kind == "lights":                       # brightness ramp or flicker
                a, f, mode = rng.uniform(0.15, 0.5), rng.uniform(0.2, 2.0), int(rng.integers(0, 2))
                gain = (lambda t, a=a, n=n: 1 + a * t / n) if mode == 0 else (lambda t, a=a, f=f: 1 + 0.5 * a * math.sin(t * f))
                at = lambda t: []
            else:                                        # nothing moving (maybe a still object)
                still, x0, y0 = rng.random() < 0.5, rng.uniform(100, 220), rng.uniform(90, 160)
                at = (lambda t, still=still, x=x0, y=y0, s=s, o=obj, val=val, d=det:
                      [(o, x, y, s, val, d)] if still else [])
            clips.append(Clip(f"{kind}/{obj}_{i:03d}", kind, obj, 0, fps, _render_clip(rng, ss, n, at, pan, gain)))
    log(f"simulated {n_pos} collision + {len(NEG_KINDS) * ss.per_kind} non-collision clips (seed {ss.seed})")
    return clips


# ============================================================================ detector
def lgmd_layers(frames, p_min, w_shift):
    f = frames.astype(np.int16)
    P = np.zeros_like(f)
    P[1:] = np.abs(f[1:] - f[:-1])
    if p_min > 0:
        P[P < p_min] = 0
    I = np.zeros_like(P)
    if len(f) > 1:
        q = np.pad(P[:-1], ((0, 0), (1, 1), (1, 1)))
        n8 = (q[:, :-2, :-2] + q[:, :-2, 1:-1] + q[:, :-2, 2:] + q[:, 1:-1, :-2] +
              q[:, 1:-1, 2:] + q[:, 2:, :-2] + q[:, 2:, 1:-1] + q[:, 2:, 2:])
        I[1:] = n8 >> 3
    S = np.maximum(P - (I >> w_shift), 0)
    return P, S


def _extent_rows(hist, A):
    """Trimmed extents for many frames at once. hist (N, L), A (N,) -> lo, hi (N,), -1 where no box."""
    c = np.cumsum(hist, axis=1)
    cut = np.maximum(1, A >> 4)
    lo = np.argmax(c >= cut[:, None], axis=1)
    hi = np.argmax(c >= (A - cut + 1)[:, None], axis=1)
    none = A < 8
    return np.where(none, -1, lo), np.where(none, -1, hi)


def traces(frames, p_min, w_shift, s_min, keep=False):
    P, S = lgmd_layers(frames, p_min, w_shift)
    act = S > s_min
    A = act.sum(axis=(1, 2)).astype(np.int64)
    x0, x1 = _extent_rows(act.sum(axis=1).astype(np.int64), A)
    y0, y1 = _extent_rows(act.sum(axis=2).astype(np.int64), A)
    E = np.where(x0 >= 0, (x1 - x0 + 1) * (y1 - y0 + 1), 0).astype(np.int64)
    tr = {"K": S.sum(axis=(1, 2), dtype=np.int64), "F": P.sum(axis=(1, 2), dtype=np.int64), "A": A, "E": E,
          "x0": x0, "x1": x1, "y0": y0, "y1": y1}
    if keep:
        tr["P"], tr["S"], tr["act"] = P, S, act
    return tr


def ema_shift(x, a):
    if a <= 0:
        return np.asarray(x, np.int64).copy()
    out = np.empty(len(x), np.int64)
    s = 0
    for i, v in enumerate(np.asarray(x).tolist()):
        s += (v - s) >> a
        out[i] = s
    return out


def grow_mask(Es, g, pct):
    n = len(Es)
    m = np.zeros(n, bool)
    if n > g:
        m[g:] = (Es[:-g] > 0) & (Es[g:] * 100 > Es[:-g] * (100 + pct))
    return m


def expand_mask(tr, g):
    n = len(tr["E"])
    m = np.zeros(n, bool)
    if n > g:
        x0, x1, y0, y1 = tr["x0"], tr["x1"], tr["y0"], tr["y1"]
        seen = (x0[g:] >= 0) & (x0[:-g] >= 0)
        wider = (x1[g:] - x0[g:]) > (x1[:-g] - x0[:-g])
        taller = (y1[g:] - y0[g:]) > (y1[:-g] - y0[:-g])
        no_in = (x0[g:] <= x0[:-g] + 1) & (x1[g:] >= x1[:-g] - 1) & (y0[g:] <= y0[:-g] + 1) & (y1[g:] >= y1[:-g] - 1)
        # grows around its own centre: the centre may move at most half as much as the width grows
        # (an object sliding in from the side grows on one side only, so its centre runs with it)
        dsum = np.abs((x0[g:] + x1[g:]) - (x0[:-g] + x1[:-g]))
        dwidth = (x1[g:] - x0[g:]) - (x1[:-g] - x0[:-g])
        m[g:] = seen & wider & taller & no_in & (dsum * 2 <= dwidth)
    return m


def confirm(cand, hits, window):
    cs = np.concatenate([[0], np.cumsum(cand)])
    idx = np.arange(1, len(cand) + 1)
    return cs[idx] - cs[np.maximum(idx - window, 0)] >= hits


def decide(tr, prm: Params):
    Es = ema_shift(tr["E"], prm.smooth)
    grow = grow_mask(Es, prm.grow_frames, prm.grow_pct)
    exp = expand_mask(tr, prm.grow_frames) if prm.expand else np.ones(len(Es), bool)
    gates = {"motion": tr["K"] > prm.k_min, "not whole view": tr["F"] < prm.f_max, "growing": grow, "expanding": exp}
    cand = gates["motion"] & gates["not whole view"] & grow & exp
    return {"Es": Es, "grow": grow, "expand": exp, "cand": cand, "gates": gates,
            "alarm": confirm(cand, prm.in_a_row, prm.window)}


class LiveDetector:
    """Frame-at-a-time version of traces() + decide() (what the FPGA does)."""

    def __init__(self):
        self.reset()

    def reset(self):
        import collections
        self.prev = self.prev_p = None
        self.es = 0
        self.hist = collections.deque(maxlen=16)
        self.cand_hist = collections.deque(maxlen=16)

    def step(self, frame, prm: Params):
        cur = frame.astype(np.int16)
        if self.prev is None or self.prev.shape != cur.shape:
            self.reset()
            self.prev, self.prev_p = cur, np.zeros_like(cur)
        P = np.abs(cur - self.prev)
        if prm.p_min > 0:
            P[P < prm.p_min] = 0
        q = np.pad(self.prev_p, 1)
        n8 = (q[:-2, :-2] + q[:-2, 1:-1] + q[:-2, 2:] + q[1:-1, :-2] + q[1:-1, 2:] +
              q[2:, :-2] + q[2:, 1:-1] + q[2:, 2:])
        S = np.maximum(P - ((n8 >> 3) >> prm.w_shift), 0)
        K, F = int(S.sum()), int(P.sum())
        act = S > prm.s_min
        A = int(act.sum())
        box = (-1, -1, -1, -1)
        if A >= 8:
            x0, x1 = _extent_rows(act.sum(0)[None].astype(np.int64), np.array([A]))
            y0, y1 = _extent_rows(act.sum(1)[None].astype(np.int64), np.array([A]))
            box = (int(x0[0]), int(x1[0]), int(y0[0]), int(y1[0]))
        E = (box[1] - box[0] + 1) * (box[3] - box[2] + 1) if box[0] >= 0 else 0
        self.es = E if prm.smooth <= 0 else self.es + ((E - self.es) >> prm.smooth)
        self.hist.append((self.es,) + box)
        g = prm.grow_frames
        grow = exp = False
        if len(self.hist) > g:
            pe, px0, px1, py0, py1 = self.hist[-1 - g]
            grow = pe > 0 and self.es * 100 > pe * (100 + prm.grow_pct)
            x0, x1, y0, y1 = box
            exp = (x0 >= 0 and px0 >= 0 and (x1 - x0) > (px1 - px0) and (y1 - y0) > (py1 - py0) and
                   x0 <= px0 + 1 and x1 >= px1 - 1 and y0 <= py0 + 1 and y1 >= py1 - 1 and
                   abs((x0 + x1) - (px0 + px1)) * 2 <= (x1 - x0) - (px1 - px0))
        if not prm.expand:
            exp = True
        cand = bool(K > prm.k_min and F < prm.f_max and grow and exp)
        self.cand_hist.append(cand)
        alarm = sum(list(self.cand_hist)[-prm.window:]) >= prm.in_a_row
        self.prev, self.prev_p = cur, P
        return {"P": P, "S": S, "act": act, "K": K, "F": F, "E": E, "Es": self.es, "box": box,
                "grow": grow, "expand": exp, "cand": cand, "alarm": alarm}


# ============================================================================ scoring
def evaluate(clips, trs, prm: Params):
    """Per clip: fired?, first alarm, warning time. Summary by kind + which condition blocks."""
    rows, gate, nfr = [], {}, 0
    for c, tr in zip(clips, trs):
        d = decide(tr, prm)
        al = d["alarm"]
        fired = bool(al.any())
        first = int(np.argmax(al)) if fired else -1
        lead = (c.n - 1 - first) / c.fps if fired and c.label else None
        es = d["Es"]
        growth = float(es.max() / max(es[es > 0].min(), 1)) if (es > 0).any() else 0.0
        rows.append({"fired": fired, "first": first, "lead": lead, "ok": fired == bool(c.label),
                     "alarm_frames": int(al.sum()), "growth": growth})
        if c.label:
            nfr += c.n
            for k, v in list(d["gates"].items()) + [("candidate", d["cand"]), ("COLLISION", al)]:
                gate[k] = gate.get(k, 0) + int(v.sum())
    kinds = {}
    for c, r in zip(clips, rows):
        kinds.setdefault(c.kind, []).append(r["fired"])
    pos = [r for c, r in zip(clips, rows) if c.label]
    neg = [r for c, r in zip(clips, rows) if not c.label]
    leads = [r["lead"] for r in pos if r["lead"] is not None]
    summary = {
        "detection_rate": round(sum(r["fired"] for r in pos) / max(len(pos), 1), 4),
        "false_alarm_rate": round(sum(r["fired"] for r in neg) / max(len(neg), 1), 4),
        "median_warning_s": round(float(np.median(leads)), 3) if leads else None,
        "alarm_rate_by_kind": {k: round(sum(v) / len(v), 3) for k, v in kinds.items()},
        "collision_frames_passing": {k: round(v / max(nfr, 1), 3) for k, v in gate.items()},
        "clips": {"collision": len(pos), "no_collision": len(neg)},
    }
    return rows, summary


# ============================================================================ optimizer
def nice_grid(lo, hi, count):
    vals = np.geomspace(max(lo, 1), max(hi, lo + 1), count)
    out = []
    for v in vals:
        mag = 10 ** max(int(np.floor(np.log10(v))) - 1, 0)
        out.append(int(round(v / mag) * mag))
    return np.unique(np.array(out, np.int64))


def kth_in_window(V, c, m):
    from numpy.lib.stride_tricks import sliding_window_view
    pad = np.full(V.shape[:-1] + (m - 1,), -1, V.dtype)
    win = sliding_window_view(np.concatenate([pad, V], -1), m, axis=-1)
    return np.sort(win, axis=-1)[..., m - c]


def first_alarm_grid(tr, Es, kts, fms, g, pct, ex, hits, win, exp_cache):
    """First COLLISION frame for every (F_MAX, K_MIN) at once (len if none)."""
    ok = grow_mask(Es, g, pct)
    if ex:
        if g not in exp_cache:
            exp_cache[g] = expand_mask(tr, g)
        ok = ok & exp_cache[g]
    mask = (tr["F"][None, :] < fms[:, None]) & ok
    V = np.where(mask, tr["K"], -1)
    if hits > 1 or win > 1:
        V = kth_in_window(V, hits, win)
    run = np.maximum.accumulate(V, axis=-1)
    return (run[:, :, None] <= kts).sum(axis=1).astype(np.int16)


def optimize(clips, target_fa=0.05, min_in_a_row=3, fine=False, log=print):
    """Exhaustive search. Most detections with false alarms <= target, at least min_in_a_row
    growing frames before COLLISION; ties -> longer warning, then a robust (middle) K_MIN."""
    w, h = clips[0].frames.shape[2], clips[0].frames.shape[1]
    layer_opts = list(itertools.product([8, 16, 24] if fine else [12, 20], [1, 3], [8, 16, 32] if fine else [12, 24]))
    smooths = [0, 1, 2]
    grows = [(1, 3), (1, 5), (2, 5), (2, 8), (3, 10), (4, 15)] if fine else [(1, 5), (2, 5), (2, 10), (3, 10), (4, 15)]
    exps = [0, 1]
    confs = [(c, c) for c in range(min_in_a_row, min_in_a_row + 3)] + [(min_in_a_row, min_in_a_row + 1)]
    kmax = fmax = 1
    for c in clips[:: max(1, len(clips) // 30)]:
        tr = traces(c.frames, 8, 1, 8)
        kmax, fmax = max(kmax, int(tr["K"].max())), max(fmax, int(tr["F"].max()))
    kts = np.concatenate([[0], nice_grid(50, kmax, 22)])
    fms = np.append(nice_grid(1000, fmax, 9), no_limit(w, h))
    combos = list(itertools.product(range(len(layer_opts)), smooths, grows, exps, confs))
    log(f"searching {len(combos) * len(kts) * len(fms):,} settings on {len(clips)} simulated clips ...")
    first = np.empty((len(combos), len(clips), len(fms), len(kts)), np.int16)
    t0 = time.time()
    for ci, c in enumerate(clips):
        cache = {}
        for k, (li, sm, (g, pct), ex, (hc, wc)) in enumerate(combos):
            if li not in cache:
                cache[li] = (traces(c.frames, *layer_opts[li]), {})
            tr, exp_cache = cache[li]
            ek = (li, sm)
            if ek not in cache:
                cache[ek] = ema_shift(tr["E"], sm)
            first[k, ci] = first_alarm_grid(tr, cache[ek], kts, fms, g, pct, ex, hc, wc, exp_cache)
        if (ci + 1) % 20 == 0 or ci + 1 == len(clips):
            log(f"  {ci + 1}/{len(clips)} clips searched ({time.time() - t0:.0f} s)")
    lens = np.array([c.n for c in clips])[None, :, None, None]
    fps = np.array([c.fps for c in clips])[None, :, None, None]
    pos = np.array([c.label == 1 for c in clips])
    hit = first < lens
    tpr = hit[:, pos].mean(1)
    fpr = hit[:, ~pos].mean(1)
    lead = np.where(hit, (lens - 1 - first) / fps, 0)[:, pos].sum(1) / np.maximum(hit[:, pos].sum(1), 1)
    score = tpr - 10 * np.maximum(0, fpr - target_fa) - 0.2 * fpr
    pad = np.pad(score, [(0, 0), (0, 0), (1, 1)], mode="edge")
    smooth = (pad[..., :-2] + pad[..., 1:-1] + pad[..., 2:]) / 3
    order = np.lexsort((lead.ravel(), smooth.ravel(), score.ravel()))[::-1]

    def unpack(flat):
        k, a, b = np.unravel_index(flat, score.shape)
        li, sm, (g, pct), ex, (hc, wc) = combos[k]
        pm, ws, smin = layer_opts[li]
        return (k, a, b), Params(pm, ws, smin, int(kts[b]), int(fms[a]), sm, g, pct, ex, hc, wc).fixed()

    top = []
    for flat in order[:20]:
        bb, prm = unpack(flat)
        top.append({"params": asdict(prm), "detection_rate": round(float(tpr[bb]), 4),
                    "false_alarm_rate": round(float(fpr[bb]), 4), "mean_warning_s": round(float(lead[bb]), 3)})
    bb, best = unpack(order[0])
    log(f"best on training sims: detects {tpr[bb]:.0%}, false alarms {fpr[bb]:.0%} ({time.time() - t0:.0f} s)")
    return {"best": asdict(best), "top": top, "target_false_alarm_rate": target_fa, "min_in_a_row": min_in_a_row,
            "train": {"detection_rate": round(float(tpr[bb]), 4), "false_alarm_rate": round(float(fpr[bb]), 4)}}


# ============================================================================ JSON
def build_json(prm: Params, ss: SimSettings, train_sum, val_sum, opt):
    w, h = ss.width, ss.height
    params = {f.name.upper(): getattr(prm, f.name) for f in fields(Params)}
    params.update({"WIDTH": w, "HEIGHT": h})
    return {
        "schema": SCHEMA,
        "saved": time.strftime("%Y-%m-%d %H:%M:%S"),
        "output": "one bit per frame: COLLISION or no collision (no direction)",
        "target": "big objects (bus, car, bike, person, box/chair) coming toward the camera",
        "params": params,
        "decision_pipeline": PIPELINE,
        "frame": {"width": w, "height": h, "fps": ss.fps, "grayscale": True, "resize": "cv2.INTER_AREA",
                  "gray": "cv2.COLOR_BGR2GRAY (BT.601 luma)", "crop_to_4_3": True},
        "register_bits": {"K_and_F": kf_bits(w, h), "neighbour_sum": 11, "box_area": int(math.ceil(math.log2(w * h + 1))),
                          "growth_product": int(math.ceil(math.log2(w * h * 300 + 1))),
                          "history_frames": max(prm.grow_frames, prm.window)},
        "simulation": asdict(ss),
        "metrics_training_sims": train_sum,
        "metrics_validation_sims_other_seed": val_sum,
        "optimizer": opt,
    }


# ============================================================================ GUI
def photo_from_bgr(img):
    import tkinter as tk
    ok, buf = cv2.imencode(".png", img)
    return tk.PhotoImage(data=base64.b64encode(buf.tobytes()).decode("ascii"), format="png")


def to_gray_small(img, w, h):
    gray = img if img.ndim == 2 else cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    hh, ww = gray.shape
    if ww * 3 > hh * 4:
        nw = hh * 4 // 3
        gray = gray[:, (ww - nw) // 2:(ww - nw) // 2 + nw]
    elif ww * 3 < hh * 4:
        nh = ww * 3 // 4
        gray = gray[(hh - nh) // 2:(hh - nh) // 2 + nh]
    return cv2.resize(gray, (w, h), interpolation=cv2.INTER_AREA)


class ParamControl:
    def __init__(self, parent, row, label, lo, hi, log_scale, on_change, hint):
        import tkinter as tk
        from tkinter import ttk
        self.lo, self.hi, self.log_scale, self.on_change = lo, hi, log_scale, on_change
        self.value = lo
        self.var = tk.StringVar()
        self.pos = tk.DoubleVar()
        self._quiet = False
        ttk.Label(parent, text=label, width=10).grid(row=row, column=0, sticky="w")
        ttk.Scale(parent, from_=0, to=1000, variable=self.pos, command=self._moved, length=170).grid(
            row=row, column=1, sticky="ew", padx=4)
        ent = ttk.Entry(parent, textvariable=self.var, width=9)
        ent.grid(row=row, column=2)
        ent.bind("<Return>", self._typed)
        ent.bind("<FocusOut>", self._typed)
        ttk.Label(parent, text=hint, foreground="#777").grid(row=row + 1, column=0, columnspan=3, sticky="w")

    def _to_pos(self, v):
        if self.hi <= self.lo:
            return 0
        if self.log_scale:
            lo = math.log(max(self.lo, 1))
            return 1000 * (math.log(max(v, 1)) - lo) / (math.log(self.hi) - lo)
        return 1000 * (v - self.lo) / (self.hi - self.lo)

    def _from_pos(self, p):
        if self.log_scale:
            lo = math.log(max(self.lo, 1))
            return int(round(math.exp(lo + p / 1000 * (math.log(self.hi) - lo))))
        return int(round(self.lo + p / 1000 * (self.hi - self.lo)))

    def set(self, v, notify=False):
        v = int(min(max(int(v), self.lo), self.hi))
        self.value = v
        self.var.set(str(v))
        self._quiet = True
        self.pos.set(self._to_pos(v))
        self._quiet = False
        if notify:
            self.on_change()

    def set_range(self, lo, hi):
        self.lo, self.hi = lo, max(hi, lo + 1)
        self.set(self.value)

    def _moved(self, _):
        if self._quiet:
            return
        v = self._from_pos(self.pos.get())
        if v != self.value:
            self.value = v
            self.var.set(str(v))
            self.on_change()

    def _typed(self, _):
        try:
            v = int(float(self.var.get().replace(",", "")))
        except ValueError:
            self.var.set(str(self.value))
            return
        if v != self.value:
            self.set(v, notify=True)


class TunerApp:
    PANEL = (320, 240)

    def __init__(self, root, auto_sim=True):
        import tkinter as tk
        from tkinter import ttk
        self.root = root
        root.title("Omni Glasses - collision tuner (simulated training)")
        root.geometry("1450x930")
        self.jobs: queue.Queue = queue.Queue()
        self.busy = False
        self.ss = SimSettings()
        self.train, self.val = [], []
        self.cache = {}
        self.rows, self.summary, self.val_summary = [], {}, {}
        self.last_opt = None
        self.sel = None
        self.view = None
        self.t = 0
        self.playing = False
        self.after_id = None
        self.live = None
        self.cursor = None

        top = ttk.Frame(root, padding=6)
        top.pack(fill="x")
        ttk.Label(top, text="Simulation:").pack(side="left")
        ttk.Label(top, text="clips per kind").pack(side="left", padx=(8, 0))
        self.per_var = tk.StringVar(value=str(self.ss.per_kind))
        ttk.Spinbox(top, from_=2, to=60, textvariable=self.per_var, width=4).pack(side="left", padx=3)
        ttk.Label(top, text="fps").pack(side="left", padx=(8, 0))
        self.fps_var = tk.StringVar(value="15")
        ttk.Spinbox(top, from_=5, to=60, textvariable=self.fps_var, width=4).pack(side="left", padx=3)
        ttk.Label(top, text="resolution").pack(side="left", padx=(8, 0))
        self.res_var = tk.StringVar(value=next(iter(RESOLUTIONS)))
        ttk.Combobox(top, textvariable=self.res_var, values=list(RESOLUTIONS), width=13, state="readonly").pack(side="left", padx=3)
        ttk.Label(top, text="noise").pack(side="left", padx=(8, 0))
        self.noise_var = tk.StringVar(value="2")
        ttk.Spinbox(top, from_=0, to=15, increment=0.5, textvariable=self.noise_var, width=4).pack(side="left", padx=3)
        ttk.Label(top, text="shake").pack(side="left", padx=(8, 0))
        self.shake_var = tk.StringVar(value="1")
        ttk.Spinbox(top, from_=0, to=10, increment=0.5, textvariable=self.shake_var, width=4).pack(side="left", padx=3)
        ttk.Label(top, text="seed").pack(side="left", padx=(8, 0))
        self.seed_var = tk.StringVar(value="1")
        ttk.Spinbox(top, from_=1, to=9999, textvariable=self.seed_var, width=5).pack(side="left", padx=3)
        ttk.Button(top, text="Simulate", command=self.simulate).pack(side="left", padx=8)
        ttk.Button(top, text="Live webcam", command=self.open_live).pack(side="left", padx=4)
        self.status = tk.StringVar(value="")
        ttk.Label(root, textvariable=self.status, padding=(8, 0), foreground="#0a5").pack(fill="x")

        body = ttk.Panedwindow(root, orient="horizontal")
        body.pack(fill="both", expand=True, padx=6, pady=6)
        left = ttk.Frame(body, padding=4)
        right = ttk.Frame(body, padding=4)
        body.add(left, weight=0)
        body.add(right, weight=1)

        pf = ttk.LabelFrame(left, text="Detector settings", padding=6)
        pf.pack(fill="x")
        ch = self.changed
        self.c = {
            "p_min": ParamControl(pf, 0, "P_MIN", 0, 64, False, ch, "ignore brightness changes smaller than this"),
            "w_shift": ParamControl(pf, 2, "W_SHIFT", 0, 7, False, ch, "LGMD inhibition 1/2^W"),
            "s_min": ParamControl(pf, 4, "S_MIN", 0, 128, False, ch, "pixel counts as moving above this"),
            "k_min": ParamControl(pf, 6, "K_MIN", 1, no_limit(80, 60), True, ch, "need at least this much motion"),
            "f_max": ParamControl(pf, 8, "F_MAX", 100, no_limit(80, 60), True, ch, "ignore whole-view changes above this"),
            "smooth": ParamControl(pf, 10, "SMOOTH", 0, 5, False, ch, "smooth the object size over ~2^S frames"),
            "grow_frames": ParamControl(pf, 12, "GROW_FR", 1, 15, False, ch, "compare size with this many frames ago"),
            "grow_pct": ParamControl(pf, 14, "GROW_PCT", 0, 100, False, ch, "must be bigger by MORE than this % (5 = 5 %)"),
            "expand": ParamControl(pf, 16, "EXPAND", 0, 1, False, ch, "1 = must widen AND heighten (not sideways)"),
            "in_a_row": ParamControl(pf, 18, "IN_A_ROW", 1, 16, False, self.hits_changed, "growing frames needed for COLLISION"),
            "window": ParamControl(pf, 20, "WINDOW", 1, 16, False, self.window_changed, "... within this many frames"),
        }
        self.set_params(Params())

        mf = ttk.LabelFrame(left, text="Results", padding=6)
        mf.pack(fill="x", pady=6)
        self.m_main = tk.StringVar(value="-")
        self.m_val = tk.StringVar(value="")
        self.m_kinds = tk.StringVar(value="")
        ttk.Label(mf, textvariable=self.m_main, font=("Segoe UI", 11, "bold"), foreground="#060").pack(anchor="w")
        ttk.Label(mf, textvariable=self.m_val, font=("Segoe UI", 10, "bold"), foreground="#035").pack(anchor="w")
        ttk.Label(mf, textvariable=self.m_kinds, justify="left", font=("Consolas", 9)).pack(anchor="w")

        of = ttk.LabelFrame(left, text="Find the best settings", padding=6)
        of.pack(fill="both", expand=True)
        row = ttk.Frame(of)
        row.pack(fill="x")
        ttk.Button(row, text="Auto-optimize", command=self.optimize).pack(side="left")
        ttk.Label(row, text="max false alarms %").pack(side="left", padx=(8, 0))
        self.target_var = tk.StringVar(value="5")
        ttk.Spinbox(row, from_=0, to=50, textvariable=self.target_var, width=4).pack(side="left", padx=3)
        ttk.Label(row, text="min in a row").pack(side="left", padx=(6, 0))
        self.minrow_var = tk.StringVar(value="3")
        ttk.Spinbox(row, from_=1, to=8, textvariable=self.minrow_var, width=3).pack(side="left", padx=3)
        self.fine_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(row, text="fine", variable=self.fine_var).pack(side="left", padx=3)
        self.opt_var = tk.StringVar(value="")
        ttk.Label(of, textvariable=self.opt_var, wraplength=430, justify="left", foreground="#035").pack(anchor="w", pady=3)
        self.top_list = tk.Listbox(of, height=5, font=("Consolas", 9))
        self.top_list.pack(fill="both", expand=True)
        self.top_list.bind("<Double-Button-1>", self.use_top)
        bf = ttk.Frame(left)
        bf.pack(fill="x", pady=(6, 0))
        ttk.Button(bf, text="Save JSON", command=self.save).pack(side="left", fill="x", expand=True)
        ttk.Button(bf, text="Load JSON", command=self.load).pack(side="left", fill="x", expand=True, padx=4)
        ttk.Button(bf, text="Defaults", command=lambda: self.set_params(Params(), True)).pack(side="left")

        self.img_label = ttk.Label(right)
        self.img_label.pack(anchor="w")
        ctl = ttk.Frame(right)
        ctl.pack(fill="x", pady=3)
        ttk.Button(ctl, text="<", width=3, command=lambda: self.step(-1)).pack(side="left")
        self.play_btn = ttk.Button(ctl, text="Play", width=6, command=self.toggle_play)
        self.play_btn.pack(side="left", padx=2)
        ttk.Button(ctl, text=">", width=3, command=lambda: self.step(1)).pack(side="left")
        self.frame_pos = tk.DoubleVar()
        self.frame_scale = ttk.Scale(ctl, from_=0, to=1, variable=self.frame_pos, command=self.seek)
        self.frame_scale.pack(side="left", fill="x", expand=True, padx=6)
        self.info = tk.StringVar()
        ttk.Label(right, textvariable=self.info, font=("Consolas", 10)).pack(anchor="w")
        self.plot = tk.Canvas(right, height=160, background="#191919", highlightthickness=0)
        self.plot.pack(fill="x", pady=4)
        self.plot.bind("<Button-1>", self.plot_click)
        self.plot.bind("<Configure>", lambda e: self.draw_plot())
        cols = ("kind", "object", "frames", "growth", "alarm", "warn", "result")
        tf = ttk.Frame(right)
        tf.pack(fill="both", expand=True)
        self.tree = ttk.Treeview(tf, columns=cols, show="tree headings", height=10)
        self.tree.heading("#0", text="simulated clip")
        self.tree.column("#0", width=200)
        for cn, txt, wd in zip(cols, ("kind", "object", "frames", "size growth", "alarm frames", "warning s", "result"),
                               (110, 70, 60, 90, 90, 80, 70)):
            self.tree.heading(cn, text=txt)
            self.tree.column(cn, width=wd, anchor="e")
        self.tree.tag_configure("wrong", background="#ffd6d6")
        sb = ttk.Scrollbar(tf, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.tree.bind("<<TreeviewSelect>>", self.select)
        root.bind("<space>", lambda e: self.toggle_play() if not isinstance(e.widget, (ttk.Entry, ttk.Spinbox)) else None)
        root.after(50, self.poll)
        if auto_sim:
            root.after(100, self.simulate)

    # ---------------- background jobs
    def run_bg(self, label, fn, done):
        if self.busy:
            self.status.set("busy - wait for the current job")
            return
        self.busy = True
        self.status.set(label)

        def work():
            try:
                self.jobs.put(("done", done, fn(lambda s: self.jobs.put(("log", s)))))
            except Exception as e:      # noqa: BLE001
                traceback.print_exc()
                self.jobs.put(("error", f"{label} failed: {e}"))
        threading.Thread(target=work, daemon=True).start()

    def poll(self):
        try:
            while True:
                j = self.jobs.get_nowait()
                if j[0] == "log":
                    self.status.set(j[1])
                elif j[0] == "done":
                    self.busy = False
                    j[1](j[2])
                else:
                    self.busy = False
                    self.status.set(j[1])
        except queue.Empty:
            pass
        self.root.after(50, self.poll)

    # ---------------- params
    def params(self):
        return Params(*[self.c[f.name].value for f in fields(Params)]).fixed()

    def set_params(self, prm: Params, notify=False):
        for f in fields(Params):
            self.c[f.name].set(getattr(prm, f.name))
        if notify:
            self.changed()

    def hits_changed(self):
        if self.c["window"].value < self.c["in_a_row"].value:
            self.c["window"].set(self.c["in_a_row"].value)
        self.changed()

    def window_changed(self):
        if self.c["in_a_row"].value > self.c["window"].value:
            self.c["in_a_row"].set(self.c["window"].value)
        self.changed()

    def set_in_a_row(self, n):
        self.c["window"].set(n)
        self.c["in_a_row"].set(n)
        self.changed()

    def changed(self):
        if self.after_id:
            self.root.after_cancel(self.after_id)
        self.after_id = self.root.after(120, self.refresh)

    # ---------------- simulation + evaluation
    def sim_settings(self):
        try:
            w, h = RESOLUTIONS[self.res_var.get()]
            return SimSettings(int(self.per_var.get()), float(self.fps_var.get()), w, h,
                               float(self.noise_var.get()), float(self.shake_var.get()), int(self.seed_var.get()))
        except ValueError:
            return SimSettings()

    def simulate(self):
        ss = self.sim_settings()

        def work(log):
            tr = simulate(ss, log)
            val = simulate(SimSettings(**{**asdict(ss), "seed": ss.seed + 1000, "per_kind": max(4, ss.per_kind // 2)}), log)
            return ss, tr, val

        def done(res):
            self.ss, self.train, self.val = res
            self.cache, self.sel, self.view, self.last_opt = {}, None, None, None
            nl = no_limit(self.ss.width, self.ss.height)
            self.c["k_min"].set_range(1, nl)
            self.c["f_max"].set_range(100, nl)
            self.top_list.delete(0, "end")
            self.opt_var.set("")
            self.status.set(f"{len(self.train)} training + {len(self.val)} validation clips simulated "
                            f"({self.ss.width}x{self.ss.height}, {self.ss.fps:g} fps)")
            self.refresh()
        self.run_bg("simulating ...", work, done)

    def refresh(self):
        self.after_id = None
        if not self.train:
            return
        prm = self.params()
        key = (prm.p_min, prm.w_shift, prm.s_min)
        if ("train", key) not in self.cache:
            if self.busy:
                self.changed()
                return
            train, val = self.train, self.val

            def work(log):
                log("computing motion layers ...")
                return key, [traces(c.frames, *key) for c in train], [traces(c.frames, *key) for c in val]

            def done(res):
                self.cache[("train", res[0])], self.cache[("val", res[0])] = res[1], res[2]
                self.status.set("ready")
                self.refresh()
            self.run_bg("computing motion layers ...", work, done)
            return
        self.rows, self.summary = evaluate(self.train, self.cache[("train", key)], prm)
        _, self.val_summary = evaluate(self.val, self.cache[("val", key)], prm)
        s, v = self.summary, self.val_summary
        self.m_main.set(f"training sims: detects {s['detection_rate']:.0%} of collisions, "
                        f"false alarms {s['false_alarm_rate']:.0%}")
        warn = f", warns {v['median_warning_s']:.2f} s before impact" if v["median_warning_s"] is not None else ""
        self.m_val.set(f"NEW sims (other seed): detects {v['detection_rate']:.0%}, false alarms "
                       f"{v['false_alarm_rate']:.0%}{warn}")
        kinds = s["alarm_rate_by_kind"]
        lines = [f"alarm rate:  approach     (want 100%) {kinds.get('approach', 0):4.0%}"]
        lines += [f"             {k:<12} (want   0%) {kinds.get(k, 0):4.0%}" for k in NEG_KINDS]
        g = s["collision_frames_passing"]
        lines.append("approach frames passing: " + "  ".join(f"{k} {v_:.0%}" for k, v_ in g.items()))
        self.m_kinds.set("\n".join(lines))
        self.fill_tree()
        self.view = None
        self.draw_plot()
        self.show()

    def fill_tree(self):
        keep = self.sel
        self.tree.delete(*self.tree.get_children())
        order = sorted(range(len(self.train)), key=lambda i: (self.rows[i]["ok"], self.train[i].name))
        for i in order:
            c, r = self.train[i], self.rows[i]
            self.tree.insert("", "end", iid=str(i), text=c.name,
                             values=(c.kind, c.obj, c.n, f"x{r['growth']:.2f}", r["alarm_frames"],
                                     f"{r['lead']:.2f}" if r["lead"] is not None else "-", "ok" if r["ok"] else "WRONG"),
                             tags=() if r["ok"] else ("wrong",))
        if keep is not None:
            self.tree.selection_set(str(keep))
            self.tree.see(str(keep))
        elif order:
            self.tree.selection_set(str(order[0]))

    # ---------------- viewer
    def select(self, _=None):
        s = self.tree.selection()
        if not s:
            return
        i = int(s[0])
        if i != self.sel:
            self.sel, self.t, self.view = i, 0, None
            self.frame_scale.configure(to=max(self.train[i].n - 1, 1))
        self.draw_plot()
        self.show()

    def view_data(self):
        if self.sel is None or not self.train:
            return None
        prm = self.params()
        key = (self.sel, prm.p_min, prm.w_shift, prm.s_min)
        if self.view is None or self.view[0] != key:
            self.view = (key, traces(self.train[self.sel].frames, prm.p_min, prm.w_shift, prm.s_min, keep=True))
        tr = self.view[1]
        return tr, decide(tr, prm)

    def show(self):
        vd = self.view_data()
        if vd is None:
            return
        tr, d = vd
        c = self.train[self.sel]
        t = min(self.t, c.n - 1)
        pw, ph = self.PANEL
        h, w = c.frames.shape[1:]
        up = lambda im: cv2.resize(im, (pw, ph), interpolation=cv2.INTER_NEAREST)  # noqa: E731
        a = cv2.cvtColor(up(c.frames[t]), cv2.COLOR_GRAY2BGR)
        b = cv2.applyColorMap(up(np.clip(tr["S"][t] * 2, 0, 255).astype(np.uint8)), cv2.COLORMAP_INFERNO)
        m = cv2.cvtColor(up(tr["act"][t].astype(np.uint8) * 255), cv2.COLOR_GRAY2BGR)
        col = (0, 0, 255) if d["alarm"][t] else ((0, 165, 255) if d["cand"][t] else (0, 255, 0))
        if tr["x0"][t] >= 0:
            for im in (a, m):
                cv2.rectangle(im, (int(tr["x0"][t] * pw / w), int(tr["y0"][t] * ph / h)),
                              (int((tr["x1"][t] + 1) * pw / w) - 1, int((tr["y1"][t] + 1) * ph / h) - 1), col, 2)
        for im, title in ((a, "frame + moving-object box"), (b, "S (LGMD)"), (m, "moving pixels (S > S_MIN)")):
            cv2.putText(im, title, (6, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1, cv2.LINE_AA)
        if d["alarm"][t]:
            cv2.rectangle(a, (0, 0), (pw - 1, ph - 1), (0, 0, 255), 6)
            cv2.putText(a, "COLLISION", (10, ph - 14), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 255), 2, cv2.LINE_AA)
        self.photo = photo_from_bgr(np.hstack([a, b, m]))
        self.img_label.configure(image=self.photo)
        prm = self.params()
        g = prm.grow_frames
        ratio = d["Es"][t] / d["Es"][t - g] if t >= g and d["Es"][t - g] > 0 else 0
        recent = int(d["cand"][max(0, t - prm.window + 1):t + 1].sum())
        self.info.set(f"{c.name} ({c.kind})  frame {t}/{c.n - 1}  size {int(tr['E'][t])} smoothed {int(d['Es'][t])} "
                      f"= x{ratio:.2f} vs {g} frames ago (need > x{1 + prm.grow_pct / 100:.2f})  "
                      f"expand {'y' if d['expand'][t] else 'n'}  K {int(tr['K'][t]):,}  F {int(tr['F'][t]):,}  "
                      f"in a row {recent}/{prm.in_a_row}  {'COLLISION' if d['alarm'][t] else ''}")
        self.frame_pos.set(t)
        if self.cursor is not None:
            x = self.plot_x(t)
            self.plot.coords(self.cursor, x, 0, x, int(self.plot.cget("height")))

    def draw_plot(self):
        cv_ = self.plot
        cv_.delete("all")
        self.cursor = None
        vd = self.view_data()
        if vd is None:
            return
        tr, d = vd
        c = self.train[self.sel]
        W_, H_ = max(cv_.winfo_width(), 200), int(cv_.cget("height"))
        n = c.n
        xs = lambda i: 4 + i * (W_ - 8) / max(n - 1, 1)  # noqa: E731
        for i in np.flatnonzero(d["cand"] & ~d["alarm"]):
            cv_.create_rectangle(xs(i) - 1, H_ - 10, xs(i) + 1, H_, fill="#a05050", outline="")
        for i in np.flatnonzero(d["alarm"]):
            cv_.create_rectangle(xs(i) - 1, 0, xs(i) + 1, H_, fill="#702020", outline="")
        top = max(int(tr["E"].max()), 1)
        y = lambda v: H_ - 12 - min(v, top) * (H_ - 26) / top  # noqa: E731
        if n > 1:
            cv_.create_line(*[v for i in range(n) for v in (xs(i), y(tr["E"][i]))], fill="#3f6f3f")
            cv_.create_line(*[v for i in range(n) for v in (xs(i), y(d["Es"][i]))], fill="#7dff7d", width=2)
        cv_.create_text(8, 6, anchor="nw", fill="#ccc", font=("Segoe UI", 9),
                        text="green = moving-object size (dark = raw)   short red = growing   tall red = COLLISION   "
                             "click to jump")
        self.plot_x = xs
        self.cursor = cv_.create_line(xs(self.t), 0, xs(self.t), H_, fill="#ffffff")

    def plot_click(self, e):
        if self.sel is None:
            return
        n = self.train[self.sel].n
        W_ = max(self.plot.winfo_width(), 200)
        self.t = int(min(max(round((e.x - 4) * (n - 1) / max(W_ - 8, 1)), 0), n - 1))
        self.show()

    def seek(self, _):
        if self.sel is not None:
            t = int(round(self.frame_pos.get()))
            if t != self.t:
                self.t = t
                self.show()

    def step(self, dd):
        if self.sel is not None:
            self.t = int(min(max(self.t + dd, 0), self.train[self.sel].n - 1))
            self.show()

    def toggle_play(self):
        self.playing = not self.playing
        self.play_btn.configure(text="Pause" if self.playing else "Play")
        if self.playing:
            self.play_tick()

    def play_tick(self):
        if not self.playing or self.sel is None:
            return
        c = self.train[self.sel]
        self.t = 0 if self.t >= c.n - 1 else self.t + 1
        self.show()
        self.root.after(max(1, int(1000 / c.fps)), self.play_tick)

    # ---------------- optimizer
    def optimize(self):
        if not self.train:
            return
        try:
            target = float(self.target_var.get()) / 100
            minrow = int(self.minrow_var.get())
        except ValueError:
            target, minrow = 0.05, 3
        clips, fine = self.train, self.fine_var.get()

        def done(res):
            self.last_opt = res
            self.top_list.delete(0, "end")
            for k, row in enumerate(res["top"]):
                p = row["params"]
                self.top_list.insert("end", f"{k + 1:2d} det {row['detection_rate']:4.0%} fa {row['false_alarm_rate']:4.0%}"
                                            f"  P{p['p_min']} W{p['w_shift']} S>{p['s_min']} K>{p['k_min']} "
                                            f"F<{p['f_max']} sm{p['smooth']} +{p['grow_pct']}%/{p['grow_frames']}fr "
                                            f"E{p['expand']} {p['in_a_row']}/{p['window']}")
            self.set_params(Params(**res["best"]), notify=True)
            self.opt_var.set(f"Best: training sims detect {res['train']['detection_rate']:.0%}, false alarms "
                             f"{res['train']['false_alarm_rate']:.0%} (target <= {res['target_false_alarm_rate']:.0%}, "
                             f">= {res['min_in_a_row']} in a row). The 'NEW sims' line above is the honest number.")
        self.run_bg("optimizing ...", lambda log: optimize(clips, target, minrow, fine, log), done)

    def use_top(self, _):
        if self.last_opt and self.top_list.curselection():
            self.set_params(Params(**self.last_opt["top"][self.top_list.curselection()[0]]["params"]), True)

    # ---------------- save / load
    def save(self):
        from tkinter import filedialog
        if not self.summary:
            return
        path = filedialog.asksaveasfilename(initialdir=str(HERE), initialfile="tuned_params.json",
                                            defaultextension=".json", filetypes=[("JSON", "*.json")])
        if path:
            doc = build_json(self.params(), self.ss, self.summary, self.val_summary, self.last_opt)
            Path(path).write_text(json.dumps(doc, indent=2))
            self.status.set(f"saved {path}")

    def load(self):
        from tkinter import filedialog, messagebox
        path = filedialog.askopenfilename(initialdir=str(HERE), filetypes=[("JSON", "*.json")])
        if not path:
            return
        try:
            p = json.loads(Path(path).read_text())["params"]
            self.set_params(Params(**{f.name: p[f.name.upper()] for f in fields(Params)}).fixed(), True)
            self.status.set(f"loaded {path}")
        except Exception as e:     # noqa: BLE001
            messagebox.showerror("Load", f"not a tuner JSON (this version): {e}")

    def open_live(self):
        if self.live is None:
            self.live = LiveWindow(self)
        else:
            self.live.top.lift()


class LiveWindow:
    """Laptop webcam -> same preprocessing -> LiveDetector with the current sliders. GREEN CLEAR / RED COLLISION."""

    GREEN, RED, AMBER = "#1f9d3a", "#d32020", "#e0a000"

    def __init__(self, app: TunerApp):
        import tkinter as tk
        from tkinter import ttk
        self.app = app
        self.top = tk.Toplevel(app.root)
        self.top.title("Live webcam - collision detector")
        self.top.protocol("WM_DELETE_WINDOW", self.close)
        bar = ttk.Frame(self.top, padding=6)
        bar.pack(fill="x")
        ttk.Label(bar, text="camera").pack(side="left")
        self.cam_var = tk.StringVar(value="0")
        ttk.Spinbox(bar, from_=0, to=5, textvariable=self.cam_var, width=3).pack(side="left", padx=4)
        ttk.Button(bar, text="Start", command=self.start).pack(side="left")
        ttk.Button(bar, text="Stop", command=self.stop).pack(side="left", padx=4)
        ttk.Button(bar, text="Reset", command=self.reset).pack(side="left", padx=4)
        ttk.Label(bar, text="  growing frames in a row for RED").pack(side="left")
        self.row_var = tk.StringVar(value=str(app.params().in_a_row))
        ttk.Spinbox(bar, from_=1, to=16, textvariable=self.row_var, width=4, command=self.row_changed).pack(side="left", padx=4)
        ttk.Label(bar, text="stay red s").pack(side="left")
        self.hold_var = tk.StringVar(value="1.0")
        ttk.Spinbox(bar, from_=0, to=5, increment=0.5, textvariable=self.hold_var, width=4).pack(side="left", padx=4)
        self.banner = tk.Label(self.top, text="press Start", font=("Segoe UI", 34, "bold"), fg="white", bg="#555555", pady=10)
        self.banner.pack(fill="x")
        self.img = tk.Label(self.top, bg="#555555", bd=0)
        self.img.pack(padx=6, pady=6)
        self.info = tk.StringVar()
        ttk.Label(self.top, textvariable=self.info, font=("Consolas", 10)).pack(anchor="w", padx=6)
        self.plot = tk.Canvas(self.top, height=100, width=960, background="#191919", highlightthickness=0)
        self.plot.pack(padx=6, pady=6)
        self.det = LiveDetector()
        self.cap = None
        self.frame = None
        self.running = False
        self.lock = threading.Lock()
        self.hist = []
        self.ticks = []
        self.red_until = 0.0

    def row_changed(self):
        try:
            self.app.set_in_a_row(max(1, min(16, int(self.row_var.get()))))
        except ValueError:
            pass

    def reset(self):
        self.det.reset()
        self.hist = []
        self.red_until = 0.0

    def start(self):
        if self.running:
            return
        try:
            idx = int(self.cam_var.get())
        except ValueError:
            idx = 0
        self.cap = cv2.VideoCapture(idx, cv2.CAP_DSHOW)
        if not self.cap.isOpened():
            self.cap = cv2.VideoCapture(idx)
        if not self.cap.isOpened():
            self.banner.configure(text=f"cannot open camera {idx}", bg="#555555")
            return
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        self.cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        self.running = True
        self.reset()
        threading.Thread(target=self.grab, daemon=True).start()
        self.tick()

    def grab(self):
        while self.running and self.cap is not None:
            ok, img = self.cap.read()
            if ok:
                with self.lock:
                    self.frame = img
            else:
                time.sleep(0.01)

    def stop(self):
        self.running = False
        if self.cap is not None:
            time.sleep(0.05)
            self.cap.release()
            self.cap = None
        self.banner.configure(text="stopped", bg="#555555")

    def close(self):
        self.stop()
        self.top.destroy()
        self.app.live = None

    def tick(self):
        if not self.running:
            return
        ss = self.app.ss
        w, h = ss.width, ss.height
        self.top.after(max(1, int(1000 / ss.fps)), self.tick)
        with self.lock:
            img = self.frame
        if img is None:
            return
        now = time.perf_counter()
        self.ticks = [t for t in self.ticks if now - t < 2.0] + [now]
        small = to_gray_small(img, w, h)
        prm = self.app.params()
        d = self.det.step(small, prm)
        self.hist = (self.hist + [(d["E"], d["Es"], d["cand"], d["alarm"])])[-160:]
        try:
            hold = max(float(self.hold_var.get()), 0.0)
        except ValueError:
            hold = 1.0
        if d["alarm"]:
            self.red_until = now + hold
        red = d["alarm"] or now < self.red_until
        recent = sum(x[2] for x in self.hist[-prm.window:])
        if red:
            self.banner.configure(text="COLLISION", bg=self.RED)
            fc = self.RED
        elif d["cand"]:
            self.banner.configure(text=f"getting closer...  {recent}/{prm.in_a_row}", bg=self.AMBER)
            fc = self.AMBER
        else:
            self.banner.configure(text="CLEAR", bg=self.GREEN)
            fc = self.GREEN
        self.img.configure(bg=fc, padx=8, pady=8)
        pw, ph = 480, 360
        a = cv2.cvtColor(cv2.resize(small, (pw, ph), interpolation=cv2.INTER_NEAREST), cv2.COLOR_GRAY2BGR)
        m = cv2.cvtColor(cv2.resize(d["act"].astype(np.uint8) * 255, (pw, ph), interpolation=cv2.INTER_NEAREST),
                         cv2.COLOR_GRAY2BGR)
        x0, x1, y0, y1 = d["box"]
        if x0 >= 0:
            col = (0, 0, 255) if red else ((0, 165, 255) if d["cand"] else (0, 255, 0))
            for im in (a, m):
                cv2.rectangle(im, (int(x0 * pw / w), int(y0 * ph / h)),
                              (int((x1 + 1) * pw / w) - 1, int((y1 + 1) * ph / h) - 1), col, 3)
        self.photo = photo_from_bgr(np.hstack([a, m]))
        self.img.configure(image=self.photo)
        g = prm.grow_frames
        prev = self.hist[-1 - g][1] if len(self.hist) > g else 0
        ratio = d["Es"] / prev if prev > 0 else 0
        self.info.set(f"{len(self.ticks) / 2:4.1f} fps   object size {d['E']} (smoothed {d['Es']})  "
                      f"x{ratio:.2f} vs {g} frames ago (need > x{1 + prm.grow_pct / 100:.2f})  "
                      f"expand {'y' if d['expand'] else 'n'}  K {d['K']:,}  in a row {recent}/{prm.in_a_row}")
        cv_ = self.plot
        cv_.delete("all")
        W_, H_ = 960, 100
        topv = max(max(x[0] for x in self.hist), 1)
        y = lambda v: H_ - 6 - min(v, topv) * (H_ - 12) / topv  # noqa: E731
        x = lambda i: 4 + i * (W_ - 8) / 159  # noqa: E731
        for i, (_, _, cand, alarm) in enumerate(self.hist):
            if alarm:
                cv_.create_rectangle(x(i) - 2, 0, x(i) + 2, H_, fill="#702020", outline="")
            elif cand:
                cv_.create_rectangle(x(i) - 1, H_ - 10, x(i) + 1, H_, fill="#a05050", outline="")
        if len(self.hist) > 1:
            cv_.create_line(*[v for i, hh in enumerate(self.hist) for v in (x(i), y(hh[1]))], fill="#7dff7d", width=2)
        cv_.create_text(8, 6, anchor="nw", fill="#ccc", font=("Segoe UI", 9),
                        text="green = moving-object size   short red = growing   tall red = COLLISION")


# ============================================================================ self-test
def selftest():
    t0 = time.time()
    ss = SimSettings(per_kind=8, seed=1)
    clips = simulate(ss)
    val = simulate(SimSettings(per_kind=6, seed=1001))
    assert all(c.frames.dtype == np.uint8 and c.frames.shape[1:] == (60, 80) for c in clips)
    print(f"simulation ok ({time.time() - t0:.1f} s)")

    if REPO_LGMD.exists():
        sys.path.insert(0, str(REPO_LGMD.parent))
        import lgmd as ref
        bad = 0
        for c in clips[::10]:
            outs = list(ref.run_clip(c.frames, ref.Params(12, 1, 3000, 80000, 3)))
            tr = traces(c.frames, 12, 1, 16)
            bad += sum((o.K, o.F) != (tr["K"][t], tr["F"][t]) for t, o in enumerate(outs))
        print(f"K, F identical to {REPO_LGMD.name}: {bad} mismatches")
        assert bad == 0

    rng = np.random.default_rng(3)
    bad = 0
    for c in clips[::7]:
        for _ in range(3):
            prm = Params(int(rng.integers(0, 25)), int(rng.integers(0, 4)), int(rng.integers(4, 40)),
                         int(rng.integers(0, 3000)), int(rng.integers(20000, 300000)), int(rng.integers(0, 3)),
                         int(rng.integers(1, 5)), int(rng.integers(0, 20)), int(rng.integers(0, 2)), 3, 4).fixed()
            want = decide(traces(c.frames, prm.p_min, prm.w_shift, prm.s_min), prm)["alarm"]
            det = LiveDetector()
            got = np.array([det.step(f, prm)["alarm"] for f in c.frames])
            bad += int((got != want).sum())
    print(f"live webcam detector vs batch: {bad} mismatching frames")
    assert bad == 0

    kts, fms = np.array([0, 500, 3000, 20000]), np.array([30000, 200000, no_limit(80, 60)])
    bad = 0
    for c in clips[::9]:
        tr = traces(c.frames, 12, 1, 16)
        for sm, g, pct, ex, hc, wc in ((0, 1, 5, 1, 3, 3), (1, 2, 10, 0, 3, 4), (2, 3, 5, 1, 4, 4)):
            es = ema_shift(tr["E"], sm)
            grid = first_alarm_grid(tr, es, kts, fms, g, pct, ex, hc, wc, {})
            for a, fm in enumerate(fms):
                for b, kt in enumerate(kts):
                    al = decide(tr, Params(12, 1, 16, int(kt), int(fm), sm, g, pct, ex, hc, wc))["alarm"]
                    bad += (int(np.argmax(al)) if al.any() else c.n) != grid[a, b]
    print(f"optimizer grid vs frame-by-frame: {bad} mismatches")
    assert bad == 0

    prm = Params()
    _, s = evaluate(clips, [traces(c.frames, prm.p_min, prm.w_shift, prm.s_min) for c in clips], prm)
    print(f"default settings on training sims: detects {s['detection_rate']:.0%}, false alarms "
          f"{s['false_alarm_rate']:.0%}; by kind {s['alarm_rate_by_kind']}")
    res = optimize(clips, 0.05, 3, log=lambda m: None)
    best = Params(**res["best"])
    _, vs = evaluate(val, [traces(c.frames, best.p_min, best.w_shift, best.s_min) for c in val], best)
    print(f"optimized: {res['best']}")
    print(f"  training sims {res['train']};  NEW sims (other seed): detects {vs['detection_rate']:.0%}, "
          f"false alarms {vs['false_alarm_rate']:.0%}, warning {vs['median_warning_s']} s")
    print(f"  by kind on new sims: {vs['alarm_rate_by_kind']}")
    json.dumps(build_json(best, ss, s, vs, res))

    import tkinter as tk
    root = tk.Tk()
    root.withdraw()
    app = TunerApp(root, auto_sim=False)
    app.ss, app.train, app.val = ss, clips, val
    key = (best.p_min, best.w_shift, best.s_min)
    app.cache[("train", key)] = [traces(c.frames, *key) for c in clips]
    app.cache[("val", key)] = [traces(c.frames, *key) for c in val]
    app.set_params(best)
    app.refresh()
    app.tree.selection_set(app.tree.get_children()[0])
    app.select()
    for _ in range(6):
        app.step(1)
    lw = LiveWindow(app)
    root.update()
    lw.close()
    root.destroy()
    print(f"GUI + live window built: ok   ({time.time() - t0:.0f} s total)")
    print("SELFTEST PASSED")
    return res, vs


def main():
    ap = argparse.ArgumentParser(description="collision tuner on simulated video")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return
    import tkinter as tk
    root = tk.Tk()
    TunerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
