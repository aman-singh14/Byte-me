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
   app sends. Type `fl` / `fr` + Enter to send a fire, `drop` to pause sensor
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
- `screens_test`: every tab and the whole gallery on a 360 dp phone, light/dark, 100%/200% text, failing on any overflow

## Protocol notes for the firmware

- The app listens on **UDP 4210** and replies to the address **and port** each
  datagram came from. The mock's frame sends from (and listens on) 4211.
- Each device sends `{"t":"hello","id":...}` every 2 s, always. Sensor samples
  also count as a hello for the frame.
- The link counts as lost after 1 s without a `sens` sample. The frame should
  treat 1 s without `hb` as "phone lost".
- Optional `"batt": 0-100` in `sens` is shown in the status strip.
- `side` is always the wearer's side. The frame flips Cam B's image sides
  before sending `fire`.
