"""Eye calibration from recorded frames: cropping screenshots, locating the pupil in blurry
frames under changing light, dropping outliers, saving, and (when the photos are present) the
real recordings in backend/data/eye_calibration."""

import os
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from unittest import mock

import cv2
import numpy as np

from backend import distance, eye_calibration as ec
from backend.config import load_config
from backend.gaze import GazeTracker
from backend.pupil import FEATURE_NAMES, locate

REAL_FOLDER = ec.DEFAULT_FOLDER


def screenshot(picture, canvas=(1500, 1180), at=(120, 90), title=True, stray=False):
    """A fake screenshot of the stream page: dark page, title, the camera picture inside."""
    page = np.full((canvas[1], canvas[0], 3), 17, np.uint8)
    if title:
        cv2.putText(page, "ESP32-CAM Live", (canvas[0] // 2 - 150, 45), cv2.FONT_HERSHEY_SIMPLEX, 1.4,
                    (240, 240, 240), 3)
    big = cv2.resize(picture, (1280, 960), interpolation=cv2.INTER_LINEAR)
    page[at[1]:at[1] + 960, at[0]:at[0] + 1280] = big
    if stray:                                              # stray light pixels in the top corners
        page[:4, :6] = (112, 112, 112)
        page[:4, -6:] = (112, 112, 112)
    return page


def eye_frame(gx, openness=1.0, seed=0):
    """A close-up eye like the REAL eye camera sees it: soft focus, a big dark pupil mass with a
    darker-than-skin iris around it, two glints, a lid shadow and sensor noise (gx -1..1 = look
    left..right). The crisp drawing in synth_eye.py is much sharper than the real camera."""
    w, h = 320, 240
    rng = np.random.default_rng(seed)
    img = np.empty((h, w, 3), np.float32)
    img[:] = (95, 105, 125)                                           # skin
    img *= np.linspace(0.8, 1.15, h)[:, None, None]
    cv2.rectangle(img, (0, 0), (w, int(h * 0.12)), (60, 65, 75), -1)  # lid shadow
    cx, cy = int(w * (0.52 + 0.17 * gx)), int(h * 0.32)
    cv2.ellipse(img, (cx, cy), (95, 55), 0, 0, 360, (150, 155, 160), -1)   # the eye opening (lighter)
    cv2.ellipse(img, (cx, cy), (48, 40), 0, 0, 360, (45, 60, 70), -1)      # iris
    cv2.ellipse(img, (cx, cy), (32, 28), 0, 0, 360, (14, 16, 16), -1)      # pupil
    for dx, dy, r in ((14, -18, 5), (24, -12, 4)):
        cv2.circle(img, (cx + dx, cy + dy), r, (235, 235, 235), -1)        # glints
    cv2.ellipse(img, (cx, cy), (100, 60), 0, 200, 340, (25, 25, 25), 3)    # lashes
    img = cv2.GaussianBlur(img, (0, 0), 5)                                 # the eye is a few cm from the lens
    img += rng.normal(0, 3, img.shape)
    return np.clip(img, 0, 255).astype(np.uint8)


class Cropping(unittest.TestCase):
    def setUp(self):
        self.pic = eye_frame(0.0)
        self.want = cv2.resize(self.pic, (320, 240), interpolation=cv2.INTER_AREA)

    def err(self, crop):
        return float(np.abs(crop.astype(int) - self.want.astype(int)).mean())

    def test_finds_the_picture_wherever_it_is(self):
        for canvas, at in (((1500, 1180), (120, 90)), ((1700, 1300), (60, 130)), ((1428, 1130), (68, 115)),
                           ((1746, 1268), (184, 77))):
            crop = ec.crop_camera_view(screenshot(self.pic, canvas, at))
            self.assertEqual(crop.shape, (240, 320, 3))
            self.assertLess(self.err(crop), 6, f"canvas {canvas} at {at}")

    def test_stray_corner_pixels_do_not_matter(self):
        crop = ec.crop_camera_view(screenshot(self.pic, stray=True))
        self.assertLess(self.err(crop), 6)

    def test_page_title_does_not_leak_in(self):
        crop = ec.crop_camera_view(screenshot(self.pic, at=(120, 70)))   # title very close to the picture
        self.assertLess(self.err(crop), 6)

    def test_raw_camera_frames_pass_through(self):
        crop = ec.crop_camera_view(self.pic)
        self.assertEqual(crop.shape, (240, 320, 3))
        self.assertLess(self.err(crop), 3)
        wide = cv2.resize(self.pic, (640, 360))                          # 16:9 raw frame: centre-cropped to 4:3
        self.assertEqual(ec.crop_camera_view(wide).shape, (240, 320, 3))

    def test_dark_vignetted_frame_is_not_mistaken_for_a_screenshot(self):
        frame = np.zeros((480, 640, 3), np.uint8)
        cv2.circle(frame, (320, 240), 230, (120, 130, 150), -1)           # flat black corners, round picture
        crop = ec.crop_camera_view(frame)
        self.assertEqual(crop.shape, (240, 320, 3))
        self.assertGreater(crop.mean(), 40)                               # the whole frame, not a sliver

    def test_unusable_images(self):
        self.assertIsNone(ec.crop_camera_view(None))
        self.assertIsNone(ec.crop_camera_view(np.zeros((10, 10, 3), np.uint8)))


class Locator(unittest.TestCase):
    def centres(self):
        fixes = {n: locate(eye_frame(g)) for n, g in (("left", -0.8), ("center", 0.0), ("right", 0.8))}
        self.assertTrue(all(fixes.values()))
        return fixes

    def test_follows_gaze_left_to_right(self):
        f = self.centres()
        self.assertLess(f["left"].x, f["center"].x - 0.05)
        self.assertLess(f["center"].x, f["right"].x - 0.05)
        self.assertAlmostEqual(f["center"].x, 0.52, delta=0.04)               # where the pupil was drawn
        self.assertAlmostEqual(f["center"].y, 0.32, delta=0.06)

    def test_signed_coordinates(self):
        f = locate(eye_frame(0.0))
        self.assertAlmostEqual(f.as_signed()[0], 2 * f.x - 1)

    def test_shape_numbers_describe_the_dark_mass(self):
        def blob(cx, cy, ax, ay):
            img = np.full((240, 320, 3), 150, np.uint8)
            cv2.ellipse(img, (cx, cy), (ax, ay), 0, 0, 360, (20, 20, 20), -1)
            return cv2.GaussianBlur(img, (0, 0), 3)
        round_ = locate(blob(160, 120, 30, 30))
        long_ = locate(blob(160, 120, 70, 24))
        self.assertAlmostEqual(round_.elong, 1.0, delta=0.25)
        self.assertGreater(long_.elong, 2.0)
        self.assertGreater(long_.area, round_.area)
        for fix, half in ((round_, 30), (long_, 70)):
            self.assertAlmostEqual(fix.left_edge, (160 - half) / 320, delta=0.08)   # reaches as far left as drawn
        shifted = locate(blob(110, 120, 30, 30))                     # the same blob further left
        self.assertLess(shifted.left_edge, round_.left_edge - 0.1)
        self.assertEqual(len(round_.vector()), len(FEATURE_NAMES))
        self.assertGreater(round_.core_area, 0)
        self.assertLess(round_.core_area, round_.area)               # the core is a part of the mass

    def test_flat_frame_has_no_pupil(self):
        self.assertIsNone(locate(np.full((240, 320, 3), 120, np.uint8)))
        noise = np.clip(np.random.default_rng(0).normal(120, 2, (240, 320, 3)), 0, 255).astype(np.uint8)
        self.assertIsNone(locate(noise))

    def test_survives_every_lighting_change(self):
        base = self.centres()
        centres = {k: (v.x, v.y) for k, v in base.items()}
        for name in ec.LIGHTING_CHANGES:
            for cls, g in (("left", -0.8), ("center", 0.0), ("right", 0.8)):
                fix = locate(ec.change_lighting(eye_frame(g), name))
                self.assertIsNotNone(fix, f"{name}: pupil lost ({cls})")
                self.assertEqual(ec.classify((fix.x, fix.y), centres), cls, f"{name}: {cls} misread")
                self.assertLess(np.hypot(fix.x - base[cls].x, fix.y - base[cls].y), 0.06, f"{name}: moved too far")


@dataclass
class Fix:
    """A fake PupilFix: position plus the shape numbers of pupil.FEATURE_NAMES."""
    x: float
    y: float
    left_edge: float = 0.3
    contrast: float = 0.6
    core_area: float = 0.08
    elong: float = 1.6
    core_x: float | None = None
    core_y: float | None = None

    def as_signed(self):
        return 2 * self.x - 1, 2 * self.y - 1

    def vector(self):
        cx = self.x if self.core_x is None else self.core_x
        cy = self.y if self.core_y is None else self.core_y
        return [2 * self.x - 1, 2 * self.y - 1, self.left_edge, self.contrast, self.core_area,
                float(np.log(self.elong)), 2 * cx - 1, 2 * cy - 1]


SHAPE = {   # what each direction looks like (modelled on the real recordings)
    "left": dict(left_edge=0.18, contrast=0.49, core_area=0.053, elong=3.7),
    "center": dict(left_edge=0.34, contrast=0.63, core_area=0.092, elong=1.66),
    "right": dict(left_edge=0.58, contrast=0.58, core_area=0.045, elong=1.6),
}


def fake_samples(rng=None, same_position=False):
    """9 frames per direction. same_position=True gives left and center the SAME x, y (only the shape
    differs): the situation where the centre of the dark mass can't tell them apart."""
    rng = rng or np.random.default_rng(0)
    out = []
    pos = {"left": (0.45, 0.40), "center": (0.58, 0.22), "right": (0.72, 0.30)}
    if same_position:
        pos["left"] = pos["center"]
    for cls, (cx, cy) in pos.items():
        for _ in range(9):
            shape = {k: v * (1 + rng.normal(0, 0.04)) for k, v in SHAPE[cls].items()}
            out.append(ec.Sample(cls, f"{cls}.png", np.zeros((240, 320, 3), np.uint8),
                                 Fix(cx + rng.normal(0, 0.01), cy + rng.normal(0, 0.01), **shape)))
    return out


class Calibration(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._p = mock.patch.object(distance, "CALIB_PATH", Path(self._tmp.name) / "c.json")
        self._p.start()

    def tearDown(self):
        self._p.stop()
        self._tmp.cleanup()

    def test_outliers_are_dropped_and_do_not_move_the_centres(self):
        samples = fake_samples()
        clean = ec.class_centres(ec.mark_outliers([s for s in fake_samples()]))
        blink = ec.Sample("center", "blink.png", np.zeros((240, 320, 3), np.uint8), Fix(0.37, 0.64))
        mid_move = ec.Sample("right", "moving.png", np.zeros((240, 320, 3), np.uint8), Fix(0.58, 0.30))
        samples += [blink, mid_move]
        ec.mark_outliers(samples)
        self.assertFalse(blink.inlier)
        self.assertFalse(mid_move.inlier)
        self.assertIn("outlier", blink.note)
        centres = ec.class_centres(samples)
        for k in clean:
            self.assertAlmostEqual(centres[k][0], clean[k][0], places=6)
            self.assertAlmostEqual(centres[k][1], clean[k][1], places=6)

    def test_tight_classes_are_not_over_rejected(self):
        samples = ec.mark_outliers(fake_samples())
        self.assertTrue(all(s.inlier for s in samples))

    def test_leave_one_out_on_separated_data(self):
        samples = ec.mark_outliers(fake_samples())
        for shaped in (True, False):
            correct, total, conf = ec.leave_one_out(samples, shaped=shaped)
            self.assertEqual((correct, total), (27, 27))
            self.assertEqual(conf["left"]["left"], 9)

    def test_shape_tells_left_from_center_when_the_position_cannot(self):
        """Left and center with the same centre of mass: position alone is a coin flip, the shape
        (reach to the left, less solid black, longer mass) separates them."""
        samples = ec.mark_outliers(fake_samples(same_position=True))
        flat_correct, total, _ = ec.leave_one_out(samples, shaped=False)
        shaped_correct, _, conf = ec.leave_one_out(samples, shaped=True)
        self.assertLess(flat_correct, total - 6, "position alone should not manage this")
        self.assertEqual(shaped_correct, total)
        self.assertEqual(conf["left"]["center"], 0)
        pos = ec.fit_model(samples, dims=(0, 1))
        full = ec.fit_model(samples)
        self.assertLess(pos.distance(pos.centres["left"], "center"), 1.0)      # nearly the same spot
        self.assertGreater(full.distance(full.centres["left"], "center"), 8.0)  # far apart with shape

    def test_shape_keeps_working_when_the_position_reading_is_off(self):
        samples = ec.mark_outliers(fake_samples())
        flat, full = ec.fit_model(samples, shaped=False), ec.fit_model(samples)
        for sigma in (0.06, 0.10):
            self.assertGreater(ec.position_noise_test(samples, full, sigma), ec.position_noise_test(samples, flat, sigma))
        self.assertGreater(ec.position_noise_test(samples, full, 0.10), 0.9)

    def test_a_perfectly_still_feature_cannot_dominate(self):
        samples = fake_samples()
        for s in samples:
            s.fix.core_area = 0.07                                        # no wobble at all
        model = ec.fit_model(ec.mark_outliers(samples))
        i = 4                                                              # core_area
        self.assertGreater(model.scale[i], 0.3 * float(np.median(model.scale)))

    def test_overlapping_classes_are_reported_weak(self):
        rng = np.random.default_rng(1)
        samples = []
        for cls, cx in (("left", 0.50), ("center", 0.52), ("right", 0.54)):
            samples += [ec.Sample(cls, "x", np.zeros((240, 320, 3), np.uint8),
                                  Fix(cx + rng.normal(0, 0.05), 0.3 + rng.normal(0, 0.05))) for _ in range(9)]
        ec.mark_outliers(samples)
        centres = ec.class_centres(samples)
        gap, spread = ec.separation(samples, centres)
        self.assertLess(gap, 3 * spread)

    def test_saved_profile_is_per_eye_method_and_loaded_by_gaze(self):
        centres = {"left": (0.45, 0.40), "center": (0.58, 0.22), "right": (0.72, 0.30)}
        signed = ec.save_centres(centres, user="me", method="closeup")           # position-only profile
        self.assertAlmostEqual(signed["left"][0], -0.10)
        cfg = load_config()                                             # product: eye method closeup
        g = GazeTracker(cfg)
        self.assertTrue(g.calibrated)
        self.assertEqual(g.profile, "me@closeup")
        self.assertAlmostEqual(g.centroids["right"][0], 0.44)
        for pupil, want in (((-0.1, -0.2), "left"), ((0.16, -0.56), "center"), ((0.44, -0.4), "right")):
            g.current = None
            self.assertEqual(g.classify_raw(pupil), want)
        dev = GazeTracker(load_config(dev=True))                        # webcam method: untouched
        self.assertFalse(dev.calibrated)
        self.assertEqual(dev.profile, "me@facemesh")

    def test_saved_position_and_shape_model_is_used_by_gaze(self):
        samples = ec.mark_outliers(fake_samples(same_position=True))
        model = ec.fit_model(samples)
        saved = ec.save_model(model, user="me", method="closeup")
        self.assertEqual(saved["features"], list(FEATURE_NAMES))
        self.assertEqual(len(saved["scale"]), len(FEATURE_NAMES))
        g = GazeTracker(load_config())
        self.assertIsNotNone(g.scale)
        self.assertEqual(g.feature_names, tuple(FEATURE_NAMES))
        fixes = {cls: [s.fix for s in samples if s.cls == cls] for cls in ec.CLASSES}
        for cls, group in fixes.items():
            for fix in group:
                g.current = None
                self.assertEqual(g.classify_raw(tuple(fix.vector())), cls)
        # a reading with only a position falls back to position (does not crash, uses the first two numbers)
        g.current = None
        self.assertIn(g.classify_raw((0.16, -0.56)), ec.CLASSES)

    def test_whole_pipeline_on_screenshots(self):
        folder = Path(self._tmp.name) / "shots"
        rng = np.random.default_rng(3)
        for cls, g in (("left", -0.8), ("center", 0.0), ("right", 0.8)):
            (folder / cls).mkdir(parents=True)
            for i in range(6):
                canvas = (1450 + int(rng.integers(0, 250)), 1150 + int(rng.integers(0, 150)))
                at = (60 + int(rng.integers(0, 120)), 80 + int(rng.integers(0, 40)))
                shot = screenshot(eye_frame(g + rng.normal(0, 0.03), seed=i), canvas, at, stray=bool(i % 2))
                cv2.imwrite(str(folder / cls / f"shot{i}.png"), shot)
        samples = ec.load_samples(str(folder))
        self.assertEqual(len(samples), 18)
        self.assertTrue(all(s.fix for s in samples))
        out = []
        model, ok = ec.report(samples, out=out.append)
        self.assertTrue(ok, "\n".join(out))
        self.assertLess(model.centres["left"][0], model.centres["center"][0])
        self.assertLess(model.centres["center"][0], model.centres["right"][0])
        self.assertIn("position + shape", "\n".join(out))
        self.assertTrue(ec.check_saved(samples, out=lambda *a: None) is False)     # nothing saved yet


@unittest.skipUnless(os.path.isdir(os.path.join(REAL_FOLDER, "center")), "no recorded eye frames on this machine")
class RealRecordings(unittest.TestCase):
    """The user's own frames (backend/data is git-ignored, so this only runs where they exist)."""

    @classmethod
    def setUpClass(cls):
        cls.samples = ec.mark_outliers(ec.load_samples(REAL_FOLDER))

    def test_every_screenshot_was_cropped_to_the_camera_picture(self):
        for s in self.samples:
            self.assertIsNotNone(s.frame, s.path)
            self.assertEqual(s.frame.shape, (240, 320, 3))
            # a cropped picture has no flat dark page margin (the stream page background is grey 17)
            self.assertGreater(float(s.frame[:6].mean()), 30, s.path)

    def test_three_directions_are_separable(self):
        centres = ec.class_centres(self.samples)
        self.assertEqual(set(centres), set(ec.CLASSES))
        correct, total, _ = ec.leave_one_out(self.samples)
        self.assertGreaterEqual(correct, 0.9 * total, f"{correct}/{total}")

    def test_shape_features_make_left_and_center_more_distinct(self):
        pos = ec.fit_model(self.samples, dims=(0, 1))
        full = ec.fit_model(self.samples)
        self.assertGreater(full.distance(full.centres["left"], "center"),
                           1.5 * pos.distance(pos.centres["left"], "center"))
        flat = ec.fit_model(self.samples, shaped=False)
        self.assertGreater(ec.position_noise_test(self.samples, full, 0.10),
                           ec.position_noise_test(self.samples, flat, 0.10))

    def test_lighting_changes_do_not_break_it(self):
        rows = ec.lighting_test(self.samples, ec.fit_model(self.samples))
        for name, ok, total, median, worst, lost in rows:
            self.assertGreaterEqual(ok / total, 0.85, name)
            self.assertLess(median, 0.05, name)


if __name__ == "__main__":
    unittest.main()
