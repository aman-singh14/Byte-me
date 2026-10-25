// esp_camera3: the BACK camera (AI-Thinker ESP32-CAM, OV2640, facing backward) + Tang Nano 20K FPGA.
// Copied from fpga/FPGA/esp32cam_rear/esp32cam_rear.ino. Changed: this header comment, and UDP_PORT 4300 -> 8103.
// The FPGA side is in fpga/ next to this file (omni_rear.v, omni_rear.cst, tuned_params.json) and the laptop
// viewer in tools/rear_udp_viewer.py. The other cameras' sketches are in ../esp_camera_eye/ and ../esp_camera2_front/.
//
//   camera (640x480 B&W JPEG) --decode 1/8--> 80x60 grayscale --SPI--> Tang Nano 20K (fpga/omni_rear.v)
//   FPGA status (SPI) --> tracking?   -> stream the JPEG frames over UDP 8103
//                     --> COLLISION?  -> Grove buzzer beeps (held HORN_HOLD_MS)
//   The FPGA ignores everything while the head turns > 90 deg/s (MPU6050 gyro on the FPGA).
//
// Board: "AI Thinker ESP32-CAM" (esp32 core 3.x, PSRAM enabled). Partition scheme: Huge APP.
//
// Wiring (all grounds together):
//   ESP32-CAM GPIO14 -> FPGA pin 73 (SPI SCK)      ESP32-CAM GPIO13 -> FPGA pin 53 (SPI MOSI)
//   ESP32-CAM GPIO15 -> FPGA pin 72 (SPI CS)       ESP32-CAM GPIO2  <- FPGA pin 71 (SPI MISO)
//   ESP32-CAM GPIO12 -> Grove Buzzer v1.2 SIG   (buzzer VCC -> 5V, GND -> GND, NC unconnected)
//   MPU6050 SCL -> FPGA pin 30, SDA -> FPGA pin 31 (3.3 V, GND)
//   Do not use the SD card. Unplug the GPIO2 wire while flashing the ESP32-CAM.
//
// Wi-Fi: joins "espholder" as a normal client (no access point). The name and password are in the
// settings below (this sketch does not use secrets.h).
// UDP 8103: status JSON is broadcast to everyone on that Wi-Fi. Video goes to every viewer that has
// sent any packet to this ESP on port 8103 in the last 10 s (tools/rear_udp_viewer.py does that
// automatically, up to MAX_VIEWERS); with no viewers it is broadcast instead.
//   video  : 16-byte header "OMNV" frame_id(u32) chunk(u16) chunks(u16) jpeg_len(u32), then <=1400 JPEG bytes
//   status : JSON text, ~5 per second and on every change, e.g.
//            {"t":"rear","seq":12,"tracking":1,"collision":0,"turning":0,"imu":1,"fpga":1,...}
//   event  : {"t":"collision","seq":12} when a collision starts

#include <Arduino.h>
#include "esp_camera.h"
#include "jpeg_decoder.h"
#include <WiFi.h>
#include <WiFiUdp.h>
#include <SPI.h>
#include "esp_timer.h"
#include "driver/gpio.h"

// ---------------- settings
const char *WIFI_SSID = "espholder";
const char *WIFI_PASS = "12345678";
const uint16_t UDP_PORT = 8103;   // back camera stream + status (was 4300: the backend listens there for rear events)

#define STREAM_FRAMESIZE FRAMESIZE_VGA   // 640x480 -> 80x60 exactly at 1/8 decode. FRAMESIZE_SVGA also works (resized)
#define JPEG_QUALITY     12              // 10 = better picture, 20 = smaller/faster
#define LOCK_EXPOSURE    1               // lock exposure/gain after warm-up (stops light flicker false alarms)
#define HORN_HOLD_MS     1000            // siren keeps sounding this long after the last collision frame
#define BUZZER_HZ        2300            // Grove buzzer resonance; driven as a tone so active and passive both sound
#define BEEP_ON_MS       120             // alarm pattern: beep ...
#define BEEP_OFF_MS      80              // ... pause
#define MAX_VIEWERS      6               // video unicast to up to this many viewers
#define VIEWER_TIMEOUT_MS 10000          // a viewer must say hello at least this often
#define STREAM_HOLD_MS   2000            // keep streaming this long after tracking stops
#define STREAM_ALWAYS    0               // 1 = stream even when nothing is tracked (testing)
#define SPI_FRAME_HZ     4000000         // frame transfer (FPGA samples SPI with its 27 MHz clock)
#define SPI_STATUS_HZ    1000000         // status read (slower so MISO is always settled)

