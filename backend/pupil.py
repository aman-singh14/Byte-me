"""Where is the pupil in a blurry close-up eye frame, whatever the lighting?

The real eye camera sits a few centimetres from the eye, so frames are soft: the pupil
is a dark mass, not a crisp circle. This finds that mass:

  1. grey, then remove a brightness ramp (light from a side/top/bottom): fit a plane to
     the picture, ignoring its darkest and brightest pixels so the pupil doesn't tilt it
  2. stretch the 2nd-98th percentile to 0..1 (removes exposure, gain and contrast)
  3. smooth, then keep the region darker than the midpoint between the image's typical
     darkness and its darkest spot ("half-max": adapts to how big the pupil looks)
  4. the biggest such region's centre of mass (weighted by darkness) is the pupil

Everything is relative to the frame's own brightness range, so a dim or bright room, a
colour cast or a ramp of light barely moves the answer (tested in test_eye_calibration).
Coordinates are fractions of the frame: x 0 = left edge, 1 = right edge; y 0 = top.

At this resolution the whole pupil is never visible, so the centre of the dark mass alone
barely tells "looking left" from "looking ahead". The SHAPE does: looking left, the dark
mass reaches further to the left, less solid black is visible (a smaller, dimmer core) and
the mass is longer and thinner. PupilFix.vector() returns position and shape together; the
gaze classifier weighs each feature by how steady it is for the wearer (see gaze.py).
"""

from dataclasses import dataclass

import cv2
import numpy as np

WORK_W, WORK_H = 320, 240          # frames are resized to this before analysis (the stream size)


# What vector() contains, in order. x, y, core_x, core_y are signed (-1..1); the rest are as named.
FEATURE_NAMES = ("x", "y", "left_edge", "contrast", "core_area", "elong", "core_x", "core_y")
# The least each feature is allowed to be treated as steady, in its own units: about how far it drifts
# under ordinary lighting changes (dimmer/brighter, shading, tint, noise, blur), measured on the real
# eye-camera recordings and on generated eyes. Recordings from one session understate this, and a
# feature that happened to sit perfectly still would otherwise get a near-zero tolerance.
FEATURE_FLOORS = (0.04, 0.02, 0.012, 0.07, 0.012, 0.045, 0.055, 0.035)
CORE_FRAC = 0.8                    # the "core" = the darkest part: where darkness is 80% of the way to the peak


@dataclass
class PupilFix:
    x: float                       # 0..1 across the frame (centre of the dark mass)
    y: float                       # 0..1 down the frame
    contrast: float                # how much darker the pupil mass is than the frame (0..1): less visible black = lower
    area: float                    # fraction of the frame the mass covers
    aspect: float                  # width / height of the mass
    solidity: float                # mass area / its convex hull (1 = a clean blob)
    left_edge: float = 0.0         # how far left the mass reaches (0..1); looking left it reaches further left
    core_area: float = 0.0         # fraction of the frame covered by the darkest core (visible solid black)
    core_x: float = 0.0            # 0..1 centre of that core
    core_y: float = 0.0
    elong: float = 1.0             # length / width of the mass from its second moments (1 = round)

    def as_signed(self):
        """The (x, y) in -1..1 that EyeTracker / GazeTracker use."""
        return 2 * self.x - 1, 2 * self.y - 1

    def vector(self):
        """Position + shape, ordered as FEATURE_NAMES (elongation is log-scaled so 2x and 1/2x are symmetric)."""
        return [2 * self.x - 1, 2 * self.y - 1, self.left_edge, self.contrast, self.core_area,
                float(np.log(max(self.elong, 1e-3))), 2 * self.core_x - 1, 2 * self.core_y - 1]


def normalize(bgr):
    """Frame -> float 0..1 picture with ramp, exposure and contrast removed."""
    g = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY) if bgr.ndim == 3 else bgr
    g = cv2.resize(g, (WORK_W, WORK_H), interpolation=cv2.INTER_AREA).astype(np.float32)
    yy, xx = np.mgrid[0:WORK_H:2, 0:WORK_W:2].astype(np.float32)          # fit on every 2nd pixel
    sub = g[::2, ::2]
    lo, hi = np.percentile(sub, [30, 97])
    keep = ((sub >= lo) & (sub <= hi)).ravel()                           # not the pupil, not the glints
    A = np.stack([xx.ravel() / WORK_W, yy.ravel() / WORK_H, np.ones(xx.size, np.float32)], 1)
    if keep.sum() < 50:
        keep[:] = True
    coef, *_ = np.linalg.lstsq(A[keep], sub.ravel()[keep], rcond=None)
    full_y, full_x = np.mgrid[0:WORK_H, 0:WORK_W].astype(np.float32)
    plane = coef[0] * full_x / WORK_W + coef[1] * full_y / WORK_H + coef[2]
    g = g - plane + plane.mean()
    lo, hi = np.percentile(g, [2, 98])
    return np.clip((g - lo) / max(hi - lo, 12.0), 0, 1)                   # 12 grey levels: flat frames stay flat


