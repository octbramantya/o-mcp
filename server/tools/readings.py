"""meter_readings: what one node's meters read over a window, per interval.

From public.telemetry_15min_agg only; raw telemetry_data is not exposed (design/mcp-catalogue.md §5,
open 3). The aggregation follows quantity_term.reading, server-side: a COUNTER becomes consumption
per interval (forward differences, with the guards graph.device_totals uses), a SAMPLE its mean, min
and max. Power factor is decoded before any statistic (design/mcp-tools.md, gap 4).
"""
import math

from .. import resolve, timewin, tools, vocab
from ..db import rows
from ..errors import ToolError
from .meters import DEVICES

NAME = "meter_readings"
TITLE = "Meter readings"
FORMAT = "readings-v1.schema.json"
DESCRIPTION = """\
Readings from the meters on one node (on the node or its feeder) over a window, per interval, in \
site time. Energy and volume registers (COUNTER) come back as consumption per interval, never as \
the register itself; instantaneous values (SAMPLE) as the mean, min and max of their 15-minute \
values. Power factor is decoded to 0..1 before any statistic. Windows are half-open: `end` is \
excluded. One point per device, quantity and interval, at most 500 in all: a week at `hour` is \
168 points per series; use `day` or `window` for longer spans. \
A reading is one meter's view. For a node without a meter, totals across nodes, or a power factor \
over a period, use node_value instead: summing children's readings misses unmetered load, and \
averaging power factor samples is not the power factor of the period."""

INTERVALS = {"15min": 0.25, "hour": 1, "day": 24, "window": None}
MAX_POINTS = 500
MAX_DAYS = 31
MAX_INTERVAL = 999999      # graph.device_totals' ceiling: above it, a register correction, not use

SQL = """
WITH raw AS (
  SELECT t.device_id, t.quantity_id, t.bucket, t.aggregated_value AS v
  FROM telemetry_15min_agg t
  WHERE t.tenant_id = %(tenant)s AND t.device_id = ANY (%(devices)s) AND t.quantity_id = ANY (%(quantities)s)
    AND t.bucket >= %(start)s::timestamp - interval '1 hour'   -- a predecessor for the first counter interval
    AND t.bucket < %(end)s
    AND t.aggregated_value IS NOT NULL AND t.aggregated_value <> 'NaN'::numeric
), val AS (
  SELECT r.device_id, r.quantity_id, r.bucket,
         CASE WHEN r.quantity_id = ANY (%(counters)s)
              THEN r.v - lag(r.v) OVER (PARTITION BY r.device_id, r.quantity_id ORDER BY r.bucket) END AS d,
         CASE WHEN NOT r.quantity_id = ANY (%(pf)s) THEN r.v      -- the magnitude, any model (server/vocab.py)
              WHEN r.v <= -2 THEN NULL                             -- Schneider: no load
              WHEN r.v > 1 THEN 2 - r.v                            -- Schneider: leading import
              WHEN r.v < -1 THEN r.v + 2                           -- Schneider: lagging export
              ELSE abs(r.v) END AS s                               -- -1..1: the PF, whatever the sign means
  FROM raw r
), slot AS (
  SELECT v.*,
         CASE %(interval)s::text
           WHEN '15min' THEN v.bucket
           WHEN 'window' THEN %(start)s::timestamp
           ELSE (date_trunc(%(trunc)s::text, (v.bucket AT TIME ZONE 'UTC') AT TIME ZONE %(tz)s::text)
                 AT TIME ZONE %(tz)s::text) AT TIME ZONE 'UTC'
         END AS slot
  FROM val v WHERE v.bucket >= %(start)s
)
SELECT device_id, quantity_id, slot,
       sum(CASE WHEN d IS NULL OR d < 0 OR d > %(max_interval)s THEN 0 ELSE d END) AS consumption,
       count(*) FILTER (WHERE d < 0 OR d > %(max_interval)s) AS rejected,
       avg(s) AS mean, min(s) AS min, max(s) AS max,
       count(*) AS samples
FROM slot GROUP BY device_id, quantity_id, slot ORDER BY device_id, quantity_id, slot
"""


def input_schema(ctx):
    return {
        "type": "object",
        "required": ["node", "quantities", "start", "end", "interval", "as_of"],
        "properties": {
            "node": tools.node(),
            "quantities": {"type": "array", "minItems": 1, "maxItems": 8, "uniqueItems": True,
                           "items": {"enum": [q["code"] for q in ctx.vocab.quantities]},
                           "description": "Quantity codes, e.g. ACTIVE_ENERGY_DELIVERED, PF_TOTAL, THD_VOLTAGE_LN. "
                                          "node_meters lists what a node's meters report; plant_vocabulary kind "
                                          "quantity says what each means."},
            "start": {"type": "string", "description": "Window start in site time, YYYY-MM-DD or YYYY-MM-DDTHH:MM."},
            "end": {"type": "string", "description": f"Window end in site time, excluded. At most {MAX_DAYS} days "
                                                     f"after start."},
            "interval": {"enum": list(INTERVALS), "default": "hour",
                         "description": "Point size. 15min is the finest stored; window gives one point for the "
                                        "whole window. hour and day follow site time."},
            "device": {"type": "string", "minLength": 1,
                       "description": "Only this device code, when the node has several meters (node_meters)."},
            "as_of": tools.as_of(ctx, "Which meters were on the node: as on this day, site time. Defaults to "
                                      "today; give a day inside the window if the meters changed since."),
        },
        "additionalProperties": False,
    }


