"""Whether a tenant's data is current, at an instant: the frontend's bottom bar (GET /api/status,
design/frontend.md §5). Where each source stops, and which meters the graph reads have gone silent.

A meter is silent when its last 15-minute bucket is more than SILENT_AFTER old, the rule node_meters
uses (plant/meters.py). Only the last LOOKBACK is read, so a meter quiet for longer shows no last
reading at all; node_meters looks further back for one node. A meter on a node the site declared
inactive is silent as declared, and listed apart.
"""
import datetime as dt

from . import timewin
from .db import rows
from .meters import SILENT_AFTER

LOOKBACK = dt.timedelta(days=1)

LATEST = """
SELECT (SELECT max("timestamp") FROM telemetry_data
         WHERE tenant_id = %(tenant)s AND "timestamp" > %(since)s AND "timestamp" <= %(at)s) AS minute,
       (SELECT max(bucket) FROM telemetry_15min_agg
         WHERE tenant_id = %(tenant)s AND bucket > %(since)s AND bucket <= %(at)s) AS quarter,
       (SELECT max(last_refreshed) FROM daily_energy_cost_summary
         WHERE tenant_id = %(tenant)s AND daily_bucket >= %(day)s::date - 3) AS summary
"""

# every device the graph reads today, the nodes it is on (a feeder's meter counts for the node fed),
# and its last bucket of any quantity the graph reads from it
METERS = """
WITH m AS (
  SELECT m.device_id, m.quantity_id, coalesce(m.node_id, e.to_node_id) AS node_id
  FROM graph.measurement m
  LEFT JOIN graph.edge e ON e.id = m.edge_id
  WHERE m.tenant_id = %(tenant)s
    AND m.is_active AND m.effective_from <= %(day)s AND (m.effective_to IS NULL OR m.effective_to >= %(day)s)
), last AS (
  SELECT t.device_id, max(t.bucket) AS last
  FROM telemetry_15min_agg t
  JOIN (SELECT DISTINCT device_id, quantity_id FROM m) q USING (device_id, quantity_id)
  WHERE t.tenant_id = %(tenant)s AND t.bucket > %(since)s AND t.bucket <= %(at)s
  GROUP BY t.device_id
)
SELECT d.id AS device_id, d.device_code AS code, d.device_name AS name, l.last,
       array_agg(DISTINCT n.id ORDER BY n.id) AS node_ids,
       array_agg(DISTINCT n.node_code ORDER BY n.node_code) AS nodes,
       bool_and(n.attrs->>'site_status' = 'inactive') AS declared
FROM (SELECT DISTINCT device_id, node_id FROM m) dm
JOIN devices d ON d.id = dm.device_id
JOIN graph.node n ON n.id = dm.node_id
LEFT JOIN last l ON l.device_id = d.id
GROUP BY d.id, d.device_code, d.device_name, l.last
ORDER BY d.device_code
"""


async def document(conn, tenant, tz, at):
    end = at.astimezone(timewin.UTC).replace(tzinfo=None)
    p = {"tenant": tenant, "at": end, "since": end - LOOKBACK, "day": at.astimezone(tz).date()}
    latest = (await rows(conn, LATEST, p))[0]
    meters = await rows(conn, METERS, p)
    silent = [m for m in meters if m["last"] is None or end - m["last"] > SILENT_AFTER]
    summary = latest["summary"]
    return {
        "at": timewin.iso(at),
        "latest_minute": timewin.local_iso(latest["minute"], tz),
        "latest_quarter": timewin.local_iso(latest["quarter"], tz),
        "summary_refreshed": timewin.iso(summary.astimezone(tz)) if summary else None,
        "lookback_hours": int(LOOKBACK.total_seconds() // 3600),
        "meters": len(meters),
        "silent": [{"device_id": m["device_id"], "code": m["code"], "name": m["name"],
                    "last_reading": timewin.local_iso(m["last"], tz), "nodes": m["nodes"], "node_ids": m["node_ids"],
                    "declared": bool(m["declared"])} for m in silent],
    }
