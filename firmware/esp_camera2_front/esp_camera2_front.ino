// esp_camera2: the FRONT camera (AI-Thinker ESP32-CAM, OV2640, facing forward).
// It only sends pictures; all processing happens in the backend on the laptop.
// The other cameras' sketches are in ../esp_camera_eye/ and ../esp_camera3_back/.
//
//   UDP 81 (live video)                  JPEG frames, 640x480 colour, up to 5 fps, sent only to
//                                        viewers that asked for them (see "UDP video" below); the backend uses this
//   http://<ip>:81/stream                the same video as MJPEG over HTTP, as in the team docs (one viewer at a time)
//   http://<ip>/capture?size=...         one JPEG on demand: qvga 320x240, vga 640x480, svga 800x600,
//                                        xga 1024x768, sxga 1280x1024, uxga 1600x1200 (up to uxga)
//   http://<ip>/sensor                   live auto-exposure (AEC) and gain (AGC), for outdoor detection
//   http://<ip>/status                   role, IP, RSSI, uptime, frames and bytes sent, viewers
//   UDP hello to port 4310 every 2 s     {"t":"cam_hello","role":"front","ip":"172.20.10.x","stream_port":81,
//                                         "http_port":80,"stream":"udp",...}
// Ports follow the team docs: video on 81 (TCP for MJPEG, UDP for the chunked frames: separate port
// spaces, so they never clash), stills/sensor/status on 80. Eye and front both use 81 on their own IPs.
//
// UDP video: a viewer (the backend) sends a datagram starting with "WANT" to UDP 81 at least
// every VIEWER_TIMEOUT_MS; the camera then sends each new frame to the address and port that
// datagram came from ("STOP" ends it). Every frame is cut into chunks of at most 1400 bytes, each
// with a 16-byte header (little-endian):
//     "CAMV"  frame_id u32  chunk u16  chunks u16  jpeg_len u32       then the chunk's JPEG bytes
// (the same layout as the back camera's "OMNV" packets). A frame with a missing chunk is dropped by
// the viewer; the next frame replaces it. No retransmission, no waiting: the newest frame always wins.
// Stills (/capture) stay on HTTP/TCP: one big picture must arrive complete.
//
// Wi-Fi: station mode only (no access point). It joins the network in secrets.h ("espholder"),
// keeps retrying until it is there, reconnects if it drops and prints its IP over serial at boot.
//
// Board: "AI Thinker ESP32-CAM" (esp32 core 3.x). Partition scheme: Huge APP.

#include <WiFi.h>
#include <WiFiUdp.h>
#include <ESPmDNS.h>
#include "esp_camera.h"
#include "esp_http_server.h"
#include "secrets.h"   // WIFI_SSID, WIFI_PASSWORD, optional BACKEND_HOST (gitignored)

// ---- this board ----------------------------------------------------------------
#define DEVICE_NAME "front"            // mDNS front-cam.local, "role" in the UDP hello
#define STREAM_PORT 81                 // live video: UDP 81 and http://<ip>:81/stream (team docs)
#define STREAM_MAX_FPS 5               // the backend analyses ~3 fps (YOLO, distance, outdoor); more only smooths the live view
#define STREAM_SIZE FRAMESIZE_VGA      // 640x480
#define STILL_MAX FRAMESIZE_UXGA       // largest /capture size (sets how much picture memory is reserved)
#define JPEG_QUALITY 12                // 10 (best) .. 63 (smallest)
#define GREYSCALE 0                    // colour: YOLO and Muse need it
#define FLIP_VERTICAL 0                // set to 1 if the image is upside down in the mount
#define MIRROR 0
#define HELLO_PORT 4310
#define HELLO_EVERY_MS 2000
#define MAX_VIEWERS 3                  // backend + up to two more (e.g. a second laptop)
#define VIEWER_TIMEOUT_MS 5000         // a viewer must send WANT at least this often
#define CHUNK_BYTES 1400               // JPEG bytes per datagram (16-byte header + 1400 < 1472: no IP fragments)

