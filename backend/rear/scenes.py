"""Synthetic rear clips for tools/mock_fpga.py and the tests (no FPGA, no camera).

Every scene returns `frames` (list of BGR images, oldest first) at 10 fps. The FPGA's
default clip is 30 frames of 160x120 grayscale; to_payload() converts to that.

  person   a person (cut from ultralytics' sample bus.jpg) growing like 1/distance
  recede   the same, played backward (walking away)
  leaves   flickering leaf shadows and a light change: motion, but nothing approaching
  square   lgmd.py's synthetic looming square: approaching, but YOLO can't name it
"""

import cv2
import numpy as np

import lgmd
from backend.streams import resolve_sample

W, H, FPS, N = 160, 120, 10, 30
PERSON_BOX = (0.06, 0.37, 0.30, 0.84)        # a pedestrian in bus.jpg (fractions of the image)
SIDE_TO_X = {"left": 0.78, "center": 0.5, "right": 0.22}   # wearer side -> image x (rear camera is mirrored)


def background(w=W, h=H, seed=0):
    """A plain street-ish backdrop: sky gradient, ground, mild texture. No YOLO objects."""
    rng = np.random.default_rng(seed)
    img = np.zeros((h, w, 3), np.float32)
    horizon = int(h * 0.45)
    img[:horizon] = np.linspace(200, 150, horizon)[:, None, None] * np.array([1.0, 0.95, 0.85])
    img[horizon:] = np.linspace(110, 80, h - horizon)[:, None, None]
    img += rng.normal(0, 4, img.shape)
    return np.clip(img, 0, 255).astype(np.uint8)


def _person_sprite():
    img = cv2.imread(resolve_sample("sample:bus.jpg"))
    h, w = img.shape[:2]
    x0, y0, x1, y1 = PERSON_BOX
    return img[int(y0 * h):int(y1 * h), int(x0 * w):int(x1 * w)]


def person(side="left", n=N, w=W, h=H, start_frac=0.25, end_frac=1.05):
    """Person walking/running toward the camera: height grows like 1/distance."""
    sprite = _person_sprite()
    bg = background(w, h)
    t_hit = n / (1 - start_frac / end_frac)          # height reaches end_frac at the last frame
    frames = []
    for t in range(n):
        frac = start_frac * t_hit / (t_hit - t)
        ph = max(4, int(frac * h))
        pw = max(2, int(ph * sprite.shape[1] / sprite.shape[0]))
        spr = cv2.resize(sprite, (pw, ph), interpolation=cv2.INTER_AREA)
        img = bg.copy()
        cx = int(SIDE_TO_X[side] * w)
        feet = int(h * 0.98)
        x0, y0 = cx - pw // 2, feet - ph
        sx0, sy0 = max(0, -x0), max(0, -y0)
        dx0, dy0 = max(0, x0), max(0, y0)
        dx1, dy1 = min(w, x0 + pw), min(h, y0 + ph)
        img[dy0:dy1, dx0:dx1] = spr[sy0:sy0 + dy1 - dy0, sx0:sx0 + dx1 - dx0]
        frames.append(img)
    return frames


def recede(side="left", n=N):
    return person(side, n)[::-1]


def leaves(n=N, w=W, h=H, seed=3):
    """Leaf shadows dancing over a static scene, plus a brightness change: lots of
    scattered motion, nothing approaching."""
    rng = np.random.default_rng(seed)
    bg = background(w, h, seed)
    frames = []
    for t in range(n):
        img = bg.astype(np.float32) * (0.8 + 0.2 * np.sin(t / 3.0))          # light flicker
        for _ in range(25):
            x, y = int(rng.uniform(0, w)), int(rng.uniform(0, h))
            ax, ay = int(rng.uniform(2, 6)), int(rng.uniform(1, 4))
            cv2.ellipse(img, (x, y), (ax, ay), rng.uniform(0, 180), 0, 360, (40, 40, 40), -1)
        frames.append(np.clip(img, 0, 255).astype(np.uint8))
    return frames


def square(n=N, w=W, h=H):
    """Still background first, then the approach right up to the last frame (the
    trigger frame is the newest one in the FPGA's ring buffer)."""
    clip = lgmd.synth_approach(n=min(n, 22))
    clip = [clip[0]] * (n - len(clip)) + list(clip)
    return [cv2.cvtColor(cv2.resize(f, (w, h), interpolation=cv2.INTER_NEAREST), cv2.COLOR_GRAY2BGR) for f in clip]


SCENES = {"person": person, "recede": recede, "leaves": leaves, "square": square}


def from_video(path, n=N, w=W, h=H):
    """Last n frames of a video file (or fewer), resized: 'the last 3 seconds'."""
    cap = cv2.VideoCapture(path)
    frames = []
    while True:
        ok, img = cap.read()
        if not ok:
            break
        frames.append(cv2.resize(img, (w, h), interpolation=cv2.INTER_AREA))
    cap.release()
    if not frames:
        raise ValueError(f"no frames in {path}")
    return frames[-n:]


def to_payload(frames, pixel_format="gray8", quality=80):
    """Frames -> list of bytes as the FPGA sends them (GRAY8 row-major, or JPEG)."""
    out = []
    for f in frames:
        if pixel_format == "gray8":
            out.append(cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).tobytes())
        else:
            ok, buf = cv2.imencode(".jpg", f, [cv2.IMWRITE_JPEG_QUALITY, quality])
            out.append(buf.tobytes())
    return out


def lgmd_stats(frames):
    """Run lgmd.py over the clip (80x60) like the FPGA would: (fired, k_peak, k per image third, frame)."""
    small = [lgmd.preprocess(f) for f in frames]
    best = None
    for i, o in enumerate(lgmd.run_clip(np.stack(small), lgmd.Params())):
        if best is None or o.K > best[1].K:
            best = (i, o)
    i, o = best
    region = 1 + int(np.argmax([o.K_L, o.K_C, o.K_R]))
    return {"frame": i, "k_peak": o.K, "k_left": o.K_L, "k_center": o.K_C, "k_right": o.K_R, "region": region}
