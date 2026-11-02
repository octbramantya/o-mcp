"""The last reading of each of a node's meters at an instant, from minute telemetry: the frontend's
Now widget (GET /api/now). Instantaneous values (SAMPLE) by default, power factor decoded as
everywhere else (design/mcp-tools.md, gap 4). Only the last LOOKBACK before the instant counts: an
older reading is not "now", and the meter is reported as having none.
"""
import datetime as dt

from . import timewin, vocab
from .db import rows
from .meters import DEVICES

LOOKBACK = dt.timedelta(minutes=15)

SQL = """
SELECT DISTINCT ON (t.device_id, t.quantity_id) t.device_id, t.quantity_id, t."timestamp" AS at, t.value
FROM telemetry_data t
WHERE t.tenant_id = %(tenant)s AND t.device_id = ANY (%(devices)s) AND t.quantity_id = ANY (%(quantities)s)
  AND t."timestamp" > %(since)s AND t."timestamp" <= %(at)s
  AND t.value IS NOT NULL AND t.value <> 'NaN'::numeric
ORDER BY t.device_id, t.quantity_id, t."timestamp" DESC
"""


def decode(code, value):
    """Power factor as a magnitude, 0..1, whatever the meter's encoding; anything else as is."""
    v = float(value)
    if code not in vocab.PF_ENCODED:
        return v
    if v <= -2:
        return None              # Schneider: no load
    return 2 - v if v > 1 else v + 2 if v < -1 else abs(v)


