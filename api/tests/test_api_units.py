import asyncio
import datetime as dt
from zoneinfo import ZoneInfo

import pytest

from api import auth, cache, config, fresh, reads, tenants, values
from plant import timewin, value


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


@pytest.mark.parametrize("start, end, kept, want", [
    ("2026-10-20T10:00", "2026-10-20T16:00", True, ("minute", "2026-10-20T10:00", "2026-10-20T16:00")),
    ("2026-10-20T10:00:30", "2026-10-20T10:29:10", True, ("minute", "2026-10-20T10:00", "2026-10-20T10:30")),
    # older than the minute data kept: 15-minute buckets, not a refusal
    ("2026-10-01T10:00", "2026-10-01T11:00", False, ("15min", "2026-10-01T10:00", "2026-10-01T11:00")),
    ("2026-10-20T10:00", "2026-10-20T16:01", True, ("15min", "2026-10-20T10:00", "2026-10-20T16:15")),
    ("2026-10-20T10:07", "2026-10-20T12:00", False, ("15min", "2026-10-20T10:00", "2026-10-20T12:00")),
    ("2026-10-20T00:00", "2026-10-22T00:00", True, ("day", "2026-10-20T00:00", "2026-10-22T00:00")),
    ("2026-10-20T00:00", "2026-10-21T06:00", True, ("15min", "2026-10-20T00:00", "2026-10-21T06:00")),
])
def test_choose_resolution(start, end, kept, want):
    r, s, e = values.choose(t(start), t(end), kept)
    assert (r, s, e) == (want[0], t(want[1]), t(want[2]))


ELEC = {"utility": "ELECTRICITY", "conserved": True}
WATER = {"utility": "WATER", "conserved": True}
THD = {"utility": "ELECTRICITY", "conserved": False}


@pytest.mark.parametrize("resolution, is_daily, rules, want", [
    ("minute", False, [WATER], {"telemetry_data"}),
    ("day", True, [ELEC, ELEC], {"daily_energy_cost_summary"}),
    ("day", False, [WATER], {"telemetry_intervals_water"}),
    ("15min", False, [ELEC], {"telemetry_15min_agg"}),
    ("15min", False, [THD, WATER], {"telemetry_15min_agg", "telemetry_intervals_water"}),
])
def test_sources_follow_device_totals(resolution, is_daily, rules, want):
    assert values.sources(resolution, is_daily, rules) == want


def test_summary_until_leaves_out_the_quarter_still_arriving():
    jkt = ZoneInfo("Asia/Jakarta")
    day = dt.datetime(2026, 10, 26)
    run = dt.datetime(2026, 10, 26, 6, 30, 0, 210000, tzinfo=dt.UTC)     # 13:30 site time
    assert values.summary_until(day, run, jkt) == dt.datetime(2026, 10, 26, 13, 15, tzinfo=jkt)
    later = dt.datetime(2026, 10, 28, 16, 30, tzinfo=dt.UTC)              # a run two days on
    assert values.summary_until(day, later, jkt) == dt.datetime(2026, 10, 27, tzinfo=jkt)
    assert values.summary_until(day, None, jkt) == dt.datetime(2026, 10, 27, tzinfo=jkt)


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


def test_cache_keeps_an_answer_while_its_version_holds():
    calls = []

    async def compute():
        calls.append(1)
        return len(calls)

    async def main():
        c = cache.Cache(ttl=0)
        assert await c.get("k", compute, ("v1",)) == 1
        assert await c.get("k", compute, ("v1",)) == 1          # past the TTL, the version still holds
        assert await c.get("k", compute, ("v2",)) == 2          # the source moved
        assert await c.get("g", compute) == 3 and await c.get("g", compute) == 4   # no version: TTL only
    asyncio.run(main())


def test_cache_doesnt_share_a_computation_started_at_an_older_version():
    async def slow():
        await asyncio.sleep(0.02)
        return "old"

    async def fast():
        return "new"

    async def main():
        c = cache.Cache()
        first = asyncio.ensure_future(c.get("k", slow, ("v1",)))
        await asyncio.sleep(0)
        assert await c.get("k", fast, ("v2",)) == "new"
        assert await first == "old"
    asyncio.run(main())


UTC = dt.UTC


def test_fresh_until_takes_the_soonest_source_within_bounds():
    now = dt.datetime(2026, 10, 28, 2, 22, 30, tzinfo=UTC)
    m = fresh.Marks(minute=dt.datetime(2026, 10, 28, 2, 22, tzinfo=UTC), quarter="job run",
                    summary="refresh", quarter_next=dt.datetime(2026, 10, 28, 2, 27, 19, tzinfo=UTC), at=now)
    assert m.fresh_until(["quarter"], now) == dt.datetime(2026, 10, 28, 2, 27, 19, tzinfo=UTC)
    assert m.fresh_until(["minute", "quarter"], now) == dt.datetime(2026, 10, 28, 2, 23, tzinfo=UTC)
    assert m.fresh_until(["summary"], now) == now + fresh.HOLD_MAX          # 02:30, capped at 5 minutes
    late = now + dt.timedelta(minutes=3)                                     # the minute feed is behind
    assert m.fresh_until(["minute"], late) == late
    unknown = fresh.Marks(None, None, None, None, now)                       # dev: no job, no data
    assert unknown.fresh_until(["quarter"], now) == now and unknown.fresh_until(["minute"], now) == now
    assert m.version(["quarter", "minute"]) == (dt.datetime(2026, 10, 28, 2, 22, tzinfo=UTC), "job run")


@pytest.mark.parametrize("start, end, interval, want", [
    ("2026-10-28T03:00", "2026-10-28T09:00", "auto", ("minute", "quarter")),
    ("2026-10-27T09:00", "2026-10-28T09:00", "auto", ("quarter",)),
    ("2026-10-28T03:00", "2026-10-28T09:00", "15min", ("quarter",)),
])
def test_readings_sources_follow_auto_interval(start, end, interval, want):
    w = timewin.window(start, end, ZoneInfo("Asia/Jakarta"), 92)
    assert reads.readings_sources(w, interval) == want