#define PIN_SPI_SCK   14
#define PIN_SPI_MOSI  13
#define PIN_SPI_MISO   2
#define PIN_SPI_CS    15
#define PIN_BUZZER    12              // Grove Buzzer SIG

// AI Thinker ESP32-CAM camera pins
#define PWDN_GPIO_NUM   32
#define RESET_GPIO_NUM  -1
#define XCLK_GPIO_NUM    0
#define SIOD_GPIO_NUM   26
#define SIOC_GPIO_NUM   27
#define Y9_GPIO_NUM     35
#define Y8_GPIO_NUM     34
#define Y7_GPIO_NUM     39
#define Y6_GPIO_NUM     36
#define Y5_GPIO_NUM     21
#define Y4_GPIO_NUM     19
#define Y3_GPIO_NUM     18
#define Y2_GPIO_NUM      5
#define VSYNC_GPIO_NUM  25
#define HREF_GPIO_NUM   23
#define PCLK_GPIO_NUM   22

// ---------------- FPGA protocol (must match omni_rear.v)
static const int FW = 80, FH = 60, NPIX = FW * FH;
static const uint8_t CMD_FRAME = 0xA1, CMD_STATUS = 0xB2, STATUS_MAGIC = 0x5A;
static const int FRAME_BYTES = 1 + 2 + NPIX + 2;

struct FpgaStatus {
  bool valid = false;
  bool tracking = false, collision = false, turning = false, imu = false, crc_ok = false, growing = false, box = false;
  uint16_t seq = 0, rate = 0, es = 0, e = 0;
  uint32_t k = 0;
  uint8_t in_row = 0, bad = 0;
};

SPIClass fpgaSpi(HSPI);
WiFiUDP udp;
struct Viewer { IPAddress ip; uint32_t last; };
static Viewer viewers[MAX_VIEWERS];
static int nViewers = 0;

static uint8_t small80[NPIX];
static uint8_t *dec = nullptr;        // decoded 1/8 image (gray), sized for the frame
static int decW = 0, decH = 0;
static uint8_t spiBuf[FRAME_BYTES];
static uint16_t frameSeq = 0;
static uint32_t videoId = 0;

static uint32_t hornUntil = 0, streamUntil = 0, lastStatusSent = 0, lockAt = 0;
static bool exposureLocked = false;
static FpgaStatus st, lastSent;
static float fps = 0;

// ---------------- buzzer tone: esp_timer toggles the pin (LEDC is left alone: the camera clock uses it)
static esp_timer_handle_t toneTimer = nullptr;
static volatile bool toneLevel = false;
static uint32_t toneHz = 0;

static void toneToggle(void *) {
  toneLevel = !toneLevel;
  gpio_set_level((gpio_num_t)PIN_BUZZER, toneLevel);
}

static void setTone(uint32_t hz) {
  if (hz == toneHz || !toneTimer) return;
  esp_timer_stop(toneTimer);                      // harmless if it was not running
  toneHz = hz;
  if (hz) {
    esp_timer_start_periodic(toneTimer, 500000 / hz);   // toggle twice per period
  } else {
    toneLevel = false;
    gpio_set_level((gpio_num_t)PIN_BUZZER, 0);
  }
}

// ---------------- CRC-16/CCITT-FALSE (same as the FPGA)
static uint16_t crc16(const uint8_t *d, size_t n, uint16_t crc = 0xFFFF) {
  while (n--) {
    crc ^= (uint16_t)(*d++) << 8;
    for (int i = 0; i < 8; i++) crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : (crc << 1);
  }
  return crc;
}

// ---------------- JPEG -> 1/8 scale grayscale (esp_jpeg decoder in the ESP32 core)
static uint8_t *rgb = nullptr;        // 1/8-scale RGB888 decode output
static size_t rgbSize = 0;

