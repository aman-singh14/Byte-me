# ESP32-CAM firmware (eye / front)

One sketch per AI-Thinker ESP32-CAM board. They only stream video (no processing on the board):

| Folder | Board | Role |
|---|---|---|
| `esp_camera_eye/` | esp_camera | EYE camera, facing the eye: 320x240 up to 25 fps |
| `esp_camera2_front/` | esp_camera2 | FRONT camera, facing forward: 320x240 capped at 5 fps |
| `esp_camera3_back/` | esp_camera3 | BACK camera + Tang Nano 20K FPGA collision detector (see the end of this file) |

The eye and front sketches are the same code except for the name and frame rate. Each one serves:

| URL | What |
|---|---|
| `http://<ip>:8101/stream` (eye) / `:8102/stream` (front) | MJPEG 320x240: EYE up to 25 fps, FRONT capped at 5 fps |
| `http://<ip>/capture?size=vga\|svga` | one 640x480 / 800x600 JPEG, on demand |
| `http://<ip>/sensor` | live exposure (`aec_lines`) and gain (`gain_reg`) for outdoor detection |
| `http://<ip>/status` | JSON: role, IP, RSSI, uptime, frames sent, free heap |
| UDP broadcast to port 4310, every 2 s | `{"t":"cam_hello","role":"eye","ip":...}`: the backend finds the camera by itself |

Wi-Fi is station mode only: all three cameras join the `espholder` network, password `12345678`
(no access point). The laptop must be on `espholder` too.

## Ports

Each camera's live stream has its own port, so they never clash with each other or with the laptop
(backend API 8000, rear events UDP 4300, camera hellos UDP 4310, OBS 4455, macOS AirPlay 5000/7000):

| Camera | Board | Live stream | Other |
|---|---|---|---|
| EYE | esp_camera (`esp_camera_eye/`) | `http://<ip>:8101/stream` (MJPEG) | `/capture`, `/sensor`, `/status` on port 80; hello to UDP 4310 |
| FRONT | esp_camera2 (`esp_camera2_front/`) | `http://<ip>:8102/stream` (MJPEG) | `/capture`, `/sensor`, `/status` on port 80; hello to UDP 4310 |
| BACK | esp_camera3 (`esp_camera3_back/`) | UDP 8103 (JPEG chunks + status JSON) | none |
Both sketches compile with arduino-cli and esp32 core 3.3.12 (`esp32:esp32:esp32cam`).

## One-time setup (Arduino IDE 2)

1. Settings > Additional boards manager URLs:
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`
2. Boards Manager: install **esp32 by Espressif Systems**.
3. Tools > Board: **AI Thinker ESP32-CAM**. Tools > Partition Scheme: **Huge APP**.
4. In each sketch folder: `cp secrets.example.h secrets.h` (Wi-Fi name and password).
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

1. Open `esp_camera_eye/esp_camera_eye.ino` for the eye board, or
   `esp_camera2_front/esp_camera2_front.ino` for the front board.
2. Connect **GPIO0 to GND**, plug in the FTDI, then press the board's **RST** button
   (on the underside, next to the ribbon cable).
3. Upload. When it prints `Connecting....`, press RST again if it doesn't catch.
4. **Remove the GPIO0–GND wire** and press RST. The firmware only runs with GPIO0 floating.
5. Open the Serial Monitor at 115200 baud. You should see the IP and
   `mDNS: http://front-cam.local:8102/stream`.

The red LED on the back blinks while it connects to Wi-Fi and stays on once connected.

From the command line instead (repo root, board in flash mode, `<port>` from `ls /dev/cu.*`):

    arduino-cli compile --fqbn esp32:esp32:esp32cam firmware/esp_camera_eye
    arduino-cli upload  --fqbn esp32:esp32:esp32cam -p <port> firmware/esp_camera_eye
    arduino-cli monitor -p <port> -c baudrate=115200

(`firmware/esp_camera2_front` for the front board.)

## Finding the cameras on the network

Laptop and both cameras join the same 2.4 GHz network (`espholder`). The backend finds each camera from its UDP
hello (`GET /discovery` shows what it heard), then tries `eye-cam.local` /
`front-cam.local`, then `static_ip` in `backend/config.yaml`. iPhone hotspots often don't
resolve `.local` names; if the hello doesn't arrive either, set `static_ip` to the IP the
Serial Monitor printed, or `BACKEND_HOST` in `secrets.h` so the hello is sent straight to
the laptop.

Quick check from the laptop: open `http://<ip>:8101/stream` (eye) or `:8102/stream` (front) and `http://<ip>/sensor` in a browser.

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

## Back camera (`esp_camera3_back/`)

A copy of the FPGA teammate's code from `fpga/FPGA/` (that folder stays as it is). Only the
sketch's header comment is new; the code, Verilog and constraints are byte-for-byte the same.

| File | Runs on | What |
|---|---|---|
| `esp_camera3_back.ino` | back ESP32-CAM | camera -> 80x60 grayscale -> SPI to the FPGA; reads the FPGA's status; buzzer on collision; JPEG video + status JSON over UDP 8103 |
| `fpga/omni_rear.v` | Tang Nano 20K | SPI slave, LGMD looming detector, box-growth collision decision, MPU6050 head-turn gate (> 90 deg/s = ignore) |
| `fpga/omni_rear.cst` | Tang Nano 20K | pin constraints (SPI 73/53/72/71, I2C 30/31, LEDs) |
| `fpga/tuned_params.json` | laptop | the detector settings the Verilog parameters were taken from (`fpga/FPGA/lgmd_tuner.py`) |
| `tools/rear_udp_viewer.py` | laptop | shows the back video and CLEAR / TRACKING / COLLISION / HEAD TURNING |

Wiring (all grounds together): ESP GPIO14 -> FPGA 73 (SCK), GPIO13 -> 53 (MOSI), GPIO15 -> 72 (CS),
GPIO2 <- 71 (MISO), GPIO12 -> Grove buzzer SIG; MPU6050 SCL -> FPGA 30, SDA -> 31.

1. **FPGA:** install Gowin EDA (Education edition is free) from gowinsemi.com. New project, device
   GW2AR-LV18QN88C8/I7 (Tang Nano 20K), add `fpga/omni_rear.v` and `fpga/omni_rear.cst`, top module
   `top`, run Synthesize then Place & Route, then Programmer -> the `.fs` bitstream to the board over USB-C
   (embedded flash, so it survives power-off). LED5 on = MPU6050 found; LED0 blinks = running.
2. **ESP32-CAM:** unplug the GPIO2 wire, flash as for the other boards:

        arduino-cli compile --fqbn esp32:esp32:esp32cam firmware/esp_camera3_back
        arduino-cli upload  --fqbn esp32:esp32:esp32cam -p <port> firmware/esp_camera3_back

   then plug GPIO2 back in and press RST. The serial monitor prints `fpga ok` once a second when
   the SPI link works (`fpga NO REPLY` = check the four SPI wires and the common ground).
3. **Watch it:** laptop on `espholder`, then `python firmware/esp_camera3_back/tools/rear_udp_viewer.py`
   (needs `opencv-python` and `numpy`). Video only flows while the FPGA is tracking something
   (`STREAM_ALWAYS 1` in the sketch streams all the time, for testing).

Note: the back camera speaks its own UDP 8103 format, not `docs/rear_event_protocol.md`, so the
backend's `backend/rear/` receiver does not pick it up yet; use the viewer above.
