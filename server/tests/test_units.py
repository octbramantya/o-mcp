"""Tests that need no database. Run: uv run pytest server/tests"""
import datetime as dt
from zoneinfo import ZoneInfo

import pytest

from server import config, resolve, sqlfile, timewin

JKT = ZoneInfo("Asia/Jakarta")


def test_translate_keeps_casts_and_escapes_percent():
    sql = "SELECT :'root'::date, :depth, x::text, format('%s', :'a'), '10:30'"
    assert sqlfile.translate(sql) == "SELECT %(root)s::date, %(depth)s, x::text, format('%%s', %(a)s), '10:30'"


def test_sld_sql_has_every_variable_sld_py_passes():
    import re
    names = set(re.findall(r"%\((\w+)\)s", sqlfile.load("tools/sld.sql")))
    assert names == {"tenant", "root", "as_of", "depth", "utility", "direction"}


NODES = [{"id": 1, "code": "LVMDB_A5", "name": "LVMDB A5"}, {"id": 2, "code": "LVMDB_A4", "name": "LVMDB_A4"},
         {"id": 3, "code": "MC_MOTOR_9", "name": "MC 9"}]


@pytest.mark.parametrize("given,code,how", [("LVMDB_A5", "LVMDB_A5", False), ("lvmdb a5", "LVMDB_A5", True),
                                            ("LVMDB-A5", "LVMDB_A5", True), ("mc 9", "MC_MOTOR_9", True)])
def test_pick(given, code, how):
    node, said = resolve.pick(NODES, given, "2026-10-12")
    assert node["code"] == code and bool(said) == how


def test_pick_miss_names_nearest():
    with pytest.raises(resolve.NotFound, match="Nearest: LVMDB_A5"):
        resolve.pick(NODES, "LVMBD_A5", "2026-10-12")


def test_window_is_half_open_site_time():
    w = timewin.window("2026-09-28", "2026-10-05", JKT, 31)
    assert w.utc() == (dt.datetime(2026, 9, 27, 17), dt.datetime(2026, 10, 4, 17))
    assert w.as_json() == {"start": "2026-09-28T00:00+07:00", "end": "2026-10-05T00:00+07:00"}


@pytest.mark.parametrize("start,end,match", [("2026-10-05", "2026-10-01", "must be after"),
                                             ("2026-09-01", "2026-10-05", "at most 31"),
                                             ("yesterday", "2026-10-05", "YYYY-MM-DD")])
def test_window_refusals(start, end, match):
    with pytest.raises(timewin.BadWindow, match=match):
        timewin.window(start, end, JKT, 31)


def test_whole_days_refuse_times():
    with pytest.raises(timewin.BadWindow):
        timewin.window("2026-10-01T08:00", "2026-10-02", JKT, 92, whole_days=True)


def test_config_has_no_defaults(monkeypatch):
    for k in list(__import__("os").environ):
        if k.startswith(("DB_", "O_MCP_")):
            monkeypatch.delenv(k)
    with pytest.raises(config.ConfigError, match="missing DB_LABEL.*O_MCP_TZ"):
        config.load()


def _env(monkeypatch, **kw):
    for k in list(__import__("os").environ):
        if k.startswith(("DB_", "O_MCP_")):
            monkeypatch.delenv(k)
    base = dict(DB_LABEL="prod", DB_HOST="h", DB_PORT="6432", DB_NAME="n", DB_USER="u", DB_PASSWORD="p",
                DB_SSLMODE="verify-ca", O_MCP_TOKEN="t" * 32, O_MCP_BIND="127.0.0.1:8080", O_MCP_TENANT="3",
                O_MCP_TZ="Asia/Jakarta")
    for k, v in {**base, **kw}.items():
        if v is not None:
            monkeypatch.setenv(k, v)


@pytest.mark.parametrize("label, mode, cert, match", [
    ("prod", "require", None, "does not check the server's certificate"),
    ("prod", "verify-ca", None, "needs DB_SSLROOTCERT"),
    ("prod", "verify-ca", "/nonexistent.pem", "not found"),
    ("dev", "prefer", "CERT", "does not check certificates"),
    ("dev", "on", None, "must be one of"),
])
def test_config_tls_refusals(monkeypatch, tmp_path, label, mode, cert, match):
    if cert == "CERT":
        (tmp_path / "ca.pem").write_text("x")
        cert = str(tmp_path / "ca.pem")
    _env(monkeypatch, DB_LABEL=label, DB_SSLMODE=mode, DB_SSLROOTCERT=cert)
    with pytest.raises(config.ConfigError, match=match):
        config.load()


def test_config_tls_passes_to_libpq(monkeypatch, tmp_path):
    (tmp_path / "ca.pem").write_text("x")
    _env(monkeypatch, DB_SSLROOTCERT=str(tmp_path / "ca.pem"))
    info = config.load().conninfo()
    assert info["sslmode"] == "verify-ca" and info["sslrootcert"] == str(tmp_path / "ca.pem")
    _env(monkeypatch, DB_LABEL="dev", DB_SSLMODE="require")
    assert "sslrootcert" not in config.load().conninfo()
