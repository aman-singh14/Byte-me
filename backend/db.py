"""SQLite storage. One connection shared across threads behind a lock (WAL mode).

    samples    one row per second: blink rate, openness, squint, distance, face present
    events     blinks, squints, too-close spells, rear alerts, calibrations, breaks (JSON data)
    app_usage  app sessions: the Mac's frontmost app (real) and an iOS dataset (mock)
"""

import json
import sqlite3
import threading
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
    ts REAL NOT NULL,
    blink_rate REAL,
    openness REAL,
    squinting INTEGER,
    distance_cm REAL,
    too_close INTEGER,
    face INTEGER
);
CREATE INDEX IF NOT EXISTS samples_ts ON samples (ts);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    ts REAL NOT NULL,
    kind TEXT NOT NULL,
    data TEXT
);
CREATE INDEX IF NOT EXISTS events_ts ON events (ts);
CREATE INDEX IF NOT EXISTS events_kind ON events (kind, ts);
CREATE TABLE IF NOT EXISTS app_usage (
    id INTEGER PRIMARY KEY,
    start REAL NOT NULL,
    end REAL NOT NULL,
    app TEXT NOT NULL,
    category TEXT,
    source TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS app_usage_start ON app_usage (start);
"""

RANGES = {           # range -> (seconds, bucket seconds)
    "hour": (3600, 60),
    "day": (86400, 900),
    "week": (7 * 86400, 7200),
}


class DB:
    def __init__(self, path):
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.lock = threading.Lock()
        with self.lock:
            self.conn.execute("PRAGMA journal_mode=WAL")
            self.conn.executescript(SCHEMA)

    def _exec(self, sql, args=()):
        with self.lock:
            cur = self.conn.execute(sql, args)
            self.conn.commit()
            return cur.lastrowid

    def _query(self, sql, args=()):
        with self.lock:
            return [dict(r) for r in self.conn.execute(sql, args).fetchall()]

    # -- writes ------------------------------------------------------------

    def add_sample(self, ts, blink_rate, openness, squinting, distance_cm, too_close, face):
        self._exec("INSERT INTO samples VALUES (?, ?, ?, ?, ?, ?, ?)",
                   (ts, blink_rate, openness, int(bool(squinting)), distance_cm, int(bool(too_close)), int(bool(face))))

    def add_event(self, ts, kind, data=None):
        return self._exec("INSERT INTO events (ts, kind, data) VALUES (?, ?, ?)",
                          (ts, kind, None if data is None else json.dumps(data)))

    def add_app_usage(self, start, end, app, category, source):
        return self._exec("INSERT INTO app_usage (start, end, app, category, source) VALUES (?, ?, ?, ?, ?)",
                          (start, end, app, category, source))

    def extend_app_usage(self, row_id, end):
        self._exec("UPDATE app_usage SET end = ? WHERE id = ?", (end, row_id))

    # -- reads -------------------------------------------------------------

    def events(self, kinds=None, since=0.0, limit=100):
        sql, args = "SELECT * FROM events WHERE ts >= ?", [since]
        if kinds:
            sql += f" AND kind IN ({','.join('?' * len(kinds))})"
            args += list(kinds)
        sql += " ORDER BY ts DESC LIMIT ?"
        rows = self._query(sql, args + [limit])
        for r in rows:
            r["data"] = json.loads(r["data"]) if r["data"] else None
        return rows

    def samples(self, since, until=None):
        if until is None:
            return self._query("SELECT * FROM samples WHERE ts >= ? ORDER BY ts", (since,))
        return self._query("SELECT * FROM samples WHERE ts >= ? AND ts < ? ORDER BY ts", (since, until))

    def history(self, range_name="day", now=None):
        """Bucketed averages over the range. Buckets with no data are left out."""
        if range_name not in RANGES:
            raise ValueError(f"range must be one of {sorted(RANGES)}")
        now = now or time.time()
        span, bucket = RANGES[range_name]
        since = now - span
        rows = self._query(
            """SELECT CAST(ts / ? AS INTEGER) * ? AS t,
                      AVG(blink_rate) AS blink_rate,
                      AVG(distance_cm) AS distance_cm,
                      AVG(squinting) AS squint_frac,
                      AVG(too_close) AS too_close_frac,
                      AVG(face) AS face_frac,
                      COUNT(*) AS n
               FROM samples WHERE ts >= ? GROUP BY t ORDER BY t""",
            (bucket, bucket, since))
        blinks = {r["t"]: r["c"] for r in self._query(
            """SELECT CAST(ts / ? AS INTEGER) * ? AS t, COUNT(*) AS c
               FROM events WHERE kind = 'blink' AND ts >= ? GROUP BY t""", (bucket, bucket, since))}
        for r in rows:
            r["blinks"] = blinks.get(r["t"], 0)
            for k in ("blink_rate", "distance_cm"):
                if r[k] is not None:
                    r[k] = round(r[k], 1)
            for k in ("squint_frac", "too_close_frac", "face_frac"):
                r[k] = round(r[k] or 0, 3)
        return {"range": range_name, "bucket_s": bucket, "since": since, "until": now, "points": rows}

    def summary(self, since):
        """Totals since a time: minutes tracked, too close, squinting, blinks, alerts."""
        s = self._query(
            """SELECT COUNT(*) AS n, SUM(face) AS face, SUM(too_close) AS too_close, SUM(squinting) AS squint,
                      AVG(blink_rate) AS blink_rate, AVG(distance_cm) AS distance_cm
               FROM samples WHERE ts >= ?""", (since,))[0]
        counts = {r["kind"]: r["c"] for r in self._query(
            "SELECT kind, COUNT(*) AS c FROM events WHERE ts >= ? GROUP BY kind", (since,))}
        return {
            "tracked_min": round((s["face"] or 0) / 60, 1),
            "too_close_min": round((s["too_close"] or 0) / 60, 1),
            "squint_min": round((s["squint"] or 0) / 60, 1),
            "avg_blink_rate": None if s["blink_rate"] is None else round(s["blink_rate"], 1),
            "avg_distance_cm": None if s["distance_cm"] is None else round(s["distance_cm"], 1),
            "blinks": counts.get("blink", 0),
            "squints": counts.get("squint_start", 0),
            "rear_alerts": counts.get("alert", 0),
            "breaks": counts.get("break", 0),
        }

    def app_usage(self, since, source=None):
        sql, args = "SELECT * FROM app_usage WHERE end >= ?", [since]
        if source:
            sql += " AND source = ?"
            args.append(source)
        return self._query(sql + " ORDER BY start", args)

    def clear_source(self, source):
        self._exec("DELETE FROM app_usage WHERE source = ?", (source,))
