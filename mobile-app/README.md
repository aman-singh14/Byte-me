# Omni Glasses companion app

Flutter (iOS + Android), Material 3. `DESIGN.md` in this folder is the source of
truth for all UI.

## Layout

| Path | What |
|---|---|
| `lib/theme/tokens.dart` | DESIGN.md tokens as ThemeExtensions (`OmniColors`, `OmniSpacing`, `OmniRadii`, `OmniType`). The only file with hex colors. |
| `lib/theme/theme.dart` | Light and dark `ThemeData`; `context.colors`, `context.space`, `context.radii`, `context.type` |
| `lib/components/` | DESIGN.md components (RingStack, StatusStrip, AlertBanner, SideIndicator, SocialTapCard, QuestCard, FriendRow, CaptionView, WhoAroundSheet, Celebration, PrivacyChip) |
| `lib/net/protocol.dart` | UDP JSON messages, pure Dart. The one place image sides are flipped to wearer sides. |
| `lib/net/glasses_link.dart` | Discovery, 250 ms heartbeat, link-lost detection |
| `lib/vision/mjpeg.dart` | MJPEG client for Cam A, newest frame only, auto-reconnect |
| `lib/vision/detector.dart` | YOLO through `ultralytics_yolo`, filtered to the 8 alert classes |
| `lib/vision/fire_namer.dart` | Names reflex fires: YOLO on Cam B's (the FPGA's) newest frames, the object on the fire's side |
| `lib/vision/rear_vision.dart` | Starts the camera when Cam A says hello; runs detection app-wide |
| `lib/alerts/tracker.dart` | Follows boxes across frames; time to contact from box growth. Pure Dart. |
| `lib/alerts/alert_engine.dart` | Decides alert level and side (thresholds, head turns, glance-back, following, night, sensitivity). Pure Dart. |
| `lib/alerts/alert_service.dart` | Feeds the engine from the glasses and camera; sends `alert` / `stop` to the frame; keeps the event log |
| `lib/alerts/alert_log.dart` | Event log: one entry per alert, saved on the phone for 7 days. Pure Dart. |
| `lib/alerts/voice.dart` | Spoken labels with the phone's own text-to-speech |
| `lib/screens/alert_widgets.dart` | Live alert banner on every tab; one app-wide announcer (voice, screen reader, haptics) |
| `assets/models/` | YOLO26n at 320 px: `.mlpackage.zip` (iOS), `.tflite` (Android) |
| `tool/export_yolo.py` | Regenerates the models (instructions at the top of the file) |
| `lib/social/` | Together: `rings_source.dart` (the interface the rings code implements, plus a stand-in), `social_api.dart` + `social_store.dart` (server client and state), `side_quests.dart`, `together_time.dart` (Bluetooth) |
| `../social/` | The social server (FastAPI + SQLite); deploy steps in its README |
| `lib/screens/` | Bottom navigation (Today, Aware, Eyes, Together) and Settings |
| `lib/gallery/widget_gallery.dart` | Widget Gallery debug screen |
| `../mock_glasses.py` | Fake glasses for development |

## Setup (once)

```bash
brew install --cask flutter
```

For iOS you also need Xcode from the App Store, then:

```bash
sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -runFirstLaunch
```

```bash
brew install cocoapods
```

For Android, install Android Studio and create an emulator in its Device Manager.
Check with `flutter doctor`.

## Run against the mock

1. Start the mock (from the repo root, using the venv that `lgmd.py` uses):

   ```bash
   .venv/bin/python mock_glasses.py
   ```

   It serves the laptop webcam at `http://<laptop>:81/stream`, says hello to
   the app every 2 s, sends sensor samples 10x/s, and prints every message the
   app sends. Type `fl` / `fr` + Enter to send a fire, `turn l` / `turn r` for a
   head turn, `drop` to pause sensor
   data for 5 s (shows the link-lost banner), `q` to quit. `--no-camera` serves
   a test pattern instead of the webcam.

