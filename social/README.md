# Social server (Together)

A small FastAPI + SQLite server for the Together tab: friends, teams, the team
ring, the weekly star leaderboard, group screen break reminders, and an
opt-in public team page. It is separate from
`backend/` (which runs on a laptop next to the glasses) because everyone's
phones have to reach it over the internet, each from its own hotspot.

**Privacy:** it only ever stores a display name, daily ring percentages and
side quest star counts, friendships, teams and group break times. No sensor data, video, audio, location, email or password.
Signing up returns a random token that stays on the phone. `DELETE /v1/me`
removes a person and everything about them.

The API is listed at the top of `app.py`; interactive docs at `/docs`.

## Run it locally

From the repo root:

```bash
uv venv -p 3.12 social/.venv && uv pip install -p social/.venv -r social/requirements-dev.txt
```

```bash
social/.venv/bin/uvicorn social.app:create_app --factory --port 8000
```

The app uses `http://localhost:8000` by default, which the iOS simulator
reaches directly. Data goes to `social.db` (set `SOCIAL_DB` to change it).

Tests:

```bash
social/.venv/bin/python -m pytest -q social/tests
```

## Deploy (Fly.io)

> The usual deploy is now the combined cloud server (`../cloud/README.md`):
> Together, Call a helper, captions and Muse at one address. The steps below
> deploy Together on its own.

Fly keeps the SQLite file on a volume, so teams and the public team page are
still there after the hackathon for judges to revisit. Creating the Fly
account (it asks for a card even on the free allowance) and logging in is
yours to do.

```bash
brew install flyctl
```

```bash
fly auth login
```

From this folder (`social/`), the first time:

```bash
fly launch --copy-config --no-deploy
```

Keep the name in `fly.toml` or pick another if it's taken. Then create the
volume and deploy:

```bash
fly volumes create social_data --size 1 --region ord
```

```bash
fly deploy
```

It's then at `https://<app>.fly.dev` (check `https://<app>.fly.dev/healthz`).
Later deploys are just `fly deploy`. The machine sleeps when idle and wakes on
the first request in a second or two; set `min_machines_running = 1` in
`fly.toml` during the demo to skip that.

### Point the app at it

Build with the URL baked in:

```bash
flutter run --dart-define=SOCIAL_URL=https://omni-glasses-social.fly.dev
```

or change it on the phone: Settings > Together server. Accounts belong to one
server, so switching signs you out.

## Public team page

A team can turn on **Public team** in the app, which also enters it in the
league. The page at `/t/<public_id>` shows the team's league points and place, its ring and
stars per member, each member's rings and stars, the next screen
break, and the league table (linking to other public teams). It updates in
place every 30 s without reloading. It shows nothing else, and returns 404
while the team is private.
