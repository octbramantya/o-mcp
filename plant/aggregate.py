"""A sampled quantity's spread across several nodes over a window, per meter: the minimum, mean,
95th percentile and maximum of each meter's readings, for the frontend's Aggregate widget
(design/frontend.md §5, "Aggregate"). Counters are solved by node_value instead (api/aggregate.py).

Each node's meters are those on the node or its feeder edge as of the window's last day, as
meter_readings finds them; two meters on one node are two rows, since their readings can't be merged
into one figure. The statistics are readings' own window point (plant/readings.py), on minute
telemetry_data or telemetry_15min_agg as the caller chooses, which keeps the last reading in each 15
minutes. An unmetered node gets one row with no meter: the solver can only give it THD_VOLTAGE_LN,
its feeder's, and that is left out for now.
"""
import datetime as dt
import math

from . import readings, timewin
from .db import rows
from .meters import DEVICES
from .resolve import LIVE_NODES

STEP = {"minute": dt.timedelta(minutes=1), "15min": dt.timedelta(minutes=15)}


def expected(start, end, source):
    """How many readings a meter reporting every step gives in [start, end): the step's instants in it."""
    step = STEP[source]
    u = start.astimezone(dt.UTC)
    base = u.replace(minute=0, second=0, microsecond=0)
    first = base + step * math.ceil((u - base) / step)
    return max(0, math.ceil((end.astimezone(dt.UTC) - first) / step))


def _num(x):
    return None if x is None else round(float(x), 4)


async def spread(conn, tenant, v, tz, ids, term, w, source):
    """(rows, findings, data_until) for quantity term over window w, ids in the order given. data_until
    is aware, the end of the latest reading's step, or None if no meter read anything."""
    as_of = (w.end - dt.timedelta(microseconds=1)).date().isoformat()
    live = {n["id"]: n for n in await rows(conn, LIVE_NODES + " AND n.id = ANY(%(ids)s)",
                                           {"tenant": tenant, "as_of": as_of, "ids": ids})}
    per_node = {}
    for i in ids:
        if i in live:
            mapped = await rows(conn, DEVICES, {"tenant": tenant, "as_of": as_of, "node_id": i})
            per_node[i] = {}
            for m in mapped:
                per_node[i].setdefault(m["device_id"], m)
    devices = sorted({d for ds in per_node.values() for d in ds})
    got = {}
    if devices:
        start, end = w.utc()
        p = readings.params(tenant, tz, devices, [term], v, start, end, "window", source)
        got = {r["device_id"]: r for r in await rows(conn, readings.SQL[source], p)}

    n_expected = expected(w.start, w.end, source)
    out, findings, last = [], [], None
    for i in ids:
        n = live.get(i)
        if n is None:
            findings.append({"code": "NOT_IN_PLANT", "node_id": i,
                             "message": f"Node {i} isn't in the plant on {as_of}, the window's last day."})
            continue
        if not per_node[i]:
            out.append({"node_id": i, "code": n["code"], "name": n["name"], "device_id": None, "device": None,
                        "device_name": None, "total": None, "origin": "NO_METER", "min": None, "mean": None,
                        "p95": None, "max": None, "samples": 0, "expected": n_expected, "last_reading": None})
            findings.append({"code": "NO_METER", "node_id": i,
                             "message": f"{n['code']} has no meter of its own or on its feeder on {as_of}."})
            continue
        for did, d in sorted(per_node[i].items(), key=lambda kv: kv[1]["device_code"]):
            r = got.get(did)
            if r and (last is None or r["last"] > last):
                last = r["last"]
            out.append({"node_id": i, "code": n["code"], "name": n["name"], "device_id": did,
                        "device": d["device_code"], "device_name": d["device_name"], "total": None,
                        "origin": "MEASURED", "min": _num(r and r["min"]), "mean": _num(r and r["mean"]),
                        "p95": _num(r and r["p95"]), "max": _num(r and r["max"]),
                        "samples": r["samples"] if r else 0, "expected": n_expected,
                        "last_reading": timewin.local_iso(r["last"], tz) if r else None})
            if not r:
                findings.append({"code": "NO_READINGS", "node_id": i, "device": d["device_code"],
                                 "message": f"{d['device_code']} ({d['device_name']}) on {n['code']} has no "
                                            f"{term['code']} readings in this window."})
    until = None if last is None else last.replace(tzinfo=dt.UTC).astimezone(tz) + STEP[source]
    return out, findings, until
