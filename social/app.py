"""Omni Glasses social server: friends, groups, team rings, group screen
breaks, and side quest stars for the weekly friends leaderboard and the
team league.

Only ring percentages and star counts leave a phone. The server never sees sensor data,
video, audio, location or anything identifying beyond the display name a
person picks. No passwords: the app gets a random token when it signs up.

    POST   /v1/users                  {"name"} -> me + token (once)
    GET    /v1/me                     me
    PATCH  /v1/me                     {"name"}
    DELETE /v1/me                     delete me and everything about me
    PUT    /v1/me/rings               {"day": "YYYY-MM-DD", "heads_up": 0-100, "outside": 0-100, "stars": 0-30,
                                       "quests": {"look_up": 0-3, ...}}
    GET    /v1/friends                friends with today's ring %, this week's ring average and stars
    POST   /v1/friends                {"code"}: add a friend by their friend code (both ways)
    DELETE /v1/friends/{id}
    GET    /v1/groups                 my groups: members' ring %, team ring, breaks
    POST   /v1/groups                 {"name"}
    POST   /v1/groups/join            {"code"}
    POST   /v1/groups/{id}/leave
    PATCH  /v1/groups/{id}            {"is_public"}: join the league, with a read-only page at /t/{public_id}
    GET    /v1/league                 public teams (and mine) ranked by points this week
    GET    /v1/teams/{id}             a team's stats and members, if it's public or mine
    POST   /v1/groups/{id}/breaks     {"starts_at": ISO 8601, "minutes": 5-60}: a reminder for the whole team
    DELETE /v1/breaks/{id}            cancel (before it starts)
    GET    /v1/public/{public_id}     the team page's data, if the group made it public
    GET    /t/{public_id}             the team page

Run: uvicorn social.app:create_app --factory --reload   (SOCIAL_DB=path, default social.db)
"""

import os
import time
from datetime import UTC, datetime

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field, field_validator

from social import page
from social.db import DB

MAX_BREAK_AHEAD_S = 7 * 24 * 3600


class Name(BaseModel):
    name: str = Field(min_length=1, max_length=24)

    @field_validator("name")
    @classmethod
    def strip(cls, v):
        v = " ".join(v.split())
        if not v:
            raise ValueError("name is empty")
        return v


class Code(BaseModel):
    code: str = Field(min_length=4, max_length=12)

    @field_validator("code")
    @classmethod
    def normalize(cls, v):
        return v.strip().upper().replace(" ", "").replace("-", "")


class Rings(BaseModel):
    day: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    heads_up: int = Field(ge=0, le=100)
    outside: int = Field(ge=0, le=100)
    stars: int = Field(default=0, ge=0, le=30)  # side quest stars earned that day
    quests: dict[str, int] = Field(default_factory=dict)  # the same stars by quest

    @field_validator("quests")
    @classmethod
    def check_quests(cls, v):
        if len(v) > 10 or any(len(k) > 32 or not 0 <= n <= 3 for k, n in v.items()):
            raise ValueError("at most 10 quests, 0-3 stars each")
        return v


class GroupPatch(BaseModel):
    is_public: bool


class NewBreak(BaseModel):
    starts_at: datetime
    minutes: int = Field(default=10, ge=5, le=60)


def iso(ts):
    return datetime.fromtimestamp(ts, tz=UTC).isoformat()


