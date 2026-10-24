"""App usage and its correlation with eye metrics.

Real iOS Screen Time data cannot leave the phone without a FamilyControls-entitled
app (DeviceActivityReport extensions have no network access). What we have instead:

  mac   REAL: the Mac's frontmost app, polled with `lsappinfo` (no permissions
        needed). Each app session is joined with the eye samples recorded
        during it, so "blink rate in Xcode vs. Safari" is measured, not made up.
  ios   MOCK: a fixed, clearly labelled dataset of a typical day of iPhone use,
        for the dashboard's iOS card. Replace it with a real import later.
"""

import re
import subprocess
import threading
import time

CATEGORIES = {
    "Safari": "browsing", "Google Chrome": "browsing", "Arc": "browsing", "Firefox": "browsing",
    "Xcode": "coding", "Code": "coding", "Visual Studio Code": "coding", "Cursor": "coding",
    "Terminal": "coding", "iTerm2": "coding", "PyCharm": "coding", "Ghostty": "coding",
    "Slack": "messaging", "Messages": "messaging", "Discord": "messaging", "WhatsApp": "messaging",
    "Mail": "messaging", "zoom.us": "video calls", "FaceTime": "video calls",
    "Microsoft Teams": "video calls", "Spotify": "media", "Music": "media", "TV": "media",
    "YouTube": "media", "Netflix": "media", "TikTok": "social", "Instagram": "social",
    "X": "social", "Reddit": "social", "Preview": "reading", "Books": "reading",
    "Notion": "productivity", "Notes": "productivity", "Microsoft Word": "productivity",
    "Pages": "productivity", "Figma": "design", "Finder": "system",
}

# Typical iPhone day: (app, category, minutes). MOCK data, labelled as such in the API.
IOS_MOCK = [
    ("Instagram", "social", 74), ("TikTok", "social", 58), ("Messages", "messaging", 41),
    ("Safari", "browsing", 35), ("YouTube", "media", 33), ("Maps", "navigation", 12),
    ("Mail", "messaging", 11), ("Books", "reading", 9), ("Camera", "photo", 6),
]
IOS_LIMITS = {"social": 60, "media": 60}   # minutes per day per category before we flag it


def category(app):
    return CATEGORIES.get(app, "other")


def frontmost_app():
    """Name of the Mac's frontmost app, or None (not macOS, or nothing in front)."""
    try:
        asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=2).stdout.strip()
        if not asn:
            return None
        info = subprocess.run(["lsappinfo", "info", "-only", "name", asn],
                              capture_output=True, text=True, timeout=2).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r'"(?:LSDisplayName|name)"\s*=\s*"([^"]+)"', info)
    return m.group(1) if m else None


class MacAppTracker:
    """Polls the frontmost app and stores sessions in app_usage (source 'mac')."""

    def __init__(self, db, poll_s=5):
        self.db = db
        self.poll_s = poll_s
        self.current = None      # (row_id, app)
        self._stop = threading.Event()
        self.thread = threading.Thread(target=self._run, name="mac-apps", daemon=True)

    def start(self):
        if frontmost_app() is None:
            print("[screentime] lsappinfo not available, Mac app tracking off")
            return self
        self.thread.start()
        return self

    def stop(self):
        self._stop.set()

    def _run(self):
        while not self._stop.is_set():
            now = time.time()
            app = frontmost_app()
            if app and self.current and self.current[1] == app:
                self.db.extend_app_usage(self.current[0], now)
            elif app:
                if self.current:
                    self.db.extend_app_usage(self.current[0], now)
                self.current = (self.db.add_app_usage(now, now, app, category(app), "mac"), app)
            self._stop.wait(self.poll_s)


def ios_mock_today():
    total = sum(m for _, _, m in IOS_MOCK)
    by_cat = {}
    for _, cat, m in IOS_MOCK:
        by_cat[cat] = by_cat.get(cat, 0) + m
    flags = [{"category": c, "minutes": m, "limit": IOS_LIMITS[c],
              "text": f"{m} min of {c} apps today, over your {IOS_LIMITS[c]} min goal."}
             for c, m in by_cat.items() if c in IOS_LIMITS and m > IOS_LIMITS[c]]
    return {
        "source": "ios_mock",
        "mock": True,
        "note": "Sample data. iOS Screen Time cannot be exported to a server without a "
                "FamilyControls-entitled app.",
        "total_min": total,
        "apps": [{"app": a, "category": c, "minutes": m} for a, c, m in IOS_MOCK],
        "by_category": by_cat,
        "flags": flags,
    }


def mac_usage(db, since):
    """Minutes per app on the Mac since a time."""
    per_app = {}
    for row in db.app_usage(since, "mac"):
        d = (row["end"] - max(row["start"], since)) / 60
        a = per_app.setdefault(row["app"], {"app": row["app"], "category": row["category"], "minutes": 0.0})
        a["minutes"] += d
    apps = sorted(per_app.values(), key=lambda a: -a["minutes"])
    for a in apps:
        a["minutes"] = round(a["minutes"], 1)
    return {"source": "mac", "mock": False, "apps": apps}


def correlate(db, since, min_samples=30):
    """Eye metrics per Mac app and per category, from the samples recorded during each app session."""
    sessions = db.app_usage(since, "mac")
    samples = db.samples(since)
    groups = {}
    i = 0
    for s in sessions:                          # sessions and samples are both sorted by time
        while i < len(samples) and samples[i]["ts"] < s["start"]:
            i += 1
        j = i
        while j < len(samples) and samples[j]["ts"] <= s["end"]:
            sm = samples[j]
            for key in (("app", s["app"]), ("category", s["category"])):
                g = groups.setdefault(key, {"n": 0, "face": 0, "rate_sum": 0.0, "rate_n": 0,
                                            "dist_sum": 0.0, "dist_n": 0, "close": 0, "squint": 0})
                g["n"] += 1
                g["face"] += sm["face"] or 0
                g["close"] += sm["too_close"] or 0
                g["squint"] += sm["squinting"] or 0
                if sm["blink_rate"] is not None:
                    g["rate_sum"] += sm["blink_rate"]
                    g["rate_n"] += 1
                if sm["distance_cm"] is not None:
                    g["dist_sum"] += sm["distance_cm"]
                    g["dist_n"] += 1
            j += 1
    out = {"app": [], "category": []}
    for (kind, name), g in groups.items():
        if g["n"] < min_samples:
            continue
        out[kind].append({
            "name": name,
            "minutes": round(g["n"] / 60, 1),
            "avg_blink_rate": round(g["rate_sum"] / g["rate_n"], 1) if g["rate_n"] else None,
            "avg_distance_cm": round(g["dist_sum"] / g["dist_n"], 1) if g["dist_n"] else None,
            "too_close_frac": round(g["close"] / g["n"], 3),
            "squint_frac": round(g["squint"] / g["n"], 3),
        })
    for kind in out:
        out[kind].sort(key=lambda r: (r["avg_blink_rate"] is None, r["avg_blink_rate"] or 0))
    worst = next((r for r in out["app"] if r["avg_blink_rate"] is not None), None)
    insight = None
    if worst and len(out["app"]) > 1:
        insight = (f"You blink least in {worst['name']} ({worst['avg_blink_rate']:.0f}/min). "
                   "Take your 20-20-20 breaks there first.")
    return {"source": "mac", "mock": False, "by_app": out["app"], "by_category": out["category"],
            "insight": insight}
