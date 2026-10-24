import time
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient

from social.app import create_app


class Clock:
    def __init__(self):
        self.now = 1_800_000_000.0

    def __call__(self):
        return self.now


@pytest.fixture
def clock(monkeypatch):
    c = Clock()
    monkeypatch.setattr(time, "time", c)
    return c


@pytest.fixture
def client(tmp_path, clock):
    return TestClient(create_app(str(tmp_path / "social.db")))


def sign_up(client, name):
    r = client.post("/v1/users", json={"name": name})
    assert r.status_code == 201
    body = r.json()
    return body, {"Authorization": f"Bearer {body['token']}"}


def iso(ts):
    return datetime.fromtimestamp(ts, tz=UTC).isoformat()


def test_sign_up_and_me(client):
    me, auth = sign_up(client, "  Maya   R ")
    assert me["name"] == "Maya R"
    assert len(me["friend_code"]) == 6
    assert client.get("/v1/me", headers=auth).json()["id"] == me["id"]
    assert client.get("/v1/me").status_code == 401
    assert client.get("/v1/me", headers={"Authorization": "Bearer nope"}).status_code == 401
    assert client.post("/v1/users", json={"name": "   "}).status_code == 422


def test_friends_see_ring_percentages_only(client):
    maya, maya_auth = sign_up(client, "Maya")
    sam, sam_auth = sign_up(client, "Sam")
    r = client.post("/v1/friends", json={"code": maya["friend_code"].lower()}, headers=sam_auth)
    assert r.status_code == 201

    client.put("/v1/me/rings", json={"day": "2027-01-15", "heads_up": 80, "outside": 40}, headers=maya_auth)
    friends = client.get("/v1/friends", headers=sam_auth).json()
    assert [(f["name"], f["heads_up"], f["outside"]) for f in friends] == [("Maya", 80, 40)]
    assert set(friends[0]) == {"id", "name", "heads_up", "outside", "stars_week", "quests_week", "ring_week", "day", "nearby_id"}
    # Both ways.
    assert client.get("/v1/friends", headers=maya_auth).json()[0]["name"] == "Sam"

    assert client.put("/v1/me/rings", json={"day": "2027-01-15", "heads_up": 120, "outside": 0},
                      headers=maya_auth).status_code == 422
    assert client.post("/v1/friends", json={"code": sam["friend_code"]}, headers=sam_auth).status_code == 400
    assert client.post("/v1/friends", json={"code": "ZZZZZZ"}, headers=sam_auth).status_code == 404

    client.delete(f"/v1/friends/{maya['id']}", headers=sam_auth)
    assert client.get("/v1/friends", headers=maya_auth).json() == []


def test_stale_rings_show_zero(client, clock):
    maya, maya_auth = sign_up(client, "Maya")
    sam, sam_auth = sign_up(client, "Sam")
    client.post("/v1/friends", json={"code": maya["friend_code"]}, headers=sam_auth)
    client.put("/v1/me/rings", json={"day": "2027-01-15", "heads_up": 80, "outside": 40}, headers=maya_auth)
    clock.now += 2 * 24 * 3600
    assert client.get("/v1/friends", headers=sam_auth).json()[0]["heads_up"] == 0


def test_stars_add_up_over_the_week(client, clock):
    maya, maya_auth = sign_up(client, "Maya")
    sam, sam_auth = sign_up(client, "Sam")
    client.post("/v1/friends", json={"code": maya["friend_code"]}, headers=sam_auth)

    def report(day, stars):
        r = client.put("/v1/me/rings", json={"day": day, "heads_up": 10, "outside": 10, "stars": stars},
                       headers=maya_auth)
        assert r.status_code == 204

    # 2027-01-15 is a Friday; its week started Monday the 11th.
    report("2027-01-10", 9)  # the Sunday before: last week
    report("2027-01-11", 4)
    report("2027-01-14", 2)
    report("2027-01-15", 1)
    report("2027-01-15", 3)  # the same day again replaces it
    assert client.get("/v1/friends", headers=sam_auth).json()[0]["stars_week"] == 9

    # Stars outlast the 36 h ring staleness, but not the week.
    clock.now += 2 * 24 * 3600
    friend = client.get("/v1/friends", headers=sam_auth).json()[0]
    assert (friend["heads_up"], friend["stars_week"]) == (0, 9)
    clock.now += 7 * 24 * 3600
    assert client.get("/v1/friends", headers=sam_auth).json()[0]["stars_week"] == 0
    assert client.put("/v1/me/rings", json={"day": "2027-01-15", "heads_up": 0, "outside": 0, "stars": 31},
                      headers=maya_auth).status_code == 422


