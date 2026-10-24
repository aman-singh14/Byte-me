"""Fill a database with a plausible past few hours so the dashboard has history to show.

    python -m backend.seed_demo                          # writes backend/data/demo.db
    python -m backend.main --config backend/config.demo.yaml   # (or set db.path to demo.db)

Seeded rows are fake; real rows get added on top while the backend runs. Never
seed the database you present as real measurements.
"""

import argparse
import math
import random
import time
from pathlib import Path

from backend.db import DB
from backend.screentime import category

SESSIONS = [  # (app, minutes, blink rate, distance cm)
    ("Xcode", 55, 8, 52), ("Safari", 25, 13, 58), ("Slack", 15, 16, 62), ("Xcode", 40, 7, 45),
    ("YouTube", 20, 11, 70), ("Terminal", 30, 9, 48), ("Messages", 10, 17, 40), ("Figma", 35, 10, 55),
]


def seed(db, hours_ago=6.0, rng=None):
    rng = rng or random.Random(7)
    t = time.time() - hours_ago * 3600
    for app, minutes, rate, dist in SESSIONS:
        start = t
        db.add_app_usage(start, start + minutes * 60, app, category(app), "mac")
        squint_left = 0
        for s in range(minutes * 60):
            ts = start + s
            r = max(2.0, rate + 2 * math.sin(s / 300) + rng.gauss(0, 1))
            d = max(25.0, dist + 6 * math.sin(s / 170) + rng.gauss(0, 2))
            if rng.random() < r / 60:
                db.add_event(ts, "blink", {"duration_s": round(rng.uniform(0.1, 0.3), 3)})
            if squint_left == 0 and rng.random() < 1 / 900:
                squint_left = rng.randint(3, 20)
                db.add_event(ts, "squint_start")
            squinting = squint_left > 0
            if squinting:
                squint_left -= 1
                if squint_left == 0:
                    db.add_event(ts, "squint_end")
            db.add_sample(ts, round(r, 1), 0.27, squinting, round(d, 1), d < 50, True)
        if rng.random() < 0.5:
            db.add_event(start + rng.uniform(0, minutes * 60), "alert",
                         {"side": rng.choice("LCR"), "k": rng.randint(3500, 9000),
                          "label": rng.choice([None, "person", "bicycle"]),
                          "text": "Object approaching from behind"})
        t = start + minutes * 60 + rng.uniform(60, 300)      # a break between sessions
        db.add_event(t, "break", {"duration_s": 120})


def main(argv=None):
    ap = argparse.ArgumentParser(description="Seed a demo database with fake history")
    ap.add_argument("--db", default=str(Path(__file__).resolve().parent / "data" / "demo.db"))
    ap.add_argument("--hours-ago", type=float, default=6.0)
    args = ap.parse_args(argv)
    seed(DB(args.db), args.hours_ago)
    print(f"seeded {args.db}")


if __name__ == "__main__":
    main()
