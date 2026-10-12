"""Every tool against the dev database, in process, each result checked strictly against its
output schema. Skipped unless O_MCP_TEST_ENV names an env file whose DB_LABEL is dev:

    O_MCP_TEST_ENV=.env O_MCP_TEST_WINDOW=2026-09-28:2026-10-04 uv run pytest server/tests

O_MCP_TEST_WINDOW is a stretch of days with telemetry (end excluded); without it the telemetry
tools are skipped. O_MCP_TENANT and O_MCP_TZ come from the environment as for the server.
"""
import asyncio
import copy
import os
import sys

import jsonschema
import pytest

from server import app, config, tools, vocab
from server.db import Database
from server.errors import ToolError

sys.path.insert(0, str(tools.DESIGN.parent / "tools"))
from check_subgraph import strict  # noqa: E402

ENV = os.environ.get("O_MCP_TEST_ENV")
WINDOW = os.environ.get("O_MCP_TEST_WINDOW", "")
pytestmark = pytest.mark.skipif(not ENV, reason="O_MCP_TEST_ENV not set")


@pytest.fixture(scope="module")
def loop():
    lp = asyncio.new_event_loop()
    yield lp
    lp.close()


@pytest.fixture(scope="module")
def ctx(loop):
    os.environ.setdefault("O_MCP_TOKEN", "t" * 32)
    os.environ.setdefault("O_MCP_BIND", "127.0.0.1:0")
    cfg = config.load(ENV)
    if cfg.db_label != "dev":
        pytest.exit(f"O_MCP_TEST_ENV targets {cfg.db_label}, not dev")
    db = Database(cfg)

    async def setup():
        await db.open()
        async with db.tx() as conn:
            return tools.Context(cfg, db, await vocab.load(conn, cfg.tenant))
    c = loop.run_until_complete(setup())
    yield c
    loop.run_until_complete(db.close())


def call(loop, ctx, name, args):
    t = tools.by_name(name)
    schema = t.input_schema(ctx)
    args = app._with_defaults(schema, args)
    app._check(schema, args)
    doc, summary = loop.run_until_complete(t.run(ctx, args))
    errors = list(jsonschema.Draft202012Validator(strict(copy.deepcopy(tools.output_schema(t.FORMAT))))
                  .iter_errors(doc))
    assert not errors, [e.message for e in errors[:5]]
    return doc, summary


def window():
    if not WINDOW:
        pytest.skip("O_MCP_TEST_WINDOW not set")
    start, end = WINDOW.split(":")
    return start, end


def test_vocabulary(loop, ctx):
    doc, _ = call(loop, ctx, "plant_vocabulary", {})
    sub = next(t for t in doc["node_types"] if t["code"] == "SUB_BOARD")
    assert {p["key"] for p in sub["properties"]} >= {"main_breaker_a", "nominal_v"}   # nominal_v is inherited
    assert next(q for q in doc["quantities"] if q["code"] == "PF_TOTAL")["node_value"] is False


def test_vocabulary_miss(loop, ctx):
    with pytest.raises(ToolError, match="Nearest"):
        call(loop, ctx, "plant_vocabulary", {"code": "SUB_BORD"})


def test_find_subtypes(loop, ctx):
    doc, _ = call(loop, ctx, "plant_find", {"type": "SWITCHBOARD", "limit": 200})
    assert {n["type"] for n in doc["nodes"]} <= set(ctx.vocab.subtypes("SWITCHBOARD")) - {"SWITCHBOARD"}
    assert doc["total"] == doc["returned"] > 0


def test_section_down_and_up(loop, ctx):
    down, _ = call(loop, ctx, "plant_section", {"root": "INCOMING_PLN", "depth": 1})
    child = next(n["code"] for n in down["nodes"] if n["depth"] == 1)
    up, _ = call(loop, ctx, "plant_section", {"root": child, "direction": "up", "depth": 1})
    assert up["query"]["direction"] == "up"
    assert "INCOMING_PLN" in {n["code"] for n in up["nodes"] if n["scope"] == "reached"}


def test_meters(loop, ctx):
    _, end = window()
    doc, _ = call(loop, ctx, "node_meters", {"node": "INCOMING_PLN", "as_of": end})
    assert doc["devices"] and doc["resolvable"]


def test_readings_decode_pf(loop, ctx):
    start, end = window()
    doc, _ = call(loop, ctx, "meter_readings", {"node": "INCOMING_PLN", "quantities": ["PF_TOTAL"], "start": start,
                                                "end": end, "interval": "window", "as_of": end})
    pts = [p for s in doc["series"] for p in s["points"]]
    assert pts and all(0 <= p["min"] <= p["max"] <= 1 for p in pts)


def test_value_origins(loop, ctx):
    start, end = window()
    doc, _ = call(loop, ctx, "node_value", {"nodes": ["INCOMING_PLN"], "quantity": "THD_VOLTAGE_LN",
                                            "start": start, "end": end, "as_of": end})
    assert doc["values"][0]["origin"] in ("MEASURED", "INHERITED", "NONE")


def test_tenant_boundary(loop, ctx):
    """For a tenant's role (migration 044): no other tenant's rows, and the base tables refused.
    Skipped for a role that is not tenant-scoped, such as a developer's superuser."""
    import psycopg

    async def check():
        async with ctx.db.pool.connection() as conn:
            other = (await (await conn.execute("SELECT count(*) FROM devices WHERE tenant_id <> %s",
                                               (ctx.config.tenant,))).fetchone())[0]
            if other:
                return "not scoped"
            await conn.rollback()
            for sql in ("SELECT 1 FROM public.devices LIMIT 1", "SELECT 1 FROM public.telemetry_15min_agg LIMIT 1",
                        "SELECT 1 FROM public.telemetry_data LIMIT 1"):
                with pytest.raises(psycopg.errors.InsufficientPrivilege):
                    await conn.execute(sql)
                await conn.rollback()
            n = (await (await conn.execute(
                "SELECT count(*) FROM graph.get_node_quantity(%s, 'ELECTRICITY', 1119, now()::timestamp - interval "
                "'1 day', now()::timestamp, current_date)", (ctx.config.tenant + 1,))).fetchone())[0]
            await conn.rollback()
            assert n == 0, f"the solver answered {n} nodes of tenant {ctx.config.tenant + 1}"
            return "scoped"
    if loop.run_until_complete(check()) == "not scoped":
        pytest.skip(f"role {ctx.config.db_user} is not tenant-scoped")
