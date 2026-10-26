"""The instruments on one node, as an o-mcp/meters v1 document: the MCP server's node_meters and the
API's GET /api/meters. Which devices read the node or its feeder, what each reports, when each last
reported against the status the site declared (design/mcp-tools.md, gap 5), and which quantities a
value can be given for the node, measured or inferred.

graph.v_device_attachment is not used: it filters is_active only, not the effective window
(design/mcp-catalogue.md §5, open 4). graph.measurement is filtered here instead.
"""
import datetime as dt

from . import timewin
from .db import rows

LOOKBACK_DAYS = 7        # what counts as "reports"
LAST_SEEN_DAYS = 90      # how far back "last reported" looks
SILENT_AFTER = dt.timedelta(hours=2)

DEVICES = """
WITH live_n AS (
  SELECT * FROM graph.node n
  WHERE n.tenant_id = %(tenant)s
    AND n.is_active AND n.effective_from <= %(as_of)s
    AND (n.effective_to IS NULL OR n.effective_to >= %(as_of)s)
), feeders AS (
  SELECT e.id, f.node_code AS from_code
  FROM graph.edge e JOIN live_n f ON f.id = e.from_node_id
  WHERE e.tenant_id = %(tenant)s AND e.to_node_id = %(node_id)s
    AND e.is_active AND e.effective_from <= %(as_of)s
    AND (e.effective_to IS NULL OR e.effective_to >= %(as_of)s)
)
SELECT m.device_id, m.quantity_id, m.role, m.multiplier, m.utility_code AS utility,
       m.edge_id, fe.from_code, d.device_code, d.device_name, d.device_type, d.status
FROM graph.measurement m
JOIN devices d ON d.id = m.device_id
LEFT JOIN feeders fe ON fe.id = m.edge_id
WHERE m.tenant_id = %(tenant)s
  AND m.is_active AND m.effective_from <= %(as_of)s
  AND (m.effective_to IS NULL OR m.effective_to >= %(as_of)s)
  AND (m.node_id = %(node_id)s OR m.edge_id IN (SELECT id FROM feeders))
ORDER BY d.device_code, m.quantity_id
"""

UTILITIES = """
SELECT DISTINCT e.utility_code FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id AND f.is_active AND f.effective_from <= %(as_of)s
                 AND (f.effective_to IS NULL OR f.effective_to >= %(as_of)s)
JOIN graph.node t ON t.id = e.to_node_id AND t.is_active AND t.effective_from <= %(as_of)s
                 AND (t.effective_to IS NULL OR t.effective_to >= %(as_of)s)
WHERE e.tenant_id = %(tenant)s AND %(node_id)s IN (e.from_node_id, e.to_node_id)
  AND e.is_active AND e.effective_from <= %(as_of)s AND (e.effective_to IS NULL OR e.effective_to >= %(as_of)s)
ORDER BY 1
"""

REPORTED = """
SELECT device_id, quantity_id, max(bucket) AS last, count(*) AS readings
FROM telemetry_15min_agg
WHERE tenant_id = %(tenant)s AND device_id = ANY (%(devices)s) AND bucket >= %(since)s AND bucket < %(until)s
GROUP BY device_id, quantity_id
"""

LAST_SEEN = """
SELECT device_id, max(bucket) AS last
FROM telemetry_15min_agg
WHERE tenant_id = %(tenant)s AND device_id = ANY (%(devices)s) AND bucket >= %(since)s AND bucket < %(until)s
GROUP BY device_id
"""


def observed_at(as_of, tz):
    """The instant 'last reported' is judged at: now for today, else the end of the as_of day."""
    now = dt.datetime.now(tz)
    end = dt.datetime.combine(dt.date.fromisoformat(as_of) + dt.timedelta(days=1), dt.time(), tz)
    return min(now, end)


def resolvable(v, utilities, mapped):
    """Per quantity node_value serves for this node's utilities: how it would get a value."""
    here = {m["quantity_id"] for m in mapped if m["edge_id"] is None and m["role"] == "TOTAL"}
    on_feeder = {m["quantity_id"] for m in mapped if m["edge_id"] is not None}
    out = []
    for q in v.node_value_quantities():
        if q["utility"] not in utilities:
            continue
        if q["kind"] == "DERIVED":
            parts = [v.quantity(c)["quantity_id"] for c in q["from"]]
            measured = all(p in here for p in parts)
            out.append({"quantity": q["code"], "unit": q["unit"], "utility": q["utility"], "availability": "DERIVED",
                        "note": f"computed from {' and '.join(q['from'])}, "
                                + ("both measured here." if measured else "solved through the network.")})
            continue
        agg = q["rule"]["network_agg"]
        if q["quantity_id"] in here:
            a, note = "MEASURED", "a meter on this node reports it."
        elif q["quantity_id"] in on_feeder:
            a, note = "MEASURED", "a meter on this node's feeder reports it."
        elif agg in ("SUM", "RSS"):
            a, note = "INFERRED", "no meter here; the solver works it out from neighbouring meters by flow balance."
        elif agg == "INHERIT":
            a, note = "INHERITED", "no meter here; the node takes its feeder's value (the worst, if several)."
        else:
            a, note = "NOT_AVAILABLE", "only a meter on this node could give it, and none reports it."
        out.append({"quantity": q["code"], "unit": q["unit"], "utility": q["utility"], "availability": a,
                    "note": note})
    return out