2. Run the app.

   **iOS simulator** (shares the Mac's network, so `127.0.0.1` reaches it).
   Xcode 27 has no separate Simulator app, so boot one from the command line:

   ```bash
   xcrun simctl boot "iPhone 17"
   ```

   ```bash
   cd mobile-app && flutter run
   ```

   **If the build fails with "resource fork, Finder information, or similar
   detritus not allowed"**: the repo is in iCloud-synced `~/Documents`, and
   codesign rejects the attributes iCloud adds. Keep Flutter's `build/` folder
   outside iCloud with a symlink (git ignores it):

   ```bash
   rm -rf build && mkdir -p ~/Library/Caches/omni_glasses_build && ln -s ~/Library/Caches/omni_glasses_build build
   ```

   Moving the whole repo out of `~/Documents` (for example to `~/Developer`)
   also fixes it.

   **Android emulator**: the emulator has its own network. Forward UDP 4210
   into it, then point the mock at the forward:

   ```bash
   adb emu redir add udp:4210:4210
   ```

   The mock's default `--phone 127.0.0.1` then reaches the emulator. The app
   sees the mock as `10.0.2.2` and replies there. (Not yet tried; if heartbeats
   don't reach the mock, use the iOS simulator or a real phone.)

   **Real phone**: turn on the phone's hotspot, join it from the laptop, and
   pass the phone's hotspot address (iPhone: `172.20.10.1`; Android: run
   `route -n get default` on the laptop and use the gateway):

   ```bash
   .venv/bin/python mock_glasses.py --phone 172.20.10.1
   ```

   On iOS, accept the Local Network prompt the first time.

3. Within a second, Today's banner changes from "Glasses not watching" to
   "Glasses connected · 82%", the mock prints `heartbeats from ..., phone
   connected`, and Eyes > Right now shows live distance and lux. Type `drop` in
   the mock to see the link-lost banner on every tab.

## Rear view and detection

- The Aware tab shows Cam A's stream with labeled boxes. The image is
  mirrored like a rear-view mirror (wearer's left on screen left), and every
  label names the wearer's side ("Car · left"), so you never have to work out
  the mirror yourself.
- Detection runs on the newest frame only, one at a time, on every tab (alerts
  must not depend on Aware being open). Frames live in memory only and are
  replaced by the next one.
- The models are YOLO26n exported at 320 px with the same settings as the
  plugin's official 640 px ones. If they are missing, the app falls back to the
  official `yolo26n` (downloaded on first run).
- With the mock, the laptop webcam faces you rather than backward, so sides are
  swapped compared to the real glasses.
- Debug builds show fps, detector time and object count under the video.

## Alert engine

How it decides, in `lib/alerts/alert_engine.dart` (all numbers are constants
at the top of the file or class, easy to tune at the venue):

- **Time to contact** comes from how fast a box grows: apparent size is
  1 / distance, so the slope of ln(size) over the last second is
  1 / time-to-contact. No calibration. Needs 0.4 s of history.
- **Size is box height**, because a walking person's width swings with every
  stride. A box cut off by the image edge isn't measured on that axis (it
  "grows" as more of the object comes into view); when the height is cut off
  up close, width is used instead, but only for rigid things (vehicles,
  bikes): a person or dog filling the frame gets no camera estimate, since
  leaning looks the same as approaching. Boxes under 5% of the image (about
  12 px) aren't measured. Growth must fit a straight line well (R² ≥ 0.75).
- **Confirmed before it buzzes:** a camera alert must qualify on every frame
  for 0.3 s first, so one odd box never alerts. Reflex fires don't wait.
- **Three sides:** the middle 30% of the rear image is straight behind; the
  rest is left or right. A box must cross a boundary by 5% of the image
  before its alert changes side, and a side change alone isn't spoken again.
- **Levels by class** (seconds to contact, normal sensitivity, daylight):

  | Class | Gentle | Urgent |
  |---|---|---|
  | car, bus, truck, motorcycle | 6 | 3 |
  | bicycle | 5 | 2.5 |
  | skateboard | 4 | 2 |
  | dog | 3 | 1.5 |
  | person | 3, **only straight behind** | never (someone walking up to talk looks the same until they slow down; the social tap handles them) |

  People off to the side are walking past, not at you, so they don't alert
  (otherwise a busy sidewalk buzzes every few seconds). 3 s catches a walker
  at about 4 m, while their feet are still in view; closer than that only
  their width is visible, and leaning changes it too much to trust.

- **Sensitivity** low / normal / high multiplies those by 0.7 / 1 / 1.4.
  **Night** (auto below 15 lux, off above 30) multiplies by 1.25 and accepts
  detections from 35% confidence instead of 45%.
- **Head turning** (over 60°/s): camera alerts freeze and frames are skipped
  until 0.3 s after the turn; approach history restarts.
- **Glance back**: turning 45° toward the alert's side (either way for
  straight behind) within 1.5 s silences it (`stop`). It comes back only if it gets worse (gentle to urgent).
