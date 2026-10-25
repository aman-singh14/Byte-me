"""Is the eye open, squinting or closed? From the shape of the dark mass in the close-up frame.

No neural network and nothing downloaded: three numbers per frame and a nearest-centroid
rule, calibrated from a few example frames of each state (the same idea as gaze.py).

At this camera distance the picture is soft, and when the lid comes down there is no pupil
left to find. What is left is the eyelid itself: a dark band. Its shape tells the states apart:

    open      a compact mass (the pupil), narrower than the picture
    squint    a wide, thin, SMOOTH band: the lid edge and lashes pressed together look like
              one solid line
    closed    a wide, thin band with a JAGGED lower edge: single lashes hang down and show

so the three features are, measured on the lighting-normalised frame (backend/pupil.py
normalize(), so a dim room, a colour cast or a ramp of light does not matter):

    span        how much of the picture's width the dark mass covers
    wide        its bounding-box width / height
    solidity    its area / the area of its convex hull (lashes cut notches in it: lower)

Skin colour is deliberately NOT used: it is the easiest thing to overfit to a few photos
of one person and says nothing about the eyelid. Brightness is not used either.

Classes are the five calibrated groups (look left / centre / right, squint, closed): gaze
changes the dark mass a lot, so "open" is three centroids rather than one blurry average.
Each feature is divided by how much it wobbles inside a class, with a floor measured from how
far ordinary lighting changes move it, so a feature that happened to sit still in the examples
cannot decide everything.
"""

import glob
import os

import cv2
import numpy as np

from backend.pupil import normalize

FEATURE_NAMES = ("span", "wide", "solidity")
# Least wobble allowed per feature, from how far lighting changes (dimmer, brighter, shaded,
# tinted, noisy) move it on the real recordings, rounded up. See eye_calibration.lid_lighting_test.
FEATURE_FLOORS = (0.10, 0.30, 0.04)
BLUR = 7.0
FRAC = 0.5                         # "half-max" of the darkness, as in pupil.locate
OPEN_STATES = ("left", "center", "right")
STATES = OPEN_STATES + ("squint", "closed")
# Folder names are accepted in any of these spellings.
FOLDER_ALIASES = {"left": ("left",), "center": ("center", "centre"), "right": ("right",),
                  "squint": ("squint", "squinting", "eyes_squinting"),
                  "closed": ("closed", "eyes_closed", "closed_eyes")}
IMAGE_EXTS = (".png", ".jpg", ".jpeg", ".bmp", ".webp")