// ---- AI-Thinker pin map ---------------------------------------------------------
#define PWDN_GPIO_NUM 32
#define RESET_GPIO_NUM -1
#define XCLK_GPIO_NUM 0
#define SIOD_GPIO_NUM 26
#define SIOC_GPIO_NUM 27
#define Y9_GPIO_NUM 35
#define Y8_GPIO_NUM 34
#define Y7_GPIO_NUM 39
#define Y6_GPIO_NUM 36
#define Y5_GPIO_NUM 21
#define Y4_GPIO_NUM 19
#define Y3_GPIO_NUM 18
#define Y2_GPIO_NUM 5
#define VSYNC_GPIO_NUM 25
#define HREF_GPIO_NUM 23
#define PCLK_GPIO_NUM 22
#define LED_GPIO_NUM 33   // small red LED on the back, active low
#define FLASH_GPIO_NUM 4  // bright white flash LED: keep it off

struct Viewer {
  IPAddress ip;
  uint16_t port;
  uint32_t last;
};

#define PART_BOUNDARY "123456789000000000000987654321"
static const char *MJPEG_TYPE = "multipart/x-mixed-replace;boundary=" PART_BOUNDARY;
static const char *MJPEG_BOUNDARY = "\r\n--" PART_BOUNDARY "\r\n";
static const char *MJPEG_PART = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

static httpd_handle_t control_httpd = NULL;
static httpd_handle_t stream_httpd = NULL;
static volatile uint8_t mjpeg_clients = 0;
static SemaphoreHandle_t cam_lock;      // /capture changes the frame size; the stream must wait
static WiFiUDP udp;                     // UDP STREAM_PORT: WANT/STOP in, video and hellos out
static Viewer viewers[MAX_VIEWERS];
static int n_viewers = 0;
static volatile uint32_t frames_sent = 0, frames_dropped = 0, frame_id = 0;
static volatile uint32_t bytes_window = 0, bytes_per_s = 0, last_frame_bytes = 0;

// OV2640 sensor-bank registers (bank 1): get_reg() takes (bank << 8) | address.
#define SENSOR_REG(a) (0x100 | (a))

// ---- UDP video -------------------------------------------------------------------

static void poll_viewers() {
  int n = udp.parsePacket();
  while (n > 0) {
    char head[4] = {0};
    udp.read((uint8_t *)head, sizeof(head));
    IPAddress ip = udp.remoteIP();
    uint16_t port = udp.remotePort();
    int i = 0;
    while (i < n_viewers && !(viewers[i].ip == ip && viewers[i].port == port)) i++;
    if (n >= 4 && memcmp(head, "WANT", 4) == 0) {
      if (i < n_viewers) {
        viewers[i].last = millis();
      } else if (n_viewers < MAX_VIEWERS) {
        viewers[n_viewers++] = {ip, port, millis()};
        Serial.printf("viewer %s:%u\n", ip.toString().c_str(), port);
      }
    } else if (n >= 4 && memcmp(head, "STOP", 4) == 0 && i < n_viewers) {
      viewers[i] = viewers[--n_viewers];
    }
    while (udp.available()) udp.read();
    n = udp.parsePacket();
  }
  uint32_t now = millis();
  int k = 0;                                     // forget viewers that stopped asking
  for (int i = 0; i < n_viewers; i++)
    if (now - viewers[i].last < VIEWER_TIMEOUT_MS) viewers[k++] = viewers[i];
  n_viewers = k;
}

// One datagram. If the Wi-Fi driver is out of buffers, give it a moment and try again.
static bool send_chunk(const Viewer &v, const uint8_t *hdr, const uint8_t *data, size_t n) {
  for (int attempt = 0; attempt < 4; attempt++) {
    if (udp.beginPacket(v.ip, v.port) && udp.write(hdr, 16) == 16 && udp.write(data, n) == n && udp.endPacket())
      return true;
    delay(2);
  }
  return false;
}

