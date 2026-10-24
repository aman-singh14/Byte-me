"""Unit tests for lgmd_step. Run: python -m unittest -v test_lgmd"""

import csv
import tempfile
import unittest
from pathlib import Path

import numpy as np

import lgmd
from lgmd import H, W, Params


def run(frames, params=None):
    return list(lgmd.run_clip(frames, params or Params()))


def reference_step(cur, prev, prev_P, prev_K, rise, p):
    """Per-pixel loop spelling of lgmd_step, shaped like the C port."""
    cur, prev, prev_P = cur.tolist(), prev.tolist(), prev_P.tolist()
    P = [[0] * W for _ in range(H)]
    F = 0
    for y in range(H):
        for x in range(W):
            d = cur[y][x] - prev[y][x]
            if d < 0:
                d = -d
            if d < p.p_min:
                d = 0
            P[y][x] = d
            F += d
    K_L = K_C = K_R = 0
    for y in range(H):
        for x in range(W):
            nsum = 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if (dy or dx) and 0 <= yy < H and 0 <= xx < W:
                        nsum += prev_P[yy][xx]
            s = P[y][x] - ((nsum >> 3) >> p.w_shift)
            if s < 0:
                s = 0
            if x < lgmd.COL_L_END:
                K_L += s
            elif x < lgmd.COL_R_START:
                K_C += s
            else:
                K_R += s
    K = K_L + K_C + K_R
    rise = min(rise + 1, lgmd.RISE_SAT) if K > prev_K else 0
    fire = K > p.k_thresh and F < p.f_max and rise >= p.n_rise
    return np.array(P, np.uint8), K, K_L, K_C, K_R, F, rise, fire


class SyntheticClips(unittest.TestCase):
    def test_expanding_square_fires(self):
        outs = run(lgmd.synth_approach())
        fired = [i for i, o in enumerate(outs) if o.fire]
        self.assertTrue(fired, f"never fired, K = {[o.K for o in outs]}")
        # It must fire before the square fills the frame (the last frame).
        self.assertLess(fired[0], len(outs) - 1)

    def test_sliding_square_does_not_fire(self):
        outs = run(lgmd.synth_sideways())
        self.assertFalse(any(o.fire for o in outs))
        # K is above threshold, so it is the rise test that rejects it.
        self.assertGreater(max(o.K for o in outs), Params().k_thresh)

    def test_receding_square_does_not_fire(self):
        self.assertFalse(any(o.fire for o in run(lgmd.synth_recede())))

    def test_brightness_jump_does_not_fire(self):
        outs = run(lgmd.synth_brightness_jump())
        self.assertFalse(any(o.fire for o in outs))
        self.assertGreaterEqual(max(o.F for o in outs), Params().f_max)

    def test_brightness_ramp_suppressed_by_f_max(self):
        frames = lgmd.synth_brightness_ramp()
        self.assertFalse(any(o.fire for o in run(frames)))
        # Without the F_MAX gate the same clip fires.
        no_gate = Params(f_max=lgmd.U21_MAX)
        self.assertTrue(any(o.fire for o in run(frames, no_gate)))


class Arithmetic(unittest.TestCase):
    def test_matches_per_pixel_reference(self):
        rng = np.random.default_rng(1)
        for p in (Params(), Params(p_min=0, w_shift=0, k_thresh=0, n_rise=1),
                  Params(p_min=40, w_shift=3, f_max=lgmd.U21_MAX, n_rise=0)):
            frames = rng.integers(0, 256, (6, H, W), dtype=np.uint8)
            frames[3] = frames[2]                          # a still frame
            frames[4] = np.clip(frames[3].astype(int) + 7, 0, 255)  # small change
            state = lgmd.init_state(frames[0])
            for cur in frames:
                ref = reference_step(cur, state.prev, state.prev_P, state.prev_K, state.rise, p)
                state, o = lgmd.lgmd_step(cur, state, p)
                np.testing.assert_array_equal(state.prev_P, ref[0])
                self.assertEqual((o.K, o.K_L, o.K_C, o.K_R, o.F, o.rise, o.fire), ref[1:])

    def test_max_values_fit_bit_widths(self):
        state = lgmd.init_state(np.zeros((H, W), np.uint8))
        state, o = lgmd.lgmd_step(np.full((H, W), 255, np.uint8), state, Params())
        self.assertEqual(o.K, 4800 * 255)
        self.assertEqual(o.F, 4800 * 255)
        self.assertEqual((o.K_L, o.K_C, o.K_R), (27 * 60 * 255, 26 * 60 * 255, 27 * 60 * 255))
        self.assertLess(o.K, 1 << 21)
        self.assertLess(max(o.K_L, o.K_C, o.K_R), 1 << 19)

    def test_inhibition_zero_padding_and_shift(self):
        # prev_P = 255 everywhere, P = 255 everywhere: interior I = 255, corner
        # I = 3*255 >> 3 = 95, edge I = 5*255 >> 3 = 159.
        p = Params(p_min=0, w_shift=1)
        full = np.full((H, W), 255, np.uint8)
        state = lgmd.State(np.zeros((H, W), np.uint8), full, 0, 0)
        _, o = lgmd.lgmd_step(full, state, p)
        self.assertEqual(o.S[30, 40], 255 - (255 >> 1))
        self.assertEqual(o.S[0, 0], 255 - (95 >> 1))
        self.assertEqual(o.S[0, 40], 255 - (159 >> 1))

    def test_noise_floor(self):
        prev = np.full((H, W), 100, np.uint8)
        cur = prev.copy()
        cur[0, 0], cur[0, 1] = 109, 110
        _, o = lgmd.lgmd_step(cur, lgmd.init_state(prev), Params(p_min=10))
        self.assertEqual(o.P[0, 0], 0)
        self.assertEqual(o.P[0, 1], 10)

    def test_pure(self):
        frames = lgmd.synth_approach()
        state = lgmd.init_state(frames[0])
        state, _ = lgmd.lgmd_step(frames[10], state, Params())
        before = [a.copy() for a in (frames[11], state.prev, state.prev_P)]
        lgmd.lgmd_step(frames[11], state, Params())
        for a, b in zip(before, (frames[11], state.prev, state.prev_P)):
            np.testing.assert_array_equal(a, b)

    def test_rise_counter_saturates(self):
        state = lgmd.State(np.zeros((H, W), np.uint8), np.zeros((H, W), np.uint8), 0, lgmd.RISE_SAT)
        cur = np.full((H, W), 50, np.uint8)
        state, o = lgmd.lgmd_step(cur, state, Params())
        self.assertEqual(o.rise, lgmd.RISE_SAT)


class Export(unittest.TestCase):
    def test_vectors_round_trip(self):
        frames = lgmd.synth_approach()
        with tempfile.TemporaryDirectory() as d:
            out = lgmd.export_vectors(frames, Params(), d)
            raw = (Path(out) / "frames.bin").read_bytes()
            self.assertEqual(len(raw), len(frames) * 4800)
            back = np.frombuffer(raw, np.uint8).reshape(-1, H, W)
            np.testing.assert_array_equal(back, frames)
            with open(Path(out) / "expected.csv") as f:
                rows = list(csv.DictReader(f))
        self.assertEqual(list(rows[0]), list(lgmd.CSV_COLUMNS))
        for row, o in zip(rows, run(back)):
            self.assertEqual(int(row["K"]), o.K)
            self.assertEqual(int(row["F"]), o.F)
            self.assertEqual(int(row["fire"]), int(o.fire))
        self.assertTrue(any(r["fire"] == "1" for r in rows))


if __name__ == "__main__":
    unittest.main()
