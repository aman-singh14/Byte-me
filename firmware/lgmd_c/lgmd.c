// C port of lgmd.py lgmd_step(). Same structure as test_lgmd.reference_step.
#include "lgmd.h"

#include <string.h>

void lgmd_init(lgmd_state_t *s, const uint8_t *first) {
  memcpy(s->prev, first, LGMD_NPIX);
  memset(s->p_buf, 0, sizeof(s->p_buf));
  s->cur_p = 0;
  s->prev_k = 0;
  s->rise = 0;
}

void lgmd_step(lgmd_state_t *s, const uint8_t *cur, const lgmd_params_t *p, lgmd_out_t *out) {
  const uint8_t *prev_p = s->p_buf[s->cur_p];
  uint8_t *P = s->p_buf[s->cur_p ^ 1];   // write P here while I reads prev_P
  uint32_t f = 0;

  // P = |cur - prev|, zeroed below P_MIN.  F = sum(P).
  for (int i = 0; i < LGMD_NPIX; i++) {
    int16_t d = (int16_t)cur[i] - (int16_t)s->prev[i];   // s9
    if (d < 0) d = -d;
    if (d < p->p_min) d = 0;
    P[i] = (uint8_t)d;
    f += (uint32_t)d;
  }

  // S = max(P - ((8-neighbor sum of prev_P) >> 3 >> W_SHIFT), 0), zero padding.
  uint32_t k_l = 0, k_c = 0, k_r = 0;
  for (int y = 0; y < LGMD_H; y++) {
    for (int x = 0; x < LGMD_W; x++) {
      uint16_t nsum = 0;   // u11
      for (int dy = -1; dy <= 1; dy++) {
        int yy = y + dy;
        if (yy < 0 || yy >= LGMD_H) continue;
        for (int dx = -1; dx <= 1; dx++) {
          int xx = x + dx;
          if ((dx == 0 && dy == 0) || xx < 0 || xx >= LGMD_W) continue;
          nsum += prev_p[yy * LGMD_W + xx];
        }
      }
      int16_t sv = (int16_t)P[y * LGMD_W + x] - (int16_t)((nsum >> 3) >> p->w_shift);   // s9
      if (sv < 0) sv = 0;
      if (x < LGMD_COL_L_END) k_l += (uint32_t)sv;
      else if (x < LGMD_COL_R_START) k_c += (uint32_t)sv;
      else k_r += (uint32_t)sv;
    }
  }
  uint32_t k = k_l + k_c + k_r;

  s->rise = (k > s->prev_k) ? (s->rise < LGMD_RISE_SAT ? s->rise + 1 : LGMD_RISE_SAT) : 0;
  out->fire = (k > p->k_thresh) && (f < p->f_max) && (s->rise >= p->n_rise);

  memcpy(s->prev, cur, LGMD_NPIX);
  s->cur_p ^= 1;   // this frame's P becomes prev_P
  s->prev_k = k;

  out->k = k;
  out->k_l = k_l;
  out->k_c = k_c;
  out->k_r = k_r;
  out->f = f;
  out->rise = s->rise;
}
