"""Calibrate gaze from recorded eye-camera frames.

    python -m backend.calibrate_eye                      # report only
    python -m backend.calibrate_eye --save               # ...and save the calibration
    python -m backend.calibrate_eye --check              # classify every frame with the SAVED calibration

Folder layout (backend/data/eye_calibration/ by default):

    left/  center/  right/      one image per frame, taken while looking left / ahead / right

The images may be raw camera frames or screenshots of the stream page (a dark page with a
title and the camera picture somewhere inside it, any window size): the camera picture is
found and cropped automatically, so the page around it never affects the numbers.

Steps: crop -> locate the pupil (backend/pupil.py, lighting-independent) -> per class, drop
outliers (blinks, frames taken mid-movement) -> class centres = medians of what is left ->
leave-one-out check -> lighting stress test (every frame re-tested under dimmer, brighter,
shaded, tinted and noisy versions) -> save under the "<user>@<eye method>" gaze profile.

What is calibrated is position AND shape of the visible dark mass (pupil.FEATURE_NAMES). At
this resolution the whole pupil is never in view, so the centre of the dark mass alone barely
separates left from ahead. Looking left the mass reaches further left, there is less solid
black (lower contrast, a smaller core) and it is longer and thinner. Each feature is weighed
by how steady it is for the wearer, so the steady ones decide.
"""

import argparse
import glob
import os
from dataclasses import dataclass

import cv2
import numpy as np

from backend.distance import load_calibration, save_calibration
from backend.gaze import GazeTracker
from backend.pupil import FEATURE_NAMES, WORK_H, WORK_W, locate

CLASSES = ("left", "center", "right")
IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".bmp", ".webp")
DEFAULT_FOLDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "eye_calibration")
OUTLIER_SIGMAS = 3.5          # robust z-score (MAD) above which a frame is dropped
OUTLIER_MIN_DIST = 0.08       # ...but never drop a frame closer than this to its class centre
MIN_SPREAD = 0.03             # floor for the robust spread, so a very tight class doesn't reject everything


# ---------------------------------------------------------------------------
# Cropping: find the camera picture inside a screenshot
# ---------------------------------------------------------------------------

def crop_camera_view(img, size=(WORK_W, WORK_H)):
    """The camera picture from a screenshot of the stream page, resized to `size`.

    A screenshot has a flat dark page around a 4:3 picture; the picture is the largest
    region that differs from the page. A frame that is already the camera picture (no flat
    border) is only resized (centre-cropped to 4:3 first if needed). Returns None only for
    an unusable (tiny or missing) image.
    """
    if img is None or img.ndim < 2 or min(img.shape[:2]) < 40:
        return None
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if img.ndim == 3 else img
    h, w = g.shape
    corners = [g[:8, :8], g[:8, -8:], g[-8:, :8], g[-8:, -8:]]
    bg = float(np.median([np.median(c) for c in corners]))
    # A screenshot's page is flat: most of every corner is the page colour (a few stray pixels from
    # the window edge are fine). A camera frame's corners are not.
    flat = all(float((np.abs(c.astype(np.float32) - bg) <= 3).mean()) >= 0.5 for c in corners)
    if flat:
        mask = (np.abs(g.astype(np.float32) - bg) > 6).astype(np.uint8) * 255
        for kernel in (3, 9, 25):                  # gentlest first: the title text must not merge with the picture
            closed = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((kernel, kernel), np.uint8))
            n, _, st, _ = cv2.connectedComponentsWithStats(closed)
            if n < 2:
                continue
            i = 1 + int(np.argmax(st[1:, cv2.CC_STAT_AREA]))
            x, y, bw, bh = (int(v) for v in st[i, :4])
            filled = st[i, cv2.CC_STAT_AREA] / max(bw * bh, 1)      # a real picture is a solid rectangle
            if bw * bh >= 0.1 * w * h and 1.25 <= bw / max(bh, 1) <= 1.42 and filled >= 0.9:
                m = 2                               # trim the anti-aliased edge
                return cv2.resize(img[y + m:y + bh - m, x + m:x + bw - m], size, interpolation=cv2.INTER_AREA)
    return _to_4x3(img, size)                      # already the camera picture