def test_groups_and_team_ring(client):
    _, maya = sign_up(client, "Maya")
    _, sam = sign_up(client, "Sam")
    group = client.post("/v1/groups", json={"name": "Byte-me"}, headers=maya).json()
    joined = client.post("/v1/groups/join", json={"code": group["invite_code"]}, headers=sam).json()
    assert [m["name"] for m in joined["members"]] == ["Maya", "Sam"]

    client.put("/v1/me/rings", json={"day": "2027-01-15", "heads_up": 100, "outside": 60}, headers=maya)
    client.put("/v1/me/rings", json={"day": "2027-01-15", "heads_up": 40, "outside": 0}, headers=sam)
    g = client.get("/v1/groups", headers=sam).json()[0]
    assert g["team"] == 50  # (80 + 20) / 2

    assert client.post("/v1/groups/join", json={"code": "NOPE42"}, headers=sam).status_code == 404
    client.post(f"/v1/groups/{g['id']}/leave", headers=sam)
    assert client.get("/v1/groups", headers=sam).json() == []
    assert client.get("/v1/groups", headers=maya).json()[0]["members"][0]["name"] == "Maya"


def test_strangers_cannot_touch_a_group(client):
    _, maya = sign_up(client, "Maya")
    _, eve = sign_up(client, "Eve")
    g = client.post("/v1/groups", json={"name": "Team"}, headers=maya).json()
    assert client.patch(f"/v1/groups/{g['id']}", json={"is_public": True}, headers=eve).status_code == 404
    starts = iso(time.time() + 600)
    assert client.post(f"/v1/groups/{g['id']}/breaks", json={"starts_at": starts}, headers=eve).status_code == 404


def test_group_break_is_a_reminder_for_the_team(client, clock):
    _, maya = sign_up(client, "Maya")
    _, sam = sign_up(client, "Sam")
    g = client.post("/v1/groups", json={"name": "Team"}, headers=maya).json()
    client.post("/v1/groups/join", json={"code": g["invite_code"]}, headers=sam)

    b = client.post(f"/v1/groups/{g['id']}/breaks", json={"starts_at": iso(clock.now + 300)}, headers=maya).json()
    assert (b["status"], b["minutes"], b["by"]) == ("upcoming", 10, "Maya")
    assert client.get("/v1/groups", headers=sam).json()[0]["breaks"][0]["id"] == b["id"]  # everyone sees it

    clock.now += 300 + 60
    assert client.get("/v1/groups", headers=sam).json()[0]["breaks"][0]["status"] == "running"
    assert client.delete(f"/v1/breaks/{b['id']}", headers=sam).status_code == 400  # already started

    clock.now += 600
    assert client.get("/v1/groups", headers=sam).json()[0]["breaks"] == []  # over: gone from the app
    client.patch(f"/v1/groups/{g['id']}", json={"is_public": True}, headers=maya)
    public = client.get(f"/v1/public/{g['public_id']}").json()
    assert public["breaks_taken"] == 1 and public["breaks"][0]["status"] == "over"


def test_break_scheduling_rules(client, clock):
    _, maya = sign_up(client, "Maya")
    g = client.post("/v1/groups", json={"name": "Team"}, headers=maya).json()
    url = f"/v1/groups/{g['id']}/breaks"
    assert client.post(url, json={"starts_at": iso(clock.now - 3600)}, headers=maya).status_code == 400
    assert client.post(url, json={"starts_at": iso(clock.now + 8 * 24 * 3600)}, headers=maya).status_code == 400
    assert client.post(url, json={"starts_at": iso(clock.now), "minutes": 2}, headers=maya).status_code == 422
    b = client.post(url, json={"starts_at": iso(clock.now + 600)}, headers=maya).json()
    assert client.delete(f"/v1/breaks/{b['id']}", headers=maya).status_code == 204
    assert client.get("/v1/groups", headers=maya).json()[0]["breaks"] == []


def test_public_team_page_is_opt_in(client):
    _, maya = sign_up(client, "Maya <script>")
    g = client.post("/v1/groups", json={"name": "Byte-me"}, headers=maya).json()
    assert client.get(f"/t/{g['public_id']}").status_code == 404

    client.patch(f"/v1/groups/{g['id']}", json={"is_public": True}, headers=maya)
    page = client.get(f"/t/{g['public_id']}")
    assert page.status_code == 200
    assert "Byte-me" in page.text and "&lt;script&gt;" in page.text
    assert page.text.count("<script>") == 1  # the page's own updater; the name is escaped
    data = client.get(f"/v1/public/{g['public_id']}").json()
    assert set(data["members"][0]) == {"name", "heads_up", "outside", "stars_week", "ring_week"}  # no ids, codes


