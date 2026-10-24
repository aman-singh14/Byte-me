"""Synthetic close-up eye: a DEV stand-in for the EYE ESP32-CAM (~3 cm from one eye,
below and to the side). Used by tests and by the "synthetic-eye" camera source.

Draws skin, an almond eye opening (rotated and squashed for the off-axis view),
sclera, iris, a dark pupil with a bright IR glint, eyelashes on the upper lid, and
an upper lid that comes down to blink or squint. Gaze moves the iris.

    frame = render(gaze=(-0.6, 0.0), openness=1.0)         # looking left, eye open
    for frame, truth in timeline(): ...                    # scripted blinks, squints, gaze
"""

import math

import cv2
import numpy as np

W, H = 320, 240
CX, CY = 160, 125            # eye center in the image
EYE_W, EYE_H = 230, 120      # almond opening, fully open
TILT_DEG = -12               # off-axis view: the eye looks rotated
IRIS_R, PUPIL_R = 44, 17
IRIS_UP = 8                  # iris sits a little above the opening's center
GAZE_X_PX, GAZE_Y_PX = 55, 18   # iris travel at gaze = +-1
FULL_TOP = EYE_H * 0.62      # upper lid height above center, fully open


def lid_height(openness):
    """Upper lid height above the opening's center. Below 0.9 the lid is over the
    pupil and `openness` is roughly the visible fraction of the pupil (0 = hidden,
    a blink); from 0.9 to 1 the lid lifts off the pupil to fully open."""
    ph = PUPIL_R * 0.9
    if openness <= 0.9:
        h = -ph + 2 * ph * max(openness, 0.0) / 0.9          # relative to the pupil center
    else:
        h = ph + (FULL_TOP - IRIS_UP - ph) * (openness - 0.9) / 0.1
    return max(IRIS_UP + h, 0.0)


def _almond(openness):
    """Polygon of the visible eye opening. The upper lid drops as openness falls;
    the lower lid barely moves (as in a real eye)."""
    top_h = lid_height(openness)
    bot_h = EYE_H * 0.38
    xs = np.linspace(-EYE_W / 2, EYE_W / 2, 48)
    s = np.sqrt(np.clip(1 - (2 * xs / EYE_W) ** 2, 0, 1))
    top = np.stack([xs, -top_h * s], 1)
    bot = np.stack([xs[::-1], bot_h * s[::-1]], 1)
    return np.concatenate([top, bot])


def _place(pts):
    a = math.radians(TILT_DEG)
    rot = np.array([[math.cos(a), -math.sin(a)], [math.sin(a), math.cos(a)]])
    return (pts @ rot.T + (CX, CY)).astype(np.int32)


def render(gaze=(0.0, 0.0), openness=1.0, glint=True, lashes=True, noise=4.0, rng=None):
    """BGR frame of the eye. gaze x/y in -1..1 (+x = image right, +y = down); openness 0..1."""
    rng = rng or np.random.default_rng(0)
    img = np.empty((H, W, 3), np.uint8)
    img[:] = (120, 140, 170)                                    # skin (BGR)
    yy = np.linspace(0, 1, H)[:, None, None]
    img = (img * (0.85 + 0.25 * yy)).clip(0, 255).astype(np.uint8)   # shading

    opening = _place(_almond(openness))
    eye = np.zeros((H, W), np.uint8)
    if lid_height(openness) > 0.5:
        cv2.fillPoly(eye, [opening], 255)

    layer = img.copy()
    layer[:] = (215, 220, 225)                                  # sclera
    ix = int(CX + gaze[0] * GAZE_X_PX)
    iy = int(CY - IRIS_UP + gaze[1] * GAZE_Y_PX)
    # Off-axis view: iris and pupil look like ellipses.
    cv2.ellipse(layer, (ix, iy), (IRIS_R, int(IRIS_R * 0.9)), TILT_DEG, 0, 360, (60, 85, 110), -1)
    cv2.ellipse(layer, (ix, iy), (PUPIL_R, int(PUPIL_R * 0.9)), TILT_DEG, 0, 360, (12, 12, 12), -1)
    if glint:
        cv2.circle(layer, (ix + 6, iy - 5), 4, (250, 250, 250), -1)   # IR reflection inside the pupil
    img[eye > 0] = layer[eye > 0]

    # Lid edge and lashes along the upper lid.
    top = opening[:48]
    cv2.polylines(img, [top], False, (70, 85, 110), 3)
    if lashes:
        for i in range(4, 44, 3):
            x, y = top[i]
            ang = math.radians(-100 + 25 * (i - 24) / 20)
            x2, y2 = int(x + 16 * math.cos(ang)), int(y + 16 * math.sin(ang))
            cv2.line(img, (int(x), int(y)), (x2, y2), (25, 25, 30), 2)

    img = cv2.GaussianBlur(img, (3, 3), 0)
    if noise:
        img = np.clip(img + rng.normal(0, noise, img.shape), 0, 255).astype(np.uint8)
    return img


def timeline(fps=15, seconds=30.0, seed=1):
    """Scripted sequence: gaze center/left/center/right every 4 s, a blink every ~3.5 s
    (3 frames), one 2.5 s squint at 16.5-19 s (with a blink inside it). Yields (frame, truth) with truth = {"gaze", "openness", "blink"}."""
    rng = np.random.default_rng(seed)
    n = int(fps * seconds)
    for i in range(n):
        t = i / fps
        phase = int(t // 4) % 4
        gx = (0.0, -0.8, 0.0, 0.8)[phase]
        openness, blink = 1.0, False
        if 16.5 <= t < 19.0:                                    # gaze is centered here
            openness = 0.7                                      # squint: lid over the top of the pupil
        k = i % int(3.5 * fps)
        if k in (20, 21, 22):                                   # 3-frame blink (200 ms at 15 fps)
            openness, blink = (0.3, 0.0, 0.3)[k - 20], True
        yield render((gx, 0.0), openness, rng=rng), {"gaze": gx, "openness": openness, "blink": blink}


class SynthEyeSource:
    """Endless frames for streams.py's "synthetic-eye" source."""

    def __init__(self, fps=15):
        self.fps = fps
        self._it = None

    def __next__(self):
        if self._it is None:
            self._it = timeline(self.fps, seconds=60.0)
        try:
            return next(self._it)[0]
        except StopIteration:
            self._it = None
            return next(self)
