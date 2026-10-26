import asyncio
import datetime as dt
from zoneinfo import ZoneInfo

import pytest

from api import auth, cache, config, tenants, values
from plant import value


def test_token_hash_is_sha256_of_the_token():
    t = auth.new_token()
    assert len(t) >= 43 and len(auth.token_hash(t)) == 32 and auth.token_hash(t) != auth.token_hash(t + "x")


@pytest.mark.parametrize("new, current, match", [
    ("short", None, "at least 12"),
    ("Someone@Example.com", None, "email"),
    ("the same password", "the same password", "differ"),
])
def test_new_password_refusals(new, current, match):
    with pytest.raises(auth.PasswordRejected, match=match):
        auth.check_new_password(new, "someone@example.com", current)


def test_temporary_password_passes_the_rules():
    auth.check_new_password(auth.temporary_password(), "someone@example.com")


def test_config_has_no_defaults_and_never_reads_db_user(monkeypatch):
    for k in ("DB_LABEL", "DB_HOST", "DB_PORT", "DB_NAME", "DB_SSLMODE", "DB_USER", "DB_PASSWORD",
              "O_API_DB_USER", "O_API_DB_PASSWORD", "O_API_BIND", "O_API_TENANT_3_PASSWORD"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.setenv("DB_USER", "postgres")
    monkeypatch.setenv("DB_PASSWORD", "superuser")
    with pytest.raises(config.ConfigError, match="O_API_DB_USER, O_API_DB_PASSWORD, O_API_BIND"):
        config.load()
    for k, v in dict(DB_LABEL="dev", DB_HOST="h", DB_PORT="5432", DB_NAME="n", DB_SSLMODE="require",
                     O_API_DB_USER="frontend_api", O_API_DB_PASSWORD="p", O_API_BIND="127.0.0.1:1").items():
        monkeypatch.setenv(k, v)
    c = config.load()
    assert (c.conninfo()["user"], c.conninfo()["password"]) == ("frontend_api", "p")


def test_config_refuses_unverified_tls_outside_dev(monkeypatch):
    for k, v in dict(DB_LABEL="prod", DB_HOST="h", DB_PORT="5432", DB_NAME="n", DB_SSLMODE="require",
                     O_API_DB_USER="frontend_api", O_API_DB_PASSWORD="p", O_API_BIND="127.0.0.1:1").items():
        monkeypatch.setenv(k, v)
    with pytest.raises(config.ConfigError, match="does not check the server's certificate"):
        config.load()


# -- resolution, pieces, tenant choice, cache -------------------------------------------------------
JKT = ZoneInfo("Asia/Jakarta")


def t(s):
    return dt.datetime.fromisoformat(s).replace(tzinfo=JKT)


@pytest.mark.parametrize("start, end, oldest, want", [
    ("2026-10-20T10:00", "2026-10-20T16:00", "2026-10-12T00:00", ("minute", "2026-10-20T10:00", "2026-10-20T16:00")),
    ("2026-10-20T10:00:30", "2026-10-20T10:29:10", "2026-10-12T00:00",
     ("minute", "2026-10-20T10:00", "2026-10-20T10:30")),
    # older than the minute data kept: 15-minute buckets, not a refusal
    ("2026-10-01T10:00", "2026-10-01T11:00", "2026-10-12T00:00", ("15min", "2026-10-01T10:00", "2026-10-01T11:00")),
    ("2026-10-20T10:00", "2026-10-20T16:01", "2026-10-12T00:00", ("15min", "2026-10-20T10:00", "2026-10-20T16:15")),
    ("2026-10-20T10:07", "2026-10-20T12:00", None, ("15min", "2026-10-20T10:00", "2026-10-20T12:00")),
    ("2026-10-20T00:00", "2026-10-22T00:00", "2026-10-12T00:00", ("day", "2026-10-20T00:00", "2026-10-22T00:00")),
    ("2026-10-20T00:00", "2026-10-21T06:00", "2026-10-12T00:00", ("15min", "2026-10-20T00:00", "2026-10-21T06:00")),
])
def test_choose_resolution(start, end, oldest, want):
    r, s, e = values.choose(t(start), t(end), oldest and t(oldest))
    assert (r, s, e) == (want[0], t(want[1]), t(want[2]))


def test_instant_pieces_cut_at_midnight():
    cuts = [dt.date(2026, 9, 28)]
    assert value.change_days(t("2026-09-27T18:00"), t("2026-09-28T06:00")) == (dt.date(2026, 9, 27),
                                                                               dt.date(2026, 9, 29))
    assert value.change_days(t("2026-09-27T00:00"), t("2026-09-29T00:00")) == (dt.date(2026, 9, 27),
                                                                               dt.date(2026, 9, 29))
    assert value.instant_pieces(t("2026-09-27T18:00"), t("2026-09-28T06:00"), cuts) == [
        (t("2026-09-27T18:00"), t("2026-09-28T00:00"), dt.date(2026, 9, 27)),
        (t("2026-09-28T00:00"), t("2026-09-28T06:00"), dt.date(2026, 9, 28))]


def _session(**kw):
    return {"tenant_id": 3, "own_tenant_id": 3, "role": "user"} | kw


@pytest.mark.parametrize("session, status", [
    (_session(tenant_id=4), 403),                                  # a user's session on another tenant
    (_session(role="admin", own_tenant_id=None, tenant_id=None), 409),
    (_session(role="admin", own_tenant_id=None, tenant_id=4), 404),
])
def test_tenant_for_session_refusals(session, status):
    ts = tenants.Tenants()
    ts.by_id = {3: "tenant 3"}
    with pytest.raises(tenants.TenantError) as e:
        ts.for_session(session)
    assert e.value.status == status


def test_tenant_for_session():
    ts = tenants.Tenants()
    ts.by_id = {3: "tenant 3", 4: "tenant 4"}
    assert ts.for_session(_session()) == "tenant 3"
    assert ts.for_session(_session(role="admin", own_tenant_id=None, tenant_id=4)) == "tenant 4"


def test_cache_runs_identical_requests_once_and_keeps_no_errors():
    calls = []

    async def compute():
        calls.append(1)
        await asyncio.sleep(0.01)
        return len(calls)

    async def failing():
        raise RuntimeError("no")

    async def main():
        c = cache.Cache()
        got = await asyncio.gather(*(c.get("k", compute) for _ in range(5)))
        assert got == [1] * 5 and await c.get("k", compute) == 1
        for _ in range(2):
            with pytest.raises(RuntimeError):
                await c.get("e", failing)
        assert "e" not in c.done
    asyncio.run(main())