static void send_frame(const camera_fb_t *fb) {
  uint16_t chunks = (fb->len + CHUNK_BYTES - 1) / CHUNK_BYTES;
  uint32_t id = ++frame_id, len = fb->len;
  uint8_t hdr[16] = {'C', 'A', 'M', 'V'};
  memcpy(hdr + 4, &id, 4);
  memcpy(hdr + 10, &chunks, 2);
  memcpy(hdr + 12, &len, 4);
  bool ok = true;
  for (int v = 0; v < n_viewers; v++) {
    for (uint16_t c = 0; c < chunks; c++) {
      memcpy(hdr + 8, &c, 2);
      size_t off = (size_t)c * CHUNK_BYTES, n = min((size_t)CHUNK_BYTES, fb->len - off);
      if (!send_chunk(viewers[v], hdr, fb->buf + off, n)) {
        ok = false;                              // the viewer drops this frame; carry on with the next
        break;
      }
    }
  }
  if (ok) frames_sent++; else frames_dropped++;
  last_frame_bytes = fb->len;
  bytes_window += fb->len * n_viewers;
}

static void stream_step() {
  static uint32_t last = 0, window_start = 0;
  uint32_t now = millis();
  if (now - window_start >= 1000) {
    bytes_per_s = bytes_window * 1000 / max(now - window_start, (uint32_t)1);
    bytes_window = 0;
    window_start = now;
  }
  if (n_viewers == 0 || now - last < 1000 / STREAM_MAX_FPS) return;
  last = now;
  xSemaphoreTake(cam_lock, portMAX_DELAY);
  camera_fb_t *fb = esp_camera_fb_get();
  xSemaphoreGive(cam_lock);
  if (!fb) {
    Serial.println("camera capture failed");
    return;
  }
  send_frame(fb);
  esp_camera_fb_return(fb);
}

// ---- MJPEG over HTTP (http://<ip>:81/stream) -------------------------------------

static esp_err_t stream_handler(httpd_req_t *req) {
  char part[64];
  esp_err_t res = httpd_resp_set_type(req, MJPEG_TYPE);
  if (res != ESP_OK) return res;
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  mjpeg_clients++;
  uint32_t last = 0;
  while (true) {
    uint32_t now = millis();
    if (now - last < 1000 / STREAM_MAX_FPS) delay(1000 / STREAM_MAX_FPS - (now - last));
    last = millis();
    xSemaphoreTake(cam_lock, portMAX_DELAY);
    camera_fb_t *fb = esp_camera_fb_get();
    xSemaphoreGive(cam_lock);
    if (!fb) {
      res = ESP_FAIL;
      break;
    }
    size_t hlen = snprintf(part, sizeof(part), MJPEG_PART, fb->len);
    res = httpd_resp_send_chunk(req, MJPEG_BOUNDARY, strlen(MJPEG_BOUNDARY));
    if (res == ESP_OK) res = httpd_resp_send_chunk(req, part, hlen);
    if (res == ESP_OK) res = httpd_resp_send_chunk(req, (const char *)fb->buf, fb->len);
    esp_camera_fb_return(fb);
    if (res != ESP_OK) break;   // viewer went away
  }
  mjpeg_clients--;
  return res;
}

// ---- HTTP: stills, sensor, status ------------------------------------------------

static framesize_t parse_size(const char *size) {
  framesize_t fs = strcmp(size, "qvga") == 0   ? FRAMESIZE_QVGA
                   : strcmp(size, "svga") == 0 ? FRAMESIZE_SVGA
                   : strcmp(size, "xga") == 0  ? FRAMESIZE_XGA
                   : strcmp(size, "sxga") == 0 ? FRAMESIZE_SXGA
                   : strcmp(size, "uxga") == 0 ? FRAMESIZE_UXGA
                                               : FRAMESIZE_VGA;
  return fs > STILL_MAX ? STILL_MAX : fs;        // the framesize_t values grow with the picture size
}

