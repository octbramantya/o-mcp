"""The API against the dev database, in process, as frontend_api. Skipped unless O_API_TEST_ENV names
an env file whose DB_LABEL is dev and which holds frontend_api's log-in (O_API_DB_*) and dev's
superuser (DB_USER, DB_PASSWORD), which removes the test's accounts afterwards:

    O_API_TEST_ENV=<file> uv run pytest api/tests

frontend_api is NOLOGIN as 061 creates it; on dev, give it LOGIN and a password by hand first.
"""
import asyncio
import copy
import datetime as dt
import json
import os
import pathlib
import sys
import uuid

import jsonschema
import psycopg
import pytest
from starlette.testclient import TestClient

from api import app, auth, config
from server.config import parse_env_file

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from check_subgraph import strict  # noqa: E402

ENV = os.environ.get("O_API_TEST_ENV")
pytestmark = pytest.mark.skipif(not ENV, reason="O_API_TEST_ENV not set")
TENANT = 3
JSON = {"content-type": "application/json"}


@pytest.fixture(scope="module")
def env():
    cfg = config.load(ENV)
    if cfg.db_label != "dev":
        pytest.exit(f"O_API_TEST_ENV targets {cfg.db_label}, not dev")
    raw = parse_env_file(ENV)
    su = dict(host=cfg.db_host, port=cfg.db_port, dbname=cfg.db_name, user=raw["DB_USER"],
              password=raw["DB_PASSWORD"], sslmode=cfg.db_sslmode)
    run = uuid.uuid4().hex[:8]
    yield cfg, su, run
    with psycopg.connect(**su) as conn:
        ids = [r[0] for r in conn.execute("SELECT id FROM frontend.app_user WHERE email LIKE %s", (f"%+{run}@%",))]
        conn.execute("DELETE FROM frontend.audit WHERE actor_id = ANY(%s) OR target_user_id = ANY(%s)"
                     " OR email LIKE %s", (ids, ids, f"%+{run}@%"))
        conn.execute("DELETE FROM frontend.session WHERE user_id = ANY(%s)", (ids,))
        conn.execute("DELETE FROM frontend.dashboard WHERE owner_id = ANY(%s)", (ids,))
        conn.execute("UPDATE frontend.app_user SET created_by = NULL WHERE id = ANY(%s)", (ids,))
        conn.execute("DELETE FROM frontend.app_user WHERE id = ANY(%s)", (ids,))


@pytest.fixture(scope="module")
def client(env):
    cfg, _, _ = env
    with TestClient(app.build(cfg), base_url="https://testserver") as c:
        yield c


def email(env, who):
    return f"{who}+{env[2]}@example.com"


def post(c, path, body=None):
    return c.post(path, json=body or {})


def login(c, address, password):
    c.cookies.clear()
    return post(c, "/api/login", {"email": address, "password": password})


def audited(env, event, address):
    with psycopg.connect(**env[1]) as conn:
        return conn.execute("SELECT count(*) FROM frontend.audit WHERE event = %s AND lower(email) = lower(%s)",
                            (event, address)).fetchone()[0]


