# ESP32-CAM firmware (eye / front)

One sketch for the EYE and FRONT AI-Thinker ESP32-CAM boards. It only streams video
(no processing on the board). Each one serves:

| URL | What |
|---|---|
| `http://<name>-cam.local:81/stream` | MJPEG, what the backend reads |
| `http://<name>-cam.local/capture` | one JPEG |
| `http://<name>-cam.local/status` | JSON: IP, RSSI, uptime, frames sent, free heap |

`<name>` is `DEVICE_NAME` in `esp32cam.ino`: `eye` or `front`. (`rear` also works if
you ever stream a rear ESP32-CAM for `rear.mode: software`; the product's rear camera
is on the FPGA.)

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

1. Set `DEVICE_NAME` (`front`, `eye` or `rear`) at the top of `esp32cam.ino`.
2. Connect **GPIO0 to GND**, plug in the FTDI, then press the board's **RST** button
   (on the underside, next to the ribbon cable).
3. Upload. When it prints `Connecting....`, press RST again if it doesn't catch.
4. **Remove the GPIO0–GND wire** and press RST. The firmware only runs with GPIO0 floating.
5. Open the Serial Monitor at 115200 baud. You should see the IP and
   `mDNS: http://front-cam.local:81/stream`.

The red LED on the back blinks while it connects to Wi-Fi and stays on once connected.

## Pointing the backend at it

Edit `backend/config.yaml`. Nothing else changes:

```yaml
cameras:
  eye:   {source: "http://eye-cam.local:81/stream"}
  front: {source: "http://front-cam.local:81/stream"}
```

These are already the defaults. The ESP32s only stream; all processing happens in the
backend. The rear camera is not an ESP32-CAM stream: it is the OV2640 on the FPGA,
which sends events (`docs/rear_event_protocol.md`).

If `.local` names don't resolve on the hotspot (mDNS is sometimes flaky on iPhone
hotspots), use the IP from the Serial Monitor. Check a stream in a browser first:
`http://<ip>:81/stream`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `camera init failed: 0x105` | Ribbon cable not seated: lift the black latch, reseat, close |
| `Brownout detector was triggered` | Power from 5 V, not 3.3 V; use a short, thick cable from the power bank |
| Never joins Wi-Fi | 2.4 GHz only. On iPhone, turn on Maximize Compatibility and keep the Hotspot screen open while it joins |
| Stream lags 1 s+ | Use `FRAMESIZE_QVGA` and `JPEG_QUALITY 20`; only one client per stream at a time |
| Upload fails: `Failed to connect` | GPIO0 not grounded, or TX/RX swapped |
| Image upside down in the mount | `FLIP_VERTICAL 1` (and/or `MIRROR 1`) |

`FRAMESIZE_VGA` (640x480) is a good default for both. Drop to `FRAMESIZE_QVGA` if the
hotspot struggles.
