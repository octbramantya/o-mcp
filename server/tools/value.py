"""node_value: one resolvable quantity for one or more nodes over a window, from the solver
(graph.get_node_quantity, graph.get_node_derived), with where each value came from.

The solver reads two kinds of bucket, and the window is converted for each (found 2026-10-12):
  - conserved electricity (the energy registers, and PF_TRUE built from them) comes from
    public.daily_energy_cost_summary, whose daily_bucket is a site-time day (refresh_daily_energy_costs
    buckets in Asia/Jakarta) compared inclusively: start day to the last day;
  - everything else (water, air, the non-conserved registers, THD) comes from 15-minute buckets
    stored in UTC, compared inclusively: the UTC instant of start to the last bucket before end.
So the tool takes whole site-time days. Shifts are not filtered: every shift name the tenant has is
passed, plus UNKNOWN, which public.get_shift_period answers for an hour no shift covers.

The plant can change inside a window: the window is cut at its change dates and solved piece by
piece (plant/value.py, shared with the frontend's API), with a PLANT_CHANGED finding.
"""
import datetime as dt

from plant import resolve, timewin
from plant.value import combine, cuts, daily, live_nodes, pieces, solve, splits

from .. import tools
from ..db import rows
from ..errors import ToolError

NAME = "node_value"
TITLE = "Node value"
FORMAT = "values-v1.schema.json"
DESCRIPTION = """\
One quantity for one or more nodes over whole days in site time, from the plant's network model, \
which works out every node, metered or not. Each value has an `origin`: MEASURED (a meter on the \
node), ROLLUP (worked out from neighbouring meters by flow balance), INHERITED (taken from the \
feeder: voltage distortion), DERIVED (computed from other quantities: PF_TRUE), or NONE (no value: \
nothing measured or inferable; never read it as zero). \
Energy and volume are totals over the window; PF_TRUE is the power factor of the window's energy, \
the number to use for a node's power factor; THD_VOLTAGE_LN is the 95th percentile. Windows are \
half-open: `end` is excluded. Quote the values; do not add nodes up yourself, since a board's \
value already includes what it feeds. node_meters says, per node, which quantities are measured \
and which inferred. \
The network is the one in effect on the window's days: when the plant changed inside the window, \
energy and volume are worked out piece by piece, each on the network of its own days, and a \
PLANT_CHANGED finding says so."""

MAX_DAYS = 92
MAX_NODES = 20

DAILY_SOURCE = "daily_energy_cost_summary"


def input_schema(ctx):
    qs = ctx.vocab.node_value_quantities()
    return {
        "type": "object",
        "required": ["nodes", "quantity", "start", "end"],
        "properties": {
            "nodes": {"type": "array", "minItems": 1, "maxItems": MAX_NODES, "uniqueItems": True,
                      "items": tools.node(),
                      "description": "Node codes or names, e.g. [\"INCOMING_PLN\", \"LVMDB_A5\"]."},
            "quantity": {"oneOf": [{"const": q["code"], "description": f"{q['utility']}, {q['unit'] or 'no unit'}. "
                                                                       f"{q['description']}"} for q in qs],
                         "description": "What to work out. Only quantities the network model can resolve."},
            "start": {"type": "string", "format": "date", "description": "First day, site time, YYYY-MM-DD."},
            "end": {"type": "string", "format": "date",
                    "description": f"Day after the last, excluded: a week is start 2026-09-28, end 2026-10-05. At "
                                   f"most {MAX_DAYS} days after start."},
        },
        "additionalProperties": False,
    }


def _num(x):
    return None if x is None else round(float(x), 4)


