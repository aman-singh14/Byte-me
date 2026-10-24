// Bit-exact check of lgmd.c against a vectors directory from `python lgmd.py --export CLIP --out DIR`.
//   cc -O2 -Wall -o check_vectors check_vectors.c lgmd.c && ./check_vectors DIR
// Exit 0 when every row of expected.csv matches.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lgmd.h"

static long json_int(const char *json, const char *key) {
  char pat[64];
  snprintf(pat, sizeof(pat), "\"%s\":", key);
  const char *at = strstr(json, pat);
  if (!at) {
    fprintf(stderr, "params.json: missing %s\n", key);
    exit(2);
  }
  return strtol(at + strlen(pat), NULL, 10);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s VECTORS_DIR\n", argv[0]);
    return 2;
  }
  char path[1024];
  static char json[4096];

  snprintf(path, sizeof(path), "%s/params.json", argv[1]);
  FILE *fj = fopen(path, "r");
  if (!fj) { perror(path); return 2; }
  size_t n = fread(json, 1, sizeof(json) - 1, fj);
  json[n] = 0;
  fclose(fj);
  // params.json is indented ("KEY": value); squeeze out spaces so the lookup is simple.
  char *w = json;
  for (char *r = json; *r; r++) if (*r != ' ' && *r != '\n') *w++ = *r;
  *w = 0;
  lgmd_params_t p = {
      (uint8_t)json_int(json, "P_MIN"), (uint8_t)json_int(json, "W_SHIFT"),
      (uint32_t)json_int(json, "K_THRESH"), (uint32_t)json_int(json, "F_MAX"),
      (uint8_t)json_int(json, "N_RISE")};

  snprintf(path, sizeof(path), "%s/frames.bin", argv[1]);
  FILE *ff = fopen(path, "rb");
  if (!ff) { perror(path); return 2; }
  snprintf(path, sizeof(path), "%s/expected.csv", argv[1]);
  FILE *fc = fopen(path, "r");
  if (!fc) { perror(path); return 2; }

  static uint8_t frame[LGMD_NPIX];
  static lgmd_state_t st;
  char line[256];
  if (!fgets(line, sizeof(line), fc)) return 2;   // header
  int frames = 0, bad = 0, fires = 0;
  while (fread(frame, 1, LGMD_NPIX, ff) == LGMD_NPIX) {
    if (frames == 0) lgmd_init(&st, frame);
    lgmd_out_t o;
    lgmd_step(&st, frame, &p, &o);
    unsigned long e[8];
    if (!fgets(line, sizeof(line), fc) ||
        sscanf(line, "%lu,%lu,%lu,%lu,%lu,%lu,%lu,%lu", &e[0], &e[1], &e[2], &e[3], &e[4], &e[5], &e[6], &e[7]) != 8) {
      fprintf(stderr, "expected.csv ends early at frame %d\n", frames);
      return 1;
    }
    unsigned long got[8] = {(unsigned long)frames, o.f, o.k, o.k_l, o.k_c, o.k_r, o.f, o.fire};
    if (memcmp(e, got, sizeof(e)) != 0) {
      if (bad < 5)
        fprintf(stderr, "frame %d: expected %lu,%lu,%lu,%lu,%lu,%lu,%lu  got %lu,%lu,%lu,%lu,%lu,%lu,%lu\n", frames,
                e[1], e[2], e[3], e[4], e[5], e[6], e[7], got[1], got[2], got[3], got[4], got[5], got[6], got[7]);
      bad++;
    }
    fires += o.fire;
    frames++;
  }
  printf("%s: %d frames, %d fire frames, %d mismatches -> %s\n", argv[1], frames, fires, bad, bad ? "FAIL" : "PASS");
  return bad ? 1 : 0;
}