def test_accounts_sessions_and_tenants(env, client):
    c = client
    boss = email(env, "boss")
    temp = asyncio.run(app.create_super_admin(env[0], boss))

    # A first log-in reaches nothing but the password change.
    r = login(c, boss, temp)
    assert r.status_code == 200 and r.json()["must_change_password"] is True
    cookie = r.headers["set-cookie"].lower()
    assert all(a in cookie for a in ("httponly", "secure", "samesite=strict"))
    assert c.get("/api/admin/users").json()["error"] == "must_change_password"
    assert post(c, "/api/password", {"current_password": "wrong", "new_password": "x" * 12}).status_code == 403
    assert post(c, "/api/password", {"current_password": temp, "new_password": "short"}).status_code == 400
    r = post(c, "/api/password", {"current_password": temp, "new_password": "boss password 1"})
    assert r.status_code == 200 and r.json()["must_change_password"] is False
    assert c.post("/api/tenant", content=b"tenant_id=3",
                  headers={"content-type": "application/x-www-form-urlencoded"}).status_code == 415

    # Accounts: a user has one tenant, an admin none, and emails are unique ignoring case.
    alice, root = email(env, "alice"), email(env, "root")
    r = post(c, "/api/admin/users", {"email": alice, "role": "user", "tenant_id": TENANT})
    assert r.status_code == 201
    alice_id, alice_temp = r.json()["user"]["id"], r.json()["temporary_password"]
    assert post(c, "/api/admin/users", {"email": alice.upper(), "role": "user", "tenant_id": TENANT}).status_code == 409
    assert post(c, "/api/admin/users", {"email": root, "role": "admin", "tenant_id": TENANT}).status_code == 400
    assert post(c, "/api/admin/users", {"email": root, "role": "user"}).status_code == 400
    r = post(c, "/api/admin/users", {"email": root, "role": "admin"})
    root_temp = r.json()["temporary_password"]
    me = c.get("/api/me").json()
    assert post(c, f"/api/admin/users/{me['user']['id']}/disable").status_code == 403

    # A user's tenant is fixed: naming another is refused, not filtered.
    assert login(c, alice, alice_temp).status_code == 200
    r = post(c, "/api/password", {"current_password": alice_temp, "new_password": "alice password 1"})
    assert r.status_code == 200
    me = c.get("/api/me").json()
    assert me["tenant"]["id"] == TENANT and [t["id"] for t in me["tenants"]] == [TENANT]
    assert post(c, "/api/tenant", {"tenant_id": TENANT}).status_code == 200
    assert post(c, "/api/tenant", {"tenant_id": TENANT + 1}).status_code == 403
    assert c.get("/api/admin/users").status_code == 403
    alice_cookie = c.cookies.get(auth.COOKIE)

    # An admin starts with no tenant and switches; each switch is audited.
    assert login(c, root, root_temp).status_code == 200
    post(c, "/api/password", {"current_password": root_temp, "new_password": "root password 1"})
    assert c.get("/api/me").json()["tenant"] is None
    r = post(c, "/api/tenant", {"tenant_id": TENANT})
    assert r.status_code == 200 and r.json()["tenant"]["name"] == "PRS"
    assert post(c, "/api/tenant", {"tenant_id": 999_999}).status_code == 404
    assert audited(env, "tenant_switched", root) == 1
    assert c.get("/api/admin/users").status_code == 403

    # A reset ends the user's sessions; disabling refuses the right password.
    login(c, boss, "boss password 1")
    r = post(c, f"/api/admin/users/{alice_id}/reset-password")
    alice_temp = r.json()["temporary_password"]
    boss_cookie = c.cookies.get(auth.COOKIE)
    c.cookies.clear()
    c.cookies.set(auth.COOKIE, alice_cookie)
    assert c.get("/api/me").status_code == 401
    c.cookies.clear()
    c.cookies.set(auth.COOKIE, boss_cookie)
    assert post(c, f"/api/admin/users/{alice_id}/disable").status_code == 200
    assert login(c, alice, alice_temp).status_code == 401
    c.cookies.set(auth.COOKIE, boss_cookie)
    assert post(c, f"/api/admin/users/{alice_id}/enable").status_code == 200
    assert login(c, alice, alice_temp).json()["must_change_password"] is True

    # Five failures for one email (the disabled try was the first) lock it out, right password or not.
    for _ in range(auth.LIMIT_EMAIL - 1):
        assert login(c, alice, "not the password").status_code == 401
    assert login(c, alice, alice_temp).status_code == 429
    assert audited(env, "login_failed", alice) == auth.LIMIT_EMAIL + 1   # and the locked-out try

    # Log-out ends the session.
    c.cookies.set(auth.COOKIE, boss_cookie)
    assert post(c, "/api/logout").status_code == 200
    c.cookies.set(auth.COOKIE, boss_cookie)
    assert c.get("/api/me").status_code == 401


DAY = "2026-10-21"      # a site day with minute data, 15-minute buckets and the daily summary on dev
OLD = "2026-10-19"      # before dev's minute data
PLN, A5 = 61, 75        # INCOMING_PLN, LVMDB_A5


