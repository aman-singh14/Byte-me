"""MediaPipe Face Landmarker (Tasks API) wrapper shared by eye tracking and distance.

mediapipe >= 0.10.30 dropped mp.solutions.face_mesh; the Tasks API needs a model
file, downloaded once to backend/models/. 478 landmarks: the 468 Face Mesh points
plus 10 iris points (468-472 one iris, 473-477 the other).
"""

import threading
import urllib.request
from pathlib import Path

import cv2
import mediapipe as mp
import numpy as np
from mediapipe.tasks.python import BaseOptions, vision

MODEL_URL = ("https://storage.googleapis.com/mediapipe-models/face_landmarker/"
             "face_landmarker/float16/latest/face_landmarker.task")
MODEL_PATH = Path(__file__).resolve().parent / "models" / "face_landmarker.task"

_download_lock = threading.Lock()


def ensure_model(path=MODEL_PATH):
    with _download_lock:
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            print(f"[face] downloading {MODEL_URL}")
            tmp = path.with_suffix(".part")
            urllib.request.urlretrieve(MODEL_URL, tmp)
            tmp.rename(path)
    return str(path)


class FaceMesh:
    """detect(bgr) -> (478, 2) float array of pixel coordinates, or None if no face."""

    def __init__(self):
        opts = vision.FaceLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=ensure_model()),
            running_mode=vision.RunningMode.VIDEO,
            num_faces=1,
            min_face_detection_confidence=0.5,
            min_face_presence_confidence=0.5,
            min_tracking_confidence=0.5,
        )
        self._lm = vision.FaceLandmarker.create_from_options(opts)
        self._ts = 0

    def detect(self, bgr):
        h, w = bgr.shape[:2]
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        self._ts += 33   # VIDEO mode only needs strictly increasing timestamps
        res = self._lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), self._ts)
        if not res.face_landmarks:
            return None
        return np.array([(p.x * w, p.y * h) for p in res.face_landmarks[0]], np.float32)

    def close(self):
        self._lm.close()