// /capture?size=...: switch the sensor up, drop the stale frames, grab one, switch back.
static esp_err_t capture_handler(httpd_req_t *req) {
  char query[32] = {0}, size[8] = "vga";
  if (httpd_req_get_url_query_str(req, query, sizeof(query)) == ESP_OK) {
    httpd_query_key_value(query, "size", size, sizeof(size));
  }
  framesize_t fs = parse_size(size);
  sensor_t *s = esp_camera_sensor_get();
  xSemaphoreTake(cam_lock, portMAX_DELAY);
  if (fs != STREAM_SIZE) s->set_framesize(s, fs);
  camera_fb_t *fb = NULL;
  for (int i = 0; i < 3; i++) {          // the first frames after a size change are still old/garbled
    if (fb) esp_camera_fb_return(fb);
    fb = esp_camera_fb_get();
  }
  if (!fb) {
    if (fs != STREAM_SIZE) s->set_framesize(s, STREAM_SIZE);
    xSemaphoreGive(cam_lock);
    httpd_resp_send_500(req);
    return ESP_FAIL;
  }
  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  esp_err_t res = httpd_resp_send(req, (const char *)fb->buf, fb->len);
  esp_camera_fb_return(fb);
  if (fs != STREAM_SIZE) {
    s->set_framesize(s, STREAM_SIZE);
    camera_fb_t *stale = esp_camera_fb_get();   // flush one frame at the old size
    if (stale) esp_camera_fb_return(stale);
  }
  xSemaphoreGive(cam_lock);
  return res;
}

// Live auto-exposure and gain. The OV2640 keeps the picture's brightness constant, so the
// backend divides mean brightness by exposure x gain to tell a sunny street from an office.
//   AEC[15:0] = REG45[5:0] << 10 | REG10 << 2 | REG04[1:0]   (exposure, in lines)
//   GAIN = REG00: (b7+1)(b6+1)(b5+1)(b4+1)(1 + b[3:0]/16)
static esp_err_t sensor_handler(httpd_req_t *req) {
  sensor_t *s = esp_camera_sensor_get();
  xSemaphoreTake(cam_lock, portMAX_DELAY);
  int r04 = s->get_reg(s, SENSOR_REG(0x04), 0xFF);
  int r10 = s->get_reg(s, SENSOR_REG(0x10), 0xFF);
  int r45 = s->get_reg(s, SENSOR_REG(0x45), 0xFF);
  int gain = s->get_reg(s, SENSOR_REG(0x00), 0xFF);
  xSemaphoreGive(cam_lock);
  char json[200];
  if (r04 < 0 || r10 < 0 || r45 < 0 || gain < 0) {
    snprintf(json, sizeof(json), "{\"role\":\"%s\",\"error\":\"register read failed\"}", DEVICE_NAME);
  } else {
    unsigned aec = ((r45 & 0x3F) << 10) | (r10 << 2) | (r04 & 0x03);
    snprintf(json, sizeof(json),
             "{\"role\":\"%s\",\"aec_lines\":%u,\"gain_reg\":%d,\"aec_enabled\":%d,\"agc_enabled\":%d,"
             "\"uptime_ms\":%lu}",
             DEVICE_NAME, aec, gain, s->status.aec, s->status.agc, (unsigned long)millis());
  }
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  return httpd_resp_send(req, json, strlen(json));
}

static esp_err_t status_handler(httpd_req_t *req) {
  char json[360];
  snprintf(json, sizeof(json),
           "{\"role\":\"%s\",\"ip\":\"%s\",\"rssi\":%d,\"uptime_s\":%lu,\"stream\":\"udp\",\"stream_port\":%d,"
           "\"viewers\":%d,\"mjpeg_clients\":%u,\"frames_sent\":%lu,\"frames_dropped\":%lu,\"last_frame_bytes\":%lu,"
           "\"bytes_per_s\":%lu,\"max_fps\":%d,\"free_heap\":%u}",
           DEVICE_NAME, WiFi.localIP().toString().c_str(), WiFi.RSSI(), millis() / 1000, STREAM_PORT,
           n_viewers, mjpeg_clients, (unsigned long)frames_sent, (unsigned long)frames_dropped,
           (unsigned long)last_frame_bytes, (unsigned long)bytes_per_s, STREAM_MAX_FPS, ESP.getFreeHeap());
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  return httpd_resp_send(req, json, strlen(json));
}