def locate(bgr, blur=7.0, frac=0.5, min_contrast=0.25, min_area=0.004, max_area=0.45, max_aspect=3.5):
    """The pupil mass in a frame, or None when there isn't one (eye closed, nothing dark,
    a thin dark line such as lashes)."""
    n = normalize(bgr)
    d = 1.0 - cv2.GaussianBlur(n, (0, 0), blur)
    base, peak = float(np.median(d)), float(np.quantile(d, 0.995))
    contrast = peak - base
    if contrast < min_contrast:
        return None
    thr = base + frac * contrast
    k, lab, st, _ = cv2.connectedComponentsWithStats((d >= thr).astype(np.uint8))
    # Candidates must look like a pupil: not tiny, not huge, not a long thin band (a lid shadow or
    # a lash line). Only then pick the darkest-by-mass one, so a big shadow can't hide the pupil.
    best, best_mass = None, 0.0
    for i in range(1, k):
        bw, bh = int(st[i, cv2.CC_STAT_WIDTH]), int(st[i, cv2.CC_STAT_HEIGHT])
        area = st[i, cv2.CC_STAT_AREA] / (WORK_W * WORK_H)
        if not (min_area <= area <= max_area) or not (1 / max_aspect <= bw / max(bh, 1) <= max_aspect):
            continue
        mass = float((d * (lab == i)).sum())
        if mass > best_mass:
            best, best_mass = i, mass
    if best is None:
        return None
    comp = lab == best
    w = np.where(comp, d - thr, 0.0).astype(np.float64)
    total = w.sum()
    if total <= 0:
        return None
    ys, xs = np.mgrid[0:WORK_H, 0:WORK_W]
    cx, cy = (w * xs).sum() / total, (w * ys).sum() / total
    bw, bh = int(st[best, cv2.CC_STAT_WIDTH]), int(st[best, cv2.CC_STAT_HEIGHT])
    area = st[best, cv2.CC_STAT_AREA] / (WORK_W * WORK_H)
    aspect = bw / max(bh, 1)
    cnts, _ = cv2.findContours(comp.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    hull = cv2.contourArea(cv2.convexHull(max(cnts, key=cv2.contourArea)))
    solidity = float(st[best, cv2.CC_STAT_AREA] / max(hull, 1.0))

    # ---- shape of the visible dark mass ----
    sx = np.sqrt((w * (xs - cx) ** 2).sum() / total)
    sy = np.sqrt((w * (ys - cy) ** 2).sum() / total)
    cxy = (w * (xs - cx) * (ys - cy)).sum() / total
    ev = np.sort(np.linalg.eigvalsh(np.array([[sx ** 2, cxy], [cxy, sy ** 2]])))[::-1]
    elong = float(np.sqrt(max(ev[0], 1e-9) / max(ev[1], 1e-9)))
    left_edge = float(np.nonzero(comp.any(axis=0))[0][0]) / WORK_W
    # the darkest core inside the mass: what is left when only the strongest 20% of darkness is kept
    core_thr = base + CORE_FRAC * contrast
    core = comp & (d >= core_thr)
    kc, labc, stc, _ = cv2.connectedComponentsWithStats(core.astype(np.uint8))
    if kc >= 2:
        bc = max(range(1, kc), key=lambda i: float((d * (labc == i)).sum()))
        wc = np.where(labc == bc, d - core_thr, 0.0).astype(np.float64)
        tc = wc.sum()
        core_area = float(stc[bc, cv2.CC_STAT_AREA]) / (WORK_W * WORK_H)
        core_x, core_y = (wc * xs).sum() / tc / WORK_W, (wc * ys).sum() / tc / WORK_H
    else:                                          # no solid core: nothing darker than the rest of the mass
        core_area, core_x, core_y = 0.0, cx / WORK_W, cy / WORK_H
    return PupilFix(float(cx) / WORK_W, float(cy) / WORK_H, contrast, float(area), float(aspect), solidity,
                    left_edge, core_area, float(core_x), float(core_y), elong)