static bool jpegTo80x60(camera_fb_t *fb) {
  int w = (fb->width + 7) / 8, h = (fb->height + 7) / 8;
  size_t need = (size_t)w * h * 3;
  if (need > rgbSize || !dec || w != decW || h != decH) {
    free(rgb); free(dec);
    rgb = (uint8_t *)malloc(need);
    dec = (uint8_t *)malloc((size_t)w * h);
    if (!rgb || !dec) { rgbSize = 0; return false; }
    rgbSize = need; decW = w; decH = h;
  }
  esp_jpeg_image_cfg_t cfg = {};
  cfg.indata = fb->buf;
  cfg.indata_size = fb->len;
  cfg.outbuf = rgb;
  cfg.outbuf_size = rgbSize;
  cfg.out_format = JPEG_IMAGE_FORMAT_RGB888;
  cfg.out_scale = JPEG_IMAGE_SCALE_1_8;           // each output pixel = average of an 8x8 block
  esp_jpeg_image_output_t out = {};
  if (esp_jpeg_decode(&cfg, &out) != ESP_OK) return false;
  int ow = min((int)out.width, decW), oh = min((int)out.height, decH);
  for (int i = 0; i < ow * oh; i++) {
    const uint8_t *p = rgb + i * 3;               // B&W camera: the three channels are equal
    dec[i] = (uint8_t)((77 * p[0] + 150 * p[1] + 29 * p[2]) >> 8);
  }
  if (ow == FW && oh == FH) {                     // VGA: already exactly 80x60
    memcpy(small80, dec, NPIX);
    return true;
  }
  for (int oy = 0; oy < FH; oy++) {               // other sizes: box-average down to 80x60
    int y0 = oy * oh / FH, y1 = max(y0 + 1, (oy + 1) * oh / FH);
    for (int ox = 0; ox < FW; ox++) {
      int x0 = ox * ow / FW, x1 = max(x0 + 1, (ox + 1) * ow / FW);
      uint32_t sum = 0, n = 0;
      for (int yy = y0; yy < y1; yy++)
        for (int xx = x0; xx < x1; xx++) { sum += dec[yy * ow + xx]; n++; }
      small80[oy * FW + ox] = sum / n;
    }
  }
  return true;
}

// ---------------- SPI to the FPGA
static void sendFrameToFpga() {
  frameSeq++;
  spiBuf[0] = CMD_FRAME;
  spiBuf[1] = frameSeq & 0xFF;
  spiBuf[2] = frameSeq >> 8;
  memcpy(spiBuf + 3, small80, NPIX);
  uint16_t crc = crc16(spiBuf + 1, 2 + NPIX);
  spiBuf[3 + NPIX] = crc & 0xFF;
  spiBuf[4 + NPIX] = crc >> 8;
  fpgaSpi.beginTransaction(SPISettings(SPI_FRAME_HZ, MSBFIRST, SPI_MODE0));
  digitalWrite(PIN_SPI_CS, LOW);
  fpgaSpi.writeBytes(spiBuf, FRAME_BYTES);
  digitalWrite(PIN_SPI_CS, HIGH);
  fpgaSpi.endTransaction();
}

static bool readFpgaStatus(FpgaStatus &s) {
  uint8_t tx[16] = {CMD_STATUS}, rx[16];
  fpgaSpi.beginTransaction(SPISettings(SPI_STATUS_HZ, MSBFIRST, SPI_MODE0));
  digitalWrite(PIN_SPI_CS, LOW);
  delayMicroseconds(2);
  fpgaSpi.transferBytes(tx, rx, 16);
  digitalWrite(PIN_SPI_CS, HIGH);
  fpgaSpi.endTransaction();
  uint8_t x = 0;
  for (int i = 0; i < 15; i++) x ^= rx[i];
  if (rx[0] != STATUS_MAGIC || x != rx[15]) return false;
  uint8_t f = rx[1];
  s.tracking = f & 1; s.collision = f & 2; s.turning = f & 4; s.imu = f & 8;
  s.crc_ok = f & 16; s.growing = f & 32; s.box = f & 64;
  s.seq = rx[2] | (rx[3] << 8);
  s.rate = rx[4] | (rx[5] << 8);
  s.es = rx[6] | (rx[7] << 8);
  s.e = rx[8] | (rx[9] << 8);
  s.k = rx[10] | (rx[11] << 8) | ((uint32_t)rx[12] << 16);
  s.in_row = rx[13];
  s.bad = rx[14];
  s.valid = true;
  return true;
}

