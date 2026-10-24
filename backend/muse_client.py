"""Meta Muse Spark (Model API) client with a hard budget guard.

API facts (checked against Meta's docs, Oct 2026): base URL https://api.meta.ai/v1,
OpenAI-compatible Chat Completions, Bearer key, images as image_url data URLs,
Standard tier $1.25 / $4.25 per 1M input / output tokens; reasoning tokens bill as
output. A 512 px JPEG is ~300 input tokens; a short answer costs ~$0.001.

Budget guard (config `muse`): every call is logged to the muse_calls table with its
tokens and cost. No call is made once the lifetime cap ($10 for now) or the daily
cap is reached, or faster than max_calls_per_min. Muse is only called on demand
("what am I looking at?") or once per confirmed rear event, never per frame.

The key comes from MUSE_API_KEY (or Meta's MODEL_API_KEY) in the environment or in
the repo's .env file (gitignored). It is never logged.
"""

import base64
import collections
import json
import os
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import cv2

ROOT = Path(__file__).resolve().parent.parent

SYSTEM_PROMPT = (
    "You are the voice of assistive smart glasses worn by a blind or low-vision person. "
    "Answer in one or two short sentences that sound natural when spoken aloud. "
    "Say where things are relative to the wearer (left, ahead, right) and roughly how far, when you can. "
    "Mention anything hazardous first. Read short text aloud if it matters. "
    "Never identify people by name and never guess identity, age, gender, race or other personal traits: "
    "say 'a person'. If you are not sure, say so briefly. No markdown, no lists."
)


class MuseUnavailable(RuntimeError):
    """No key, budget or rate limit reached, or the API failed. str() is user-safe."""


@dataclass
class MuseResult:
    text: str
    prompt_tokens: int
    completion_tokens: int
    reasoning_tokens: int
    cost_usd: float
    latency_s: float
    model: str


def load_key(env_file=None):
    for name in ("MUSE_API_KEY", "MODEL_API_KEY"):
        if os.environ.get(name):
            return os.environ[name]
    path = Path(env_file or ROOT / ".env")
    try:
        for line in path.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                if k.strip() in ("MUSE_API_KEY", "MODEL_API_KEY") and v.strip():
                    return v.strip().strip('"').strip("'")
    except OSError:
        pass
    return None


def encode_image(img, max_side=512, quality=70):
    """Downscale so the longer side is max_side and JPEG-encode: ~30 KB, ~300 tokens."""
    h, w = img.shape[:2]
    s = min(1.0, max_side / max(h, w))
    if s < 1.0:
        img = cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])
    if not ok:
        raise ValueError("JPEG encoding failed")
    return base64.b64encode(buf.tobytes()).decode()