async def run(ctx, args):
    cfg, v = ctx.config, ctx.vocab
    w = timewin.window(args["start"], args["end"], cfg.tz, MAX_DAYS, whole_days=True)
    q = next(x for x in v.node_value_quantities() if x["code"] == args["quantity"])
    first, end = w.start.date(), w.end.date()
    last_day = end - dt.timedelta(days=1)
    is_daily = daily(q, v)
    if is_daily:
        source, read = DAILY_SOURCE, "site-time days"
    else:
        source = ("telemetry_intervals_water" if q["utility"] == "WATER" and q["rule"]["conserved"]
                  else "telemetry_15min_agg")
        read = "15-minute buckets"

    def bounds(a, b):
        """A piece of whole site days, as the solver's inclusive bounds for this source."""
        piece = timewin.Window(dt.datetime.combine(a, dt.time(), cfg.tz), dt.datetime.combine(b, dt.time(), cfg.tz))
        if is_daily:
            return piece.start.replace(tzinfo=None), (piece.end - dt.timedelta(days=1)).replace(tzinfo=None)
        s, e = piece.utc()
        return s, e - dt.timedelta(minutes=15)

    async with ctx.db.tx(read_only=False) as conn:
        changes = await cuts(conn, cfg.tenant, first, end)
        plan = pieces(first, end, changes) if splits(q, v) else [(first, end, last_day)]
        # a node is found if it is in effect on any piece's day, the latest piece first
        nodes = await live_nodes(conn, cfg.tenant, [d for _, _, d in pieces(first, end, changes)])
        span = last_day.isoformat() if not changes else f"any day from {first} to {last_day}"
        picked, notes, misses = [], [], []
        for given in args["nodes"]:
            try:
                n, how = resolve.pick(nodes, given, span)
            except resolve.NotFound as e:
                misses.append(str(e))
                continue
            if n not in picked:
                picked.append(n)
            if how:
                notes.append(how)
        if misses:
            raise ToolError(" ".join(misses))
        solved = await solve(conn, cfg.tenant, v, q, plan, bounds)
        if source == DAILY_SOURCE:
            last = (await rows(conn, "SELECT max(daily_bucket) AS t FROM daily_energy_cost_summary "
                                     "WHERE tenant_id = %s", (cfg.tenant,)))[0]["t"]
            data_until = None if last is None else timewin.iso((last + dt.timedelta(days=1)).replace(tzinfo=cfg.tz))
        else:
            last = (await rows(conn, "SELECT max(bucket) AS t FROM telemetry_15min_agg WHERE tenant_id = %s "
                                     "AND bucket >= %s AND bucket < %s",
                               (cfg.tenant, w.utc()[0], w.utc()[1] + dt.timedelta(days=1))))[0]["t"]
            data_until = timewin.local_iso(last + dt.timedelta(minutes=15), cfg.tz) if last else None

    values, findings = [], []
    derived = q["kind"] == "DERIVED"
    for n in picked:
        c = combine([s.get(n["id"]) for s in solved], derived)
        val, origin, parts = c if c else (None, "NONE", (None, None) if derived else None)
        row = {"code": n["code"], "name": n["name"], "value": _num(val), "origin": origin,
               "parts": {q["from"][0]: _num(parts[0]), q["from"][1]: _num(parts[1])} if derived else None}
        if c is None:
            findings.append({"code": "NOT_IN_NETWORK", "node": n["code"],
                             "message": f"{n['code']} has no {q['utility'].lower()} connection "
                                        f"{'as of ' + last_day.isoformat() if len(plan) == 1 else 'in this window'}, "
                                        f"so it has no {q['code']}."})
        elif row["origin"] == "NONE":
            findings.append({"code": "NO_VALUE", "node": n["code"],
                             "message": f"{n['code']} has no {q['code']} for this window: nothing measured there or "
                                        f"around it to work it out from"
                                        f"{' on part of it' if len(plan) > 1 else ''}. This is not zero."})
        values.append(row)
    if changes:
        on = ", ".join(d.isoformat() for d in changes)
        findings.append({"code": "PLANT_CHANGED", "message": (
            f"The plant changed on {on}, inside this window; each value was worked out in {len(plan)} pieces, "
            f"each on the network of its own days." if len(plan) > 1 else
            f"The plant changed on {on}, inside this window, and {q['code']} can't be combined across pieces, "
            f"so the whole window was worked out on the network of {last_day}.")})
    if data_until is None or data_until < timewin.iso(w.end):
        findings.append({"code": "DATA_INCOMPLETE",
                         "message": (f"{source} has no data for this window." if data_until is None else
                                     f"{source} has data only up to {data_until}; the window runs to "
                                     f"{timewin.iso(w.end)}, so values are short of the full window.")})
    doc = {"schema": "o-mcp/values", "version": 1,
           "query": {"tenant": cfg.tenant, "nodes": [n["code"] for n in picked], "quantity": q["code"],
                     "as_of": last_day.isoformat(), "window": w.as_json(),
                     "pieces": [{"start": a.isoformat(), "end": b.isoformat(), "as_of": d.isoformat()}
                                for a, b, d in plan]},
           "quantity": {"code": q["code"], "utility": q["utility"], "unit": q["unit"], "kind": q["kind"],
                        "source": source, "read_as": read, "data_until": data_until,
                        "shifts": "all"},
           "values": values, "findings": findings}
    summary = f"{q['code']} for {len(values)} node(s), {timewin.iso(w.start)} to {timewin.iso(w.end)} (excluded): " + \
        "; ".join(f"{r['code']} {r['value'] if r['value'] is not None else 'no value'} ({r['origin']})" for r in values)
    if notes:
        summary = ". ".join(s[0].upper() + s[1:] for s in notes) + ". " + summary
    return doc, summary
