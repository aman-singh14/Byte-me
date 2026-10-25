"""FastAPI server. CORS is open so the Flutter app (or any phone browser) on the
same network can call it. Interactive docs at /docs.

    GET  /                       web dashboard (backend/static/index.html)
    GET  /stats/live             current blink rate, squint, distance, rear LGMD state
    GET  /stats/history?range=   hour | day | week, bucketed averages
    GET  /stats/summary?range=   totals for the range
    GET  /alerts                 rear-camera alerts, newest first
    GET  /events?kind=           any stored events
    GET  /recommendations        rule-based tips
    GET  /cameras                stream status per camera
    GET  /stream/{camera}        annotated MJPEG (eye, front, rear)
    POST /calibrate/eye          record a new open-eye baseline (look at the screen 5 s)
    POST /calibrate/distance     {"known_cm": 50}: stand at a known distance first
    POST /distance/device        {"device": "laptop" | "phone"}
    GET  /gaze                   current gaze (left/center/right), calibration state, regions
    POST /gaze/calibrate         {"regions": ["left","center","right"]} (default all three, ~3 s each)
    POST /gaze/calibrate/cancel
    PUT  /gaze/regions           {"left": [0, 0.41], "center": [0.26, 0.74], "right": [0.59, 1]}
    POST /assist/look            {"question"?, "region_override"?: left|center|right|all}: what am I looking at?
    POST /assist/describe        {"question"?}: same, whole forward view
    GET  /assist/last            the last answer
    GET  /muse/usage             Muse spend, caps, tokens, recent calls
    POST /vlm/{feature}          {"images": [{"camera", "jpeg"}], "use_front"?}: one structured VLM answer (backend/vlm.py)
    POST /rear/packets           raw rear-protocol packets (HTTP transport for an ESP32 bridge)
    GET  /rear/status            FPGA link: online, packet/CRC stats, last result
    GET  /rear/events            recent rear results (what, dangerous, side, time to contact)
    GET  /eyes/live              blinks/min, partial blinks, squint, low-blink flag, near-work + distance
    GET  /eyes/history?range=    hour | day | week: blink rate, partial blinks, squints, low-blink stretches
    GET  /closeup/sessions?date= close-up sessions for a day (YYYY-MM-DD, default today) + totals by object
    GET  /closeup/calibration    which near-work objects are calibrated, thresholds
    POST /closeup/calibrate      {"object": "phone"|"laptop"|"book"|"tv"|"keyboard", "known_cm": 40}
    GET  /rings/today            heads-up (minutes, goal, breaks), outside (minutes, goal), points
    GET  /rings/history?days=7   one entry per day
    GET  /outdoor                live brightness estimate, outside or not, sensor status
    POST /outdoor/calibrate      {"where": "indoor"|"outdoor"} at a typical spot
    POST /dev/outside            {"on": true|false|null}: dev mode only, force outdoor on/off/auto
    GET  /discovery              cameras that announced themselves, stream URL candidates
    GET  /screentime             Mac app usage (real) + iOS usage (mock, labelled)
    GET  /screentime/correlation eye metrics per Mac app and category
    GET  /facetime               current OBS scene
    POST /facetime/switch        {"target": "glasses" | "mac" | "toggle"}
    WS   /ws/live                {"type":"live",...} every 0.5 s and {"type":"event",...} as they happen
    POST /rooms, GET /h/{room}, WS /ws/wearer/{room}, WS /ws/helper/{room}: Call a helper (backend/helper.py)
    WS   /ws/captions            live captions relay to Muse Voice Transcribe (backend/captions.py)
"""

import asyncio
import time
from pathlib import Path

import cv2
from fastapi import FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

from backend import captions, helper, screentime
from backend.db import RANGES
from backend.facetime import FaceTimeError, FaceTimeSwitch
from backend.muse_client import MuseUnavailable
from backend.recommendations import recommend
from backend.rings import DAY, closeup_summary, day_start
from backend.vlm import VlmError

