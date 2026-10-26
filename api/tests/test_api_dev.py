"""The API against the dev database, in process, as frontend_api. Skipped unless O_API_TEST_ENV names
an env file whose DB_LABEL is dev and which holds frontend_api's log-in (O_API_DB_*) and dev's
superuser (DB_USER, DB_PASSWORD), which removes the test's accounts afterwards:

    O_API_TEST_ENV=<file> uv run pytest api/tests

frontend_api is NOLOGIN as 061 creates it; on dev, give it LOGIN and a password by hand first.
"""
import asyncio
import os
import uuid

import psycopg
import pytest
from starlette.testclient import TestClient

from api import app, auth, config
from server.config import parse_env_file

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