- **Reflex fires** (Cam B, the FPGA's locust detector) are always urgent and
  last 1.5 s. The buzz goes out at once with Cam A's best guess for the word.
  Then the app runs YOLO on Cam B's newest frames (up to 3, within 0.6 s)
  and takes the biggest object on the fire's side or straight behind; that
  name replaces the guess. The voice waits 0.3 s for it, so the wearer hears
  "Car", not "Behind" then "Car". Repeated fires on one side are named once.
- **Who decides what:** close range is the reflex's job (people and things
  only partly in view can't be measured from Cam A's boxes). Cam A's time to
  contact warns earlier, at range.
- **One alert at a time**: urgent first, then reflex, then the soonest.
  Alerts hold their level for 1 s so noisy frames don't flicker.
- **Possibly following**: a person behind the wearer for 3 minutes (short
  gaps of up to 10 s allowed) is reported once. It's based on presence only,
  never identity, and it can't yet tell whether the wearer is walking or
  standing in a queue.

### What the wearer gets

- **Banner** pinned under the title on every tab ("Car · close, behind left"),
  with a dismiss button that works like glancing back.
- **Side indicator** above the rear view on Aware.
- **Voice:** one word ("Car"; "Behind" for a reflex fire the camera can't
  name), spoken on device, even with the silent switch on. The side comes
  from which motor buzzes. With VoiceOver / TalkBack on, the screen reader
  says the full sentence instead, so they don't talk over each other.
- **Phone haptics** match the glasses: gentle is one pulse, urgent is three.
- **Possibly following** shows as a card on Today and Aware and is spoken.
- **Event log** on Aware (newest first) and the latest entry on Today: one
  entry per alert with its highest level, closest time to contact, whether
  the reflex fired, and how it ended ("you looked back", "dismissed"). Kept on
  the phone for 7 days, never shared, clearable.
- **Debug builds** add the engine's view to each box: time to contact
  ("3.2 s"), `-` when it isn't approaching, or "40% ignored" below the
  confidence cutoff. Use this for tuning.

Try it with the mock: walk toward the webcam (gentle "person" alert at about
2 s to contact), or type `fl`. The mock prints the `alert` and `stop` messages.

## Together (friends, teams, quests)

Run the social server (see `../social/README.md`), then the app as usual: it
uses `http://localhost:8000` unless built with `--dart-define=SOCIAL_URL=...`
or changed in Settings > Together server.

- **Joining:** pick a display name. No account or password; the server hands
  the phone a random token.
