""""What am I looking at?": gaze region of the FRONT camera -> local YOLO (spoken at once)
-> Muse (spoken when it arrives).

    1. Pick the region: an explicit override, words in the question ("on my left"),
       or the wearer's current gaze (center when unknown). "all" = the whole view.
    2. Crop that part of the latest FRONT frame.
    3. YOLO on the crop -> a short sentence spoken immediately ("Ahead: a laptop, about
       60 centimeters away").
    4. Crop + detections + question -> Muse -> a richer 1-2 sentence answer, spoken next.
       If Muse is unavailable (no key, budget, offline), the local answer stands.

Answers also go out as "assist_answer" events on /ws/live (stage "local", then "muse").
"""

import re
import time

from backend.muse_client import MuseUnavailable
from backend.vision import quick_answer

REGION_WORDS = [
    (r"\b(left)\b", "left"),
    (r"\b(right)\b", "right"),
    (r"\b(around me|everything|whole|all around|surroundings|describe the scene)\b", "all"),
    (r"\b(ahead|in front|straight|center|middle)\b", "center"),
]
DEFAULT_QUESTION = "What am I looking at?"


def region_from_question(question):
    q = (question or "").lower()
    for pattern, region in REGION_WORDS:
        if re.search(pattern, q):
            return region
    return None


class Assistant:
    def __init__(self, front_reader, detector, muse, gaze, voice, emit, focal_px=None, db=None, still_fn=None):
        self.front = front_reader
        self.detector = detector
        self.muse = muse
        self.gaze = gaze
        self.voice = voice
        self.emit = emit
        self.focal_px = focal_px          # callable(width) -> FRONT focal length in px
        self.db = db
        self.still_fn = still_fn          # callable -> a higher-res FRONT still (or None)
        self.last = None

    def pick_region(self, question=None, region_override=None):
        if region_override:
            if region_override not in ("left", "center", "right", "all"):
                raise ValueError("region_override must be left, center, right or all")
            return region_override, "override"
        from_q = region_from_question(question)
        if from_q:
            return from_q, "question"
        if self.gaze is not None and self.gaze.smoothed:
            return self.gaze.smoothed, "gaze"
        return "center", "default"

    def _say(self, text, stage, extra):
        self.voice.say(text, source="assist")
        self.emit("assist_answer", {"stage": stage, "text": text, **extra})

    def look(self, question=None, region_override=None, use_muse=True):
        t0 = time.time()
        question = (question or "").strip() or DEFAULT_QUESTION
        region, why = self.pick_region(question, region_override)
        result = {"question": question, "region": region, "region_source": why, "detections": [],
                  "local_answer": None, "muse_answer": None, "muse_error": None, "timing_s": {}}

        status = self.front.status() if self.front is not None else {"ok": False}
        _, frame, _ = self.front.latest() if self.front is not None else (0, None, 0)
        if frame is not None and status.get("ok") and self.still_fn is not None:
            still = self.still_fn()       # one 640x480/800x600 /capture, only now, for detail
            if still is not None:
                frame = still
                result["still"] = True
        if frame is None or not status.get("ok"):
            text = "The front camera is offline, so I can't see right now."
            result["local_answer"] = text
            self._say(text, "local", {"region": region})
            self.last = result
            return result

        crop, x0 = self.gaze.crop(frame, region) if self.gaze is not None else (frame, 0)
        focal = self.focal_px(frame.shape[1]) if self.focal_px else None
        mirrored = bool(getattr(self.gaze, "front_mirrored", False))
        dets = self.detector.detect(crop, x_offset=x0, full_width=frame.shape[1], focal_px=focal, mirrored=mirrored)
        local = quick_answer(dets, region)
        result["detections"] = [d.as_dict() for d in dets]
        result["local_answer"] = local
        result["timing_s"]["local"] = round(time.time() - t0, 3)
        self._say(local, "local", {"region": region})          # spoken before Muse is even asked

        if use_muse and self.muse is not None:
            where = {"left": "the left part", "right": "the right part", "center": "the middle part",
                     "all": "all"}[region]
            context = (f"The image is {where} of what the wearer's forward-facing camera sees. "
                       f"Local object detector found: "
                       + (", ".join(f"{d.label} ({d.position}"
                                    + (f", ~{d.distance_cm / 100:.1f} m" if d.distance_cm else "") + ")"
                                    for d in dets[:6]) or "nothing")
                       + ". Use it as a hint, but trust the image.")
            try:
                r = self.muse.ask(question, image=crop, purpose="assist", context=context)
                result["muse_answer"] = r.text
                result["muse_cost_usd"] = round(r.cost_usd, 5)
                self._say(r.text, "muse", {"region": region, "cost_usd": round(r.cost_usd, 5)})
            except MuseUnavailable as e:
                result["muse_error"] = str(e)
                self.emit("assist_answer", {"stage": "muse_unavailable", "text": None, "error": str(e),
                                            "region": region})
        result["timing_s"]["total"] = round(time.time() - t0, 3)
        if self.db is not None:
            self.db.add_event(t0, "assist", {k: result[k] for k in ("question", "region", "local_answer",
                                                                     "muse_answer", "muse_error")})
        self.last = result
        return result
