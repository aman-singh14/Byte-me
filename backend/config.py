"""Loads backend/config.yaml (the product: ESP32-CAM streams + FPGA rear events).

Dev mode (`--dev`) deep-merges backend/config.dev.yaml on top. It swaps in stand-ins
(laptop webcam, still images, mock FPGA) so we can work before the hardware arrives.
The stand-ins are never part of the product config.
"""

import copy
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PATH = Path(__file__).resolve().parent / "config.yaml"
DEV_PATH = Path(__file__).resolve().parent / "config.dev.yaml"


def deep_merge(base, over):
    """Dicts merge key by key; anything else in `over` replaces the value in `base`."""
    out = copy.deepcopy(base)
    for k, v in (over or {}).items():
        out[k] = deep_merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else copy.deepcopy(v)
    return out


def _read(path):
    with open(path) as f:
        return yaml.safe_load(f) or {}


def load_config(path=None, dev=False, dev_path=None):
    cfg = _read(Path(path or DEFAULT_PATH))
    if dev:
        cfg = deep_merge(cfg, _read(Path(dev_path or DEV_PATH)))
    cfg["dev"] = bool(dev)
    db_path = Path(cfg.get("db", {}).get("path", "backend/data/mega.db"))
    if not db_path.is_absolute():
        cfg.setdefault("db", {})["path"] = str(ROOT / db_path)
    return cfg