// ---------------- UDP
static void sendJson(const char *json) {             // status: everyone on the Wi-Fi
  udp.beginPacket(WiFi.broadcastIP(), UDP_PORT);
  udp.write((const uint8_t *)json, strlen(json));
  udp.endPacket();
}

static void sendStatusJson() {
  char js[300];
  snprintf(js, sizeof(js),
           "{\"t\":\"rear\",\"seq\":%u,\"tracking\":%d,\"collision\":%d,\"turning\":%d,\"imu\":%d,"
           "\"fpga\":%d,\"yaw_dps\":%.1f,\"size\":%u,\"size_smoothed\":%u,\"k\":%lu,\"in_row\":%u,"
           "\"bad_frames\":%u,\"streaming\":%d,\"horn\":%d,\"fps\":%.1f}",
           st.seq, st.tracking, st.collision, st.turning, st.imu, st.valid, st.rate / 65.5f, st.e, st.es,
           (unsigned long)st.k, st.in_row, st.bad, (int)(millis() < streamUntil || STREAM_ALWAYS),
           (int)(millis() < hornUntil), fps);
  sendJson(js);
  lastSent = st;
  lastStatusSent = millis();
}

static void sendJpeg(camera_fb_t *fb) {
  const size_t CH = 1400;
  uint16_t chunks = (fb->len + CH - 1) / CH;
  uint8_t hdr[16] = {'O', 'M', 'N', 'V'};
  videoId++;
  memcpy(hdr + 4, &videoId, 4);
  memcpy(hdr + 10, &chunks, 2);
  uint32_t len = fb->len;
  memcpy(hdr + 12, &len, 4);
  uint32_t now = millis();
  int k = 0;                                        // drop viewers that stopped saying hello
  for (int i = 0; i < nViewers; i++)
    if (now - viewers[i].last < VIEWER_TIMEOUT_MS) viewers[k++] = viewers[i];
  nViewers = k;
  int targets = nViewers ? nViewers : 1;
  for (int v = 0; v < targets; v++) {
    IPAddress to = nViewers ? viewers[v].ip : WiFi.broadcastIP();
    for (uint16_t c = 0; c < chunks; c++) {
      memcpy(hdr + 8, &c, 2);
      size_t off = (size_t)c * CH, n = min(CH, fb->len - off);
      udp.beginPacket(to, UDP_PORT);
      udp.write(hdr, 16);
      udp.write(fb->buf + off, n);
      udp.endPacket();
    }
  }
}

static void pollUdp() {
  int n = udp.parsePacket();
  while (n > 0) {
    IPAddress ip = udp.remoteIP();                // any packet = "I want the video"
    if (ip != WiFi.localIP()) {
      int i = 0;
      while (i < nViewers && viewers[i].ip != ip) i++;
      if (i < nViewers) viewers[i].last = millis();
      else if (nViewers < MAX_VIEWERS) viewers[nViewers++] = {ip, millis()};
    }
    while (udp.available()) udp.read();
    n = udp.parsePacket();
  }
}

// ---------------- setup
static bool initCamera() {
  camera_config_t config = {};
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;  config.pin_d1 = Y3_GPIO_NUM;  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;  config.pin_d4 = Y6_GPIO_NUM;  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM; config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM; config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;   config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.jpeg_quality = JPEG_QUALITY;
  config.frame_size = psramFound() ? STREAM_FRAMESIZE : FRAMESIZE_QVGA;
  config.fb_count = psramFound() ? 2 : 1;
  config.fb_location = psramFound() ? CAMERA_FB_IN_PSRAM : CAMERA_FB_IN_DRAM;
  config.grab_mode = CAMERA_GRAB_LATEST;          // always the newest frame, no backlog
  if (esp_camera_init(&config) != ESP_OK) return false;
  sensor_t *s = esp_camera_sensor_get();
  s->set_special_effect(s, 2);                    // grayscale (smaller JPEGs, B&W stream)
  return true;
}

