"""Writes the eye-tracking parity fixtures for the phone app: synthetic close-up eye frames
(backend/synth_eye.py) and what the laptop's own code finds in them (backend/pupil.py locate,
backend/eye_tracking.py CloseupEye). mobile-app/test/eye_parity_test.dart runs the app's port
(mobile-app/lib/eyes/pupil.dart) on the same frames and expects the same answers.

    .venv/bin/python tools/make_eye_fixtures.py

Run it again after changing the laptop's eye code, then make the app match.
"""

import gzip
import json
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from backend import synth_eye  # noqa: E402
from backend.eye_calibration import change_lighting  # noqa: E402
from backend.eye_tracking import CloseupEye  # noqa: E402
from backend.pupil import locate  # noqa: E402

OUT = os.path.join(ROOT, "mobile-app", "test", "fixtures", "eye")


def grey(bgr):
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)


def blob(cx, cy, ax, ay):
    img = np.full((240, 320), 150, np.uint8)
    cv2.ellipse(img, (cx, cy), (ax, ay), 0, 0, 360, 20, -1)
    return cv2.GaussianBlur(img, (0, 0), 3)


def sequence():
    """(name, grey frame): settle on an open eye, then gaze, lid, lighting, noise and a closed eye."""
    frames = [(f"settle {i}", grey(synth_eye.render((0, 0), 1.0, noise=0))) for i in range(12)]
    frames += [(f"gaze {g:+.1f}", grey(synth_eye.render((g, 0), 1.0, noise=0))) for g in (-0.8, -0.4, 0.0, 0.4, 0.8)]
    frames += [(f"open {o}", grey(synth_eye.render((0, 0), o, noise=0))) for o in (1.0, 0.7, 0.5, 0.3, 0.05, 0.0)]
    frames += [("reopen", grey(synth_eye.render((0, 0), 1.0, noise=0)))]
    for name in ("dim room (x0.4)", "bright room (x2)", "shade from left", "gamma 1.7", "extra blur"):
        frames.append((name, grey(change_lighting(synth_eye.render((-0.6, 0), 1.0, noise=0), name))))
    frames.append(("noisy", grey(synth_eye.render((0.5, 0), 1.0, noise=4.0))))
    frames.append(("no glint", grey(synth_eye.render((0, 0), 1.0, glint=False, noise=0))))
    return frames


def main():
    os.makedirs(OUT, exist_ok=True)
    frames = sequence() + [("blob round", blob(160, 120, 30, 30)), ("blob long", blob(160, 120, 70, 24)),
                           ("blob left", blob(110, 120, 30, 30)), ("flat", np.full((240, 320), 120, np.uint8))]
    eye = CloseupEye()
    expected = []
    for i, (name, g) in enumerate(frames):
        fix = locate(g)
        row = {"name": name, "locate": None if fix is None else [round(v, 5) for v in fix.vector()]}
        if not name.startswith(("blob", "flat")):        # CloseupEye only sees the eye sequence, in order
            f = eye.extract(g)
            row["openness"] = round(f.openness, 5)
            row["pupil"] = None if f.pupil is None else [round(v, 5) for v in f.pupil]
        expected.append(row)
    with gzip.open(os.path.join(OUT, "frames.gray.gz"), "wb", compresslevel=9) as f:
        for _, g in frames:
            f.write(np.ascontiguousarray(g, np.uint8).tobytes())
    with open(os.path.join(OUT, "expected.json"), "w") as f:
        json.dump({"width": 320, "height": 240, "frames": expected}, f, indent=1)
    print(f"{len(frames)} frames -> {OUT}")


if __name__ == "__main__":
    main()