static void start_server() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;
  httpd_uri_t capture_uri = {.uri = "/capture", .method = HTTP_GET, .handler = capture_handler, .user_ctx = NULL};
  httpd_uri_t sensor_uri = {.uri = "/sensor", .method = HTTP_GET, .handler = sensor_handler, .user_ctx = NULL};
  httpd_uri_t status_uri = {.uri = "/status", .method = HTTP_GET, .handler = status_handler, .user_ctx = NULL};
  if (httpd_start(&control_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(control_httpd, &capture_uri);
    httpd_register_uri_handler(control_httpd, &sensor_uri);
    httpd_register_uri_handler(control_httpd, &status_uri);
  }
  // MJPEG gets its own server on port 81 so a long-lived stream never blocks the others.
  config.server_port = STREAM_PORT;
  config.ctrl_port += 1;
  httpd_uri_t stream_uri = {.uri = "/stream", .method = HTTP_GET, .handler = stream_handler, .user_ctx = NULL};
  if (httpd_start(&stream_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(stream_httpd, &stream_uri);
  }
}

// ---- camera and Wi-Fi --------------------------------------------------------------

static bool init_camera() {
  camera_config_t c = {};
  c.ledc_channel = LEDC_CHANNEL_0;
  c.ledc_timer = LEDC_TIMER_0;
  c.pin_d0 = Y2_GPIO_NUM;
  c.pin_d1 = Y3_GPIO_NUM;
  c.pin_d2 = Y4_GPIO_NUM;
  c.pin_d3 = Y5_GPIO_NUM;
  c.pin_d4 = Y6_GPIO_NUM;
  c.pin_d5 = Y7_GPIO_NUM;
  c.pin_d6 = Y8_GPIO_NUM;
  c.pin_d7 = Y9_GPIO_NUM;
  c.pin_xclk = XCLK_GPIO_NUM;
  c.pin_pclk = PCLK_GPIO_NUM;
  c.pin_vsync = VSYNC_GPIO_NUM;
  c.pin_href = HREF_GPIO_NUM;
  c.pin_sccb_sda = SIOD_GPIO_NUM;
  c.pin_sccb_scl = SIOC_GPIO_NUM;
  c.pin_pwdn = PWDN_GPIO_NUM;
  c.pin_reset = RESET_GPIO_NUM;
  c.xclk_freq_hz = 20000000;
  c.pixel_format = PIXFORMAT_JPEG;
  // Reserve memory for the largest still we serve; the sensor then runs at the stream size.
  c.frame_size = STILL_MAX;
  c.jpeg_quality = JPEG_QUALITY;
  c.grab_mode = CAMERA_GRAB_LATEST;   // always the newest frame: lower latency, drops old ones
  if (psramFound()) {
    c.fb_count = 2;
    c.fb_location = CAMERA_FB_IN_PSRAM;
  } else {
    c.fb_count = 1;
    c.fb_location = CAMERA_FB_IN_DRAM;
    c.frame_size = FRAMESIZE_QVGA;
  }
  esp_err_t err = esp_camera_init(&c);
  if (err != ESP_OK) {
    Serial.printf("camera init failed: 0x%x (check the ribbon cable)\n", err);
    return false;
  }
  sensor_t *s = esp_camera_sensor_get();
  s->set_framesize(s, STREAM_SIZE);
  s->set_vflip(s, FLIP_VERTICAL);
  s->set_hmirror(s, MIRROR);
  s->set_special_effect(s, GREYSCALE ? 2 : 0);   // 2 = grayscale
  s->set_exposure_ctrl(s, 1);   // auto exposure on: /sensor reports what it chose
  s->set_gain_ctrl(s, 1);
  return true;
}

static void wait_for_wifi(uint32_t timeout_ms) {
  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < timeout_ms) {
    digitalWrite(LED_GPIO_NUM, !digitalRead(LED_GPIO_NUM));   // blink while connecting
    delay(250);
    Serial.print(".");
  }
}