def values(c, nodes, start, end, quantity="ACTIVE_ENERGY_DELIVERED"):
    return c.get("/api/values", params={"quantity": quantity, "nodes": ",".join(map(str, nodes)),
                                        "start": start, "end": end})


def test_values_by_resolution_and_tenant(env, client):
    c = client
    boss, bob, ada = email(env, "boss2"), email(env, "bob"), email(env, "ada")
    temp = asyncio.run(app.create_super_admin(env[0], boss))
    login(c, boss, temp)
    post(c, "/api/password", {"current_password": temp, "new_password": "boss password 2"})
    temps = {bob: post(c, "/api/admin/users", {"email": bob, "role": "user", "tenant_id": TENANT}),
             ada: post(c, "/api/admin/users", {"email": ada, "role": "admin"})}
    accounts = {}
    for who, r in temps.items():
        temp = r.json()["temporary_password"]
        login(c, who, temp)
        post(c, "/api/password", {"current_password": temp, "new_password": "a password 2026"})
        accounts[who] = c.cookies.get(auth.COOKIE)

    # The tenant's pool is its own role, and sees only its tenant.
    async def whoami():
        async with c.app.state.tenants.by_id[TENANT].tx() as conn:
            return (await (await conn.execute("SELECT current_user")).fetchone())[0]
    assert c.portal.call(whoami) == "prs_frontend"

    # An admin reads nothing until they choose a site.
    c.cookies.clear()
    c.cookies.set(auth.COOKIE, accounts[ada])
    assert values(c, [PLN], f"{DAY}T00:00", f"{DAY}T06:00").status_code == 409
    post(c, "/api/tenant", {"tenant_id": TENANT})
    assert values(c, [PLN], f"{DAY}T00:00", f"{DAY}T06:00").status_code == 200

    c.cookies.clear()
    c.cookies.set(auth.COOKIE, accounts[bob])
    # A short window older than the minute data is drawn from 15-minute buckets.
    old = values(c, [PLN], f"{OLD}T10:07", f"{OLD}T11:00").json()
    assert old["resolution"] == "15min" and old["window"]["start"].startswith(f"{OLD}T10:00")
    assert old["values"][0]["value"] is not None

    # A window running past the 15-minute data says where it stops.
    with psycopg.connect(**env[1]) as conn:
        last = conn.execute("SELECT max(bucket) FROM telemetry_15min_agg WHERE tenant_id = %s",
                            (TENANT,)).fetchone()[0]
    tz = c.app.state.tenants.by_id[TENANT].tz
    stop = (last + dt.timedelta(minutes=15)).replace(tzinfo=dt.UTC).astimezone(tz)
    r = values(c, [PLN], (stop - dt.timedelta(hours=7)).isoformat(timespec="minutes"),
               (stop + dt.timedelta(hours=1)).isoformat(timespec="minutes")).json()
    assert r["resolution"] == "15min" and r["source"] == "telemetry_15min_agg"
    assert r["data_until"] == stop.isoformat(timespec="minutes")
    assert "DATA_INCOMPLETE" in [f["code"] for f in r["findings"]]

    # Refusals: an id the role can't see, a quantity the solver can't resolve.
    r = values(c, [999_999], f"{DAY}T00:00", f"{DAY}T06:00")
    assert r.status_code == 400 and "999999" in r.json()["message"]
    assert values(c, [PLN], f"{DAY}T00:00", f"{DAY}T06:00", quantity="PF_TOTAL").status_code == 400

    # Four 6-hour windows at minute resolution add up to the day from the daily summary.
    quarters = [values(c, [PLN, A5], f"{DAY}T{h:02d}:00", f"{DAY}T{h + 6:02d}:00" if h < 18 else "2026-10-22T00:00")
                .json() for h in (0, 6, 12, 18)]
    assert {q["resolution"] for q in quarters} == {"minute"}
    assert not [f for q in quarters for f in q["findings"] if f["code"] == "DATA_INCOMPLETE"]
    assert all(v["value"] is not None for q in quarters for v in q["values"])
    if c.app.state.tenants.by_id[TENANT].vocab.shift_names == ["UNKNOWN"]:
        pytest.skip("dev has no tenant_shift_periods rows, so the daily summary filters to nothing; "
                    "rebuild dev with tools/dev_refresh.sh, which copies them")
    day = values(c, [PLN, A5], f"{DAY}T00:00", "2026-10-22T00:00").json()
    assert day["resolution"] == "day" and all(v["origin"] != "NONE" for v in day["values"])
    assert day["source"] == "daily_energy_cost_summary" and day["data_until"].startswith("2026-10-22T00:00")
    assert "DATA_INCOMPLETE" not in [f["code"] for f in day["findings"]]
    for i, v in enumerate(day["values"]):
        minutes = sum(q["values"][i]["value"] for q in quarters)
        assert abs(minutes - v["value"]) <= max(1, 0.01 * v["value"]), (v["code"], minutes, v["value"])


