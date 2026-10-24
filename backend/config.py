"""Loads backend/config.yaml. Plain dicts, no schema: this is a hackathon."""

from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PATH = Path(__file__).resolve().parent / "config.yaml"


def load_config(path=None):
    path = Path(path or DEFAULT_PATH)
    with open(path) as f:
        cfg = yaml.safe_load(f) or {}
    db_path = Path(cfg.get("db", {}).get("path", "backend/data/mega.db"))
    if not db_path.is_absolute():
        cfg.setdefault("db", {})["path"] = str(ROOT / db_path)
    return cfg
