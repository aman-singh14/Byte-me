"""Open / squint / closed from the eyelid's shape (backend/eye_state.py)."""

import os

import cv2
import numpy as np
import pytest

from backend import eye_state as E
from backend.eye_calibration import change_lighting
from backend.eye_tracking import EyeTracker, CloseupEye

PHOTOS = E.DEFAULT_FOLDER
HAVE_PHOTOS = all(E.find_folder(PHOTOS, s) for s in ("left", "center", "right", "squint", "closed"))
real = pytest.mark.skipif(not HAVE_PHOTOS, reason="recorded eye-camera frames are not on this machine")


def band(frame_w=320, frame_h=240, span=0.8, thick=0.25, jagged=False, seed=0):
    """A skin-coloured picture with a dark horizontal band (a lid) across `span` of its width."""
    img = np.full((frame_h, frame_w, 3), (150, 160, 170), np.uint8)
    x0, x1 = int(frame_w * (1 - span) / 2), int(frame_w * (1 + span) / 2)
    y0, y1 = 20, 20 + int(frame_h * thick)
    img[y0:y1, x0:x1] = (25, 25, 30)
    if jagged:                                     # lashes: dark strokes hanging below the band
        rng = np.random.default_rng(seed)
        for x in range(x0, x1, 40):
            img[y1:y1 + int(rng.integers(40, 70)), x:x + 16] = (25, 25, 30)
    return cv2.GaussianBlur(img, (0, 0), 3)


def blob(frame_w=320, frame_h=240, r=45, cx=160, cy=120):
    img = np.full((frame_h, frame_w, 3), (150, 160, 170), np.uint8)
    cv2.circle(img, (cx, cy), r, (25, 25, 30), -1)
    return cv2.GaussianBlur(img, (0, 0), 3)


class TestFeatures:
    def test_band_is_wider_than_a_pupil(self):
        s_band, w_band, _ = E.lid_features(band())
        s_blob, w_blob, _ = E.lid_features(blob())
        assert s_band > 0.7 > s_blob + 0.2
        assert w_band > 2.5 > w_blob

    def test_lashes_lower_the_solidity(self):
        assert E.lid_features(band(jagged=True))[2] < E.lid_features(band())[2] - 0.05

    def test_flat_picture_has_no_features(self):
        assert E.lid_features(np.full((240, 320, 3), 120, np.uint8)) is None

    @pytest.mark.parametrize("name", ["dim room (x0.4)", "bright room (x2)", "warm light", "cool light", "sensor noise"])
    def test_lighting_barely_moves_them(self, name):
        for img in (band(), band(jagged=True), blob()):
            a, b = np.array(E.lid_features(img)), np.array(E.lid_features(change_lighting(img, name)))
            assert np.all(np.abs(a - b) < np.array(E.FEATURE_FLOORS) * 2)


class TestModel:
    def toy(self):
        return E.fit({"center": [(0.5, 1.5, 0.9)] * 5, "left": [(0.7, 2.0, 0.82)] * 5, "right": [(0.3, 1.2, 0.96)] * 5,
                      "squint": [(0.8, 2.5, 0.9)] * 5, "closed": [(0.88, 2.6, 0.7)] * 5})

    def test_states(self):
        m = self.toy()
        assert m.state((0.52, 1.5, 0.9)) == "open"
        assert m.state((0.8, 2.5, 0.9)) == "squint"
        assert m.state((0.88, 2.6, 0.7)) == "closed"

    def test_a_perfectly_still_feature_does_not_get_zero_tolerance(self):
        assert np.all(self.toy().scale >= np.array(E.FEATURE_FLOORS) - 1e-9)

    def test_roundtrip_and_wrong_features_rejected(self):
        m = self.toy()
        back = E.LidModel.from_dict(m.to_dict())
        assert back.state((0.8, 2.5, 0.9)) == "squint"
        assert E.LidModel.from_dict({"features": ["x"], "scale": [1]}) is None
        assert E.LidModel.from_dict(None) is None

    def test_saved_per_profile(self, tmp_path, monkeypatch):
        from backend import distance
        monkeypatch.setattr(distance, "CALIB_PATH", str(tmp_path / "c.json"))
        E.save_model(self.toy(), "someone", "closeup")
        assert E.load_model("someone", "closeup").state((0.88, 2.6, 0.7)) == "closed"
        assert E.load_model("other", "closeup") is None


class TestTracker:
    def tracker(self):
        m = E.fit({"center": [E.lid_features(blob())] * 3, "left": [E.lid_features(blob(cx=100))] * 3,
                   "right": [E.lid_features(blob(cx=220))] * 3, "squint": [E.lid_features(band(span=0.78))] * 3,
                   "closed": [E.lid_features(band(span=0.88, jagged=True))] * 3})
        return EyeTracker({"eye": {"method": "closeup"}}, extractor=CloseupEye(lid_model=m))

    def test_closed_lid_is_a_blink_not_an_open_eye(self):
        tr = self.tracker()
        t = 0.0
        for _ in range(130):
            tr.process(blob(), t); t += 0.05
        for _ in range(3):
            tr.process(band(span=0.88, jagged=True), t); t += 0.05
        for _ in range(20):
            tr.process(blob(), t); t += 0.05
        assert tr.detector.total_blinks == 1

    def test_open_eye_looking_around_is_not_a_blink_or_squint(self):
        tr = self.tracker()
        t = 0.0
        for cx in [160] * 100 + [100] * 40 + [220] * 40 + [160] * 40:
            tr.process(blob(cx=cx), t); t += 0.05
        assert tr.detector.total_blinks == 0 and not tr.detector.squinting

    def test_squint_is_noticed(self):
        tr = self.tracker()
        t, events = 0.0, []
        for _ in range(120):
            events += tr.process(blob(), t)[1]; t += 0.05
        for _ in range(50):
            events += tr.process(band(span=0.78), t)[1]; t += 0.05
        assert "squint_start" in [e[0] for e in events]


@real
class TestRealFrames:
    def feats(self):
        return E.features_by_state(E.load_frames(PHOTOS))

    def test_leave_one_out(self):
        right, total, _ = E.leave_one_out(self.feats())
        assert right >= 0.9 * total

    def test_closed_and_squint_never_confused_with_each_other(self):
        feats = self.feats()
        m = E.fit({k: [v for _, v in its] for k, its in feats.items()})
        assert all(m.state(v) == "closed" for _, v in feats["closed"])
        assert all(m.state(v) == "squint" for _, v in feats["squint"])

    def test_survives_dim_and_shaded_light(self):
        frames = E.load_frames(PHOTOS)
        feats = self.feats()
        m = E.fit({k: [v for _, v in its] for k, its in feats.items()})
        ok = tot = 0
        for name in ("dim room (x0.4)", "bright room (x2)", "warm light", "cool light", "sensor noise", "extra blur",
                     "shade from top", "shade from bottom", "shade from left"):
            for state, items in frames.items():
                for _, f in items:
                    v = E.lid_features(change_lighting(f, name))
                    tot += 1
                    ok += v is not None and m.state(v) == ("open" if state in E.OPEN_STATES else state)
        assert ok >= 0.9 * tot