def account(c, who, role="user"):
    """A new account with its password changed, logged in; returns its cookie. c must hold a super
    admin's cookie, which it holds again afterwards."""
    admin = c.cookies.get(auth.COOKIE)
    r = post(c, "/api/admin/users", {"email": who, "role": role} | ({"tenant_id": TENANT} if role == "user" else {}))
    temp = r.json()["temporary_password"]
    login(c, who, temp)
    post(c, "/api/password", {"current_password": temp, "new_password": "a password 2026"})
    cookie = c.cookies.get(auth.COOKIE)
    c.cookies.clear()
    c.cookies.set(auth.COOKIE, admin)
    return cookie


def as_(c, cookie):
    c.cookies.clear()
    c.cookies.set(auth.COOKIE, cookie)


DOC = {"time": {"from": "now-24h", "to": "now"}, "refresh": None, "channels": {"A": {"kind": "node", "id": PLN}},
       "widgets": [{"id": "w1", "type": "value", "title": None, "x": 0, "y": 0, "w": 6, "h": 4, "channel": "A",
                    "settings": {"quantity": "ACTIVE_ENERGY_DELIVERED", "nodes": [PLN]}}]}


def test_dashboards_owner_only_and_admin_read_only(env, client):
    c = client
    boss = email(env, "boss3")
    temp = asyncio.run(app.create_super_admin(env[0], boss))
    login(c, boss, temp)
    post(c, "/api/password", {"current_password": temp, "new_password": "boss password 3"})
    carol, dave, ada = (account(c, email(env, "carol")), account(c, email(env, "dave")),
                        account(c, email(env, "ada3"), "admin"))

    # A user's own dashboard: created, listed, opened.
    as_(c, carol)
    r = post(c, "/api/dashboards", {"title": " Compressors ", "document": DOC, "format_version": 1})
    assert r.status_code == 201
    mine = r.json()
    assert mine["title"] == "Compressors" and mine["document"] == DOC and mine["read_only"] is False
    path = f"/api/dashboards/{mine['id']}"
    assert [d["id"] for d in c.get("/api/dashboards").json()["dashboards"]] == [mine["id"]]
    assert "document" not in c.get("/api/dashboards").json()["dashboards"][0]
    assert c.get(path).json()["document"] == DOC
    for bad in ({"title": "x", "document": [], "format_version": 1},
                {"title": "x", "document": DOC, "format_version": 2},
                {"title": " ", "document": DOC, "format_version": 1},
                {"title": "x", "document": DOC | {"pad": "x" * 300_000}, "format_version": 1},
                {"title": "x", "document": DOC | {"refresh": 5}, "format_version": 1},
                {"title": "x", "document": DOC | {"time": {"from": "yesterday", "to": "now"}}, "format_version": 1},
                {"title": "x", "document": DOC | {"widgets": [DOC["widgets"][0] | {"x": 24}]}, "format_version": 1}):
        assert post(c, "/api/dashboards", bad).status_code == 400
    assert c.get("/api/admin/dashboards").status_code == 403

    # A save from a stale copy is refused; each save moves updated_at on.
    assert post(c, path, {"title": "x", "updated_at": "2026-01-01T00:00:00+00:00"}).status_code == 409
    r = post(c, path, {"title": "Compressors, 2", "updated_at": mine["updated_at"]})
    assert r.status_code == 200 and r.json()["title"] == "Compressors, 2" and r.json()["document"] == DOC
    assert r.json()["updated_at"] != mine["updated_at"]
    assert post(c, path, {"title": "lost", "updated_at": mine["updated_at"]}).status_code == 409

    # Another user can't tell it exists.
    as_(c, dave)
    assert c.get("/api/dashboards").json()["dashboards"] == []
    assert c.get(path).status_code == 404
    assert post(c, path, {"title": "x", "updated_at": mine["updated_at"]}).status_code == 404
    assert post(c, f"{path}/copy").status_code == 404 and post(c, f"{path}/delete").status_code == 404
    assert c.get("/api/dashboards/x").status_code == 404

    # An admin chooses a site, then lists, opens and copies a user's dashboard, read-only; both audited.
    as_(c, ada)
    assert c.get("/api/admin/dashboards").status_code == 409
    post(c, "/api/tenant", {"tenant_id": TENANT})
    listed = c.get("/api/admin/dashboards").json()["dashboards"]
    assert mine["id"] in [d["id"] for d in listed]
    r = c.get(path).json()
    assert r["read_only"] is True and r["owner"]["email"] == email(env, "carol")
    assert audited(env, "dashboard_opened_by_admin", email(env, "ada3")) == 1
    assert post(c, path, {"title": "x", "updated_at": r["updated_at"]}).status_code == 403
    assert post(c, f"{path}/delete").status_code == 403
    r = post(c, f"{path}/copy")
    assert r.status_code == 201 and r.json()["read_only"] is False and r.json()["title"] == "Copy of Compressors, 2"
    copy = r.json()["id"]
    assert audited(env, "dashboard_copied_by_admin", email(env, "ada3")) == 1
    assert [d["id"] for d in c.get("/api/dashboards").json()["dashboards"]] == [copy]

    # The user sees neither the admin's copy nor the admin's own dashboards; deleting hides theirs.
    as_(c, carol)
    assert c.get(f"/api/dashboards/{copy}").status_code == 404
    assert c.get(path).json()["title"] == "Compressors, 2"
    assert post(c, f"{path}/delete").status_code == 200
    assert c.get(path).status_code == 404 and c.get("/api/dashboards").json()["dashboards"] == []
    as_(c, ada)
    assert mine["id"] not in [d["id"] for d in c.get("/api/admin/dashboards").json()["dashboards"]]


