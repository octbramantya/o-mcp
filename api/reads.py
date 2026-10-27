"""The plant routes beside GET /api/values (design/frontend.md §5, §7): the vocabulary, the node finder,
a plant section, a node's meters, readings and last readings, the sankey with its diagnostics, and
the data's status for the bottom bar. Each runs the
MCP tool's own query from plant/, and answers in the tool's v1 format, which carries node ids
(decision 19): a widget stores the id and shows the code and name the answer gives.

Nodes are given by graph.node.id and looked up on the network of as_of. Topology is drawn on one
day (decision 20, A): the frontend passes its range's last day as as_of; readings and the sankey
take the window and use its last day themselves. A node retired by then is refused by name.

Each read returns (cache key, compute): the key is built from the parsed request, so a bad request
fails before the cache, and every answer is cached as /api/values' are (api/cache.py).
"""
import datetime as dt

from plant import find, meters, now, readings, section, status, timewin
from plant import vocab as vocabulary
from plant.db import rows
from plant.errors import PlantError
from plant.resolve import LIVE_NODES
from plant.value import change_days, cuts, daily

from . import values

NODES_LIMIT_MAX = 500
READINGS_MAX_DAYS = 92
READINGS_MAX_POINTS = 10000
READINGS_MAX_QUANTITIES = 8
READINGS_INTERVALS = ("auto", "15min", "hour", "day", "window")
SANKEY_MAX_DAYS = 92
SANKEY_DEFAULT = "ACTIVE_ENERGY_DELIVERED"
INSTANT = dt.timedelta(microseconds=1)


# -- parameters -----------------------------------------------------------------------------------
def _as_of(params, tz):
    s = params.get("as_of")
    return (timewin.parse_date(s, "as_of") if s else timewin.today(tz)).isoformat()


def _int(params, key, default=None, low=None, high=None):
    s = params.get(key)
    if s is None or s == "":
        if default is None:
            raise PlantError(f"{key} is required.")
        return default
    try:
        n = int(s)
    except ValueError as e:
        raise PlantError(f"{key} must be a whole number; got {s!r}.") from e
    if (low is not None and n < low) or (high is not None and n > high):
        raise PlantError(f"{key} must be between {low} and {high}; got {n}.")
    return n


def _choice(params, key, options, default=None):
    s = params.get(key) or default
    if s is not None and s not in options:
        raise PlantError(f"{key} must be one of {', '.join(options)}; got {s!r}.")
    return s


def _bool(params, key, default=None):
    s = params.get(key)
    if s is None or s == "":
        return default
    if s not in ("true", "false"):
        raise PlantError(f"{key} must be true or false; got {s!r}.")
    return s == "true"


def _last_day(w):
    return (w.end - INSTANT).date()


async def node_on(conn, tenant, nid, as_of):
    """The node with id nid as a row of resolve.live_nodes on as_of, or PlantError naming it."""
    got = await rows(conn, LIVE_NODES + " AND n.id = %(id)s", {"tenant": tenant, "as_of": as_of, "id": nid})
    if got:
        return got[0]
    other = await rows(conn, "SELECT node_code AS code FROM graph.node WHERE tenant_id = %s AND id = %s",
                       (tenant, nid))
    if other:
        raise PlantError(f"{other[0]['code']} isn't in the plant on {as_of}.")
    raise PlantError(f"No node {nid} in this site.")


# -- the reads ------------------------------------------------------------------------------------
def vocabulary_doc(tenant, _params):
    async def compute():
        return vocabulary.document(tenant.vocab)
    return ("vocabulary", tenant.id), compute


def nodes(tenant, params):
    v = tenant.vocab
    statuses = next((p["enum_values"] for p in v.properties if p["key"] == "site_status"), None) or []
    f = {"text": params.get("text") or None,
         "type": _choice(params, "type", [t["code"] for t in v.node_types]),
         "class": _choice(params, "class", [c["code"] for c in v.node_classes]),
         "utility": _choice(params, "utility", [u["code"] for u in v.utilities]),
         "metered": _bool(params, "metered"),
         "site_status": _choice(params, "site_status", [*statuses, "none"])}
    as_of, limit = _as_of(params, tenant.tz), _int(params, "limit", 200, 1, NODES_LIMIT_MAX)

    async def compute():
        async with tenant.tx() as conn:
            return await find.nodelist(conn, tenant.id, v, as_of, f, limit)
    return ("nodes", tenant.id, as_of, limit, *f.items()), compute


