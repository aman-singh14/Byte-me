#!/bin/sh
# Export test vectors from lgmd.py for every synthetic clip and check the C port against them.
# Run from the repo root: sh firmware/lgmd_c/check_all.sh
set -e
PY=${PY:-.venv/bin/python}
OUT=${OUT:-vectors/c_check}
mkdir -p "$OUT"
cc -O2 -Wall -Wextra -o "$OUT/check_vectors" firmware/lgmd_c/check_vectors.c firmware/lgmd_c/lgmd.c
$PY lgmd.py --synth "$OUT/clips" > /dev/null
status=0
for clip in "$OUT"/clips/*.npz; do
  name=$(basename "$clip" .npz)
  $PY lgmd.py --export "$clip" --out "$OUT/$name" > /dev/null
  "$OUT/check_vectors" "$OUT/$name" || status=1
done
exit $status
