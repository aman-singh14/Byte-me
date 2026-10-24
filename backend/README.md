# Mega Glasses backend

The glasses have three cameras, and all the processing happens here, on the laptop:

| Camera | Hardware | Backend does |
|---|---|---|
| EYE | ESP32-CAM ~3 cm from one eye, MJPEG over Wi-Fi | close-up pupil tracking → blinks, squints, gaze |
| FRONT | ESP32-CAM looking outward, MJPEG over Wi-Fi | distance to the screen/phone, "what am I looking at?" |
| REAR | OV2640 on the FPGA, which runs LGMD in hardware | receives EVENT + last 3 s of video, classifies, warns |

The ESP32s only stream video. Results are stored in SQLite and served by FastAPI:
a web dashboard at `/`, and Aman's app fed live over its own UDP protocol.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Python 3.11+. The first run downloads MediaPipe's face model (3.7 MB, dev mode only)
to `backend/models/`; YOLO's `yolov8n.pt` (6 MB) goes there too.

## Run the product

All three cameras on the phone hotspot (see `../firmware/esp32cam/README.md`), then from the repo root:

```bash
.venv/bin/python -m backend.main
```

Camera URLs are in `config.yaml` (`http://eye-cam.local:81/stream`,
`http://front-cam.local:81/stream`). If a stream is down there is no fallback: the
dashboard shows **"EYE camera offline"** / **"FRONT camera offline"** and the backend
retries every 3 s.

- Dashboard: <http://localhost:8000/> (on a phone on the same hotspot:
  `http://<laptop-ip>:8000/`). API docs: <http://localhost:8000/docs>.
- The first 5 s with the eye in view are eye calibration: keep the eye open and look
  ahead normally. For distance, sit at a known distance from the screen (say 50 cm)
  and press *Calibrate distance…*.

Useful overrides: `--eye <url> --front <url>`, `--port 8001`, `--phone 172.20.10.1`,
`--speech print` (silence), `--preview` (annotated camera windows).

## Dev mode (no hardware)

Until the ESP32-CAMs and the FPGA arrive, `--dev` merges `config.dev.yaml` on top of
`config.yaml` and swaps in **stand-ins that are not part of the product**:

| Product | Dev stand-in |
|---|---|
| EYE camera + close-up pupil tracking | laptop webcam + MediaPipe face mesh (whole face) |
| FRONT camera + screen-width distance | the same webcam + face-width distance, or a still image (`--front sample:bus.jpg`, any .jpg/.png/.mp4) |
| REAR FPGA events | lgmd.py in software on a synthetic looming square (`rear.mode: software`); later `tools/mock_fpga.py` |

```bash
.venv/bin/python -m backend.main --dev --preview
.venv/bin/python -m backend.main --dev --front sample:bus.jpg    # a street scene as the forward view
```

On macOS, give the terminal camera access (System Settings → Privacy & Security →
Camera). The synthetic rear says "Object approaching from behind" every ~5 s
(`--speech print` for silence). `mock_glasses.py` can also stand in for an ESP32 over
the network: run it and use `http://localhost:81/stream` as a source.

Demo history for the pitch (fake data, kept in a separate file):

```bash
.venv/bin/python -m backend.seed_demo            # writes backend/data/demo.db
# then set db.path: backend/data/demo.db in config.yaml
```

## With Aman's app

The backend speaks `mobile-app/lib/net/protocol.dart` (it pretends to be the
"frame" device, like `mock_glasses.py`). Run **either** the backend **or**
`mock_glasses.py`, since they share ports. Real distance and blinks go out in
`sens`, and rear alerts go out as `fire`. Set `app_bridge.phone_ip` (`127.0.0.1` for
the iOS simulator, `172.20.10.1` for a real iPhone on its own hotspot).

## Run pieces on their own

```bash
python -m backend.streams --config            # show every configured camera (--dev for stand-ins)
python -m backend.eye_tracking                 # EYE camera: blink/squint/pupil window (--dev: webcam)
python -m backend.distance                     # FRONT camera: distance, [k] calibrates at 50 cm (--dev: webcam)
python -m backend.rear_alert                   # rear.mode software: LGMD + speech on the synthetic clip
python -m backend.facetime status              # OBS scene (docs/facetime.md)
python -m unittest discover -s backend/tests -t .
```

## Files

| File | What |
|---|---|
| `config.yaml` | Camera sources, thresholds, ports. The only file that changes for hardware |
| `streams.py` | Threaded latest-frame readers, reconnect, fallback, shared per source |
| `face.py` | MediaPipe Face Landmarker wrapper (Tasks API, model auto-download) |
| `eye_tracking.py` | Extractors (Face Mesh EAR / close-up pupil) + blink/squint detector |
| `distance.py` | Face-width or screen-width distance, calibration, too-close flag |
| `rear_alert.py` | `lgmd.lgmd_step` per frame → `say` with cooldown, optional YOLO label |
| `db.py` | SQLite: 1 Hz samples, events, app usage; history buckets |
| `recommendations.py` | Rules: low blink rate, too close, 20-20-20, frequent squinting |
| `screentime.py` | Mac frontmost-app tracker (real), iOS sample data (mock), correlation |
| `facetime.py` | OBS scene switch for FaceTime |
| `app_bridge.py` | UDP protocol for `mobile-app/` + MJPEG on :81 |
| `api.py` | FastAPI routes + WebSocket `/ws/live` |
| `main.py` | Runs everything |
| `static/index.html` | Dashboard (no build step, no CDN) |
| `seed_demo.py` | Fake history for demos |

## API

| Method | Path | |
|---|---|---|
| GET | `/stats/live` | Blink rate, squint, openness, pupil, distance, too-close, session minutes, rear LGMD |
| GET | `/stats/history?range=hour\|day\|week` | Bucketed averages + blink counts |
| GET | `/stats/summary?range=` | Totals: minutes tracked/too close/squinting, blinks, alerts, breaks |
| GET | `/alerts` | Rear alerts, newest first |
| GET | `/events?kind=blink&kind=alert` | Any stored events |
| GET | `/recommendations` | `[{id, level: urgent\|suggest\|info, title, text}]` |
| GET | `/cameras` | Per-camera status (active source, fps, fallback) |
| GET | `/stream/{eye\|front\|rear}` | Annotated MJPEG |
| POST | `/calibrate/eye` | New open-eye baseline over the next 5 s with a face in view |
| POST | `/calibrate/distance` | `{"known_cm": 50}` |
| POST | `/distance/device` | `{"device": "laptop"\|"phone"}` (threshold 50 / 30 cm) |
| GET | `/screentime`, `/screentime/correlation` | Mac usage (real), iOS (mock), blink rate per app |
| GET/POST | `/facetime`, `/facetime/switch` | `{"target": "glasses"\|"mac"\|"toggle"}` |
| WS | `/ws/live` | `{"type":"live",...}` every 0.5 s, `{"type":"event",...}` as they happen |

CORS is open (`*`) so the Flutter app can call it from a phone.

## Known limits

- The close-up eye method (the product's) has only been tested on synthetic eye
  images; tune it on the first real eye-camera footage. The dev face-mesh method was
  checked on a webcam and a still portrait.
- Screen-width distance assumes a 30 cm laptop screen / 7 cm phone; calibrate once at a
  known distance. (The dev face-width method assumes a 14 cm face.)
- The LGMD defaults are untuned on real footage (see the root README).
- Blink rate ignores blinks that last longer than 0.5 s, and frame-based timing gets
  coarser at ESP32 frame rates (~10-15 fps).
