# FaceTime: switch between the Mac webcam and the glasses' view

FaceTime on a Mac can use any camera macOS knows about, and OBS Studio can publish a
virtual one. OBS shows either the Mac webcam or the glasses' front-camera stream,
and the backend flips between the two over obs-websocket.

```
glasses front cam --MJPEG--> OBS "Glasses POV" scene --+
Mac webcam ----------------> OBS "Mac Webcam" scene ---+--> OBS Virtual Camera --> FaceTime
                                    ^
              POST /facetime/switch (dashboard buttons, or python -m backend.facetime)
```

## Setup (once, about 10 minutes)

1. Install OBS Studio 30+ (`brew install --cask obs`) and open it. Allow camera access.
2. **Scene "Mac Webcam":** Scenes `+` → name it exactly `Mac Webcam`. Sources `+` →
   *Video Capture Device* → pick the FaceTime HD camera.
3. **Scene "Glasses POV":** Scenes `+` → `Glasses POV`. Sources `+` → *Media Source*:
   - uncheck *Local File*
   - Input: `http://front-cam.local:81/stream` (or the ESP32's IP; before the hardware
     arrives, `http://localhost:81/stream` from `mock_glasses.py` or the backend's bridge)
   - Input Format: `mjpeg`
   - check *Restart playback when source becomes active*
   - set *Network Buffering* to 0 MB for the lowest latency
   - Right-click the source → Transform → *Fit to screen*.
4. **WebSocket:** Tools → WebSocket Server Settings → *Enable WebSocket server*,
   port 4455. Either untick *Enable Authentication*, or put the password in
   `backend/config.yaml` under `obs.password`.
5. **Virtual camera:** click *Start Virtual Camera* (bottom right). The first time,
   macOS asks you to allow the system extension (System Settings → General → Login
   Items & Extensions → Camera Extensions → OBS).
6. In FaceTime: menu bar *Video* → **OBS Virtual Camera**.

## Switching

- Dashboard: *Glasses view* / *Mac webcam* buttons (Controls card).
- API: `curl -X POST localhost:8000/facetime/switch -H 'content-type: application/json' -d '{"target":"glasses"}'`
  (`"mac"` or `"toggle"` also work; `GET /facetime` shows the current scene).
- Command line: `python -m backend.facetime glasses | mac | toggle | status`.

Scene names are configurable (`obs.scene_mac`, `obs.scene_glasses`).

## Limits

- **iPhone FaceTime cannot use a virtual camera.** iOS only lets FaceTime use the
  phone's own cameras. On the phone the only way to show the glasses' view is
  screen sharing (SharePlay → Share My Screen) with the dashboard's camera preview open.
- The ESP32 stream is about 10-20 fps with 100-300 ms of latency, so audio leads the
  glasses' video slightly. In OBS, *Advanced Audio Properties* → Sync Offset on the
  mic (about +200 ms) evens it out.
- OBS must be running with the virtual camera started. If it is closed, FaceTime
  shows a black "OBS Virtual Camera" image, and `/facetime/switch` returns 503
  with the reason.
