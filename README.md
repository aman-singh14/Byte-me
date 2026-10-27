# OmniGlasses

**A smartwatch for your eyes.** OmniGlasses are camera glasses that look forward, look behind you, and look at your eye, so they can tell you what you're looking at, warn you when something is coming up from behind, and keep track of how your eyes are holding up after a long day of screens.

We built this at HackTX 2026 for the Meta track, using Meta's Muse models for vision and live captions.

[Devpost](https://devpost.com/software/omniglasses-bi8as1)

---

## Why we built it

Most of us spend the whole day staring at a laptop or a phone. We blink less, we squint more, and we stop noticing what's going on around us. We wanted glasses that quietly look out for you: your eyes, your surroundings, and the people you spend time with.

## What it does

**Eye health.** A tiny camera sits about 3 cm from one eye. It tracks your blinks, squints and where you're looking. In our testing the open / squint / closed classifier was about 98% accurate. Your blink rate, squint time and "heads-up" time (time not staring at a screen) show up as daily rings in the app, next to an "outside" ring that uses the front camera's brightness and exposure to tell when you're outdoors.

**Screen strain.** The front camera notices when you're close to a phone, laptop, TV, keyboard or book, estimates how far away it is, and logs how long you've been at it. It picked out strain-causing devices about 99% of the time in our tests.

**Look and Ask.** Ask "what am I looking at?" and the glasses use your gaze to crop the part of the front camera you're actually looking at. A local YOLO model gives a quick spoken answer right away, and then Meta Muse Spark gives a fuller description a moment later.

**Rear collision alerts.** A rear camera connected to an FPGA runs a locust-inspired "looming" detector (LGMD) right on the hardware, so there's no cloud delay. When something big is closing in fast, like a bike or a car, you hear a warning, and the clip is then sent to Muse to say what it was. A gyroscope filters out false alarms from turning your head. It caught about 95% of approaching objects in our test clips.

**Live captions and Shared POV.** On a video call you can switch to the glasses' front camera so someone can see what you see, with live captions from Meta Muse Voice Transcribe.

**Together.** Friends and teams compete on leaderboards for healthier blink rates, less squinting and more time looking up from screens.

## How it works

```
 EYE cam (ESP32-CAM) ──UDP──┐
                            ├──> Python backend (FastAPI, laptop) ──> Flutter app (iOS / Android)
 FRONT cam (ESP32-CAM) ─UDP─┘        │   eye tracking, gaze, near-work,      alerts, rings, captions,
                                     │   rings, SQLite, Muse calls            Together, helper calls
 REAR cam ──> Tang Nano 20K FPGA ────┘
              (LGMD collision detector,
               sends an EVENT the moment it fires)

 Cloud (Fly.io): Together server, helper call relay, captions relay, Muse image questions
```

The cameras and the phone all join the phone's personal hotspot. The Flutter app can do the eye tracking, near-work detection and rings on the phone itself, so the glasses work without a laptop. The Python backend is where we built and tested everything first, and it still runs the web dashboard.

- **Hardware.** Three AI-Thinker ESP32-CAM boards in a 3D-printed frame. The STL files and the wiring diagram are in `hardware/`.
- **Firmware** (`firmware/`). The ESP32s only send pictures. Frames are split into small UDP chunks with our own header, so a lost packet costs one frame instead of freezing the stream.
- **FPGA** (`fpga/`). The rear collision detector, written in Verilog. It uses integer-only math so the Python reference (`lgmd.py`), the C port and the FPGA all give the exact same answer on the same frames.
- **Backend** (`backend/`). Python + FastAPI + OpenCV. It does the pupil tracking, blink and squint classification, gaze calibration, distance to screens, the rear alert path and all the Muse calls. Muse calls have a hard budget cap and rate limit, and they only happen when you ask or when the rear camera fires, never on every frame.
- **App** (`mobile-app/`). Flutter, with on-device YOLO for naming rear hazards, the alert engine, captions and the Together tab.
- **Helper web page** (`helper-web/`). React + Vite. A friend can join a call from a link, see your camera and guide you with haptic buzzes.

## Run it

You'll need Python 3.11+, and Flutter if you want the app.

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Put your Meta Model API key in a `.env` file at the repo root (it's gitignored):

```
MUSE_API_KEY=your-key-here
```

**No glasses? Use dev mode.** Your laptop webcam stands in for the eye and front cameras, and a fake looming square stands in for the rear camera:

```bash
.venv/bin/python -m backend.main --dev --preview
```

**With the glasses.** Put all three cameras and the laptop on the same Wi-Fi (see `firmware/README.md`), then:

```bash
.venv/bin/python -m backend.main
```

The dashboard is at http://localhost:8001 and the API docs are at http://localhost:8001/docs. The first 5 seconds with your eye in view are calibration, so keep your eye open and look straight ahead.

**The app:**

```bash
cd mobile-app && flutter run
```

More detail lives in each folder's README: `backend/`, `mobile-app/`, `firmware/`, `social/` and `cloud/`.

## Privacy

Camera frames and audio are only passed through, never saved. Muse is told never to identify people or guess anything personal about them. The Together server only stores a display name and daily ring scores.

## What was hard

- Streaming video from several ESP32s over UDP without losing a ton of frames.
- Getting the ESP32 and the FPGA to talk with our own binary protocol.
- Calibrating gaze for different lighting and different eyes.
- None of us had used an FPGA before this weekend.

## What's next

More features that use the cameras, and getting the glasses on more people so we can collect real-world data and keep improving the models.

## Team

- **Saatvik Kesarwani**: computer vision and the eye-health side (eye tracking, gaze, Look and Ask, camera streaming, the Eyes and Rings pages)
- **Aman Singh**: app and backend
- **Dev Sinharoy**: FPGA collision detector
- **Dillon Mehta**: hardware, CAD and electronics