def lid_features(bgr):
    """(span, wide, solidity) of the dominant dark mass, or None for a frame with no contrast at all."""
    n = normalize(bgr).astype(np.float32)
    d = cv2.GaussianBlur(1.0 - n, (0, 0), BLUR)
    base, peak = float(np.median(d)), float(np.quantile(d, 0.995))
    if peak - base < 0.15:
        return None
    k, lab, st, _ = cv2.connectedComponentsWithStats((d >= base + FRAC * (peak - base)).astype(np.uint8))
    if k < 2:
        return None
    best = 1 + int(np.argmax([float((d * (lab == i)).sum()) for i in range(1, k)]))
    w, h = int(st[best, cv2.CC_STAT_WIDTH]), int(st[best, cv2.CC_STAT_HEIGHT])
    cnts, _ = cv2.findContours((lab == best).astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    c = max(cnts, key=cv2.contourArea)
    solidity = cv2.contourArea(c) / max(cv2.contourArea(cv2.convexHull(c)), 1.0)
    return (w / lab.shape[1], w / max(h, 1), float(solidity))


class LidModel:
    """Nearest centroid in units of per-feature wobble. `centroids` maps each state to its vector."""

    def __init__(self, centroids, scale):
        self.centroids = {k: np.asarray(v, float) for k, v in centroids.items()}
        self.scale = np.asarray(scale, float)

    def distances(self, vec):
        v = np.asarray(vec, float)
        return {k: float(np.sqrt((((v - c) / self.scale) ** 2).sum())) for k, c in self.centroids.items()}

    def classify(self, vec):
        """('left'|'center'|'right'|'squint'|'closed', distance to it)."""
        dist = self.distances(vec)
        best = min(dist, key=dist.get)
        return best, dist[best]

    def state(self, vec):
        """'open' | 'squint' | 'closed' (the three gaze centroids all mean open)."""
        label, _ = self.classify(vec)
        return "open" if label in OPEN_STATES else label

    def to_dict(self):
        out = {k: [float(x) for x in v] for k, v in self.centroids.items()}
        out["scale"] = [float(x) for x in self.scale]
        out["features"] = list(FEATURE_NAMES)
        return out

    @classmethod
    def from_dict(cls, d):
        if not d or tuple(d.get("features", ())) != FEATURE_NAMES:
            return None
        cents = {k: d[k] for k in STATES if k in d}
        if "squint" not in cents and "closed" not in cents:
            return None
        return cls(cents, d["scale"])


def fit(by_class):
    """by_class: state -> list of feature vectors. Centroid = median; scale = pooled robust wobble, floored."""
    cents, spreads = {}, []
    for k, vecs in by_class.items():
        a = np.asarray(vecs, float)
        med = np.median(a, axis=0)
        cents[k] = med
        spreads.append((np.median(np.abs(a - med), axis=0) * 1.4826) ** 2)
    pooled = np.sqrt(np.mean(spreads, axis=0))
    return LidModel(cents, np.maximum(pooled, FEATURE_FLOORS))


def find_folder(root, state):
    for name in FOLDER_ALIASES[state]:
        p = os.path.join(root, name)
        if os.path.isdir(p):
            return p
    return None


def load_frames(root, size=(320, 240)):
    """state -> [(path, frame)] for every state folder under root (already-cropped camera pictures)."""
    out = {}
    for state in STATES:
        folder = find_folder(root, state)
        if not folder:
            continue
        frames = []
        for p in sorted(glob.glob(os.path.join(folder, "*"))):
            if p.lower().endswith(IMAGE_EXTS):
                img = cv2.imread(p)
                if img is not None:
                    frames.append((p, cv2.resize(img, size, interpolation=cv2.INTER_AREA)))
        if frames:
            out[state] = frames
    return out


def features_by_state(frames):
    out = {}
    for state, items in frames.items():
        feats = [(p, lid_features(f)) for p, f in items]
        out[state] = [(p, v) for p, v in feats if v is not None]
    return out


def leave_one_out(feats):
    """Refit without each frame in turn and classify it. -> (correct, total, mistakes [(path, true, predicted)])."""
    correct, total, bad = 0, 0, []
    for state, items in feats.items():
        for i, (path, vec) in enumerate(items):
            rest = {k: [v for j, (_, v) in enumerate(its) if not (k == state and j == i)]
                    for k, its in feats.items()}
            rest = {k: v for k, v in rest.items() if v}
            pred = fit(rest).state(vec)
            truth = "open" if state in OPEN_STATES else state
            total += 1
            if pred == truth:
                correct += 1
            else:
                bad.append((os.path.basename(path), state, pred))
    return correct, total, bad


# ---- saving, loading, the command line --------------------------------------------------------

DEFAULT_FOLDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "eye_calibration_cropped")


def profile_name(user="me", method="closeup"):
    return f"{user}@{method}"


def save_model(model, user="me", method="closeup"):
    from backend.distance import load_calibration, save_calibration
    data = load_calibration().get("eye_state", {})
    data[profile_name(user, method)] = model.to_dict()
    save_calibration("eye_state", data)


def load_model(user="me", method="closeup"):
    """The saved LidModel for this wearer and eye method, or None (then openness stays as before)."""
    from backend.distance import load_calibration
    return LidModel.from_dict(load_calibration().get("eye_state", {}).get(profile_name(user, method)))


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(description="Calibrate open / squint / closed from example eye-camera frames")
    ap.add_argument("folder", nargs="?", default=DEFAULT_FOLDER,
                    help="folder with left/ center/ right/ eyes_squinting/ eyes_closed/ pictures")
    ap.add_argument("--save", action="store_true", help="save the calibration (profile <user>@<method>)")
    ap.add_argument("--user", default="me")
    ap.add_argument("--method", default="closeup")
    args = ap.parse_args(argv)
    frames = load_frames(args.folder)
    missing = [s for s in ("squint", "closed") if s not in frames]
    if missing or not any(s in frames for s in OPEN_STATES):
        print(f"need pictures of an open eye (left/center/right) and of {', '.join(missing) or 'squint and closed'}"
              f" in {args.folder}")
        return 1
    feats = features_by_state(frames)
    print("frames per state: " + ", ".join(f"{k} {len(v)}" for k, v in feats.items()))
    model = fit({k: [v for _, v in its] for k, its in feats.items()})
    print("%-8s %s" % ("state", "  ".join(f"{n:>9s}" for n in FEATURE_NAMES)))
    for k in STATES:
        if k in model.centroids:
            print("%-8s %s" % (k, "  ".join(f"{x:9.3f}" for x in model.centroids[k])))
    print("wobble   " + "  ".join(f"{x:9.3f}" for x in model.scale))
    right, total, bad = leave_one_out(feats)
    print(f"leave-one-out (each frame judged by a model that never saw it): {right}/{total} correct")
    for name, true, pred in bad:
        print(f"  wrong: {name}: is {true}, called {pred}")
    if args.save:
        save_model(model, args.user, args.method)
        print(f"saved {profile_name(args.user, args.method)} to backend/data/calibration.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
