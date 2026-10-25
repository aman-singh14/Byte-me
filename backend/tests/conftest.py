"""Tests never read or write the wearer's real calibration (backend/data/calibration.json):
a saved gaze or eyelid calibration there would change what EyeTracker and GazeTracker do."""

from pathlib import Path

import pytest

from backend import distance


@pytest.fixture(autouse=True)
def _private_calibration(tmp_path, monkeypatch):
    monkeypatch.setattr(distance, "CALIB_PATH", Path(tmp_path) / "calibration.json")
