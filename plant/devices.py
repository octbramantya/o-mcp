"""Every device of the site's register as an o-mcp/devicelist v1 document: the API's GET /api/devices,
for the frontend's Reference view (design/frontend.md §5), which finds a device or a quantity without
knowing the node first. Per device: what the register records about it, where the network model reads
it on as_of (the node, or the edge into a node), and which quantities it reported in the last day.

The per-node detail (each quantity's last reading, a silent meter against the site's status, what a
value can be given for) stays in plant/meters.py; this is the index that leads there.
"""
import datetime as dt

from . import timewin
from .db import rows
from .meters import SILENT_AFTER, hardware, observed_at

REPORTED_DAYS = 1        # a week, as meters.py's lookback, reads seven times the buckets for every device

DEVICES = """
SELECT d.id, d.device_code, d.device_name, d.device_type, d.status, d.is_active, d.metadata
FROM devices d
WHERE d.tenant_id = %(tenant)s
ORDER BY d.device_code, d.id
"""

# A measurement in effect, on a node in effect or on an edge in effect between two such nodes. A
# feeder's quantity belongs to the node the edge goes into, as in meters.py.
MAPPINGS = """
WITH live_n AS (
  SELECT n.id, n.node_code FROM graph.node n
  WHERE n.tenant_id = %(tenant)s
    AND n.is_active AND n.effective_from <= %(as_of)s
    AND (n.effective_to IS NULL OR n.effective_to >= %(as_of)s)
), live_e AS (
  SELECT e.id, e.from_node_id, e.to_node_id FROM graph.edge e
  JOIN live_n f ON f.id = e.from_node_id
  JOIN live_n t ON t.id = e.to_node_id
  WHERE e.tenant_id = %(tenant)s
    AND e.is_active AND e.effective_from <= %(as_of)s
    AND (e.effective_to IS NULL OR e.effective_to >= %(as_of)s)
)
SELECT m.device_id, m.quantity_id, m.role, m.multiplier, m.edge_id,
       coalesce(n.id, t.id) AS node_id, coalesce(n.node_code, t.node_code) AS node_code,
       f.node_code AS feeder_from
FROM graph.measurement m
LEFT JOIN live_n n ON n.id = m.node_id
LEFT JOIN live_e e ON e.id = m.edge_id
LEFT JOIN live_n t ON t.id = e.to_node_id
LEFT JOIN live_n f ON f.id = e.from_node_id
WHERE m.tenant_id = %(tenant)s
  AND m.is_active AND m.effective_from <= %(as_of)s
  AND (m.effective_to IS NULL OR m.effective_to >= %(as_of)s)
  AND (n.id IS NOT NULL OR e.id IS NOT NULL)
ORDER BY m.device_id, 7, m.quantity_id
"""

REPORTED = """
SELECT device_id, quantity_id, max(bucket) AS last
FROM telemetry_15min_agg
WHERE tenant_id = %(tenant)s AND bucket >= %(since)s AND bucket < %(until)s
GROUP BY device_id, quantity_id
"""


async def document(conn, tenant, v, tz, as_of):
    """as_of is a date in ISO form."""
    at = observed_at(as_of, tz)
    until = at.astimezone(timewin.UTC).replace(tzinfo=None)
    p = {"tenant": tenant, "as_of": as_of}
    devices = await rows(conn, DEVICES, p)
    mapped = await rows(conn, MAPPINGS, p)
    reported = await rows(conn, REPORTED, {"tenant": tenant, "until": until,
                                           "since": until - dt.timedelta(days=REPORTED_DAYS)})
    by_device, heard = {}, {}
    for m in mapped:
        by_device.setdefault(m["device_id"], []).append(m)
    for r in reported:
        heard.setdefault(r["device_id"], []).append(r)

    def code(qid):
        return (v.quantity_by_id(qid) or {}).get("code")

    out = []
    for d in devices:
        rep = sorted(heard.get(d["id"], []), key=lambda r: r["quantity_id"])
        last = max((r["last"] for r in rep), default=None)
        out.append({
            "device_id": d["id"], "code": d["device_code"], "name": d["device_name"], "type": d["device_type"],
            "declared_status": d["status"], "active": bool(d["is_active"]),
            **hardware(d["metadata"]),
            "graph": [{"quantity_id": m["quantity_id"], "code": code(m["quantity_id"]), "role": m["role"],
                       "multiplier": float(m["multiplier"]),
                       "attached_to": "FEEDER" if m["edge_id"] else "NODE",
                       "node_id": m["node_id"], "node": m["node_code"],
                       "edge": m["edge_id"], "feeder_from": m["feeder_from"]}
                      for m in by_device.get(d["id"], [])],
            "last_reading": timewin.local_iso(last, tz),
            "reporting": last is not None and at - last.replace(tzinfo=timewin.UTC) <= SILENT_AFTER,
            "reported": [{"quantity_id": r["quantity_id"], "code": code(r["quantity_id"])} for r in rep],
        })
    return {
        "schema": "o-mcp/devicelist", "version": 1,
        "query": {"tenant": tenant, "as_of": as_of, "observed_at": timewin.iso(at), "reported_days": REPORTED_DAYS},
        "devices": out,
    }