static void connectWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);                           // low latency
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.printf("Connecting to Wi-Fi \"%s\"", WIFI_SSID);
  for (int i = 0; i < 60 && WiFi.status() != WL_CONNECTED; i++) { delay(250); Serial.print("."); }
  Serial.println();
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("Wi-Fi ok, ESP32-CAM IP %s, sending UDP %u to %s\n", WiFi.localIP().toString().c_str(),
                  UDP_PORT, WiFi.broadcastIP().toString().c_str());
    udp.begin(UDP_PORT);
  } else {
    Serial.println("Wi-Fi not connected yet (keeps trying in the background)");
  }
}

void setup() {
  pinMode(PIN_BUZZER, OUTPUT);
  digitalWrite(PIN_BUZZER, LOW);
  esp_timer_create_args_t targs = {};
  targs.callback = toneToggle;
  targs.name = "siren";
  esp_timer_create(&targs, &toneTimer);
  pinMode(PIN_SPI_CS, OUTPUT);
  digitalWrite(PIN_SPI_CS, HIGH);
  Serial.begin(115200);
  delay(200);
  Serial.println("\nOmni Glasses rear camera");
  if (!initCamera()) {
    Serial.println("Camera init failed - check the ribbon cable and PSRAM setting");
    while (true) delay(1000);
  }
  fpgaSpi.begin(PIN_SPI_SCK, PIN_SPI_MISO, PIN_SPI_MOSI, -1);
  connectWifi();
  lockAt = millis() + 2000;
}

// ---------------- main loop
void loop() {
  static uint32_t lastFrameMs = 0, lastWifiTry = 0;
  static bool prevCollision = false;
  uint32_t now = millis();

  if (WiFi.status() != WL_CONNECTED && now - lastWifiTry > 5000) {
    lastWifiTry = now;
    WiFi.reconnect();
  } else if (WiFi.status() == WL_CONNECTED) {
    static bool udpStarted = false;
    if (!udpStarted) { udp.begin(UDP_PORT); udpStarted = true; }
    pollUdp();
  }

  if (LOCK_EXPOSURE && !exposureLocked && now > lockAt) {
    sensor_t *s = esp_camera_sensor_get();
    s->set_exposure_ctrl(s, 0);
    s->set_gain_ctrl(s, 0);
    s->set_whitebal(s, 0);
    exposureLocked = true;
    Serial.println("exposure locked");
  }

  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb) { delay(5); return; }

  bool ok = jpegTo80x60(fb);
  if (ok) {
    sendFrameToFpga();
    delayMicroseconds(400);                       // FPGA needs ~0.2 ms to process a frame
    FpgaStatus s;
    bool got = readFpgaStatus(s);
    if (got && s.seq != frameSeq) {               // not finished yet: ask once more
      delayMicroseconds(400);
      got = readFpgaStatus(s);
    }
    if (got) st = s; else st.valid = false;
  }

  now = millis();
  if (st.valid && st.collision) hornUntil = now + HORN_HOLD_MS;
  if (st.valid && st.tracking) streamUntil = now + STREAM_HOLD_MS;
  setTone(now < hornUntil && (now % (BEEP_ON_MS + BEEP_OFF_MS)) < BEEP_ON_MS ? BUZZER_HZ : 0);

  bool collisionNow = st.valid && st.collision;
  if (WiFi.status() == WL_CONNECTED) {
    if (collisionNow && !prevCollision) {
      char js[64];
      snprintf(js, sizeof(js), "{\"t\":\"collision\",\"seq\":%u}", st.seq);
      sendJson(js);
    }
    if (STREAM_ALWAYS || now < streamUntil) sendJpeg(fb);
    bool changed = st.tracking != lastSent.tracking || st.collision != lastSent.collision ||
                   st.turning != lastSent.turning || st.valid != lastSent.valid;
    if (changed || now - lastStatusSent > 200) sendStatusJson();
  }
  prevCollision = collisionNow;
  esp_camera_fb_return(fb);

  uint32_t dt = now - lastFrameMs;
  lastFrameMs = now;
  if (dt > 0) fps = 0.9f * fps + 0.1f * (1000.0f / dt);
  static uint32_t lastPrint = 0;
  if (now - lastPrint > 1000) {
    lastPrint = now;
    Serial.printf("%.1f fps  fpga %s  tracking %d  collision %d  turning %d  imu %d  size %u  wifi %s\n",
                  fps, st.valid ? "ok" : "NO REPLY", st.tracking, st.collision, st.turning, st.imu, st.e,
                  WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString().c_str() : "down");
  }
}
