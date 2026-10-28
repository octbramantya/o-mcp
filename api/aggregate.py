"""GET /api/aggregate: one quantity across several nodes over a window, an o-mcp/aggregate v1 document,
for the Aggregate widget (design/frontend.md §1 decision 21, §5 "Aggregate").

    COUNTER with a solver rule, or derived    TOTAL    one figure per node, solved as /api/values
                                                       solves it (api/values.py), metered or not
    SAMPLE                                    SPREAD   per meter: minimum, mean, 95th percentile,
                                                       maximum (plant/aggregate.py)

A spread reads minute telemetry_data for a window of 6 hours or less within the minute data kept,
and 15-minute data otherwise, as Readings does; a total takes /api/values' resolution. The answer
says which. The window is at most a year. The eight power factor registers (PF_TOTAL, PF_A..C,
DPF_*) are a SPREAD of readings decoded to 0..1 first, as readings decodes them (design/mcp-tools.md,
gap 4): refused until 2026-10-28, when the decode was put in front of them. PF_TRUE is a total.
"""
from plant import aggregate, timewin
from plant import vocab as vocabulary
from plant.db import rows
from plant.errors import PlantError

from . import values

MAX_DAYS = 366
MAX_NODES = values.MAX_NODES


def quantity(v, code):
    """(statistic, quantity) for a code: TOTAL with node_value's entry, or SPREAD with the term."""
    total = {q["code"]: q for q in v.node_value_quantities()
             if q["kind"] == "DERIVED" or v.quantity(q["code"])["reading"] == "COUNTER"}
    if code in total:
        return "TOTAL", total[code]
    t = v.quantity(code) if code else None
    if t and t["reading"] == "SAMPLE":
        return "SPREAD", t
    if t:
        raise PlantError(f"{code} is a counter the solver has no rule for, not offered here.")
    raise PlantError("quantity must be a quantity code; GET /api/vocabulary lists them.")


def parse(params, tenant):
    statistic, q = quantity(tenant.vocab, params.get("quantity"))
    try:
        ids = [int(x) for x in params.get("nodes", "").split(",") if x.strip()]
    except ValueError as e:
        raise PlantError("nodes must be node ids, separated by commas.") from e
    if not ids or len(ids) > MAX_NODES:
        raise PlantError(f"Give between 1 and {MAX_NODES} node ids.")
    w = timewin.window(params.get("start"), params.get("end"), tenant.tz, MAX_DAYS)
    return statistic, q, list(dict.fromkeys(ids)), w


async def total(tenant, q, ids, w):
    r = await values.run(tenant, q, ids, w)
    out = [{"node_id": x["node_id"], "code": x["code"], "name": x["name"], "device_id": None, "device": None,
            "device_name": None, "total": x["value"], "origin": x["origin"], "min": None, "mean": None, "p95": None,
            "max": None, "samples": None, "expected": None, "last_reading": None} for x in r["values"]]
    return {"resolution": r["resolution"], "window": r["window"], "source": r["source"],
            "data_until": r["data_until"], "pieces": r["pieces"], "rows": out, "findings": r["findings"]}


async def spread(tenant, t, ids, w):
    async with tenant.tx() as conn:
        known = await rows(conn, "SELECT id FROM graph.node WHERE tenant_id = %s AND id = ANY(%s)", (tenant.id, ids))
        unknown = [i for i in ids if i not in {k["id"] for k in known}]
        if unknown:
            raise PlantError(f"No node {', '.join(map(str, unknown))} in this site.")
        short = w.end - w.start <= values.MINUTE_MAX
        source = "minute" if short and await values.minutes_kept(conn, tenant, w.start) else "15min"
        out, findings, until = await aggregate.spread(conn, tenant.id, tenant.vocab, tenant.tz, ids, t, w, source)
    if until is None or until < w.end:
        name = "telemetry_data" if source == "minute" else "telemetry_15min_agg"
        findings.append({"code": "DATA_INCOMPLETE", "message": (
            f"{name} has no {t['code']} for these meters in this window." if until is None else
            f"The latest {t['code']} reading of these meters ends {timewin.iso(until)}; the window runs to "
            f"{timewin.iso(w.end)}.")})
    return {"resolution": source, "window": w.as_json(),
            "source": "telemetry_data" if source == "minute" else "telemetry_15min_agg",
            "data_until": timewin.iso(until) if until else None, "pieces": [], "rows": out, "findings": findings}


async def run(tenant, statistic, q, ids, w):
    body = await (total(tenant, q, ids, w) if statistic == "TOTAL" else spread(tenant, q, ids, w))
    reading = "DERIVED" if q.get("kind") == "DERIVED" else tenant.vocab.quantity(q["code"])["reading"]
    return {"schema": "o-mcp/aggregate", "version": 1,
            "query": {"tenant": tenant.id, "quantity": q["code"], "nodes": ids, "requested": w.as_json()},
            "quantity": {"code": q["code"], "unit": q["unit"], "description": q["description"],
                         "reading": reading, "decoded": q["code"] in vocabulary.PF_ENCODED},
            "statistic": statistic, **body}