def _num(x):
    return None if x is None else round(float(x), 4)


async def run(ctx, args):
    cfg, v = ctx.config, ctx.vocab
    w = timewin.window(args["start"], args["end"], cfg.tz, MAX_DAYS)
    interval = args["interval"]
    hours = INTERVALS[interval]
    per_series = 1 if hours is None else math.ceil(w.days() * 24 / hours)
    terms = [v.quantity(c) for c in args["quantities"]]
    async with ctx.db.tx() as conn:
        nodes = await resolve.live_nodes(conn, cfg.tenant, args["as_of"])
        node, how = resolve.pick(nodes, args["node"], args["as_of"])
        mapped = await rows(conn, DEVICES, {"tenant": cfg.tenant, "as_of": args["as_of"], "node_id": node["id"]})
        devices = {}
        for m in mapped:
            devices.setdefault(m["device_id"], m)
        if args.get("device"):
            devices = {k: d for k, d in devices.items() if d["device_code"] == args["device"]}
            if not devices:
                codes = sorted({m["device_code"] for m in mapped}) or ["none"]
                raise ToolError(f"No device {args['device']!r} on {node['code']} as of {args['as_of']}. "
                                f"Its devices: {', '.join(codes)}.")
        if not devices:
            raise ToolError(f"{node['code']} has no meter of its own or on its feeder as of {args['as_of']}. "
                            f"Use node_value for what the solver infers there.")
        points = per_series * len(devices) * len(terms)
        if points > MAX_POINTS:
            raise ToolError(f"That is {points} points ({len(devices)} device(s) x {len(terms)} quantities x "
                            f"{per_series} intervals); the limit is {MAX_POINTS}. Use a coarser interval, a shorter "
                            f"window, fewer quantities, or one device.")
        start, end = w.utc()
        got = await rows(conn, SQL, {
            "tenant": cfg.tenant, "devices": sorted(devices), "quantities": [t["quantity_id"] for t in terms],
            "start": start, "end": end, "interval": interval,
            "trunc": interval if interval in ("hour", "day") else "hour",
            "tz": cfg.tz.key, "max_interval": MAX_INTERVAL,
            "counters": [t["quantity_id"] for t in terms if t["reading"] == "COUNTER"],
            "pf": [v.quantity(c)["quantity_id"] for c in vocab.PF_ENCODED]})

    series, findings = [], []
    for did, d in sorted(devices.items(), key=lambda kv: kv[1]["device_code"]):
        for t in terms:
            counter = t["reading"] == "COUNTER"
            pts = [{"start": timewin.local_iso(r["slot"], cfg.tz),
                    "consumption": _num(r["consumption"]) if counter else None,
                    "mean": None if counter else _num(r["mean"]),
                    "min": None if counter else _num(r["min"]),
                    "max": None if counter else _num(r["max"]),
                    "samples": r["samples"], "rejected": r["rejected"] if counter else 0}
                   for r in got if r["device_id"] == did and r["quantity_id"] == t["quantity_id"]]
            series.append({"device": d["device_code"], "device_name": d["device_name"], "quantity": t["code"],
                           "unit": t["unit"], "reading": t["reading"],
                           "decoded": t["code"] in vocab.PF_ENCODED, "points": pts})
            label = f"{d['device_code']} ({d['device_name']})"
            if not pts:
                findings.append({"code": "NO_READINGS", "device": d["device_code"], "quantity": t["code"],
                                 "message": f"{label} has no {t['code']} readings between {timewin.iso(w.start)} "
                                            f"and {timewin.iso(w.end)}."})
            rejected = sum(p["rejected"] for p in pts)
            if rejected:
                findings.append({"code": "COUNTER_RESET", "device": d["device_code"], "quantity": t["code"],
                                 "message": f"{label}'s {t['code']} register went backwards or jumped "
                                            f"implausibly {rejected} time(s); those intervals count as zero, so "
                                            f"its consumption is a lower bound."})
    doc = {"schema": "o-mcp/readings", "version": 1,
           "query": {"tenant": cfg.tenant, "node": node["code"], "as_of": args["as_of"], "interval": interval,
                     "window": w.as_json(), "quantities": args["quantities"], "device": args.get("device")},
           "series": series, "findings": findings}
    n = sum(len(s["points"]) for s in series)
    summary = (f"{node['code']}: {len(series)} series, {n} points, {interval} intervals from {timewin.iso(w.start)} "
               f"to {timewin.iso(w.end)} (excluded); {len(findings)} finding(s).")
    return doc, (f"{how[0].upper()}{how[1:]}. " if how else "") + summary
