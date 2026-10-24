# ESP32-CAM firmware (eye / front)

One sketch for the EYE and FRONT AI-Thinker ESP32-CAM boards. It only streams video
(no processing on the board). Each one serves:

| URL | What |
|---|---|
| `http://<ip>:81/stream` | MJPEG 320x240: EYE up to 25 fps, FRONT capped at 5 fps |
| `http://<ip>/capture?size=vga\|svga` | one 640x480 / 800x600 JPEG, on demand |
| `http://<ip>/sensor` | live exposure (`aec_lines`) and gain (`gain_reg`) for outdoor detection |
| `http://<ip>/status` | JSON: role, IP, RSSI, uptime, frames sent, free heap |
| UDP broadcast to port 4310, every 2 s | `{"t":"cam_hello","role":"eye","ip":...}`: the backend finds the camera by itself |

Set `DEVICE_ROLE` in `esp32cam.ino` to `ROLE_EYE` or `ROLE_FRONT`. Wi-Fi is station mode
only: every camera joins the phone hotspot (no access point).

> Not compiled yet: no Arduino toolchain on the machine where it was written. It
> sticks to the standard `esp32-camera` / `esp_http_server` API that the stock
> CameraWebServer example uses. Expect a small fix or two on the first compile.

## One-time setup (Arduino IDE 2)

1. Settings > Additional boards manager URLs:
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`
2. Boards Manager: install **esp32 by Espressif Systems**.
3. Tools > Board: **AI Thinker ESP32-CAM**. Tools > Partition Scheme: **Huge APP**.
4. `cp secrets.example.h secrets.h`, then put in the hotspot name and password.
   `secrets.h` is gitignored.

## Wiring the FTDI adapter (the board has no USB)

Set the FTDI jumper to **5V** (the ESP32-CAM browns out on 3.3 V while Wi-Fi is on).

| FTDI | ESP32-CAM |
|---|---|
| 5V (VCC) | 5V |
| GND | GND |
| TX | U0R (GPIO3) |
| RX | U0T (GPIO1) |
| — | **GPIO0 → GND** (jumper wire, flash mode only) |

TX goes to RX: the FTDI's transmit pin connects to the board's receive pin.

## Flashing each board

1. Set `DEVICE_ROLE` (`ROLE_EYE` or `ROLE_FRONT`) at the top of `esp32cam.ino`.
2. Connect **GPIO0 to GND**, plug in the FTDI, then press the board's **RST** button
   (on the underside, next to the ribbon cable).
3. Upload. When it prints `Connecting....`, press RST again if it doesn't catch.
4. **Remove the GPIO0–GND wire** and press RST. The firmware only runs with GPIO0 floating.
5. Open the Serial Monitor at 115200 baud. You should see the IP and
   `mDNS: http://front-cam.local:81/stream`.

The red LED on the back blinks while it connects to Wi-Fi and stays on once connected.

## Finding the cameras on the hotspot

Laptop, phone and both cameras join the same 2.4 GHz phone hotspot (iPhone: Maximize
Compatibility on; addresses are 172.20.10.x). The backend finds each camera from its UDP
hello (`GET /discovery` shows what it heard), then tries `eye-cam.local` /
`front-cam.local`, then `static_ip` in `backend/config.yaml`. iPhone hotspots often don't
resolve `.local` names; if the hello doesn't arrive either, set `static_ip` to the IP the
Serial Monitor printed, or `BACKEND_HOST` in `secrets.h` so the hello is sent straight to
the laptop.

Quick check from the laptop: open `http://<ip>:81/stream` and `http://<ip>/sensor` in a browser.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `camera init failed: 0x105` | Ribbon cable not seated: lift the black latch, reseat, close |
| `Brownout detector was triggered` | Power from 5 V, not 3.3 V; use a short, thick cable from the power bank |
| Never joins Wi-Fi | 2.4 GHz only. On iPhone, turn on Maximize Compatibility and keep the Hotspot screen open while it joins |
| Stream lags 1 s+ | Raise `JPEG_QUALITY` (e.g. 20) or lower `STREAM_MAX_FPS`; only one client per stream at a time |
| Upload fails: `Failed to connect` | GPIO0 not grounded, or TX/RX swapped |
| Image upside down in the mount | `FLIP_VERTICAL 1` (and/or `MIRROR 1`) |
| `/sensor` says "register read failed" | Older esp32-camera without `get_reg`: update the esp32 core |