async def document(conn, tenant, v, tz, node, as_of):
    """node is a row of resolve.live_nodes on as_of, a date in ISO form."""
    at = observed_at(as_of, tz)
    until = at.astimezone(timewin.UTC).replace(tzinfo=None)
    p = {"tenant": tenant, "as_of": as_of, "node_id": node["id"]}
    mapped = await rows(conn, DEVICES, p)
    utilities = [r["utility_code"] for r in await rows(conn, UTILITIES, p)]
    ids = sorted({m["device_id"] for m in mapped})
    reported, seen = [], {}
    if ids:
        reported = await rows(conn, REPORTED, {"tenant": tenant, "devices": ids, "until": until,
                                               "since": until - dt.timedelta(days=LOOKBACK_DAYS)})
        quiet = [i for i in ids if not any(r["device_id"] == i for r in reported)]
        if quiet:
            seen = {r["device_id"]: r["last"] for r in await rows(conn, LAST_SEEN, {
                "tenant": tenant, "devices": quiet, "until": until,
                "since": until - dt.timedelta(days=LAST_SEEN_DAYS)})}

    attrs = node["attrs"] or {}
    status, status_as_of = attrs.get("site_status"), attrs.get("site_status_as_of")
    if status and status_as_of and as_of < status_as_of:
        status = status_as_of = None   # attrs has no history: before the record, state nothing
    findings, devices = [], []
    for did in ids:
        ms = [m for m in mapped if m["device_id"] == did]
        d = ms[0]
        rep = sorted((r for r in reported if r["device_id"] == did), key=lambda r: r["quantity_id"])
        last = max((r["last"] for r in rep), default=seen.get(did))
        observed = ("NO_DATA" if last is None else
                    "REPORTING" if at - last.replace(tzinfo=timewin.UTC) <= SILENT_AFTER else "SILENT")
        label = f"{d['device_code']} ({d['device_name']})"
        devices.append({
            "device_id": did, "code": d["device_code"], "name": d["device_name"], "type": d["device_type"],
            "declared_status": d["status"],
            "attached_to": "FEEDER" if d["edge_id"] else "NODE",
            "edge": d["edge_id"], "feeder_from": d["from_code"],
            "graph_quantities": [{"code": (v.quantity_by_id(m["quantity_id"]) or {}).get("code"),
                                  "quantity_id": m["quantity_id"], "role": m["role"],
                                  "multiplier": float(m["multiplier"])} for m in ms],
            "last_reading": timewin.local_iso(last, tz),
            "observed": observed,
            "reported": [{"code": (v.quantity_by_id(r["quantity_id"]) or {}).get("code"),
                          "quantity_id": r["quantity_id"],
                          "unit": (v.quantity_by_id(r["quantity_id"]) or {}).get("unit"),
                          "reading": (v.quantity_by_id(r["quantity_id"]) or {}).get("reading"),
                          "last_reading": timewin.local_iso(r["last"], tz), "readings": r["readings"]} for r in rep],
        })
        since = (f"since {timewin.local_iso(last, tz)}" if last else
                 f"in the {LAST_SEEN_DAYS} days before {timewin.iso(at)}")
        if observed == "REPORTING" and status == "inactive":
            findings.append({"code": "STATUS_OUT_OF_DATE", "node": node["code"], "device": d["device_code"],
                             "message": f"{node['code']} is recorded as inactive since {status_as_of}, but {label} "
                                        f"reported at {timewin.local_iso(last, tz)}. The status is probably out of "
                                        f"date; ask the site."})
        elif observed != "REPORTING" and status == "inactive":
            findings.append({"code": "SILENT_AS_DECLARED", "node": node["code"], "device": d["device_code"],
                             "message": f"{label} has not reported {since}, as expected: the site turned "
                                        f"{node['code']} off (inactive since {status_as_of})."})
        elif observed != "REPORTING":
            findings.append({"code": "METER_SILENT", "node": node["code"], "device": d["device_code"],
                             "message": f"{label} has not reported {since}, and nothing on record explains it."})
        for r in rep:
            if not v.quantity_by_id(r["quantity_id"]):
                findings.append({"code": "UNKNOWN_QUANTITY", "node": node["code"], "device": d["device_code"],
                                 "quantity_id": r["quantity_id"],
                                 "message": f"{label} reports quantity id {r['quantity_id']}, which has no entry "
                                            f"in the quantity vocabulary, so what it measures is not known."})
    if not ids:
        findings.append({"code": "NO_METER", "node": node["code"],
                         "message": f"{node['code']} has no meter of its own or on its feeder; its values come "
                                    f"from the solver, as listed under resolvable."})
    doc = {
        "schema": "o-mcp/meters", "version": 1,
        "query": {"tenant": tenant, "node": node["code"], "as_of": as_of, "observed_at": timewin.iso(at),
                  "lookback_days": LOOKBACK_DAYS},
        "node": {"id": node["id"], "code": node["code"], "name": node["name"], "class": node["class"],
                 "type": node["type"], "utilities": utilities, "site_status": status,
                 "site_status_as_of": status_as_of},
        "devices": devices,
        "resolvable": resolvable(v, utilities, mapped),
        "findings": findings,
    }
    return doc
