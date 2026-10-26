"""GET /api/values: one quantity for nodes over a window, solved on the graph (plant/value.py), at the
resolution the window calls for (design/frontend.md §1 decision 9, §3).

    window <= 6 h, starting within the minute data kept   minute   graph.resolution = 'minute'
    whole site days                                       day      unset: electricity energy from the
                                                                   daily summary, the rest from 15-minute buckets
    anything else                                         15min    graph.resolution = '15min'

A short window older than the minute data (production keeps 14 days) is drawn from 15-minute
buckets, not refused. The window is snapped outwards to its resolution (a minute, or 15 minutes)
and the answer says which resolution and window it used, for the widget to label.

Nodes are given by graph.node.id (decision 19) and answered with their code and name as of the
window's last day. An id the tenant's role can't see is refused, as if it didn't exist.
"""
import datetime as dt

from plant import timewin
from plant.db import rows
from plant.errors import PlantError
from plant.value import change_days, combine, cuts, daily, instant_pieces, live_nodes, solve, splits

MINUTE_MAX = dt.timedelta(hours=6)
MAX_DAYS = 92
MAX_NODES = 50
MINUTE, QUARTER = dt.timedelta(minutes=1), dt.timedelta(minutes=15)


def _floor(t, step):
    u = t.astimezone(dt.UTC)
    base = u.replace(minute=0, second=0, microsecond=0)
    return (base + step * ((u - base) // step)).astimezone(t.tzinfo)


def _ceil(t, step):
    f = _floor(t, step)
    return f if f == t else f + step


def _midnight(t):
    return t.timetz().replace(tzinfo=None) == dt.time()


def choose(start, end, oldest_minute):
    """(resolution, start, end): the resolution for a site-time window, and the window snapped to it.
    oldest_minute is the tenant's oldest minute reading (aware), or None if it has none."""
    if _midnight(start) and _midnight(end):
        return "day", start, end
    s, e = _floor(start, MINUTE), _ceil(end, MINUTE)
    if e - s <= MINUTE_MAX and oldest_minute is not None and s >= oldest_minute:
        return "minute", s, e
    return "15min", _floor(start, QUARTER), _ceil(end, QUARTER)


def parse(params, tenant):
    """The query's quantity, node ids and window, or PlantError naming what's wrong."""
    v = tenant.vocab
    qs = {q["code"]: q for q in v.node_value_quantities()}
    code = params.get("quantity")
    if code not in qs:
        raise PlantError(f"quantity must be one of {', '.join(sorted(qs))}.")
    try:
        ids = [int(x) for x in params.get("nodes", "").split(",") if x.strip()]
    except ValueError as e:
        raise PlantError("nodes must be node ids, separated by commas.") from e
    if not ids or len(ids) > MAX_NODES:
        raise PlantError(f"Give between 1 and {MAX_NODES} node ids.")
    w = timewin.window(params.get("start"), params.get("end"), tenant.tz, MAX_DAYS)
    return qs[code], list(dict.fromkeys(ids)), w


def _num(x):
    return None if x is None else round(float(x), 4)


async def run(tenant, q, ids, w):
    v, tz = tenant.vocab, tenant.tz
    derived = q["kind"] == "DERIVED"
    async with tenant.tx() as conn:
        oldest = None
        if w.end - w.start <= MINUTE_MAX + MINUTE:
            t = (await rows(conn, "SELECT min(timestamp) AS t FROM telemetry_data WHERE tenant_id = %s",
                            (tenant.id,)))[0]["t"]
            oldest = t.replace(tzinfo=dt.UTC).astimezone(tz) if t else None
        resolution, start, end = choose(w.start, w.end, oldest)
        is_daily = resolution == "day" and daily(q, v)
        if resolution != "day":
            await conn.execute("SELECT set_config('graph.resolution', %s, true)", (resolution,))

        def bounds(a, b):
            if is_daily:
                return a.replace(tzinfo=None), (b - dt.timedelta(days=1)).replace(tzinfo=None)
            s, e = timewin.Window(a, b).utc()
            return s, e - (MINUTE if resolution == "minute" else QUARTER)

        changes = await cuts(conn, tenant.id, *change_days(start, end))
        every = instant_pieces(start, end, changes)
        plan = every if splits(q, v) else [(start, end, every[-1][2])]
        known = {r["id"]: r for r in await rows(conn, "SELECT id, node_code AS code, node_name AS name"
                                                      " FROM graph.node WHERE tenant_id = %s AND id = ANY(%s)",
                                                (tenant.id, ids))}
        unknown = [i for i in ids if i not in known]
        if unknown:
            raise PlantError(f"No node {', '.join(map(str, unknown))} in this site.")
        live = {n["id"]: n for n in await live_nodes(conn, tenant.id, [d for _, _, d in every])}
        solved = await solve(conn, tenant.id, v, q, plan, bounds)

    values, findings = [], []
    for i in ids:
        n = live.get(i) or known[i]
        c = combine([s.get(i) for s in solved], derived)
        val, origin, parts = c if c else (None, "NONE", (None, None) if derived else None)
        values.append({"node_id": i, "code": n["code"], "name": n["name"], "value": _num(val), "origin": origin,
                       "parts": {q["from"][0]: _num(parts[0]), q["from"][1]: _num(parts[1])} if derived else None})
        if c is None:
            findings.append({"code": "NOT_IN_NETWORK", "node_id": i,
                             "message": f"{n['code']} has no {q['utility'].lower()} connection in this window."})
        elif origin == "NONE":
            findings.append({"code": "NO_VALUE", "node_id": i,
                             "message": f"{n['code']} has no {q['code']} for this window: nothing measured there or "
                                        f"around it to work it out from. This is not zero."})
    if changes:
        on = ", ".join(d.isoformat() for d in changes)
        findings.append({"code": "PLANT_CHANGED", "message": (
            f"The plant changed on {on}; each value was worked out in {len(plan)} pieces." if len(plan) > 1 else
            f"The plant changed on {on}, and {q['code']} can't be combined across pieces, so the window was "
            f"worked out on the network of {plan[0][2]}.")})
    return {"tenant": tenant.id,
            "quantity": {"code": q["code"], "utility": q["utility"], "unit": q["unit"], "kind": q["kind"]},
            "requested": w.as_json(), "window": timewin.Window(start, end).as_json(), "resolution": resolution,
            "pieces": [{"start": timewin.iso(a), "end": timewin.iso(b), "as_of": d.isoformat()} for a, b, d in plan],
            "values": values, "findings": findings}