def create_app(db_path=None):
    db = DB(db_path or os.environ.get("SOCIAL_DB", "social.db"))
    app = FastAPI(title="Omni Glasses social", version="1")
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

    def me(authorization: str = Header(default="")):
        token = authorization.removeprefix("Bearer ").strip()
        user = db.user_by_token(token) if token else None
        if user is None:
            raise HTTPException(401, "Unknown or missing token")
        return user

    def member_of(group_id, user):
        group = db.group(group_id)
        if group is None or not db.is_member(group_id, user["id"]):
            raise HTTPException(404, "No such group")
        return group

    # --- views ---------------------------------------------------------------

    def user_view(u):
        return {"id": u["id"], "name": u["name"], "friend_code": u["friend_code"], "nearby_id": u["nearby_id"]}

    def person_view(u):
        """What friends and group members see: a name, today's ring
        percentages, and this week's ring average and side quest stars."""
        return {"id": u["id"], "name": u["name"], **db.latest_rings(u["id"])}

    def break_view(b, now):
        """A group screen break is just a reminder: everyone on the team gets
        a nudge to look up and talk. Nothing is measured or reported."""
        end = b["starts_at"] + b["minutes"] * 60
        by = db.user(b["created_by"]) if b["created_by"] else None
        return {
            "id": b["id"],
            "starts_at": iso(b["starts_at"]),
            "ends_at": iso(end),
            "minutes": b["minutes"],
            "status": "upcoming" if now < b["starts_at"] else "running" if now < end else "over",
            "by": by["name"] if by else None,
        }

    def team_percent(people):
        """The team ring: the average of everyone's two rings."""
        if not people:
            return 0
        return round(sum((p["heads_up"] + p["outside"]) / 2 for p in people) / len(people))

    def team_stats(people):
        """A team's numbers for the league. Points = 10 per side quest star
        (per member, this week) + the team's average ring this week, so both
        quests and rings count and a small team can beat a big one."""
        n = len(people)
        if n == 0:
            return {"members": 0, "stars": 0.0, "ring_week": 0, "points": 0, "team": 0,
                    "heads_up": 0, "outside": 0, "quests": {}}
        stars = round(sum(p["stars_week"] for p in people) / n, 1)
        ring_week = round(sum(p["ring_week"] for p in people) / n)
        quests = {}
        for p in people:
            for quest, count in p["quests_week"].items():
                quests[quest] = quests.get(quest, 0) + count
        return {
            "members": n,
            "stars": stars,
            "ring_week": ring_week,
            "points": round(stars * 10 + ring_week),
            "team": team_percent(people),
            "heads_up": round(sum(p["heads_up"] for p in people) / n),
            "outside": round(sum(p["outside"] for p in people) / n),
            "quests": quests,  # team total this week, by quest
        }

    def league(extra=()):
        """Public teams, plus the groups in [extra] (the asker's own, even if
        private), most points first."""
        groups = {g["id"]: g for g in db.public_groups()}
        for group_id in extra:
            groups[group_id] = db.group(group_id)
        rows = []
        for g in groups.values():
            people = [person_view(u) for u in db.members(g["id"])]
            rows.append({
                "id": g["id"],
                "name": g["name"],
                "public_id": g["public_id"] if g["is_public"] else None,
                **team_stats(people),
            })
        rows.sort(key=lambda r: (-r["points"], -r["stars"], r["name"].lower()))
        for rank, r in enumerate(rows, 1):
            r["rank"] = rank
        return rows

    def group_view(g, user_id):
        people = [person_view(u) for u in db.members(g["id"])]
        now = time.time()
        return {
            "id": g["id"],
            "name": g["name"],
            "invite_code": g["invite_code"],
            "public_id": g["public_id"],
            "is_public": bool(g["is_public"]),
            "team": team_percent(people),
            "members": people,
            "breaks": [break_view(b, now) for b in db.breaks_of(g["id"], since=now)],
        }

    def public_view(g):
        people = sorted((person_view(u) for u in db.members(g["id"])), key=lambda p: -p["stars_week"])
        now = time.time()
        breaks = [break_view(b, now) for b in db.recent_breaks(g["id"])]
        ranked = league()
        mine = next(r for r in ranked if r["id"] == g["id"])
        shown = [r for r in ranked if r["rank"] <= 5 or r is mine]
        return {
            "name": g["name"],
            **team_stats(people),
            "rank": mine["rank"],
            "teams": len(ranked),
            "league": [{k: r[k] for k in ("rank", "name", "members", "points", "stars", "public_id")} | {"me": r is mine}
                       for r in shown],
            "members": [{k: p[k] for k in ("name", "heads_up", "outside", "stars_week", "ring_week")} for p in people],
            "breaks": [{k: b[k] for k in ("starts_at", "minutes", "status")} for b in breaks],
            "breaks_taken": sum(1 for b in breaks if b["status"] != "upcoming"),
        }

    # --- me ------------------------------------------------------------------

    @app.post("/v1/users", status_code=201)
    def sign_up(body: Name):
        user, token = db.create_user(body.name)
        return {**user_view(user), "token": token}

    @app.get("/v1/me")
    def get_me(user=Depends(me)):
        return user_view(user)

    @app.patch("/v1/me")
    def rename(body: Name, user=Depends(me)):
        db.rename(user["id"], body.name)
        return user_view(db.user(user["id"]))

    @app.delete("/v1/me", status_code=204)
    def delete_me(user=Depends(me)):
        for g in db.groups_of(user["id"]):
            db.leave_group(g["id"], user["id"])
        db.delete_user(user["id"])

    @app.put("/v1/me/rings", status_code=204)
    def put_rings(body: Rings, user=Depends(me)):
        db.set_rings(user["id"], body.day, body.heads_up, body.outside, body.stars, body.quests)

    # --- friends -------------------------------------------------------------

    @app.get("/v1/friends")
    def friends(user=Depends(me)):
        return [{**person_view(f), "nearby_id": f["nearby_id"]} for f in db.friends(user["id"])]

    @app.post("/v1/friends", status_code=201)
    def add_friend(body: Code, user=Depends(me)):
        friend = db.one("SELECT * FROM users WHERE friend_code = ?", (body.code,))
        if friend is None:
            raise HTTPException(404, "No one has that friend code")
        if friend["id"] == user["id"]:
            raise HTTPException(400, "That's your own code")
        db.add_friend(user["id"], friend["id"])
        return {**person_view(friend), "nearby_id": friend["nearby_id"]}

    @app.delete("/v1/friends/{friend_id}", status_code=204)
    def remove_friend(friend_id: int, user=Depends(me)):
        db.remove_friend(user["id"], friend_id)

    # --- groups --------------------------------------------------------------

    @app.get("/v1/groups")
    def groups(user=Depends(me)):
        return [group_view(g, user["id"]) for g in db.groups_of(user["id"])]

    @app.get("/v1/league")
    def get_league(user=Depends(me)):
        mine = {g["id"] for g in db.groups_of(user["id"])}
        return [{**r, "mine": r["id"] in mine} for r in league(extra=mine)]

    @app.get("/v1/teams/{group_id}")
    def team(group_id: int, user=Depends(me)):
        """Another team's page in the app: its stats and members (names,
        rings, stars). Only public teams, or your own."""
        g = db.group(group_id)
        mine = {m["id"] for m in db.groups_of(user["id"])}
        if g is None or not (g["is_public"] or g["id"] in mine):
            raise HTTPException(404, "No such team, or it's private")
        row = next(r for r in league(extra=mine) if r["id"] == g["id"])
        people = sorted((person_view(u) for u in db.members(g["id"])), key=lambda p: -p["stars_week"])
        return {**row, "mine": g["id"] in mine, "people": people}

    @app.post("/v1/groups", status_code=201)
    def create_group(body: Name, user=Depends(me)):
        return group_view(db.create_group(body.name, user["id"]), user["id"])

    @app.post("/v1/groups/join")
    def join_group(body: Code, user=Depends(me)):
        group = db.group_by_code(body.code)
        if group is None:
            raise HTTPException(404, "No group has that code")
        db.join_group(group["id"], user["id"])
        return group_view(group, user["id"])

    @app.post("/v1/groups/{group_id}/leave", status_code=204)
    def leave_group(group_id: int, user=Depends(me)):
        member_of(group_id, user)
        db.leave_group(group_id, user["id"])

    @app.patch("/v1/groups/{group_id}")
    def patch_group(group_id: int, body: GroupPatch, user=Depends(me)):
        member_of(group_id, user)
        db.set_public(group_id, body.is_public)
        return group_view(db.group(group_id), user["id"])

    # --- group breaks --------------------------------------------------------

    def break_for(break_id, user):
        b = db.brk(break_id)
        if b is None or not db.is_member(b["group_id"], user["id"]):
            raise HTTPException(404, "No such break")
        return b

    @app.post("/v1/groups/{group_id}/breaks", status_code=201)
    def schedule_break(group_id: int, body: NewBreak, user=Depends(me)):
        member_of(group_id, user)
        starts = body.starts_at.timestamp()
        now = time.time()
        if starts < now - 60 or starts > now + MAX_BREAK_AHEAD_S:
            raise HTTPException(400, "Pick a time from now to a week ahead")
        return break_view(db.create_break(group_id, starts, body.minutes, user["id"]), now)

    @app.delete("/v1/breaks/{break_id}", status_code=204)
    def cancel_break(break_id: int, user=Depends(me)):
        b = break_for(break_id, user)
        if time.time() >= b["starts_at"]:
            raise HTTPException(400, "It has already started")
        db.delete_break(break_id)

    # --- public team page ----------------------------------------------------

    def public_group(public_id):
        group = db.group_by_public_id(public_id)
        if group is None:
            raise HTTPException(404, "This team page is private or doesn't exist")
        return group

    @app.get("/v1/public/{public_id}")
    def public_data(public_id: str):
        return public_view(public_group(public_id))

    @app.get("/t/{public_id}", response_class=HTMLResponse)
    def public_page(public_id: str):
        return page.render(public_view(public_group(public_id)))

    @app.get("/healthz")
    def health():
        return {"ok": True}

    return app
