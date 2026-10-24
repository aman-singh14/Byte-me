# Mega Glasses backend

Eye camera → blinks, squints, pupil. Front camera → distance to the screen. Rear
camera → LGMD (`../lgmd.py`, unchanged) → spoken warning. Everything is stored in
SQLite and served by FastAPI, with a web dashboard at `/` and Aman's app fed live
data over its own UDP protocol.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Python 3.11+. On macOS, give the terminal camera access (System Settings → Privacy &
Security → Camera). The first run downloads MediaPipe's face model (3.7 MB) to
`backend/models/`.

## Run the demo (webcam, no hardware)

From the repo root:

```bash
.venv/bin/python -m backend.main --preview
```

- Dashboard: <http://localhost:8000/> (on a phone on the same hotspot:
  `http://<laptop-ip>:8000/`). API docs: <http://localhost:8000/docs>.
- `--preview` opens annotated camera windows (`c` recalibrates the eyes, `q` quits).
- The first 5 s with your face in view are eye calibration: keep your eyes open and
  look at the screen. Then sit at a known distance (say 50 cm) and press
  *Calibrate distance…* in the dashboard.
- The rear camera defaults to `synthetic` (lgmd.py's looming square), so you hear
  "Object approaching from behind" every ~5 s. Set `cameras.rear.source: 0` to try it
  on the webcam (walk toward it fast), or pass `--speech print` for silence.

Useful overrides: `--eye 1 --front 0 --rear http://rear-cam.local:81/stream`,
`--port 8001`, `--phone 172.20.10.1`, `--speech print`.

Demo history for the pitch (fake data, kept in a separate file):

```bash
.venv/bin/python -m backend.seed_demo            # writes backend/data/demo.db
# then set db.path: backend/data/demo.db in config.yaml
```

## With Aman's app

The backend speaks `mobile-app/lib/net/protocol.dart` (it pretends to be the
"frame" device, like `mock_glasses.py`). Run **either** the backend **or**
`mock_glasses.py`, since they share ports. Real distance and blinks go out in
`sens`, and rear alerts go out as `fire`. The rear camera is served at `:81/stream`
for the app's rear view. Set `app_bridge.phone_ip` (`127.0.0.1` for the iOS simulator,
`172.20.10.1` for a real iPhone on its own hotspot).

## When the ESP32-CAMs arrive

Only `config.yaml` changes. See `../firmware/esp32cam/README.md`:

```yaml
cameras:
  front: {source: "http://front-cam.local:81/stream", fallback: 0}
  eye:   {source: "http://eye-cam.local:81/stream"}
  rear:  {source: "http://rear-cam.local:81/stream", fallback: synthetic}
eye:      {method: closeup}   # camera ~3 cm from one eye: dark-pupil ellipse fit
distance: {method: object}    # front camera sees the screen: bright-rectangle width
```

A dead stream switches to its `fallback` and the primary is retried every 3 s.

## Run pieces on their own

```bash
python -m backend.streams --config            # show every configured camera
python -m backend.eye_tracking                 # blink/squint/pupil window
python -m backend.distance                     # distance window, [k] calibrates at 50 cm
python -m backend.rear_alert --source 0        # LGMD + speech on the webcam
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

- Eye tracking was checked on a still portrait and synthetic signals, not yet on a
  real blinking face or the real eye camera. `CloseupEye` has only been tested on a
  synthetic eye drawing, so tune `dark_offset` on the first real footage.
- Face-width distance assumes a 14 cm face. Calibration fixes the scale for one person.
- The LGMD defaults are untuned on real footage (see the root README).
- Blink rate ignores blinks that last longer than 0.5 s, and frame-based timing gets
  coarser at ESP32 frame rates (~10-15 fps).
