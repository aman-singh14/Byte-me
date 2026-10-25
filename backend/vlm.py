"""One VLM service for every snapshot feature in the app (Muse Spark through MuseClient).

    POST /vlm/{feature}   {"images": [{"camera": "rear"|"front"|"phone", "jpeg": "<base64>"}], "use_front": false,
                           "question": "..." (ask only)}
                          -> {"feature", "result": {...}, "latency_s", "model"}

Each feature has its own prompt, JSON schema (structured output) and timeout (4 s
by default). The app sends the snapshots it has (the rear camera is the phone's);
"use_front" adds this laptop's newest FRONT frame. Images are downscaled to at most
muse.image_max_side (512 px) and JPEG'd by MuseClient before they leave.

Nothing is stored: images and answers live only for the request. MuseClient logs
tokens, cost and latency for the budget guard, never the answer or the image.
"""

import base64
import json

import cv2
import numpy as np

from backend.muse_client import MuseUnavailable

# Rules for every call, on top of each feature's own prompt.
SYSTEM_PROMPT = (
    "You help a person wearing camera glasses, who may be blind or have low vision. "
    "Describe positions and actions only. Never identify people, and never guess anyone's identity, "
    "age, race, gender or emotion: say 'a person'. If you are not sure, say so. "
    "Never say or imply that something is safe (for example never 'safe to cross'). "
    "Directions are always from the wearer's point of view. The rear camera faces backward, "
    "so the left side of a rear image is behind the wearer's RIGHT. "
    "Answer only with JSON that matches the schema. Keep strings short and natural to say aloud."
)

MAX_IMAGE_BYTES = 2_000_000
MAX_QUESTION_CHARS = 300

# Hidden reasoning counts toward max_tokens, even at minimal effort: a yes/no
# about a person used ~300 before answering. This leaves room for the answer.
MAX_TOKENS = 800


def _schema(properties):
    """A strict object schema: every property required, nothing else allowed."""
    return {"type": "object", "properties": properties, "required": list(properties),
            "additionalProperties": False}


# name -> prompt, schema, timeout (s), cameras it accepts
FEATURES = {
    # Step 1: someone stopped close behind or beside the wearer. Are they engaging?
    "social_confirm": {
        "prompt": ("This is one frame from the camera on the back of the wearer's head. A person has just "
                   "stopped close behind or beside the wearer. Is that person facing the wearer or trying "
                   "to get their attention (for example waving, talking to them, reaching toward them)? "
                   "Someone walking past, queueing with their back turned or looking at a phone is not. "
                   "action: two to four words for what they are doing, like 'waving' or 'standing still'."),
        "schema": _schema({"engaging": {"type": "boolean"}, "action": {"type": "string"}}),
        "timeout_s": 4.0,
        "cameras": ("rear",),
    },
    # A short description, used by the app's latency check.
    "describe": {
        "prompt": "In one short sentence, what is in view? summary: that sentence.",
        "schema": _schema({"summary": {"type": "string"}}),
        "timeout_s": 4.0,
        "cameras": ("rear", "front"),
    },
    # Ask without the laptop: the wearer's spoken question about one photo (glasses front camera, or phone).
    "ask": {
        "prompt": ("This photo is from the camera the wearer is pointing at what they are asking about: their "
                   "glasses' front camera, or their phone camera when the glasses aren't connected (the image "
                   "list says which). Answer their question from the photo in one or two short sentences. "
                   "answer: that reply."),
        "schema": _schema({"answer": {"type": "string"}}),
        "timeout_s": 8.0,
        "cameras": ("phone", "front"),
        "question": True,
    },
}


class VlmError(ValueError):
    """A bad request (unknown feature, bad image). str() is user-safe."""


def decode_jpeg(b64):
    try:
        data = base64.b64decode(b64, validate=True)
    except (ValueError, TypeError) as e:
        raise VlmError("image is not base64") from e
    if not 0 < len(data) <= MAX_IMAGE_BYTES:
        raise VlmError("image is empty or too large")
    img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise VlmError("image is not a JPEG")
    return img


def check(value, schema):
    """True if value fits our (small) subset of JSON schema."""
    kind = schema.get("type")
    if kind == "object":
        props = schema.get("properties", {})
        return (isinstance(value, dict) and all(k in value for k in schema.get("required", []))
                and all(check(value[k], props[k]) for k in props if k in value))
    if kind == "array":
        return isinstance(value, list) and all(check(v, schema.get("items", {})) for v in value)
    if kind == "string":
        return isinstance(value, str) and ("enum" not in schema or value in schema["enum"])
    if kind == "boolean":
        return isinstance(value, bool)
    if kind == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return True


def parse_answer(text, schema):
    """The model's JSON, or MuseUnavailable if it isn't what the schema asks for."""
    text = text.strip()
    if not text.startswith("{"):  # tolerate a code fence or a word before the object
        start, end = text.find("{"), text.rfind("}")
        text = text[start:end + 1] if 0 <= start < end else text
    try:
        value = json.loads(text)
    except ValueError as e:
        raise MuseUnavailable("Muse did not answer in the expected format") from e
    if not check(value, schema):
        raise MuseUnavailable("Muse did not answer in the expected format")
    return value


class VlmService:
    def __init__(self, muse, front_frame=None):
        self.muse = muse
        self.front_frame = front_frame      # callable -> newest FRONT frame (BGR) or None

    def run(self, feature, images=(), use_front=False, question=None):
        """images: [(camera, base64 JPEG)]; question: the wearer's words (ask only).
        Raises VlmError (bad request) or MuseUnavailable."""
        spec = FEATURES.get(feature)
        if spec is None:
            raise VlmError(f"unknown feature {feature!r}")
        asked = (question or "").strip()[:MAX_QUESTION_CHARS] if spec.get("question") else ""
        if spec.get("question") and not asked:
            raise VlmError(f"{feature} needs a question")
        named = []
        for camera, b64 in images:
            if camera not in spec["cameras"]:
                raise VlmError(f"{feature} does not take a {camera} image")
            named.append((camera, decode_jpeg(b64)))
        if use_front:
            frame = self.front_frame() if self.front_frame else None
            if frame is None:
                raise MuseUnavailable("the front camera is offline")
            named.append(("front", frame))
        if not named:
            raise VlmError("send at least one image")
        order = "; ".join(f"image {i + 1}: {cam} camera" for i, (cam, _) in enumerate(named))
        context = f"Images: {order}." + (f'\nThe wearer asked: "{asked}"' if asked else "")
        r = self.muse.ask(spec["prompt"], images=[img for _, img in named], purpose=f"vlm_{feature}",
                          context=context, system=SYSTEM_PROMPT, schema=spec["schema"],
                          timeout_s=spec["timeout_s"], max_tokens=MAX_TOKENS)
        return {"feature": feature, "result": parse_answer(r.text, spec["schema"]),
                "latency_s": round(r.latency_s, 3), "model": r.model}