def strictly(doc, fmt):
    """doc against its v1 schema with every property required and no other allowed, as the server's tests."""
    schema = strict(copy.deepcopy(json.loads((ROOT / "design" / fmt).read_text())))
    errors = list(jsonschema.Draft202012Validator(schema).iter_errors(doc))
    assert not errors, [e.message for e in errors[:5]]


def test_plant_reads(env, client):
    c = client
    boss = email(env, "boss4")
    temp = asyncio.run(app.create_super_admin(env[0], boss))
    login(c, boss, temp)
    post(c, "/api/password", {"current_password": temp, "new_password": "boss password 4"})
    dan = account(c, email(env, "dan"))
    c.cookies.clear()
    assert c.get("/api/nodes").status_code == 401
    as_(c, dan)

    v = c.get("/api/vocabulary").json()
    strictly(v, "vocabulary-v1.schema.json")

    # The finder, a section and a node's meters, each in the MCP tool's format with node ids.
    found = c.get("/api/nodes", params={"text": "A5", "as_of": DAY}).json()
    strictly(found, "nodelist-v1.schema.json")
    assert A5 in [n["id"] for n in found["nodes"]]
    assert c.get("/api/nodes", params={"type": "NO_SUCH_TYPE"}).status_code == 400
    sec = c.get("/api/section", params={"node": PLN, "as_of": DAY, "depth": 2}).json()
    strictly(sec, "subgraph-v1.schema.json")
    assert [n["id"] for n in sec["nodes"] if n["depth"] == 0] == [PLN] and A5 in [n["id"] for n in sec["nodes"]]
    up = c.get("/api/section", params={"node": A5, "as_of": DAY, "direction": "up", "depth": 3}).json()
    assert PLN in [n["id"] for n in up["nodes"] if n["scope"] == "reached"]
    m = c.get("/api/meters", params={"node": A5, "as_of": DAY}).json()
    strictly(m, "meters-v1.schema.json")
    assert m["node"]["id"] == A5 and m["devices"]

    # A node retired before as_of is refused by its code; an unknown id as such.
    with psycopg.connect(**env[1]) as conn:
        retired = conn.execute("SELECT id FROM graph.node WHERE tenant_id = %s AND node_code = 'MC302_BARU'",
                               (TENANT,)).fetchone()[0]
    r = c.get("/api/meters", params={"node": retired, "as_of": DAY})
    assert r.status_code == 400 and "MC302_BARU" in r.json()["message"]
    assert c.get("/api/section", params={"node": retired, "as_of": "2026-09-01"}).status_code == 200
    assert c.get("/api/section", params={"node": 999_999}).status_code == 400

    # Readings: minutes for a short window within the minute data, adding up to the 15-minute buckets.
    q = {"node": A5, "quantities": "ACTIVE_ENERGY_DELIVERED,PF_TOTAL", "start": f"{DAY}T10:00", "end": f"{DAY}T12:00"}
    short = c.get("/api/readings", params=q).json()
    strictly(short, "readings-v1.schema.json")
    assert short["query"]["interval"] == "minute" and short["query"]["node_id"] == A5
    whole = c.get("/api/readings", params=q | {"interval": "window"}).json()
    assert whole["query"]["interval"] == "window"
    for s, w in zip(short["series"], whole["series"], strict=True):
        assert s["device_id"] == w["device_id"] and s["quantity"] == w["quantity"]
        if s["reading"] == "COUNTER":
            minutes = sum(p["consumption"] for p in s["points"])
            assert len(s["points"]) == 120
            assert abs(minutes - w["points"][0]["consumption"]) <= max(1, 0.01 * minutes), (minutes, w)
        else:
            assert 0 <= min(p["min"] for p in s["points"] if p["min"] is not None) <= 1
    assert c.get("/api/readings", params=q | {"start": f"{OLD}T10:00", "end": f"{OLD}T12:00"}).json()[
        "query"]["interval"] == "15min"
    assert c.get("/api/readings", params=q | {"start": "2026-10-01", "end": "2026-10-22"}).json()[
        "query"]["interval"] == "hour"
    assert c.get("/api/readings", params=q | {"quantities": "NOPE"}).status_code == 400
    r = c.get("/api/readings", params=q | {"start": "2026-08-01", "end": "2026-10-22", "interval": "15min"})
    assert r.status_code == 400 and "points" in r.json()["message"]

    # The sankey and its diagnostics, in whole site days, drawn on the window's last day.
    s = c.get("/api/sankey", params={"start": "2026-10-20", "end": "2026-10-22"}).json()
    assert s["as_of"] == "2026-10-21" and s["window"]["end"].startswith("2026-10-22T00:00")
    assert s["source"] == "daily_energy_cost_summary" and not s["findings"]
    supply = sum(x["value"] for x in s["links"] if x["link_kind"] == "SUPPLY")
    assert supply > 0
    d = c.get("/api/diagnostics", params={"start": "2026-10-20", "end": "2026-10-22"}).json()
    assert d["diagnostics"] and len(d["property_gaps"]) == 31
    assert all(g["node_id"] for g in d["property_gaps"])
    s = c.get("/api/sankey", params={"start": "2026-09-27", "end": "2026-09-29"}).json()
    assert {"PLANT_CHANGED", "DATA_INCOMPLETE"} <= {f["code"] for f in s["findings"]}
    assert c.get("/api/sankey", params={"start": "2026-10-20", "end": "2026-10-22",
                                        "quantity": "THD_VOLTAGE_LN"}).status_code == 400