STATIC = Path(__file__).resolve().parent / "static"


class DistanceCalibration(BaseModel):
    known_cm: float = 50.0


class Device(BaseModel):
    device: str


class FaceTimeTarget(BaseModel):
    target: str = "toggle"


class CloseupCalibration(BaseModel):
    object: str
    known_cm: float


class OutdoorCalibration(BaseModel):
    where: str


class OutsideOverride(BaseModel):
    on: bool | None = None


class LookRequest(BaseModel):
    question: str | None = None
    region_override: str | None = None
    require_gaze: bool = False


class VlmImage(BaseModel):
    camera: str
    jpeg: str                       # base64


class VlmRequest(BaseModel):
    images: list[VlmImage] = []
    use_front: bool = False


class GazeCalibration(BaseModel):
    regions: list[str] = ["left", "center", "right"]


class GazeRegions(BaseModel):
    left: tuple[float, float]
    center: tuple[float, float]
    right: tuple[float, float]


def create_app(rt):
    app = FastAPI(title="Glasses backend", version="0.1")
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
    facetime = FaceTimeSwitch(rt.cfg)
    app.include_router(helper.router(helper.Rooms()))
    app.include_router(captions.router())

    def check_range(range_name):
        if range_name not in RANGES:
            raise HTTPException(400, f"range must be one of {sorted(RANGES)}")
        return time.time() - RANGES[range_name][0]

    @app.get("/")
    def dashboard():
        return FileResponse(STATIC / "index.html")

    @app.get("/stats/live")
    def stats_live():
        return rt.live()

    @app.get("/stats/history")
    def stats_history(range: str = "day"):
        check_range(range)
        return rt.db.history(range)

    @app.get("/stats/summary")
    def stats_summary(range: str = "day"):
        return {"range": range, **rt.db.summary(check_range(range))}

    @app.get("/alerts")
    def alerts(limit: int = Query(50, le=1000)):
        return rt.db.events(["alert"], limit=limit)

    @app.get("/events")
    def events(kind: list[str] | None = Query(None), limit: int = Query(100, le=5000), since: float = 0):
        return rt.db.events(kind, since=since, limit=limit)

    @app.get("/recommendations")
    def recommendations():
        return recommend(rt.live(), rt.db, rt.cfg)

    @app.get("/cameras")
    def cameras():
        return rt.streams.status()

    @app.get("/stream/{camera}")
    def stream(camera: str):
        if camera not in ("eye", "front", "rear"):
            raise HTTPException(404, "camera must be eye, front or rear")

        def frames():
            last = None
            while True:
                img = rt.frame(camera)
                if img is None or img is last:
                    time.sleep(0.03)
                    continue
                last = img
                ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 70])
                if ok:
                    yield b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + buf.tobytes() + b"\r\n"

        return StreamingResponse(frames(), media_type="multipart/x-mixed-replace; boundary=frame")

    @app.post("/calibrate/eye")
    def calibrate_eye():
        rt.eye.calibrate()
        return {"ok": True, "seconds": rt.eye.detector.calibration_s,
                "text": "Keep your eyes open and look at the screen normally."}

    @app.post("/calibrate/distance")
    def calibrate_distance(body: DistanceCalibration):
        try:
            focal = rt.distance.calibrate(body.known_cm)
        except ValueError as e:
            raise HTTPException(409, str(e))
        return {"ok": True, "focal_px": round(focal, 1), "known_cm": body.known_cm}

    @app.post("/distance/device")
    def distance_device(body: Device):
        try:
            rt.distance.set_device(body.device)
        except ValueError as e:
            raise HTTPException(400, str(e))
        return {"ok": True, "device": body.device, "threshold_cm": rt.distance.threshold_cm}

    @app.get("/gaze")
    def gaze_get():
        g = rt.gaze
        return {**g.state(), "centroids": g.centroids, "regions": g.regions}

    @app.post("/gaze/calibrate")
    def gaze_calibrate(body: GazeCalibration | None = None):
        regions = (body or GazeCalibration()).regions
        bad = [r for r in regions if r not in ("left", "center", "right")]
        if bad or not regions:
            raise HTTPException(400, "regions must be left, center and/or right")
        rt.gaze.start_calibration(regions)
        return {"ok": True, "steps": regions, "step_s": rt.gaze.step_s,
                "text": "Follow the spoken prompts: look left, straight ahead, then right."}

    @app.post("/gaze/calibrate/cancel")
    def gaze_calibrate_cancel():
        rt.gaze.cancel_calibration()
        return {"ok": True}

    @app.put("/gaze/regions")
    def gaze_regions(body: GazeRegions):
        regions = body.model_dump()
        for name, (a, b) in regions.items():
            if not 0 <= a < b <= 1:
                raise HTTPException(400, f"{name}: need 0 <= start < end <= 1")
        rt.gaze.regions = {k: tuple(v) for k, v in regions.items()}
        return {"ok": True, "regions": rt.gaze.regions}

    EYE_KEYS = ("eye_detected", "calibrated", "calibrating", "blink_rate", "blinks_total", "partial_blinks",
                "squinting", "openness_ratio", "low_blink", "low_blink_since", "method")
    NEAR_KEYS = ("nearwork", "nearwork_object", "nearwork_distance_cm", "nearwork_close", "nearwork_threshold_cm",
                 "nearwork_objects", "closeup_session", "heads_up")

    @app.get("/eyes/live")
    def eyes_live():
        d = rt.live()
        return {"ts": d["ts"], "cameras": d.get("cameras", {}), **{k: d.get(k) for k in EYE_KEYS},
                **{k: d.get(k) for k in NEAR_KEYS}}

    @app.get("/eyes/history")
    def eyes_history(range: str = "day"):
        since = check_range(range)
        h = rt.db.history(range)
        b = h["bucket_s"]
        partial = {}
        for e in rt.db.events(["partial_blink"], since=since, limit=100000):
            k = int(e["ts"] // b) * b
            partial[k] = partial.get(k, 0) + 1
        points = [{"t": p["t"], "blink_rate": p["blink_rate"], "blinks": p["blinks"],
                   "partial_blinks": partial.get(p["t"], 0), "squint_frac": p["squint_frac"]} for p in h["points"]]
        squints = [e["ts"] for e in rt.db.events(["squint_start"], since=since, limit=10000)][::-1]
        low = rt.db.intervals("low_blink", since, time.time() + 1)
        live = rt.live()
        if live.get("low_blink") and live.get("low_blink_since"):
            low = low + [{"start": live["low_blink_since"], "end": live["ts"], "open": True}]
        return {"range": range, "bucket_s": b, "points": points, "squints": squints,
                "low_blink": [{"start": i["start"], "end": i["end"], "open": i.get("open", False)} for i in low]}

    @app.get("/closeup/sessions")
    def closeup_sessions(date: str | None = None):
        if date:
            try:
                d0 = day_start(time.mktime(time.strptime(date, "%Y-%m-%d")) + 3600)
            except ValueError:
                raise HTTPException(400, "date must be YYYY-MM-DD")
        else:
            d0 = day_start()
        return closeup_summary(rt.db, d0, open_session=rt.front.closeup.open_session(time.time()))

    @app.get("/closeup/calibration")
    def closeup_calibration():
        return rt.front.nearwork.calibration()

    @app.post("/closeup/calibrate")
    def closeup_calibrate(body: CloseupCalibration):
        if not 5 <= body.known_cm <= 500:
            raise HTTPException(400, "known_cm must be between 5 and 500")
        try:
            return rt.front.nearwork.calibrate(body.object, body.known_cm)
        except ValueError as e:
            raise HTTPException(409, str(e))

    @app.get("/rings/today")
    def rings_today():
        return {**rt.rings.today(), "heads_up_now": rt.front.headsup.active(time.time()),
                "outside_now": rt.front.outdoor.outside}

    @app.get("/rings/history")
    def rings_history(days: int = Query(7, ge=1, le=60)):
        return rt.rings.history(days)

    @app.get("/outdoor")
    def outdoor_live():
        return rt.front.outdoor.state(time.time())

    @app.post("/outdoor/calibrate")
    def outdoor_calibrate(body: OutdoorCalibration):
        try:
            return rt.front.outdoor.calibrate(body.where)
        except ValueError as e:
            raise HTTPException(409, str(e))

    @app.post("/dev/outside")
    def dev_outside(body: OutsideOverride):
        if not rt.cfg.get("dev"):
            raise HTTPException(403, "only in dev mode (--dev)")
        rt.front.outdoor.manual = body.on
        return {"manual": body.on}

    @app.get("/discovery")
    def discovery():
        return rt.directory.status()

    @app.post("/assist/look")
    def assist_look(body: LookRequest | None = None):
        body = body or LookRequest()
        try:
            return rt.assistant.look(body.question, body.region_override, require_gaze=body.require_gaze)
        except ValueError as e:
            raise HTTPException(400, str(e))

    @app.post("/assist/describe")
    def assist_describe(body: LookRequest | None = None):
        return rt.assistant.look((body.question if body else None) or "Describe what is in front of me.", "all")

    @app.get("/assist/last")
    def assist_last():
        return rt.assistant.last or {}

    @app.get("/muse/usage")
    def muse_usage():
        return rt.muse.usage()

    @app.post("/vlm/{feature}")
    def vlm(feature: str, body: VlmRequest | None = None):
        body = body or VlmRequest()
        try:
            return rt.vlm.run(feature, [(i.camera, i.jpeg) for i in body.images], body.use_front)
        except VlmError as e:
            raise HTTPException(400, str(e)) from e
        except MuseUnavailable as e:
            raise HTTPException(503, str(e)) from e

    @app.post("/rear/packets")
    async def rear_packets(request: Request):
        if rt.rear_service is None:
            raise HTTPException(409, "rear.mode is not fpga")
        body = await request.body()
        before = rt.rear_service.stats["parse_errors"]
        n = rt.rear_service.feed_bytes(body, source=f"http:{request.client.host if request.client else '?'}")
        return {"accepted": n, "errors": rt.rear_service.stats["parse_errors"] - before}

    @app.get("/rear/status")
    def rear_status():
        if rt.rear_service is None:
            return {"mode": rt.rear_mode}
        return rt.rear_service.status()

    @app.get("/rear/events")
    def rear_events():
        return list(reversed(rt.rear_service.history)) if rt.rear_service is not None else []

    @app.get("/screentime")
    def screentime_usage(range: str = "day"):
        since = check_range(range)
        return {"mac": screentime.mac_usage(rt.db, since), "ios": screentime.ios_mock_today()}

    @app.get("/screentime/correlation")
    def screentime_correlation(range: str = "day"):
        return screentime.correlate(rt.db, check_range(range))

    @app.get("/facetime")
    def facetime_status():
        try:
            return facetime.status()
        except FaceTimeError as e:
            raise HTTPException(503, str(e))

    @app.post("/facetime/switch")
    def facetime_switch(body: FaceTimeTarget):
        try:
            res = facetime.switch(body.target)
        except ValueError as e:
            raise HTTPException(400, str(e))
        except FaceTimeError as e:
            raise HTTPException(503, str(e))
        rt.emit("facetime", res)
        return res

    @app.websocket("/ws/live")
    async def ws_live(ws: WebSocket):
        await ws.accept()
        _, last_id = rt.events_after(0)
        try:
            while True:
                evs, last_id_new = rt.events_after(last_id)
                last_id = last_id_new
                for e in evs:
                    await ws.send_json({"type": "event", **e})
                await ws.send_json({"type": "live", **rt.live()})
                await asyncio.sleep(0.5)
        except (WebSocketDisconnect, RuntimeError):
            pass

    return app
