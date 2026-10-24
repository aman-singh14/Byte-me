// Camera firmware for the AI-Thinker ESP32-CAM (OV2640).
//
// Trimmed-down CameraWebServer: MJPEG on http://<name>.local:81/stream, a single
// JPEG on http://<name>.local/capture, and JSON on /status. The backend reads the
// stream with OpenCV; set its URL in backend/config.yaml.
//
// Before flashing:
//   1. cp secrets.example.h secrets.h   and fill in the hotspot name and password
//   2. set DEVICE_NAME below: "front", "eye" or "rear"
// Board: "AI Thinker ESP32-CAM" (esp32 core 2.x or 3.x). See README.md for wiring.

#include <WiFi.h>
#include <ESPmDNS.h>
#include "esp_camera.h"
#include "esp_http_server.h"
#include "secrets.h"   // WIFI_SSID, WIFI_PASSWORD (gitignored)

// ---- per-device settings ----------------------------------------------------
#define DEVICE_NAME "front"            // front | eye | rear  -> mDNS front-cam.local, etc.
#define FRAME_SIZE  FRAMESIZE_VGA      // 640x480. QVGA (320x240) if Wi-Fi is weak; the rear LGMD only needs 80x60
#define JPEG_QUALITY 14                // 10 (best) .. 63 (smallest)
#define FLIP_VERTICAL 0                // set to 1 if the image is upside down in the mount
#define MIRROR 0

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

#define PART_BOUNDARY "123456789000000000000987654321"
static const char *STREAM_CONTENT_TYPE = "multipart/x-mixed-replace;boundary=" PART_BOUNDARY;
static const char *STREAM_BOUNDARY = "\r\n--" PART_BOUNDARY "\r\n";
static const char *STREAM_PART = "Content-Type: image/jpeg\r\nContent-Length: %u\r\n\r\n";

static httpd_handle_t control_httpd = NULL;
static httpd_handle_t stream_httpd = NULL;
static volatile uint32_t frames_sent = 0;
static volatile uint8_t stream_clients = 0;

static esp_err_t stream_handler(httpd_req_t *req) {
  char part[64];
  esp_err_t res = httpd_resp_set_type(req, STREAM_CONTENT_TYPE);
  if (res != ESP_OK) return res;
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  stream_clients++;
  while (true) {
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) {
      Serial.println("camera capture failed");
      res = ESP_FAIL;
      break;
    }
    size_t hlen = snprintf(part, sizeof(part), STREAM_PART, fb->len);
    res = httpd_resp_send_chunk(req, STREAM_BOUNDARY, strlen(STREAM_BOUNDARY));
    if (res == ESP_OK) res = httpd_resp_send_chunk(req, part, hlen);
    if (res == ESP_OK) res = httpd_resp_send_chunk(req, (const char *)fb->buf, fb->len);
    esp_camera_fb_return(fb);
    if (res != ESP_OK) break;   // client went away
    frames_sent++;
  }
  stream_clients--;
  return res;
}

static esp_err_t capture_handler(httpd_req_t *req) {
  camera_fb_t *fb = esp_camera_fb_get();
  if (!fb) {
    httpd_resp_send_500(req);
    return ESP_FAIL;
  }
  httpd_resp_set_type(req, "image/jpeg");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  esp_err_t res = httpd_resp_send(req, (const char *)fb->buf, fb->len);
  esp_camera_fb_return(fb);
  return res;
}

static esp_err_t status_handler(httpd_req_t *req) {
  char json[256];
  snprintf(json, sizeof(json),
           "{\"name\":\"%s\",\"ip\":\"%s\",\"rssi\":%d,\"uptime_s\":%lu,\"frames_sent\":%lu,"
           "\"stream_clients\":%u,\"free_heap\":%u}",
           DEVICE_NAME, WiFi.localIP().toString().c_str(), WiFi.RSSI(), millis() / 1000,
           (unsigned long)frames_sent, stream_clients, ESP.getFreeHeap());
  httpd_resp_set_type(req, "application/json");
  httpd_resp_set_hdr(req, "Access-Control-Allow-Origin", "*");
  return httpd_resp_send(req, json, strlen(json));
}

static void start_servers() {
  httpd_config_t config = HTTPD_DEFAULT_CONFIG();
  config.server_port = 80;
  httpd_uri_t capture_uri = {.uri = "/capture", .method = HTTP_GET, .handler = capture_handler, .user_ctx = NULL};
  httpd_uri_t status_uri = {.uri = "/status", .method = HTTP_GET, .handler = status_handler, .user_ctx = NULL};
  if (httpd_start(&control_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(control_httpd, &capture_uri);
    httpd_register_uri_handler(control_httpd, &status_uri);
  }
  // The stream gets its own server (port 81) so a long-lived stream never blocks /status.
  config.server_port = 81;
  config.ctrl_port += 1;
  httpd_uri_t stream_uri = {.uri = "/stream", .method = HTTP_GET, .handler = stream_handler, .user_ctx = NULL};
  if (httpd_start(&stream_httpd, &config) == ESP_OK) {
    httpd_register_uri_handler(stream_httpd, &stream_uri);
  }
}

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
  c.frame_size = FRAME_SIZE;
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
  s->set_vflip(s, FLIP_VERTICAL);
  s->set_hmirror(s, MIRROR);
  return true;
}

static void connect_wifi() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);   // modem sleep adds a lot of stream latency
  WiFi.setHostname(DEVICE_NAME "-cam");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  Serial.printf("connecting to %s", WIFI_SSID);
  uint32_t t0 = millis();
  while (WiFi.status() != WL_CONNECTED) {
    digitalWrite(LED_GPIO_NUM, !digitalRead(LED_GPIO_NUM));   // blink while connecting
    delay(250);
    Serial.print(".");
    if (millis() - t0 > 30000) {
      Serial.println("\nno Wi-Fi after 30 s (2.4 GHz only; iPhone: Maximize Compatibility), restarting");
      ESP.restart();
    }
  }
  digitalWrite(LED_GPIO_NUM, LOW);   // solid on = connected
  Serial.printf("\nconnected, IP %s, RSSI %d dBm\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_GPIO_NUM, OUTPUT);
  pinMode(FLASH_GPIO_NUM, OUTPUT);
  digitalWrite(FLASH_GPIO_NUM, LOW);
  Serial.printf("\ncamera '%s'\n", DEVICE_NAME);
  if (!init_camera()) {
    delay(3000);
    ESP.restart();
  }
  connect_wifi();
  if (MDNS.begin(DEVICE_NAME "-cam")) {
    MDNS.addService("http", "tcp", 80);
    Serial.printf("mDNS: http://%s-cam.local:81/stream\n", DEVICE_NAME);
  }
  start_servers();
  Serial.printf("stream:  http://%s:81/stream\n", WiFi.localIP().toString().c_str());
}

void loop() {
  // Reconnect if the hotspot drops (phone locked, walked away).
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("Wi-Fi lost, reconnecting");
    digitalWrite(LED_GPIO_NUM, HIGH);
    WiFi.reconnect();
    uint32_t t0 = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < 15000) delay(250);
    if (WiFi.status() != WL_CONNECTED) ESP.restart();
    digitalWrite(LED_GPIO_NUM, LOW);
  }
  delay(1000);
}
