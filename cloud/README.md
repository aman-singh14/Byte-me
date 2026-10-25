# Cloud server

One small server with everything the phone needs that isn't next to the glasses,
at one HTTPS address. With it, the app works on cellular or any Wi-Fi, with no laptop:

| Service | Paths | Code |
|---|---|---|
| Together | `/v1/...`, `/t/{id}`, `/healthz` | `social/app.py` |
| Call a helper | `/rooms`, `/h/{room}`, `/ws/wearer/{room}`, `/ws/helper/{room}`, `/livekit-token` | `backend/helper.py` |
| Live captions | `WS /ws/captions` | `backend/captions.py` |
| Muse image questions | `POST /vlm/{feature}` | `backend/vlm.py` |

The laptop backend (`backend/main.py`) still does everything that needs the glasses'
cameras: eye tracking, near-work, rings, rear events and "Ask".

**Keys** (`MUSE_API_KEY`, `LIVEKIT_*`) are Fly secrets on the server and never go in
the app or the image (`.dockerignore` leaves `.env` out).

**Costs are capped**, because anyone who finds the address can use it:
- **Muse:** the `muse.*` caps in `backend/config.yaml`: $5 a day, $10 in all, 6 calls a minute. They're counted in `/data/muse.db`, separately from the laptop's count.
- **Captions:** `CAPTIONS_DAILY_MINUTES`, default 120 a day (about $0.36), plus 4 sessions at once. The count is kept in memory, so a restart starts it over.
- **Helper rooms:** they cost nothing here. LiveKit counts call minutes against its own free allowance.

**Privacy:** nothing new is stored. Together keeps what it always did. Frames, audio and captions only pass through. Access logs are off, because helper links carry room tokens.

## Run it locally

From the repo root (the backend's `.venv` has everything it needs):

```bash
.venv/bin/uvicorn cloud.app:create_app --factory --port 8080
```

Data goes to `./data`; set `DATA_DIR` to change it. Tests:

```bash
PYTHONPATH=. .venv/bin/python -m unittest -v cloud.test_app
```

## Deploy (Fly.io)

`fly.toml` is at the repo root because the image needs `social/` and `backend/`. Run
every command from the repo root. Making the Fly account (it asks for a card) is
yours to do. It costs a few dollars a month: one small machine that sleeps when idle,
and a 1 GB volume.

```bash
brew install flyctl
```

```bash
fly auth login
```

The first time, register the app without deploying. Keep the name in `fly.toml`, or
pick another if it's taken:

```bash
fly launch --copy-config --no-deploy
```

Create the volume for Together and the Muse spend log:

```bash
fly volumes create omni_data --size 1 --region ord
```

Send the keys from `.env` as secrets. The values go to Fly, not into the image:

```bash
fly secrets import < .env
```

Then deploy:

```bash
fly deploy
```

Check `https://<app>.fly.dev/`. It answers with `"ok": true` and the captions
minutes left today. Later deploys are just `fly deploy`.

During a demo, set `min_machines_running = 1` in `fly.toml` so the first request
doesn't wait for the machine to wake. **Never run more than one machine**: helper
rooms and captions sessions live in one process's memory.

If you already deployed `social/` on its own (`omni-glasses-social`), this replaces
it. That app's teams stay on its own volume.

## Point the app at it

```bash
flutter run --release --dart-define=CLOUD_URL=https://omni-glasses.fly.dev
```

That one address covers Together, Call a helper, captions and Muse. `SOCIAL_URL`,
`HELPER_URL` and `CAPTIONS_URL` still override it one service at a time. A Together
address typed into Settings wins over all of them. Add
`--dart-define=FRONT_CAM_URL=...` as before for the helper's front-camera view.