def test_league_ranks_public_teams_by_stars_per_member(client):
    def team(name, stars, public=True):
        """A team whose members earned [stars] each this week."""
        g = None
        for i, n in enumerate(stars):
            _, auth = sign_up(client, f"{name}{i}")
            if g is None:
                g = client.post("/v1/groups", json={"name": name}, headers=auth).json()
                first = auth
            else:
                client.post("/v1/groups/join", json={"code": g["invite_code"]}, headers=auth)
            client.put("/v1/me/rings", json={"day": "2027-01-15", "heads_up": 50, "outside": 50, "stars": n},
                       headers=auth)
        client.patch(f"/v1/groups/{g['id']}", json={"is_public": public}, headers=first)
        return g, first

    big, _ = team("Big", [4, 4, 4, 4])  # 4 per member
    small, _ = team("Small", [9, 6])  # 7.5 per member: wins despite fewer stars
    hidden, hidden_auth = team("Hidden", [12], public=False)

    league = client.get("/v1/league", headers=hidden_auth).json()
    # Points: 10 per star per member + the week's average ring (50 for everyone here).
    assert [(r["name"], r["stars"], r["points"], r["rank"], r["mine"]) for r in league] == [
        ("Hidden", 12.0, 170, 1, True),  # my own private team shows for me only
        ("Small", 7.5, 125, 2, False),
        ("Big", 4.0, 90, 3, False),
    ]
    assert league[0]["public_id"] is None and league[1]["public_id"] == small["public_id"]

    page = client.get(f"/v1/public/{big['public_id']}").json()
    assert (page["rank"], page["teams"], page["stars"]) == (2, 2, 4.0)  # private teams aren't in it
    assert [r["name"] for r in page["league"]] == ["Small", "Big"]
    assert "Hidden" not in client.get(f"/t/{small['public_id']}").text


def test_quest_stars_and_ring_average_add_up_over_the_week(client):
    maya, maya_auth = sign_up(client, "Maya")
    _, sam = sign_up(client, "Sam")
    client.post("/v1/friends", json={"code": maya["friend_code"]}, headers=sam)
    for day, ring, quests in [("2027-01-14", 20, {"look_up": 3}), ("2027-01-15", 60, {"look_up": 1, "hang_out": 2})]:
        r = client.put("/v1/me/rings", json={"day": day, "heads_up": ring, "outside": ring,
                                             "stars": sum(quests.values()), "quests": quests}, headers=maya_auth)
        assert r.status_code == 204
    friend = client.get("/v1/friends", headers=sam).json()[0]
    assert friend["quests_week"] == {"look_up": 4, "hang_out": 2}
    assert (friend["stars_week"], friend["ring_week"]) == (6, 40)
    bad = {"day": "2027-01-15", "heads_up": 0, "outside": 0, "quests": {"look_up": 4}}
    assert client.put("/v1/me/rings", json=bad, headers=maya_auth).status_code == 422


def test_team_details_for_public_teams_and_my_own(client):
    _, maya = sign_up(client, "Maya")
    _, eve = sign_up(client, "Eve")
    g = client.post("/v1/groups", json={"name": "Byte-me"}, headers=maya).json()
    client.put("/v1/me/rings", json={"day": "2027-01-15", "heads_up": 80, "outside": 40, "stars": 3,
                                     "quests": {"look_up": 3}}, headers=maya)
    assert client.get(f"/v1/teams/{g['id']}", headers=eve).status_code == 404  # private
    mine = client.get(f"/v1/teams/{g['id']}", headers=maya).json()
    assert (mine["mine"], mine["points"], mine["quests"], mine["people"][0]["name"]) == (True, 90, {"look_up": 3}, "Maya")
    client.patch(f"/v1/groups/{g['id']}", json={"is_public": True}, headers=maya)
    theirs = client.get(f"/v1/teams/{g['id']}", headers=eve).json()
    assert (theirs["mine"], theirs["rank"], theirs["heads_up"]) == (False, 1, 80)
    assert theirs["members"] == 1
    assert "friend_code" not in theirs["people"][0] and "nearby_id" not in theirs["people"][0]


def test_delete_me_removes_everything(client):
    maya, maya_auth = sign_up(client, "Maya")
    _, sam = sign_up(client, "Sam")
    client.post("/v1/friends", json={"code": maya["friend_code"]}, headers=sam)
    client.post("/v1/groups", json={"name": "Solo"}, headers=maya_auth)
    assert client.delete("/v1/me", headers=maya_auth).status_code == 204
    assert client.get("/v1/me", headers=maya_auth).status_code == 401
    assert client.get("/v1/friends", headers=sam).json() == []
