"""Daily rings (heads-up, outside), close-up totals and points, from stored stretches.

    heads-up ring  minutes with no near-work in view (glasses worn), goal 180 min
    outside ring   minutes outdoors (exposure-normalized brightness), goal 120 min
    points         +5 per heads-up break, +1 per 5 outside minutes, +20 per ring
                   completed (once a day); all from sensor data, only while worn

Stretches that are still open (heads-up right now) count up to `now`.
"""

import time

DAY = 86400


def day_start(t=None):
    lt = time.localtime(t or time.time())
    return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))


def clipped_seconds(intervals, since, until):
    return sum(max(0.0, min(i["end"], until) - max(i["start"], since)) for i in intervals)


class Rings:
    def __init__(self, cfg, db):
        r = cfg.get("rings", {})
        self.db = db
        self.goal = {"heads_up": r.get("heads_up_goal_min", 180), "outside": r.get("outside_goal_min", 120)}
        p = r.get("points", {})
        self.pts = {"heads_up_break": p.get("heads_up_break", 5), "outside_per_5min": p.get("outside_per_5min", 1),
                    "ring_complete": p.get("ring_complete", 20)}
        self.min_break_s = r.get("min_break_s", 60)     # a heads-up stretch earns points if >= this long
        self.open = {"heads_up": None, "outside": None}  # start time of a stretch that is still going
        self._completed = {}                             # (day, kind) -> True once the bonus was given

    # -- recording -------------------------------------------------------------

    def stretch_started(self, kind, start):
        self.open[kind] = start

    def stretch_ended(self, kind, start, end):
        self.open[kind] = None
        if end - start <= 0:
            return
        self.db.add_interval(kind, start, end)
        if kind == "heads_up" and end - start >= self.min_break_s:
            self.db.add_points(end, "heads_up_break", self.pts["heads_up_break"],
                               f"heads-up break, {round((end - start) / 60)} min")
        elif kind == "outside":
            n = int((end - start) // 300) * self.pts["outside_per_5min"]
            if n:
                self.db.add_points(end, "outside", n, f"{round((end - start) / 60)} min outside")
        self.check_goals(end)

    def check_goals(self, now=None):
        """Award the ring-complete bonus the first time a ring fills today."""
        now = now or time.time()
        d0 = day_start(now)
        for kind in ("heads_up", "outside"):
            if self._completed.get((d0, kind)):
                continue
            already = any(p["kind"] == f"{kind}_ring" for p in self.db.points(d0, d0 + DAY))
            if already:
                self._completed[(d0, kind)] = True
                continue
            if self.minutes(kind, d0, now) >= self.goal[kind]:
                self.db.add_points(now, f"{kind}_ring", self.pts["ring_complete"], f"{kind.replace('_', '-')} ring complete")
                self._completed[(d0, kind)] = True

    # -- queries ----------------------------------------------------------------

    def minutes(self, kind, since, until):
        ivs = self.db.intervals(kind, since, until)
        if self.open.get(kind) is not None:
            ivs = ivs + [{"start": self.open[kind], "end": min(until, time.time())}]
        return clipped_seconds(ivs, since, until) / 60

    def day(self, d0, now=None):
        now = now or time.time()
        until = min(d0 + DAY, now)
        hu = self.db.intervals("heads_up", d0, until)
        breaks = len(hu) + (1 if self.open["heads_up"] is not None and d0 <= now < d0 + DAY else 0)
        pts = self.db.points(d0, d0 + DAY)
        out = {}
        for kind in ("heads_up", "outside"):
            m = self.minutes(kind, d0, until)
            out[kind] = {"minutes": round(m, 1), "goal_min": self.goal[kind],
                         "percent": round(100 * m / self.goal[kind]) if self.goal[kind] else 0,
                         "active": self.open[kind] is not None and d0 <= now < d0 + DAY}
        out["heads_up"]["breaks"] = breaks
        out["points"] = sum(p["points"] for p in pts)
        out["date"] = time.strftime("%Y-%m-%d", time.localtime(d0))
        return out

    def today(self, now=None):
        now = now or time.time()
        d = self.day(day_start(now), now)
        d["points_log"] = [{"ts": p["ts"], "points": p["points"], "reason": p["reason"]}
                           for p in self.db.points(day_start(now))][-20:]
        return d

    def history(self, days=7, now=None):
        now = now or time.time()
        d0 = day_start(now)
        return [self.day(d0 - i * DAY, now) for i in range(days - 1, -1, -1)]


def closeup_summary(db, d0, now=None, open_session=None):
    """Close-up sessions for a day: list, total minutes, minutes per object, timeline."""
    now = now or time.time()
    until = min(d0 + DAY, now)
    sessions = db.closeup_sessions(d0, d0 + DAY)
    rows = [dict(s, duration_min=round((min(s["end"], until) - max(s["start"], d0)) / 60, 1)) for s in sessions]
    if open_session is not None and d0 <= open_session["start"] < d0 + DAY:
        rows.append({"start": open_session["start"], "end": now, "object": open_session["object"], "min_cm": None,
                     "avg_cm": None, "samples": None, "open": True,
                     "duration_min": round((now - open_session["start"]) / 60, 1)})
    by_object = {}
    for r in rows:
        by_object[r["object"]] = round(by_object.get(r["object"], 0) + r["duration_min"], 1)
    return {
        "date": time.strftime("%Y-%m-%d", time.localtime(d0)),
        "total_min": round(sum(r["duration_min"] for r in rows), 1),
        "by_object": by_object,
        "sessions": rows,
        "longest_min": max((r["duration_min"] for r in rows), default=0),
    }
