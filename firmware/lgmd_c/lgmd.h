// LGMD collision detector, C port of lgmd.py's lgmd_step(). Integer only, no malloc.
// Must match expected.csv from `python lgmd.py --export` bit for bit (see check_vectors.c).
// Drop lgmd.h + lgmd.c into the ESP32 sketch folder to run it on the rear camera.
#pragma once
#include <stdint.h>

#define LGMD_W 80
#define LGMD_H 60
#define LGMD_NPIX (LGMD_W * LGMD_H)
#define LGMD_COL_L_END 27     /* left third:   columns  0..26 */
#define LGMD_COL_R_START 53   /* center third: columns 27..52, right: 53..79 */
#define LGMD_RISE_SAT 15

typedef struct {
  uint8_t p_min;      /* u8  noise floor on P */
  uint8_t w_shift;    /* u3  inhibition weight 2^-W_SHIFT */
  uint32_t k_thresh;  /* u21 */
  uint32_t f_max;     /* u21 */
  uint8_t n_rise;     /* u4 */
} lgmd_params_t;

typedef struct {
  uint8_t prev[LGMD_NPIX];        /* previous frame */
  uint8_t p_buf[2][LGMD_NPIX];    /* ping-pong: P of the previous frame / P being written */
  uint8_t cur_p;                  /* index of the buffer holding prev_P */
  uint32_t prev_k;                /* u21 */
  uint8_t rise;                   /* u4, saturating */
} lgmd_state_t;

typedef struct {
  uint32_t k, k_l, k_c, k_r, f;   /* u21 / u19 */
  uint8_t rise;
  uint8_t fire;
} lgmd_out_t;

#define LGMD_DEFAULT_PARAMS {10, 1, 3000, 80000, 3}

/* Reset: prev = first frame, prev_P = 0, prev_K = 0, rise = 0. */
void lgmd_init(lgmd_state_t *s, const uint8_t *first);

/* Advance one 80x60 row-major frame. */
void lgmd_step(lgmd_state_t *s, const uint8_t *cur, const lgmd_params_t *p, lgmd_out_t *out);