class MuseClient:
    def __init__(self, cfg, db, key=None, transport=None):
        m = cfg.get("muse", {})
        self.db = db
        self.enabled = m.get("enabled", True)
        self.base_url = m.get("base_url", "https://api.meta.ai/v1").rstrip("/")
        self.model = m.get("model", "muse-spark-1.3")
        self.max_tokens = m.get("max_tokens", 300)          # reasoning uses ~60-90 of these
        self.reasoning_effort = m.get("reasoning_effort", "minimal")
        self.timeout_s = m.get("timeout_s", 20)
        self.lifetime_cap = m.get("lifetime_cap_usd", 10.0)
        self.daily_cap = m.get("daily_cap_usd", 5.0)
        self.prior_spend = m.get("prior_spend_usd", 0.0)    # spent with this key outside this backend
        self.max_per_min = m.get("max_calls_per_min", 6)
        p = m.get("price_per_mtok", {})
        self.price_in = p.get("input", 1.25) / 1e6
        self.price_cached = p.get("cached_input", 0.15) / 1e6
        self.price_out = p.get("output", 4.25) / 1e6
        self.image_side = m.get("image_max_side", 512)
        self.image_quality = m.get("image_quality", 70)
        self.key = key if key is not None else load_key()
        self._transport = transport or self._post      # tests inject a fake
        self._recent = collections.deque()
        self._lock = threading.Lock()

    # -- budget ----------------------------------------------------------------

    def spent(self, since=0.0):
        """Dollars spent since a time; the lifetime total (since=0) includes prior_spend_usd."""
        return float(self.db.muse_spend(since)["cost"]) + (self.prior_spend if since == 0.0 else 0.0)

    def _day_start(self):
        lt = time.localtime()
        return time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))

    def check_budget(self):
        """Raise MuseUnavailable if a call is not allowed right now."""
        if not self.enabled:
            raise MuseUnavailable("Muse is turned off in config")
        if not self.key:
            raise MuseUnavailable("no Muse API key (set MUSE_API_KEY in .env)")
        if self.spent() >= self.lifetime_cap:
            raise MuseUnavailable(f"Muse budget cap of ${self.lifetime_cap:.2f} reached")
        if self.spent(self._day_start()) >= self.daily_cap:
            raise MuseUnavailable(f"Muse daily cap of ${self.daily_cap:.2f} reached")
        now = time.time()
        with self._lock:
            while self._recent and self._recent[0] < now - 60:
                self._recent.popleft()
            if len(self._recent) >= self.max_per_min:
                raise MuseUnavailable("too many Muse requests this minute")
            self._recent.append(now)

    def usage(self):
        total = dict(self.db.muse_spend())
        total["cost"] = self.spent()
        today = self.db.muse_spend(self._day_start())
        return {
            "model": self.model,
            "has_key": bool(self.key),
            "enabled": self.enabled,
            "total_usd": round(float(total["cost"]), 5),
            "today_usd": round(float(today["cost"]), 5),
            "lifetime_cap_usd": self.lifetime_cap,
            "daily_cap_usd": self.daily_cap,
            "remaining_usd": round(max(0.0, self.lifetime_cap - float(total["cost"])), 4),
            "calls": total["calls"],
            "failed_calls": total["failed"],
            "tokens": {k: total[k] for k in ("prompt_tokens", "completion_tokens", "reasoning_tokens")},
            "by_purpose": self.db.muse_by_purpose(),
            "recent": self.db.muse_recent(5),
            "max_calls_per_min": self.max_per_min,
            "note": "Spend is counted by this backend only; Meta's dashboard is the source of truth.",
        }

    # -- calls -------------------------------------------------------------------

    def _post(self, url, body, headers, timeout):
        req = urllib.request.Request(url, json.dumps(body).encode(), headers)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)

    def ask(self, question, image=None, purpose="assist", context=None, system=SYSTEM_PROMPT):
        """One chat completion. image: BGR array (downscaled + JPEG'd here) or None.
        Returns MuseResult; raises MuseUnavailable (never spends past the caps)."""
        self.check_budget()
        text = question if not context else f"{question}\n\n{context}"
        content = [{"type": "text", "text": text}]
        if image is not None:
            b64 = encode_image(image, self.image_side, self.image_quality)
            content.append({"type": "image_url", "image_url": {"url": f"data:image/jpeg;base64,{b64}"}})
        body = {"model": self.model, "max_tokens": self.max_tokens, "reasoning_effort": self.reasoning_effort,
                "messages": [{"role": "system", "content": system}, {"role": "user", "content": content}]}
        headers = {"Authorization": f"Bearer {self.key}", "Content-Type": "application/json"}
        t0 = time.time()
        try:
            r = self._transport(f"{self.base_url}/chat/completions", body, headers, self.timeout_s)
        except urllib.error.HTTPError as e:
            detail = e.read()[:200].decode(errors="replace")
            self.db.add_muse_call(t0, purpose, self.model, False, latency_s=time.time() - t0,
                                  error=f"HTTP {e.code}: {detail}")
            raise MuseUnavailable(f"Muse API error {e.code}") from e
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as e:
            self.db.add_muse_call(t0, purpose, self.model, False, latency_s=time.time() - t0, error=repr(e))
            raise MuseUnavailable("could not reach Muse") from e
        dt = time.time() - t0
        u = r.get("usage") or {}
        pt, ct = int(u.get("prompt_tokens", 0)), int(u.get("completion_tokens", 0))
        rt = int((u.get("completion_tokens_details") or {}).get("reasoning_tokens", 0))
        cached = int((u.get("prompt_tokens_details") or {}).get("cached_tokens", 0))
        cost = (pt - cached) * self.price_in + cached * self.price_cached + ct * self.price_out
        answer = ((r.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
        answer = answer.strip()
        self.db.add_muse_call(t0, purpose, r.get("model", self.model), bool(answer), pt, ct, rt, cached,
                              cost, dt, None if answer else "empty answer")
        print(f"[muse] {purpose}: {pt}+{ct} tokens (reasoning {rt}) ${cost:.5f} {dt:.2f}s, "
              f"total ${self.spent():.4f} of ${self.lifetime_cap:.2f}")
        if not answer:
            raise MuseUnavailable("Muse returned no text")
        return MuseResult(answer, pt, ct, rt, cost, dt, r.get("model", self.model))
