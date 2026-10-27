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
