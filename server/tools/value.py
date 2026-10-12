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
"""
import datetime as dt

from .. import resolve, timewin, tools
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
and which inferred."""

MAX_DAYS = 92
MAX_NODES = 20

DAILY_SOURCE = "daily_energy_cost_summary"


def input_schema(ctx):
    qs = ctx.vocab.node_value_quantities()
    return {
        "type": "object",
        "required": ["nodes", "quantity", "start", "end", "as_of"],
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
            "as_of": tools.as_of(ctx, "The network as it was on this day, in site time. Defaults to today; for a "
                                      "past window give its last day if the plant has changed since."),
        },
        "additionalProperties": False,
    }


def daily(q, v):
    """True when the solver reads this quantity from site-time days."""
    rules = [v.quantity(c)["rule"] for c in q["from"]] if q["kind"] == "DERIVED" else [q["rule"]]
    return all(r["utility"] == "ELECTRICITY" and r["conserved"] for r in rules)


def _num(x):
    return None if x is None else round(float(x), 4)


async def run(ctx, args):
    cfg, v = ctx.config, ctx.vocab
    w = timewin.window(args["start"], args["end"], cfg.tz, MAX_DAYS, whole_days=True)
    q = next(x for x in v.node_value_quantities() if x["code"] == args["quantity"])
    if daily(q, v):
        p_start = w.start.replace(tzinfo=None)
        p_end = (w.end - dt.timedelta(days=1)).replace(tzinfo=None)
        source, read = DAILY_SOURCE, "site-time days"
    else:
        p_start, end_utc = w.utc()
        p_end = end_utc - dt.timedelta(minutes=15)
        source = ("telemetry_intervals_water" if q["utility"] == "WATER" and q["rule"]["conserved"]
                  else "telemetry_15min_agg")
        read = "15-minute buckets"
    async with ctx.db.tx(read_only=False) as conn:
        nodes = await resolve.live_nodes(conn, cfg.tenant, args["as_of"])
        picked, notes, misses = [], [], []
        for given in args["nodes"]:
            try:
                n, how = resolve.pick(nodes, given, args["as_of"])
            except resolve.NotFound as e:
                misses.append(str(e))
                continue
            if n not in picked:
                picked.append(n)
            if how:
                notes.append(how)
        if misses:
            raise ToolError(" ".join(misses))
        if q["kind"] == "DERIVED":
            got = await rows(conn, "SELECT * FROM graph.get_node_derived(%s, %s, %s, %s, %s, %s)",
                             (cfg.tenant, q["code"], p_start, p_end, args["as_of"], v.shift_names))
        else:
            got = await rows(conn, "SELECT * FROM graph.get_node_quantity(%s, %s, %s, %s, %s, %s, %s)",
                             (cfg.tenant, q["utility"], q["quantity_id"], p_start, p_end, args["as_of"],
                              v.shift_names))
        if source == DAILY_SOURCE:
            last = (await rows(conn, "SELECT max(daily_bucket) AS t FROM daily_energy_cost_summary "
                                     "WHERE tenant_id = %s", (cfg.tenant,)))[0]["t"]
            data_until = None if last is None else timewin.iso((last + dt.timedelta(days=1)).replace(tzinfo=cfg.tz))
        else:
            last = (await rows(conn, "SELECT max(bucket) AS t FROM telemetry_15min_agg WHERE tenant_id = %s "
                                     "AND bucket >= %s AND bucket < %s",
                               (cfg.tenant, w.utc()[0], w.utc()[1] + dt.timedelta(days=1))))[0]["t"]
            data_until = timewin.local_iso(last + dt.timedelta(minutes=15), cfg.tz) if last else None

    by_id = {r["node_id"]: r for r in got}
    values, findings = [], []
    for n in picked:
        r = by_id.get(n["id"])
        if q["kind"] == "DERIVED":
            val = _num(r["val"]) if r else None
            row = {"code": n["code"], "name": n["name"], "value": val,
                   "origin": "DERIVED" if val is not None else "NONE",
                   "parts": {q["from"][0]: _num(r["p_val"]) if r else None,
                             q["from"][1]: _num(r["q_val"]) if r else None}}
        else:
            origin = r["origin"] if r else "NONE"
            row = {"code": n["code"], "name": n["name"],
                   "value": None if origin == "NONE" or r["val"] is None else _num(r["val"]),
                   "origin": origin if r is not None and r["val"] is not None else "NONE", "parts": None}
        if r is None:
            findings.append({"code": "NOT_IN_NETWORK", "node": n["code"],
                             "message": f"{n['code']} has no {q['utility'].lower()} connection as of {args['as_of']}, "
                                        f"so it has no {q['code']}."})
        elif row["origin"] == "NONE":
            findings.append({"code": "NO_VALUE", "node": n["code"],
                             "message": f"{n['code']} has no {q['code']} for this window: nothing measured there or "
                                        f"around it to work it out from. This is not zero."})
        values.append(row)
    if data_until is None or data_until < timewin.iso(w.end):
        findings.append({"code": "DATA_INCOMPLETE",
                         "message": (f"{source} has no data for this window." if data_until is None else
                                     f"{source} has data only up to {data_until}; the window runs to "
                                     f"{timewin.iso(w.end)}, so values are short of the full window.")})
    doc = {"schema": "o-mcp/values", "version": 1,
           "query": {"tenant": cfg.tenant, "nodes": [n["code"] for n in picked], "quantity": q["code"],
                     "as_of": args["as_of"], "window": w.as_json()},
           "quantity": {"code": q["code"], "utility": q["utility"], "unit": q["unit"], "kind": q["kind"],
                        "source": source, "read_as": read, "data_until": data_until,
                        "shifts": "all"},
           "values": values, "findings": findings}
    summary = f"{q['code']} for {len(values)} node(s), {timewin.iso(w.start)} to {timewin.iso(w.end)} (excluded): " + \
        "; ".join(f"{r['code']} {r['value'] if r['value'] is not None else 'no value'} ({r['origin']})" for r in values)
    if notes:
        summary = ". ".join(s[0].upper() + s[1:] for s in notes) + ". " + summary
    return doc, summary
