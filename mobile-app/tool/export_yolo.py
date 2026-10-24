#!/usr/bin/env python3
"""Export YOLO26n at 320 px for the app's rear-camera detector.

The ultralytics_yolo plugin's official models are fixed at 640 x 640. The rear
camera is 320 x 240, so a 320 px model does about a quarter of the work for the
same pixels. This writes, into assets/models/:

    yolo26n_320.mlpackage.zip   Core ML int8, NMS-free (iOS)
    yolo26n_320.tflite          LiteRT w8a32 (Android), raw outputs, NMS on device

The settings match the plugin's own official exports, only imgsz differs.
All 80 COCO classes stay in the model; the app keeps only the ones it alerts on.

The two formats need different pins (coremltools 9.0 wants PyTorch <= 2.7 and
NumPy < 2.5; LiteRT wants a new PyTorch), so each gets its own venv.
Run from mobile-app/ (Python 3.12):

    # Android (LiteRT)
    uv venv --python 3.12 ~/.cache/omni-yolo-litert
    uv pip install --python ~/.cache/omni-yolo-litert --torch-backend cpu \\
        "ultralytics-opencv-headless[export-litert]>=8.4.142"
    ~/.cache/omni-yolo-litert/bin/python tool/export_yolo.py litert

    # iOS (Core ML), macOS only
    uv venv --python 3.12 ~/.cache/omni-yolo-coreml
    uv pip install --python ~/.cache/omni-yolo-coreml --torch-backend cpu \\
        "ultralytics-opencv-headless>=8.4.142" "torch==2.7.1" "torchvision==0.22.1" "coremltools==9.0" "numpy==2.2.6" scikit-learn
    ~/.cache/omni-yolo-coreml/bin/python tool/export_yolo.py coreml
"""

import argparse
import os
import shutil
import sys
import tempfile
from pathlib import Path

IMGSZ = 320
MODEL = "yolo26n"
OUT = Path(__file__).resolve().parents[1] / "assets" / "models"


def export_coreml(model):
    # Core ML int8, NMS-free (same as the plugin's official iOS assets).
    mlpackage = Path(model.export(format="coreml", imgsz=IMGSZ, int8=True, nms=False, batch=1))
    zip_base = OUT / f"{MODEL}_{IMGSZ}.mlpackage"
    shutil.make_archive(str(zip_base), "zip", root_dir=mlpackage.parent, base_dir=mlpackage.name)
    print(f"wrote {zip_base}.zip")


def export_litert(model):
    # LiteRT w8a32 with raw outputs; the plugin runs NMS natively on Android.
    tflite = Path(model.export(format="litert", quantize="w8a32", nms=None, imgsz=IMGSZ, batch=1))
    shutil.copy(tflite, OUT / f"{MODEL}_{IMGSZ}.tflite")
    print(f"wrote {OUT / f'{MODEL}_{IMGSZ}.tflite'}")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Export YOLO26n at 320 px for the app")
    ap.add_argument("format", choices=["coreml", "litert"])
    args = ap.parse_args(argv)

    from ultralytics import YOLO

    OUT.mkdir(parents=True, exist_ok=True)
    # Ultralytics writes weights and exports into the current folder.
    os.chdir(tempfile.mkdtemp(prefix="omni-yolo-"))
    model = YOLO(f"{MODEL}.pt")  # downloads the official weights on first run
    {"coreml": export_coreml, "litert": export_litert}[args.format](model)
    return 0


if __name__ == "__main__":
    sys.exit(main())
