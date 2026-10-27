"""What one node's meters read over a window, per interval: an o-mcp/readings v1 document, for the MCP
server's meter_readings and the API's GET /api/readings.

From telemetry_15min_agg, or for the API's short windows from minute telemetry_data (design/frontend.md
§3); the caller decides which. telemetry_15min_agg keeps the last reading in each 15 minutes, not their
mean, so a SAMPLE's statistics there are of those readings. The aggregation follows
quantity_term.reading, server-side: a COUNTER becomes consumption per interval (forward differences,
with the guards graph.device_totals uses), a SAMPLE its mean, min, max and 95th percentile. Power factor
is decoded before any statistic (design/mcp-tools.md, gap 4).
"""
import math

from . import timewin, vocab
from .db import rows
from .errors import PlantError
from .meters import DEVICES

INTERVALS = {"minute": 1 / 60, "15min": 0.25, "hour": 1, "day": 24, "window": None}
MAX_INTERVAL = 999999      # graph.device_totals' ceiling: above it, a register correction, not use

# (table, time column, value column, lookback for the first counter interval) per source
SOURCES = {"15min": ("telemetry_15min_agg", "bucket", "aggregated_value", "1 hour"),
           "minute": ("telemetry_data", '"timestamp"', "value", "15 minutes")}

TEMPLATE = """
WITH raw AS (
  SELECT t.device_id, t.quantity_id, t.{time} AS bucket, t.{value} AS v
  FROM {table} t
  WHERE t.tenant_id = %(tenant)s AND t.device_id = ANY (%(devices)s) AND t.quantity_id = ANY (%(quantities)s)
    AND t.{time} >= %(start)s::timestamp - %(lookback)s::interval   -- a predecessor for the first counter interval
    AND t.{time} < %(end)s
    AND t.{value} IS NOT NULL AND t.{value} <> 'NaN'::numeric
), val AS (
  SELECT r.device_id, r.quantity_id, r.bucket,
         CASE WHEN r.quantity_id = ANY (%(counters)s)
              THEN r.v - lag(r.v) OVER (PARTITION BY r.device_id, r.quantity_id ORDER BY r.bucket) END AS d,
         CASE WHEN NOT r.quantity_id = ANY (%(pf)s) THEN r.v      -- the magnitude, any model (plant/vocab.py)
              WHEN r.v <= -2 THEN NULL                             -- Schneider: no load
              WHEN r.v > 1 THEN 2 - r.v                            -- Schneider: leading import
              WHEN r.v < -1 THEN r.v + 2                           -- Schneider: lagging export
              ELSE abs(r.v) END AS s                               -- -1..1: the PF, whatever the sign means
  FROM raw r
), slot AS (
  SELECT v.*,
         CASE %(interval)s::text
           WHEN '15min' THEN v.bucket
           WHEN 'minute' THEN v.bucket
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
       percentile_cont(0.95) WITHIN GROUP (ORDER BY s) AS p95,
       count(*) AS samples, max(bucket) AS last
FROM slot GROUP BY device_id, quantity_id, slot ORDER BY device_id, quantity_id, slot
"""

SQL = {k: TEMPLATE.format(table=t, time=c, value=val) for k, (t, c, val, _) in SOURCES.items()}


def _num(x):
    return None if x is None else round(float(x), 4)


def points(w, interval, series):
    """How many points a request makes: intervals per series times series."""
    hours = INTERVALS[interval]
    return (1 if hours is None else math.ceil(w.days() * 24 / hours)) * series


def params(tenant, tz, devices, terms, v, start, end, interval, source):
    """The parameters of SQL[source] for these devices (ids) and quantity terms, start and end naive UTC."""
    return {"tenant": tenant, "devices": sorted(devices), "quantities": [t["quantity_id"] for t in terms],
            "start": start, "end": end, "interval": interval, "lookback": SOURCES[source][3],
            "trunc": interval if interval in ("hour", "day") else "hour",
            "tz": tz.key, "max_interval": MAX_INTERVAL,
            "counters": [t["quantity_id"] for t in terms if t["reading"] == "COUNTER"],
            "pf": [v.quantity(c)["quantity_id"] for c in vocab.PF_ENCODED]}


async def document(conn, tenant, v, tz, node, as_of, codes, w, interval, max_points, device=None):
    """node is a row of resolve.live_nodes on as_of. device narrows to one device, by code (str) or id
    (int). Minute intervals read telemetry_data, every other interval the 15-minute buckets."""
    terms = [v.quantity(c) for c in codes]
    mapped = await rows(conn, DEVICES, {"tenant": tenant, "as_of": as_of, "node_id": node["id"]})
    devices = {}
    for m in mapped:
        devices.setdefault(m["device_id"], m)
    if device is not None:
        key = "device_id" if isinstance(device, int) else "device_code"
        devices = {k: d for k, d in devices.items() if d[key] == device}
        if not devices:
            codes_on = sorted({m["device_code"] for m in mapped}) or ["none"]
            raise PlantError(f"No device {device!r} on {node['code']} as of {as_of}. "
                             f"Its devices: {', '.join(codes_on)}.")
    if not devices:
        raise PlantError(f"{node['code']} has no meter of its own or on its feeder as of {as_of}. "
                         f"Use node_value for what the solver infers there.")
    n = points(w, interval, len(devices) * len(terms))
    if n > max_points:
        raise PlantError(f"That is {n} points ({len(devices)} device(s) x {len(terms)} quantities x "
                         f"{points(w, interval, 1)} intervals); the limit is {max_points}. Use a coarser interval, "
                         f"a shorter window, fewer quantities, or one device.")
    chosen = next(iter(devices.values()))["device_code"] if device is not None else None
    start, end = w.utc()
    source = "minute" if interval == "minute" else "15min"
    got = await rows(conn, SQL[source], params(tenant, tz, devices, terms, v, start, end, interval, source))

    series, findings = [], []
    for did, d in sorted(devices.items(), key=lambda kv: kv[1]["device_code"]):
        for t in terms:
            counter = t["reading"] == "COUNTER"
            pts = [{"start": timewin.local_iso(r["slot"], tz),
                    "consumption": _num(r["consumption"]) if counter else None,
                    "mean": None if counter else _num(r["mean"]),
                    "min": None if counter else _num(r["min"]),
                    "max": None if counter else _num(r["max"]),
                    "p95": None if counter else _num(r["p95"]),
                    "samples": r["samples"], "rejected": r["rejected"] if counter else 0}
                   for r in got if r["device_id"] == did and r["quantity_id"] == t["quantity_id"]]
            series.append({"device_id": did, "device": d["device_code"], "device_name": d["device_name"],
                           "quantity": t["code"], "unit": t["unit"], "reading": t["reading"],
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
    return {"schema": "o-mcp/readings", "version": 1,
            "query": {"tenant": tenant, "node": node["code"], "node_id": node["id"], "as_of": as_of,
                      "interval": interval, "window": w.as_json(), "quantities": list(codes),
                      "device": chosen},
            "series": series, "findings": findings}