def subgraph(tenant, params):
    nid, as_of = _int(params, "node"), _as_of(params, tenant.tz)
    depth = _int(params, "depth", 1, 1, section.DEPTH_MAX)
    direction = _choice(params, "direction", section.DIRECTIONS, "down")
    utility = _choice(params, "utility", [u["code"] for u in tenant.vocab.utilities])

    async def compute():
        async with tenant.tx() as conn:
            node = await node_on(conn, tenant.id, nid, as_of)
            return await section.subgraph(conn, tenant.id, node["code"], as_of, depth, direction, utility)
    return ("section", tenant.id, nid, as_of, depth, direction, utility), compute


def node_meters(tenant, params):
    nid, as_of = _int(params, "node"), _as_of(params, tenant.tz)

    async def compute():
        async with tenant.tx() as conn:
            node = await node_on(conn, tenant.id, nid, as_of)
            return await meters.document(conn, tenant.id, tenant.vocab, tenant.tz, node, as_of)
    return ("meters", tenant.id, nid, as_of), compute


def auto_interval(w, oldest_minute):
    """minute for a window of 6 hours or less within the minute data (design/frontend.md §3), else
    the coarsest point that still draws a line: 15min up to 2 days, hour up to 31, day beyond."""
    span = w.end - w.start
    if span <= values.MINUTE_MAX and oldest_minute is not None and w.start >= oldest_minute:
        return "minute"
    return "15min" if span <= dt.timedelta(days=2) else "hour" if span <= dt.timedelta(days=31) else "day"


def node_readings(tenant, params):
    v = tenant.vocab
    nid = _int(params, "node")
    codes = list(dict.fromkeys(c.strip() for c in params.get("quantities", "").split(",") if c.strip()))
    if not 1 <= len(codes) <= READINGS_MAX_QUANTITIES:
        raise PlantError(f"Give between 1 and {READINGS_MAX_QUANTITIES} quantity codes, separated by commas.")
    unknown = [c for c in codes if not v.quantity(c)]
    if unknown:
        raise PlantError(f"No quantity {', '.join(unknown)}; GET /api/vocabulary lists them.")
    w = timewin.window(params.get("start"), params.get("end"), tenant.tz, READINGS_MAX_DAYS)
    interval = _choice(params, "interval", READINGS_INTERVALS, "auto")
    device = _int(params, "device", 0)
    as_of = _last_day(w).isoformat()

    async def compute():
        async with tenant.tx() as conn:
            chosen = interval
            if chosen == "auto":
                oldest = await values.oldest_minute(conn, tenant) if w.end - w.start <= values.MINUTE_MAX else None
                chosen = auto_interval(w, oldest)
            node = await node_on(conn, tenant.id, nid, as_of)
            return await readings.document(conn, tenant.id, v, tenant.tz, node, as_of, codes, w, chosen,
                                           READINGS_MAX_POINTS, device or None)
    key = ("readings", tenant.id, nid, tuple(codes), interval, device,
           values._floor(w.start, values.MINUTE), values._ceil(w.end, values.MINUTE))
    return key, compute


def _sankey_params(tenant, params):
    """The quantity, the window as whole site days (first, last included), and the window asked for.
    A window not on midnights draws every day it touches, as the Grafana panel does."""
    v = tenant.vocab
    qs = {q["code"]: q for q in v.node_value_quantities()
          if q["kind"] == "RULE" and q["rule"]["conserved"] and q["rule"]["network_agg"] == "SUM"}
    q = qs[_choice(params, "quantity", sorted(qs), SANKEY_DEFAULT)]
    w = timewin.window(params.get("start"), params.get("end"), tenant.tz, SANKEY_MAX_DAYS)
    return q, w.start.date(), _last_day(w), w


def _days(first, last, tz):
    return (dt.datetime.combine(first, dt.time(), tz), dt.datetime.combine(last + dt.timedelta(days=1), dt.time(), tz))


async def _context(conn, tenant, q, first, last):
    """What the sankey and its diagnostics both say about their window: where the data stops
    (DATA_INCOMPLETE, as /api/values) and whether the plant changed inside it (decision 20)."""
    start, end = _days(first, last, tenant.tz)
    source, until = await values.data_until(conn, tenant.id, values.sources("day", daily(q, tenant.vocab),
                                                                              [q["rule"]]), start, end)
    changes = await cuts(conn, tenant.id, *change_days(start, end))
    findings = []
    if changes:
        findings.append({"code": "PLANT_CHANGED", "message": (
            f"The plant changed on {', '.join(d.isoformat() for d in changes)}; the whole window is drawn on the "
            f"network of {last}.")})
    if until is None or until < end:
        findings.append({"code": "DATA_INCOMPLETE", "message": (
            f"{source} has no data for this window." if until is None else
            f"{source} has data only up to {timewin.iso(until)}; the window runs to {timewin.iso(end)}.")})
    return {"tenant": tenant.id,
            "quantity": {"code": q["code"], "utility": q["utility"], "unit": q["unit"]},
            "window": timewin.Window(start, end).as_json(), "as_of": last.isoformat(),
            "source": source, "data_until": timewin.iso(until) if until else None}, findings