async def document(conn, tenant, v, tz, node, at, codes=None):
    """node is a row of resolve.live_nodes on at's day; at an aware instant. codes narrows the
    quantities; without it, every SAMPLE quantity."""
    terms = [v.quantity(c) for c in codes] if codes else [q for q in v.quantities if q["reading"] == "SAMPLE"]
    mapped = await rows(conn, DEVICES, {"tenant": tenant, "as_of": at.astimezone(tz).date().isoformat(),
                                        "node_id": node["id"]})
    devices = {}
    for m in mapped:
        devices.setdefault(m["device_id"], m)
    end = at.astimezone(timewin.UTC).replace(tzinfo=None)
    got = await rows(conn, SQL, {"tenant": tenant, "devices": sorted(devices), "at": end, "since": end - LOOKBACK,
                                 "quantities": [t["quantity_id"] for t in terms]}) if devices else []
    by_id = {t["quantity_id"]: t for t in terms}
    out, findings = [], []
    for did, d in sorted(devices.items(), key=lambda kv: kv[1]["device_code"]):
        mine = sorted((r for r in got if r["device_id"] == did), key=lambda r: by_id[r["quantity_id"]]["code"])
        out.append({"device_id": did, "code": d["device_code"], "name": d["device_name"],
                    "readings": [{"quantity": by_id[r["quantity_id"]]["code"], "unit": by_id[r["quantity_id"]]["unit"],
                                  "value": decode(by_id[r["quantity_id"]]["code"], r["value"]),
                                  "at": timewin.local_iso(r["at"], tz)} for r in mine]})
        if not mine:
            findings.append({"code": "NO_RECENT_READING", "device_id": did,
                             "message": f"{d['device_code']} ({d['device_name']}) has no reading in the "
                                        f"{int(LOOKBACK.total_seconds() // 60)} minutes before {timewin.iso(at)}."})
    if not devices:
        findings.append({"code": "NO_METER", "message": f"{node['code']} has no meter of its own or on its feeder."})
    return {"node": {"id": node["id"], "code": node["code"], "name": node["name"]},
            "at": timewin.iso(at), "lookback_minutes": int(LOOKBACK.total_seconds() // 60),
            "devices": out, "findings": findings}


# -- many nodes at once: the single-line diagram's live figures (design/frontend.md §5) ------------------
MAX_NODES = 300

# Where each meter of the nodes sits: on a feeder into one of them when it has a row on that edge,
# else on each node it has a x1 row on. A row with another multiplier corrects the arithmetic (048:
# PLTSC x 1/3 on LVMDB_A4) and says nothing about where the meter is.
PLACES = """
WITH live_n AS (
  SELECT id, node_code FROM graph.node n
  WHERE n.tenant_id = %(tenant)s
    AND n.is_active AND n.effective_from <= %(as_of)s AND (n.effective_to IS NULL OR n.effective_to >= %(as_of)s)
), feeders AS (
  SELECT e.id, e.from_node_id, f.node_code AS from_code, e.to_node_id, t.node_code AS to_code
  FROM graph.edge e JOIN live_n f ON f.id = e.from_node_id JOIN live_n t ON t.id = e.to_node_id
  WHERE e.tenant_id = %(tenant)s AND e.to_node_id = ANY (%(nodes)s)
    AND e.is_active AND e.effective_from <= %(as_of)s AND (e.effective_to IS NULL OR e.effective_to >= %(as_of)s)
)
SELECT DISTINCT m.device_id, d.device_code, d.device_name, m.node_id, n.node_code,
       fe.id AS edge_id, fe.from_node_id, fe.from_code, fe.to_node_id, fe.to_code
FROM graph.measurement m
JOIN devices d ON d.id = m.device_id
LEFT JOIN live_n n ON n.id = m.node_id
LEFT JOIN feeders fe ON fe.id = m.edge_id
WHERE m.tenant_id = %(tenant)s
  AND m.is_active AND m.effective_from <= %(as_of)s AND (m.effective_to IS NULL OR m.effective_to >= %(as_of)s)
  AND ((m.node_id = ANY (%(nodes)s) AND n.id IS NOT NULL AND m.multiplier = 1) OR fe.id IS NOT NULL)
"""


def places(mapped):
    """{device_id: (device row, [place])}: a meter's feeders if it has any, else its nodes."""
    found = {}
    for m in mapped:
        found.setdefault(m["device_id"], (m, []))[1].append(m)
    out = {}
    for did, (d, rows_) in found.items():
        feeders = [r for r in rows_ if r["edge_id"] is not None]
        chosen = feeders or [r for r in rows_ if r["node_id"] is not None]
        on = []
        for r in chosen:
            p = ({"kind": "feeder", "edge_id": r["edge_id"], "from_id": r["from_node_id"], "from": r["from_code"],
                  "to_id": r["to_node_id"], "to": r["to_code"]} if r["edge_id"] is not None
                 else {"kind": "node", "node_id": r["node_id"], "node": r["node_code"]})
            if p not in on:
                on.append(p)
        out[did] = (d, sorted(on, key=lambda p: (p["kind"], p.get("node") or p["from"], p.get("to") or "")))
    return out


async def many(conn, tenant, v, tz, ids, at, codes):
    """The last reading of codes from every meter at or on a feeder into the nodes ids, at an aware
    instant, each meter with where it sits. Nodes not in the plant on at's day are left out."""
    terms = [v.quantity(c) for c in codes]
    mapped = await rows(conn, PLACES, {"tenant": tenant, "as_of": at.astimezone(tz).date().isoformat(), "nodes": ids})
    devices = places(mapped)
    end = at.astimezone(timewin.UTC).replace(tzinfo=None)
    got = await rows(conn, SQL, {"tenant": tenant, "devices": sorted(devices), "at": end, "since": end - LOOKBACK,
                                 "quantities": [t["quantity_id"] for t in terms]}) if devices else []
    by_id = {t["quantity_id"]: t for t in terms}
    out, findings = [], []
    for did, (d, on) in sorted(devices.items(), key=lambda kv: kv[1][0]["device_code"]):
        order = lambda r: codes.index(by_id[r["quantity_id"]]["code"])  # noqa: E731
        mine = sorted((r for r in got if r["device_id"] == did), key=order)
        out.append({"device_id": did, "code": d["device_code"], "name": d["device_name"], "on": on,
                    "readings": [{"quantity": by_id[r["quantity_id"]]["code"],
                                  "value": decode(by_id[r["quantity_id"]]["code"], r["value"]),
                                  "at": timewin.local_iso(r["at"], tz)} for r in mine]})
        if len(mine) < len(terms):
            missing = [t["code"] for t in terms if not any(by_id[r["quantity_id"]] is t for r in mine)]
            findings.append({"code": "NO_RECENT_READING", "device_id": did,
                             "message": f"{d['device_code']} ({d['device_name']}) has no {', '.join(missing)} in the "
                                        f"{int(LOOKBACK.total_seconds() // 60)} minutes before {timewin.iso(at)}."})
    return {"at": timewin.iso(at), "lookback_minutes": int(LOOKBACK.total_seconds() // 60),
            "quantities": [{"code": t["code"], "unit": t["unit"], "decoded": t["code"] in vocab.PF_ENCODED}
                           for t in terms],
            "devices": out, "findings": findings}