- **Friends and this week's stars:** add each other with a 6-letter friend
  code. A leaderboard ranks you and your friends by side quest stars from
  Monday to now (each person's own week).
- **Team:** make one or join with a team code. The **team ring** is everyone's
  two rings averaged. Turning on **Public team** puts it in the league and
  gives it a read-only page (`/t/<id>` on the server) to share with judges.
- **Team league:** public teams (and yours, even while private) ranked by
  points this week: 10 per side quest star per member, plus the team's
  average ring this week, so quests and rings both count and a small team
  can beat a big one. Tap a team for its page: points, rings today, stars by
  quest, and members.
- **Profiles:** tap a friend (leaderboard) or a teammate (team card or a
  team's page) to see their stars this week by quest, their average ring
  this week, and today's rings. Phones upload each day's stars by quest
  along with the total, so these add up on the server.
- **Group screen breaks:** a reminder, nothing measured. Anyone on the team
  schedules one (now, in 5/15/30 min or at a time, for 10/15/20 min); it
  shows as one line in the team card and on Today, with Cancel until it
  starts. At the start every teammate's glasses get `{"t":"groupbreak"}` and
  the app says "Look up and talk".
- **Side quests:** always running, nothing to start or tap. Each has three
  goals and each goal reached earns a star (3 a quest, 12 a day):
  - Look up: heads-up minutes today (30 / 60 / 120).
  - Golden hour: minutes outside (over 1,000 lux) between 5 and 8 pm (10 / 20 / 40).
  - Phone-down lunch: minutes between 11:30 and 2 with nothing closer than
    45 cm, the distance a phone is held at (15 / 30 / 45). A plate or a
    friend across the table is farther, so it still counts.
  - Hang out: minutes with a friend nearby, from Together time (15 / 30 / 60).

  Measured on the phone from the glasses' sensor samples and starting over
  each day. Only the day's star count is uploaded, with the ring
  percentages. A star gets a celebration, and it says so when it moves you
  past a friend on the leaderboard. Stars are self-reported by the phone;
  there's no cheat-proofing.
- **Together time (Bluetooth, off by default):** while the app is open, the
  phone advertises a random id only friends learn and listens for theirs;
  a friend within a few meters counts as together. Its card shows today's
  minutes, who's nearby now, and **best friends**: the friends you spent the
  most time near over the last 30 days. Minutes stay on the phone (kept 30
  days). Needs real phones (the simulator has no Bluetooth). Limitation: the
  id doesn't rotate yet, and iOS stops advertising in the background.
- **Rings:** the social features read today's Heads-up and Outside minutes
  through `RingsSource` (`lib/social/rings_source.dart`). `StandInRings`
  fills in from sensor samples until the real rings code implements it;
  swap it in `main.dart`. Only the percentages leave the phone.

## Call a helper

A helper (friend, family, guide) opens a link in any browser, sees the
glasses' front or rear camera live, and guides the wearer with haptic arrows.
Server: `backend/helper.py` (see `backend/README.md`). The app's side is
`lib/helper/helper_call.dart` and `lib/screens/helper_screen.dart` (Aware
tab, and a card on Today).

- **Video:** the camera's original JPEGs go to the server over a WebSocket,
  up to 10 fps, newest only, with at most two frames in flight (the server
  acks each one), so a slow network drops frames instead of lagging. Frames
  only go out while a helper is connected. Rear frames come from the rear
  stream rear vision already has open (an ESP32-CAM serves one client at a
  time); the front stream is opened only while the helper is watching it.
- **Guidance:** the helper's Left / Forward / Right / Stop goes to the frame
  as `{"t":"guide","dir":...}` (a buzz unlike any alert) and is spoken.
- **Alerts** (approach and "someone behind you") are passed on to the helper.
- Leaving the app while live ends the call; leaving while waiting (to send the
  link) doesn't. Status is spoken, or announced to VoiceOver / TalkBack.
- Not yet (build steps 3-5): two-way audio (LiveKit), the full helper page,
  the LIVE LED on the glasses, keep-screen-on.

Run it end to end on one laptop:

```bash
.venv/bin/python mock_glasses.py                    # glasses + webcam (repo root)
```

```bash
.venv/bin/python -m backend.helper --port 8020      # helper server (repo root)
```

```bash
flutter run --dart-define=FRONT_CAM_URL=http://localhost:81/stream
```

In the app: Aware (or Today) > **Call a helper**. Copy the link from the
share sheet and open it in a browser. Arrow keys / Space or the buttons send
guidance; the mock prints `[frame] GUIDE <- LEFT ...`.

For a helper on another network, put the server behind HTTPS (no account
needed for a quick tunnel) and build the app against it:

```bash
cloudflared tunnel --url http://localhost:8020
```

```bash
flutter run --dart-define=HELPER_URL=https://<name>.trycloudflare.com --dart-define=FRONT_CAM_URL=http://front-cam.local:81/stream
```

## Widget Gallery

Debug builds only: Today > profile button (top right) > Developer > Widget
Gallery. Or start straight on it:

```bash
flutter run --route /gallery
```

The buttons at the top pick which variants show: Light, Dark, 200% text.

## Tests

```bash
flutter test
```

- `protocol_test`: parsing, encoding, side flip
- `glasses_link_test`: real UDP on localhost (discovery, heartbeat, lost, commands)
- `contrast_test`: every DESIGN.md text/shape pair in both themes
- `alert_log_test`: one entry per alert, merging, limits, save and load
- `tracker_test`, `alert_engine_test`: approach scenarios played frame by frame (levels, sides, turns, glances, fires, modes, following)
- `screens_test`: every tab and the whole gallery on a 360 dp phone, light/dark, 100%/200% text, failing on any overflow

## Protocol notes for the firmware

- The app listens on **UDP 4210** and replies to the address **and port** each
  datagram came from. The mock's frame sends from (and listens on) 4211.
- Each device sends `{"t":"hello","id":...}` every 2 s, always. Sensor samples
  also count as a hello for the frame. Ids: `frame`, `camA`, and `camB` (the
  FPGA reflex camera).
- **Cam B (FPGA)** sends its fires through the frame as `fire` (side L/R,
  already the wearer's side), and serves its video like Cam A: MJPEG at
  `http://<camB>:81/stream`, any resolution, facing backward (left of its
  image = wearer's right). If the video ends up arriving another way, only
  the frame source in `lib/vision/fire_namer.dart` changes.
- The link counts as lost after 1 s without a `sens` sample. The frame should
  treat 1 s without `hb` as "phone lost".
- Optional `"batt": 0-100` in `sens` is shown in the status strip.
- `side` is always the wearer's side. The frame flips Cam B's image sides
  before sending `fire`.
- **`alert` can have `"side":"B"`: straight behind, buzz both motors.** This
  is an addition to the original protocol; the frame only ever sends L/R.
  Firmware that doesn't know "B" yet should treat it as both sides, not
  ignore it.
- `yaw_rate` is degrees per second, **positive when the head turns toward the
  wearer's left** (counterclockwise seen from above, the usual z-up gyro).
- The app answers every `fire` with `alert` level 2 on that side (so the
  phone and glasses agree even if the frame doesn't buzz on its own), and
  sends `stop` when an alert ends or the wearer glances back at it. `alert`
  replaces any alert before it.
- Suggested buzz patterns (the phone uses the same): level 1 one pulse,
  level 2 three strong pulses about 150 ms apart.
- **`guide` (Call a helper): `{"t":"guide","dir":"L"|"R"|"fwd"|"stop"}`**, a
  direction from a remote helper. It must feel different from alerts, so it
  uses long pulses: `L`/`R` two 400 ms pulses (150 ms gap) on that side,
  `fwd` two 250 ms pulses on both motors, `stop` one steady 1 s buzz on both.
  An approach alert always wins: no guidance while an alert is buzzing.
  `mock_glasses.py` prints each one with its pattern.