static void connect_wifi() {
  WiFi.softAPdisconnect(true);  // never an access point: we join the network
  WiFi.mode(WIFI_STA);
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.setSleep(false);         // modem sleep adds a lot of stream latency
  WiFi.setHostname(DEVICE_NAME "-cam");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.printf("connecting to %s", WIFI_SSID);
  wait_for_wifi(30000);
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("\nno Wi-Fi after 30 s (2.4 GHz only; iPhone: Maximize Compatibility), restarting");
    ESP.restart();
  }
  digitalWrite(LED_GPIO_NUM, LOW);   // solid on = connected
  Serial.printf("\nconnected, IP %s, RSSI %d dBm\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
}

// Tell the backend where we are: broadcast on the network, and unicast to BACKEND_HOST if set.
static void send_hello() {
  char msg[200];
  int n = snprintf(msg, sizeof(msg),
                   "{\"t\":\"cam_hello\",\"role\":\"%s\",\"ip\":\"%s\",\"stream\":\"udp\",\"stream_port\":%d,"
                   "\"http_port\":80,\"max_fps\":%d}",
                   DEVICE_NAME, WiFi.localIP().toString().c_str(), STREAM_PORT, STREAM_MAX_FPS);
  udp.beginPacket(IPAddress(255, 255, 255, 255), HELLO_PORT);
  udp.write((const uint8_t *)msg, n);
  udp.endPacket();
#ifdef BACKEND_HOST
  IPAddress backend;
  if (WiFi.hostByName(BACKEND_HOST, backend)) {
    udp.beginPacket(backend, HELLO_PORT);
    udp.write((const uint8_t *)msg, n);
    udp.endPacket();
  }
#endif
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_GPIO_NUM, OUTPUT);
  pinMode(FLASH_GPIO_NUM, OUTPUT);
  digitalWrite(FLASH_GPIO_NUM, LOW);
  Serial.printf("\ncamera '%s'\n", DEVICE_NAME);
  cam_lock = xSemaphoreCreateMutex();
  if (!init_camera()) {
    delay(3000);
    ESP.restart();
  }
  connect_wifi();
  if (MDNS.begin(DEVICE_NAME "-cam")) {
    MDNS.addService("http", "tcp", 80);
    Serial.printf("mDNS: %s-cam.local\n", DEVICE_NAME);
  }
  start_server();
  udp.begin(STREAM_PORT);
  Serial.printf("video:   UDP %s:%d (send WANT to receive), http://%s:%d/stream\n", WiFi.localIP().toString().c_str(),
                STREAM_PORT, WiFi.localIP().toString().c_str(), STREAM_PORT);
  Serial.printf("status:  http://%s/status\n", WiFi.localIP().toString().c_str());
}

void loop() {
  static uint32_t last_hello = 0;
  if (WiFi.status() != WL_CONNECTED) {
    // The network dropped (phone locked, walked away): auto-reconnect is on, but give it a push.
    Serial.println("Wi-Fi lost, reconnecting");
    digitalWrite(LED_GPIO_NUM, HIGH);
    n_viewers = 0;
    WiFi.reconnect();
    wait_for_wifi(20000);
    if (WiFi.status() != WL_CONNECTED) ESP.restart();
    digitalWrite(LED_GPIO_NUM, LOW);
    Serial.printf("\nreconnected, IP %s\n", WiFi.localIP().toString().c_str());
    last_hello = 0;               // announce the (possibly new) IP right away
  }
  if (millis() - last_hello >= HELLO_EVERY_MS) {
    last_hello = millis();
    send_hello();
  }
  poll_viewers();
  stream_step();
  delay(1);
}