def _to_4x3(img, size):
    h, w = img.shape[:2]
    if w * 3 > h * 4:                               # too wide: trim the sides
        nw = h * 4 // 3
        img = img[:, (w - nw) // 2:(w - nw) // 2 + nw]
    elif w * 3 < h * 4:                             # too tall: trim top and bottom
        nh = w * 3 // 4
        img = img[(h - nh) // 2:(h - nh) // 2 + nh]
    return cv2.resize(img, size, interpolation=cv2.INTER_AREA)


# ---------------------------------------------------------------------------
# Lighting changes (used by the stress test and by the unit tests)
# ---------------------------------------------------------------------------

def _ramp(n, a, b):
    return np.linspace(a, b, n, dtype=np.float32)


def _shade_v(f, a, b):
    return f * _ramp(f.shape[0], a, b)[:, None, None]


def _shade_h(f, a, b):
    return f * _ramp(f.shape[1], a, b)[None, :, None]


LIGHTING_CHANGES = {
    "dim room (x0.4)": lambda f: f * 0.4 + 5,
    "bright room (x2)": lambda f: f * 2.0,
    "darker (x0.6)": lambda f: f * 0.6,
    "brighter (x1.5)": lambda f: f * 1.5,
    "lower contrast": lambda f: (f - f.mean()) * 0.6 + f.mean(),
    "gamma 0.6": lambda f: 255 * (f / 255) ** 0.6,
    "gamma 1.7": lambda f: 255 * (f / 255) ** 1.7,
    "shade from top": lambda f: _shade_v(f, 1.5, 0.6),
    "shade from bottom": lambda f: _shade_v(f, 0.6, 1.5),
    "shade from left": lambda f: _shade_h(f, 1.5, 0.6),
    "shade from right": lambda f: _shade_h(f, 0.6, 1.5),
    "warm light": lambda f: f * np.array([0.75, 1.0, 1.25], np.float32),
    "cool light": lambda f: f * np.array([1.25, 1.0, 0.75], np.float32),
    "sensor noise": lambda f: f + np.random.default_rng(0).normal(0, 8, f.shape),
    "extra blur": lambda f: cv2.GaussianBlur(f, (0, 0), 3),
}


def change_lighting(img, name):
    return np.clip(LIGHTING_CHANGES[name](img.astype(np.float32)), 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# Loading, calibrating, checking
# ---------------------------------------------------------------------------

@dataclass
class Sample:
    cls: str
    path: str
    frame: np.ndarray | None          # cropped 320x240 camera picture (None: no picture found)
    fix: object = None                # PupilFix or None
    inlier: bool = False
    note: str = ""


def load_samples(folder):
    """Every image in folder/<class>/, cropped and with its pupil located."""
    samples = []
    for cls in CLASSES:
        paths = sorted(p for p in glob.glob(os.path.join(folder, cls, "*")) if p.lower().endswith(IMAGE_EXTS))
        for p in paths:
            frame = crop_camera_view(cv2.imread(p))
            s = Sample(cls, p, frame)
            if frame is None:
                s.note = "no camera picture found"
            else:
                s.fix = locate(frame)
                if s.fix is None:
                    s.note = "no pupil found (closed eye?)"
            samples.append(s)
    return samples


def _xy(sample):
    return np.array([sample.fix.x, sample.fix.y])


def mark_outliers(samples):
    """Per class: frames far from the class's typical position are dropped (a blink, a frame
    taken while the eye was still moving). Robust: medians and MAD, not means."""
    for cls in CLASSES:
        group = [s for s in samples if s.cls == cls and s.fix is not None]
        if not group:
            continue
        pts = np.array([_xy(s) for s in group])
        med = np.median(pts, axis=0)
        mad = np.median(np.abs(pts - med), axis=0) * 1.4826
        scale = np.maximum(mad, MIN_SPREAD)
        for s, p in zip(group, pts):
            z = float(np.max(np.abs(p - med) / scale))
            dist = float(np.hypot(*(p - med)))
            s.inlier = not (z > OUTLIER_SIGMAS and dist > OUTLIER_MIN_DIST)
            if not s.inlier:
                s.note = f"outlier: {dist:.2f} from the typical {cls} position"
    return samples


def class_centres(samples):
    """{class: (x, y)} medians (fractions of the frame) over the inlier frames."""
    out = {}
    for cls in CLASSES:
        pts = [_xy(s) for s in samples if s.cls == cls and s.inlier]
        if pts:
            out[cls] = tuple(float(v) for v in np.median(pts, axis=0))
    return out


def classify(xy, centres):
    return min(centres, key=lambda k: float(np.hypot(xy[0] - centres[k][0], xy[1] - centres[k][1])))


@dataclass
class Model:
    """Class centres plus how much each feature normally wobbles. scale=None: position (x, y) only."""
    centres: dict                       # class -> tuple (position, or position + shape)
    scale: tuple | None
    y_weight: float = 1.0               # position-only model: how much up/down counts

    @property
    def shaped(self):
        return self.scale is not None

    def distance(self, v, cls):
        c, v = np.asarray(self.centres[cls], float), np.asarray(v, float)
        if self.scale is not None:
            return float(np.sqrt((((v - c) / np.asarray(self.scale)) ** 2).sum()))
        return float(np.sqrt((v[0] - c[0]) ** 2 + (self.y_weight * (v[1] - c[1])) ** 2))

    def classify(self, v):
        return min(self.centres, key=lambda k: self.distance(v, k))

    def margin(self):
        """Distance between the two closest class centres, in this model's own units (for a shaped
        model: how many 'natural wobbles' apart they are; bigger = easier to tell apart)."""
        ks = list(self.centres)
        return min(self.distance(self.centres[a], b) for i, a in enumerate(ks) for b in ks[i + 1:])


def _vector(fix, shaped):
    return fix.vector() if shaped else fix.as_signed()


def fit_model(samples, shaped=True, y_weight=1.0, dims=None):
    """Model from the inlier frames, or None if a direction has none. dims: use only these entries of
    the feature vector (still weighed by steadiness): dims=(0, 1) is "position only" in the same
    units as the full model, for a fair comparison."""
    groups = {}
    for cls in CLASSES:
        rows = [_vector(s.fix, shaped) for s in samples if s.cls == cls and s.inlier and s.fix is not None]
        if not rows:
            return None
        groups[cls] = rows if dims is None else [[r[i] for i in dims] for r in rows]
    centres = {c: tuple(float(v) for v in np.median(np.array(r, float), axis=0)) for c, r in groups.items()}
    scale = GazeTracker.scale_from_samples(groups) if shaped else None      # same formula the live calibration uses
    return Model(centres, scale, y_weight)


def leave_one_out(samples, shaped=True):
    """Accuracy when each frame is classified using a model built WITHOUT it.
    Returns (correct, total, confusion {true: {predicted: n}})."""
    inl = [s for s in samples if s.inlier and s.fix is not None]
    conf = {c: {k: 0 for k in CLASSES} for c in CLASSES}
    correct = 0
    for s in inl:
        model = fit_model([t for t in inl if t is not s], shaped)
        if model is None:
            continue
        pred = model.classify(_vector(s.fix, shaped))
        conf[s.cls][pred] += 1
        correct += pred == s.cls
    return correct, len(inl), conf


def lighting_test(samples, model):
    """Re-locate every inlier frame under each lighting change. Returns rows of
    (name, correct, total, median shift, worst shift, lost) where shift is how far the
    pupil moved (fraction of the frame width) and lost = no pupil found any more."""
    rows = []
    inl = [s for s in samples if s.inlier and s.fix is not None]
    for name in LIGHTING_CHANGES:
        ok, shifts, lost = 0, [], 0
        for s in inl:
            fix = locate(change_lighting(s.frame, name))
            if fix is None:
                lost += 1
                continue
            shifts.append(float(np.hypot(fix.x - s.fix.x, fix.y - s.fix.y)))
            ok += model.classify(_vector(fix, model.shaped)) == s.cls
        rows.append((name, ok, len(inl), float(np.median(shifts)) if shifts else 1.0,
                     float(max(shifts)) if shifts else 1.0, lost))
    return rows


def position_noise_test(samples, model, sigma, trials=30, seed=0):
    """Accuracy when the measured POSITION of the pupil is off by random noise (sigma = fraction of
    the picture), as happens when only part of the pupil is visible. Shape features are left
    alone: this asks whether they can carry the decision when the position is unreliable."""
    inl = [s for s in samples if s.inlier and s.fix is not None]
    names = FEATURE_NAMES if model.shaped else ("x", "y")
    pos = [i for i, n in enumerate(names) if n in ("x", "y", "core_x", "core_y")]
    rng = np.random.default_rng(seed)
    ok = total = 0
    for _ in range(trials):
        for s in inl:
            v = np.array(_vector(s.fix, model.shaped), float)
            v[pos] += rng.normal(0, 2 * sigma, len(pos))           # these are signed coordinates: 2x the fraction
            ok += model.classify(v) == s.cls
            total += 1
    return ok / max(total, 1)


def separation(samples, centres):
    """Smallest distance between two class centres, and the typical within-class spread (position only)."""
    ks = list(centres)
    gaps = [float(np.hypot(centres[a][0] - centres[b][0], centres[a][1] - centres[b][1]))
            for i, a in enumerate(ks) for b in ks[i + 1:]]
    spreads = []
    for cls in CLASSES:
        pts = np.array([_xy(s) for s in samples if s.cls == cls and s.inlier])
        if len(pts) > 1:
            spreads.append(float(np.sqrt(pts.var(axis=0).sum())))
    return min(gaps), (float(np.median(spreads)) if spreads else 0.0)


def gaze_profile(user, method):
    """Calibrations are kept per wearer AND per eye method: webcam numbers mean something
    completely different from the eye camera's."""
    return f"{user}@{method}"


def save_model(model, user="me", method="closeup"):
    """Store the model in the form GazeTracker loads: one list per direction, plus "scale"
    and "features" when it includes shape."""
    saved = {k: [round(float(x), 5) for x in v] for k, v in model.centres.items()}
    if model.shaped:
        saved["scale"] = [round(float(x), 6) for x in model.scale]
        saved["features"] = list(FEATURE_NAMES)
    data = load_calibration().get("gaze", {})
    data[gaze_profile(user, method)] = saved
    save_calibration("gaze", data)
    return saved


def save_centres(centres, user="me", method="closeup"):
    """Position-only calibration from (x, y) fractions, stored as signed (-1..1) coordinates."""
    signed = {k: [round(2 * x - 1, 4), round(2 * y - 1, 4)] for k, (x, y) in centres.items()}
    data = load_calibration().get("gaze", {})
    data[gaze_profile(user, method)] = signed
    save_calibration("gaze", data)
    return signed


def save_crops(samples, out_dir):
    n = 0
    for s in samples:
        if s.frame is None:
            continue
        d = os.path.join(out_dir, s.cls)
        os.makedirs(d, exist_ok=True)
        cv2.imwrite(os.path.join(d, os.path.basename(s.path)), s.frame)
        n += 1
    return n


def contact_sheet(samples, predictions=None, thumb=(200, 150), cols=6):
    """One tile per frame. Red cross = where the pupil was found; blue x = dropped as an outlier.
    With predictions ({path: label} from check_saved): the tile also shows "true -> predicted" and a
    green border when the saved calibration got it right, red when it did not."""
    tiles = []
    for s in samples:
        if s.frame is None:
            t = np.zeros((thumb[1], thumb[0], 3), np.uint8)
            cv2.putText(t, "no picture", (10, 80), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 255), 1)
        else:
            t = cv2.resize(s.frame, thumb)
            if s.fix is not None:
                p = (int(s.fix.x * thumb[0]), int(s.fix.y * thumb[1]))
                if s.inlier:
                    cv2.drawMarker(t, p, (0, 0, 255), cv2.MARKER_CROSS, 16, 2)
                else:
                    cv2.drawMarker(t, p, (255, 120, 0), cv2.MARKER_TILTED_CROSS, 16, 2)
            tag = f"{s.cls[0].upper()} " + ("x%.2f y%.2f" % (s.fix.x, s.fix.y) if s.fix else "none")
            cv2.putText(t, tag + ("" if s.inlier else " DROPPED"), (4, 14), cv2.FONT_HERSHEY_SIMPLEX, 0.4,
                        (0, 255, 255), 1)
            pred = (predictions or {}).get(s.path)
            if pred is not None:
                right = pred == s.cls
                color = (0, 200, 0) if right else (0, 0, 255)
                cv2.rectangle(t, (0, 0), (thumb[0] - 1, thumb[1] - 1), color, 3)
                cv2.rectangle(t, (0, thumb[1] - 22), (thumb[0], thumb[1]), (0, 0, 0), -1)
                cv2.putText(t, f"{s.cls} -> {pred}" + ("" if right else "  WRONG"), (6, thumb[1] - 7),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1)
        tiles.append(t)
    while len(tiles) % cols:
        tiles.append(np.zeros_like(tiles[0]))
    return np.vstack([np.hstack(tiles[i:i + cols]) for i in range(0, len(tiles), cols)])


# ---------------------------------------------------------------------------
# Report + CLI
# ---------------------------------------------------------------------------

def frame_table(samples, out=print):
    """One line per frame: where the pupil was found, its shape, and whether it counted."""
    out(f"{'class':7s} {'file':32s} {'x':>6s} {'y':>6s} {'left edge':>9s} {'contrast':>8s} {'core':>6s}  status")
    for s in samples:
        name = os.path.basename(s.path)[-32:]
        if s.fix is None:
            out(f"{s.cls:7s} {name:32s} {'-':>6s} {'-':>6s} {'-':>9s} {'-':>8s} {'-':>6s}  {s.note or 'no pupil'}")
        else:
            out(f"{s.cls:7s} {name:32s} {s.fix.x:6.3f} {s.fix.y:6.3f} {s.fix.left_edge:9.3f} {s.fix.contrast:8.2f} "
                f"{s.fix.core_area:6.3f}  {'used' if s.inlier else 'DROPPED: ' + s.note}")


def report(samples, robustness=True, out=print):
    """Print the whole calibration report. Returns (model, ok): the position + shape model."""
    mark_outliers(samples)
    centres = class_centres(samples)
    out(f"frames: {len(samples)} ({', '.join(f'{c} {sum(s.cls == c for s in samples)}' for c in CLASSES)})")
    for s in samples:
        if s.note:
            out(f"  skipped {s.cls}/{os.path.basename(s.path)}: {s.note}")
    out("\nwhere the pupil mass is (x, y as a fraction of the camera picture):")
    for cls in CLASSES:
        pts = np.array([_xy(s) for s in samples if s.cls == cls and s.inlier])
        if len(pts):
            out(f"  {cls:6s} ({centres[cls][0]:.3f}, {centres[cls][1]:.3f})  n={len(pts)}")
    model = fit_model(samples, shaped=True)
    flat = fit_model(samples, shaped=False)
    if model is None:
        out("\nneed usable frames in all three folders (left, center, right)")
        return None, False

    out("\nshape of the visible dark mass per direction (medians) and how steady each number is for you:")
    out(f"  {'feature':11s} {'left':>8s} {'center':>8s} {'right':>8s}   {'wobble':>7s}  {'left vs center':>14s}")
    for i, name in enumerate(FEATURE_NAMES):
        l, c, r = (model.centres[k][i] for k in CLASSES)
        out(f"  {name:11s} {l:8.3f} {c:8.3f} {r:8.3f}   {model.scale[i]:7.3f}  {abs(l - c) / model.scale[i]:12.1f}x")
    out("  (the last column: how many 'wobbles' apart left and center are on that feature; >3 separates well)")

    pos = fit_model(samples, shaped=True, dims=(0, 1))      # x, y only, measured in the same wobble units
    out(f"\nhow far apart the closest two directions are, in natural wobbles (bigger = easier to tell apart):  "
        f"position only {pos.margin():.1f}   position + shape {model.margin():.1f}")
    out(f"left vs center specifically:  position only {pos.distance(pos.centres['left'], 'center'):.1f}   "
        f"position + shape {model.distance(model.centres['left'], 'center'):.1f}")

    out("\nleave-one-out (each frame judged by a model built without it):")
    ok = True
    for label, shaped in (("position only ", False), ("position+shape", True)):
        correct, total, conf = leave_one_out(samples, shaped)
        out(f"  {label}: {correct}/{total} correct")
        if shaped:
            out("    true \\ predicted  " + "  ".join(f"{k:>6s}" for k in CLASSES))
            for c in CLASSES:
                out(f"    {c:16s}  " + "  ".join(f"{conf[c][k]:6d}" for k in CLASSES))
            ok = correct >= 0.9 * total

    out("\nif the measured position is off (only part of the pupil visible), how often is the answer still right?")
    out(f"  {'position error':>16s} {'position only':>14s} {'position+shape':>15s}")
    for sigma in (0.03, 0.06, 0.10):
        out(f"  {'+-%.2f' % sigma:>16s} {100 * position_noise_test(samples, flat, sigma):13.0f}% "
            f"{100 * position_noise_test(samples, model, sigma):14.0f}%")

    if robustness:
        out("\nlighting stress test (position + shape; every kept frame re-tested under each change):")
        out(f"  {'change':20s} {'right class':>12s} {'median move':>12s} {'worst move':>11s} {'lost':>5s}")
        rows = lighting_test(samples, model)
        for name, n_ok, n, med, worst, lost in rows:
            out(f"  {name:20s} {n_ok:>8d}/{n:<3d} {med:12.3f} {worst:11.3f} {lost:5d}")
        worst_acc = min(r[1] / max(r[2], 1) for r in rows)
        out(f"  worst case across all changes: {100 * worst_acc:.0f}% of frames still in the right class")
        ok = ok and worst_acc >= 0.85
    return model, ok


def check_saved(samples, user="me", method="closeup", out=print, predictions=None):
    """Classify every frame with the SAVED calibration, through GazeTracker (what the app uses).
    predictions: optional dict that is filled with {image path: predicted label}."""
    from backend.config import load_config
    from backend.gaze import GazeTracker
    cfg = load_config()
    cfg["eye"]["method"] = method
    g = GazeTracker(cfg, user=user)
    if not g.calibrated:
        out(f"no saved calibration for {gaze_profile(user, method)}: run with --save first")
        return False
    conf = {c: {k: 0 for k in CLASSES} for c in CLASSES}
    for s in samples:
        if s.fix is None:
            continue
        g.current = None
        pred = g.classify_raw(tuple(s.fix.vector()))
        conf[s.cls][pred] += 1
        if predictions is not None:
            predictions[s.path] = pred
    total = sum(sum(r.values()) for r in conf.values())
    correct = sum(conf[c][c] for c in CLASSES)
    out(f"profile {gaze_profile(user, method)} ({'position + shape' if g.scale else 'position only'}): "
        f"{correct}/{total} frames classified correctly (including any dropped outliers)")
    out("  true \\ predicted  " + "  ".join(f"{k:>6s}" for k in CLASSES))
    for c in CLASSES:
        out(f"  {c:16s}  " + "  ".join(f"{conf[c][k]:6d}" for k in CLASSES))
    return correct >= 0.85 * max(total, 1)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Calibrate gaze from recorded eye-camera frames")
    ap.add_argument("folder", nargs="?", default=DEFAULT_FOLDER, help="folder with left/ center/ right/ images")
    ap.add_argument("--save", action="store_true", help="save the calibration (profile <user>@<method>)")
    ap.add_argument("--check", action="store_true", help="classify every frame with the saved calibration")
    ap.add_argument("--user", default="me")
    ap.add_argument("--method", default="closeup", help="eye method the calibration is for (default closeup)")
    ap.add_argument("--crops", metavar="DIR", help="also write the cropped 320x240 frames here")
    ap.add_argument("--sheet", metavar="FILE", help="write a contact sheet image (red cross = pupil, blue x = dropped; "
                                                    "with --check: true -> predicted, green/red border)")
    ap.add_argument("--fast", action="store_true", help="skip the lighting stress test")
    ap.add_argument("--table", action="store_true", help="print the pupil coordinates and shape of every frame")
    ap.add_argument("--position-only", action="store_true", help="save the old position-only calibration instead")
    args = ap.parse_args(argv)

    samples = load_samples(args.folder)
    if not samples:
        raise SystemExit(f"no images found in {args.folder}/left, center, right")
    if args.table:
        mark_outliers(samples)
        frame_table(samples)
        print()
    preds = {}
    if args.check:
        mark_outliers(samples)
        ok = check_saved(samples, args.user, args.method, predictions=preds)
    else:
        model, ok = report(samples, robustness=not args.fast)
        if args.save:
            if model is None:
                print("\nnot saved: need all three classes")
            else:
                if args.position_only:
                    model = fit_model(samples, shaped=False)
                saved = save_model(model, args.user, args.method)
                print(f"\nsaved gaze calibration {gaze_profile(args.user, args.method)} "
                      f"({'position + shape' if model.shaped else 'position only'}): {saved}")
    if args.crops:
        print(f"wrote {save_crops(samples, args.crops)} cropped frames to {args.crops}")
    if args.sheet:
        mark_outliers(samples)
        cv2.imwrite(args.sheet, contact_sheet(samples, preds or None))
        print("contact sheet:", args.sheet)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
