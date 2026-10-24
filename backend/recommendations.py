"""Rule-based eye-health recommendations. Pure functions over live state + the DB."""

import time


def recommend(live, db, cfg, now=None):
    """Returns a list of {id, level, title, text}, most important first.
    level: "urgent" | "suggest" | "info"."""
    now = now or time.time()
    r = cfg.get("recommendations", {})
    out = []

    rate = live.get("blink_rate")
    low = r.get("low_blink_per_min", 10)
    if rate is not None and live.get("eye_detected") and rate < low:
        out.append({
            "id": "blink_more", "level": "suggest", "title": "Blink more",
            "text": f"You are blinking {rate:.0f} times a minute (relaxed is about 15-20). "
                    "Screens cut blinking, which dries your eyes. Try a few slow, full blinks, "
                    "or look away for a moment.",
        })

    window = 15 * 60
    close_min = sum(s["too_close"] for s in db.samples(now - window, now)) / 60
    limit = r.get("too_close_minutes", 5)
    if close_min >= limit or live.get("too_close_for_s", 0) >= limit * 60:
        out.append({
            "id": "move_back", "level": "urgent", "title": "Move back from the screen",
            "text": f"You were closer than {live.get('threshold_cm', 50)} cm for {close_min:.0f} of the last "
                    "15 minutes. An arm's length (50-70 cm for a laptop) is easier on your focusing muscles.",
        })
    elif live.get("too_close"):
        out.append({
            "id": "too_close_now", "level": "suggest", "title": "A bit close",
            "text": f"You are {live.get('distance_cm', 0):.0f} cm from the screen right now.",
        })

    session_min = live.get("session_min", 0) or 0
    if session_min >= r.get("session_minutes", 20):
        out.append({
            "id": "20_20_20", "level": "urgent", "title": "Time for a 20-20-20 break",
            "text": f"You have been looking at the screen for {session_min:.0f} minutes. "
                    "Look at something 20 feet (6 m) away for 20 seconds.",
        })

    squints = len(db.events(["squint_start"], since=now - 30 * 60, limit=1000))
    if squints >= 3:
        out.append({
            "id": "squinting", "level": "suggest", "title": "You keep squinting",
            "text": f"{squints} squints in the last 30 minutes. Try a bigger font, less glare or more "
                    "light. If it keeps happening, it may be time for an eye exam.",
        })

    if not out:
        out.append({
            "id": "all_good", "level": "info", "title": "Looking good",
            "text": "Blink rate, distance and breaks are all in a healthy range right now.",
        })
    order = {"urgent": 0, "suggest": 1, "info": 2}
    return sorted(out, key=lambda x: order[x["level"]])
