"""SQLite storage for the social server.

Stores only what friends see: display names, daily ring percentages and side
quest stars, plus friendships, groups and group screen break times. No sensor data, no video, no
audio, no location.
"""

import hashlib
import json
import secrets
import sqlite3
import threading
import time
import uuid
from datetime import UTC, date, datetime, timedelta

# Codes people type or read out: no 0/O, 1/I/L.
CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    token_hash TEXT NOT NULL UNIQUE,
    friend_code TEXT NOT NULL UNIQUE,
    nearby_id TEXT NOT NULL UNIQUE,   -- what this phone advertises over Bluetooth, only friends learn it
    created REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS friends (
    a INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    b INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    PRIMARY KEY (a, b)
);
CREATE TABLE IF NOT EXISTS rings (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day TEXT NOT NULL,                -- the phone's local date, YYYY-MM-DD
    heads_up INTEGER NOT NULL,        -- percent of goal, 0-100
    outside INTEGER NOT NULL,         -- percent of goal, 0-100
    stars INTEGER NOT NULL DEFAULT 0, -- side quest stars earned that day
    quests TEXT NOT NULL DEFAULT '{}', -- the same stars by quest, JSON {"look_up": 2}
    updated REAL NOT NULL,
    PRIMARY KEY (user_id, day)
);
CREATE TABLE IF NOT EXISTS groups (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    invite_code TEXT NOT NULL UNIQUE,
    public_id TEXT NOT NULL UNIQUE,   -- for the read-only team page, only if is_public
    is_public INTEGER NOT NULL DEFAULT 0,
    created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS members (
    group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    joined REAL NOT NULL,
    PRIMARY KEY (group_id, user_id)
);
CREATE TABLE IF NOT EXISTS breaks (
    id INTEGER PRIMARY KEY,
    group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    starts_at REAL NOT NULL,          -- unix seconds
    minutes INTEGER NOT NULL,
    created_by INTEGER REFERENCES users(id) ON DELETE SET NULL,
    created REAL NOT NULL
);
"""


def hash_token(token):
    return hashlib.sha256(token.encode()).hexdigest()


def new_code(n=6):
    return "".join(secrets.choice(CODE_ALPHABET) for _ in range(n))


class DB:
    def __init__(self, path):
        self.conn = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys = ON")
        self.conn.execute("PRAGMA journal_mode = WAL")
        self.conn.executescript(SCHEMA)
        for column in ("stars INTEGER NOT NULL DEFAULT 0", "quests TEXT NOT NULL DEFAULT '{}'"):
            try:  # databases made before these columns existed
                self.conn.execute(f"ALTER TABLE rings ADD COLUMN {column}")
            except sqlite3.OperationalError:
                pass
        self.lock = threading.Lock()

    def q(self, sql, args=()):
        with self.lock:
            return self.conn.execute(sql, args).fetchall()

    def one(self, sql, args=()):
        rows = self.q(sql, args)
        return rows[0] if rows else None

    def run(self, sql, args=()):
        with self.lock:
            cur = self.conn.execute(sql, args)
            return cur.lastrowid

    def unique_code(self, table, column, n=6):
        while True:
            code = new_code(n)
            if not self.one(f"SELECT 1 FROM {table} WHERE {column} = ?", (code,)):
                return code

    # --- users -------------------------------------------------------------

    def create_user(self, name):
        token = secrets.token_urlsafe(32)
        user_id = self.run(
            "INSERT INTO users (name, token_hash, friend_code, nearby_id, created) VALUES (?, ?, ?, ?, ?)",
            (name, hash_token(token), self.unique_code("users", "friend_code"), str(uuid.uuid4()), time.time()),
        )
        return self.user(user_id), token

    def user(self, user_id):
        return self.one("SELECT * FROM users WHERE id = ?", (user_id,))

    def user_by_token(self, token):
        return self.one("SELECT * FROM users WHERE token_hash = ?", (hash_token(token),))

    def rename(self, user_id, name):
        self.run("UPDATE users SET name = ? WHERE id = ?", (name, user_id))

    def delete_user(self, user_id):
        self.run("DELETE FROM users WHERE id = ?", (user_id,))

    # --- rings -------------------------------------------------------------

    def set_rings(self, user_id, day, heads_up, outside, stars=0, quests=None):
        self.run(
            """INSERT INTO rings (user_id, day, heads_up, outside, stars, quests, updated)
               VALUES (?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (user_id, day) DO UPDATE SET heads_up = excluded.heads_up,
               outside = excluded.outside, stars = excluded.stars, quests = excluded.quests,
               updated = excluded.updated""",
            (user_id, day, heads_up, outside, stars, json.dumps(quests or {}), time.time()),
        )

    def latest_rings(self, user_id, max_age_s=36 * 3600):
        """Today's rings as the user last reported them (zeros if stale), and
        this week's side quest stars (in all and by quest) and average ring.
        A week is Monday to Sunday of their own latest day, so it follows
        their own time zone."""
        row = self.one("SELECT * FROM rings WHERE user_id = ? ORDER BY day DESC LIMIT 1", (user_id,))
        stats = {"heads_up": 0, "outside": 0, "stars_week": 0, "quests_week": {}, "ring_week": 0, "day": None}
        if row is None:
            return stats
        day = date.fromisoformat(row["day"])
        monday = day - timedelta(days=day.weekday())
        today = datetime.fromtimestamp(time.time(), tz=UTC).date()
        if (today - monday).days < 8:  # a day of slack for time zones
            week = self.q("SELECT * FROM rings WHERE user_id = ? AND day >= ?", (user_id, monday.isoformat()))
            stats["stars_week"] = sum(r["stars"] for r in week)
            quests = {}
            for r in week:
                for quest, n in json.loads(r["quests"] or "{}").items():
                    quests[quest] = quests.get(quest, 0) + n
            stats["quests_week"] = quests
            # Each day's ring is the average of its two rings.
            stats["ring_week"] = round(sum((r["heads_up"] + r["outside"]) / 2 for r in week) / len(week))
        if time.time() - row["updated"] <= max_age_s:
            stats.update(heads_up=row["heads_up"], outside=row["outside"], day=row["day"])
        return stats

    # --- friends -----------------------------------------------------------

    def add_friend(self, a, b):
        self.run("INSERT OR IGNORE INTO friends (a, b) VALUES (?, ?)", (a, b))
        self.run("INSERT OR IGNORE INTO friends (a, b) VALUES (?, ?)", (b, a))

    def remove_friend(self, a, b):
        self.run("DELETE FROM friends WHERE (a = ? AND b = ?) OR (a = ? AND b = ?)", (a, b, b, a))

    def friends(self, user_id):
        return self.q(
            "SELECT u.* FROM friends f JOIN users u ON u.id = f.b WHERE f.a = ? ORDER BY u.name COLLATE NOCASE",
            (user_id,),
        )

    # --- groups ------------------------------------------------------------

    def create_group(self, name, user_id):
        group_id = self.run(
            "INSERT INTO groups (name, invite_code, public_id, created_by, created) VALUES (?, ?, ?, ?, ?)",
            (name, self.unique_code("groups", "invite_code"), secrets.token_urlsafe(8), user_id, time.time()),
        )
        self.join_group(group_id, user_id)
        return self.group(group_id)

    def group(self, group_id):
        return self.one("SELECT * FROM groups WHERE id = ?", (group_id,))

    def group_by_code(self, code):
        return self.one("SELECT * FROM groups WHERE invite_code = ?", (code,))

    def public_groups(self):
        return self.q("SELECT * FROM groups WHERE is_public = 1")

    def group_by_public_id(self, public_id):
        return self.one("SELECT * FROM groups WHERE public_id = ? AND is_public = 1", (public_id,))

    def set_public(self, group_id, is_public):
        self.run("UPDATE groups SET is_public = ? WHERE id = ?", (1 if is_public else 0, group_id))

    def join_group(self, group_id, user_id):
        self.run("INSERT OR IGNORE INTO members (group_id, user_id, joined) VALUES (?, ?, ?)",
                 (group_id, user_id, time.time()))

    def leave_group(self, group_id, user_id):
        self.run("DELETE FROM members WHERE group_id = ? AND user_id = ?", (group_id, user_id))
        if not self.one("SELECT 1 FROM members WHERE group_id = ?", (group_id,)):
            self.run("DELETE FROM groups WHERE id = ?", (group_id,))  # last one out

    def is_member(self, group_id, user_id):
        return self.one("SELECT 1 FROM members WHERE group_id = ? AND user_id = ?", (group_id, user_id)) is not None

    def groups_of(self, user_id):
        return self.q(
            "SELECT g.* FROM members m JOIN groups g ON g.id = m.group_id WHERE m.user_id = ? ORDER BY g.created",
            (user_id,),
        )

    def members(self, group_id):
        return self.q(
            """SELECT u.* FROM members m JOIN users u ON u.id = m.user_id WHERE m.group_id = ?
               ORDER BY u.name COLLATE NOCASE""",
            (group_id,),
        )

    # --- group breaks ------------------------------------------------------

    def create_break(self, group_id, starts_at, minutes, user_id):
        break_id = self.run(
            "INSERT INTO breaks (group_id, starts_at, minutes, created_by, created) VALUES (?, ?, ?, ?, ?)",
            (group_id, starts_at, minutes, user_id, time.time()),
        )
        return self.brk(break_id)

    def brk(self, break_id):
        return self.one("SELECT * FROM breaks WHERE id = ?", (break_id,))

    def breaks_of(self, group_id, since):
        return self.q(
            "SELECT * FROM breaks WHERE group_id = ? AND starts_at + minutes * 60 >= ? ORDER BY starts_at",
            (group_id, since),
        )

    def recent_breaks(self, group_id, limit=10):
        return self.q("SELECT * FROM breaks WHERE group_id = ? ORDER BY starts_at DESC LIMIT ?", (group_id, limit))

    def delete_break(self, break_id):
        self.run("DELETE FROM breaks WHERE id = ?", (break_id,))