def _num(x):
    return None if x is None else round(float(x), 4)


def sankey(tenant, params):
    q, first, last, w = _sankey_params(tenant, params)
    detail = _bool(params, "node_detail", True)

    async def compute():
        async with tenant.tx() as conn:
            links = await rows(conn, "SELECT source, target, value, color, link_kind, is_ambiguous"
                                     " FROM graph.sankey(%s, %s, %s, p_quantity_id => %s, p_node_detail => %s)",
                               (tenant.id, first, last, q["quantity_id"], detail))
            head, findings = await _context(conn, tenant, q, first, last)
        for r in links:
            r["value"] = _num(r["value"])
        return {**head, "requested": w.as_json(), "node_detail": detail, "links": links, "findings": findings}
    return ("sankey", tenant.id, q["code"], first, last, detail), compute


DIAGNOSTICS = """
SELECT d.kind, d.node_code, n.id AS node_id, d.value, d.detail
FROM graph.sankey_diagnostics(%(tenant)s, %(first)s, %(last)s, p_quantity_id => %(quantity)s) d
LEFT JOIN graph.node n ON n.tenant_id = %(tenant)s AND n.node_code = d.node_code
  AND n.is_active AND n.effective_from <= %(last)s AND (n.effective_to IS NULL OR n.effective_to >= %(last)s)
ORDER BY CASE d.kind WHEN 'NEGATIVE_RESIDUAL' THEN 1 WHEN 'NEGATIVE_FLOW' THEN 2 WHEN 'NO_DATA' THEN 3
                     WHEN 'REVERSE_ENERGY' THEN 4 WHEN 'UNASSIGNED' THEN 5 ELSE 6 END,
         abs(d.value) DESC NULLS LAST, d.node_code
"""

PROPERTY_GAPS = """
SELECT g.node_code, n.id AS node_id, g.node_name, g.node_type, g.attr_key AS property, g.kind, g.status,
       g.used_by, g.detail
FROM graph.v_property_gaps g
LEFT JOIN graph.node n ON n.tenant_id = g.tenant_id AND n.node_code = g.node_code
  AND n.is_active AND n.effective_from <= CURRENT_DATE AND (n.effective_to IS NULL OR n.effective_to >= CURRENT_DATE)
WHERE g.tenant_id = %(tenant)s
ORDER BY g.node_code, g.attr_key
"""


def diagnostics(tenant, params):
    """What the sankey can't show over the window (graph.sankey_diagnostics), and the properties the
    site still has to supply (graph.v_property_gaps, as of today: properties have no history)."""
    q, first, last, w = _sankey_params(tenant, params)

    async def compute():
        async with tenant.tx() as conn:
            diag = await rows(conn, DIAGNOSTICS, {"tenant": tenant.id, "first": first, "last": last,
                                                  "quantity": q["quantity_id"]})
            gaps = await rows(conn, PROPERTY_GAPS, {"tenant": tenant.id})
            head, findings = await _context(conn, tenant, q, first, last)
        for r in diag:
            r["value"] = _num(r["value"])
        return {**head, "requested": w.as_json(), "diagnostics": diag, "property_gaps": gaps, "findings": findings}
    return ("diagnostics", tenant.id, q["code"], first, last), compute


def _at(params, tz):
    """An instant in site time, to the minute: at, or now. A later one is now: nothing is read after it."""
    current = dt.datetime.now(tz).replace(second=0, microsecond=0)
    s = params.get("at")
    return current if not s else min(timewin.parse_local(s, tz, "at").replace(second=0, microsecond=0), current)


def node_now(tenant, params):
    """The last reading of each of a node's meters at an instant (plant/now.py)."""
    v = tenant.vocab
    nid, at = _int(params, "node"), _at(params, tenant.tz)
    codes = list(dict.fromkeys(c.strip() for c in params.get("quantities", "").split(",") if c.strip()))
    unknown = [c for c in codes if not v.quantity(c)]
    if unknown:
        raise PlantError(f"No quantity {', '.join(unknown)}; GET /api/vocabulary lists them.")

    async def compute():
        async with tenant.tx() as conn:
            node = await node_on(conn, tenant.id, nid, at.date().isoformat())
            return await now.document(conn, tenant.id, v, tenant.tz, node, at, codes)
    return ("now", tenant.id, nid, tuple(codes), at), compute


def data_status(tenant, params):
    """Where each source stops and which meters are silent, at an instant (plant/status.py)."""
    at = _at(params, tenant.tz)

    async def compute():
        async with tenant.tx() as conn:
            return await status.document(conn, tenant.id, tenant.tz, at)
    return ("status", tenant.id, at), compute
