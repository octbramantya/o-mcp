"""A quantity's value for nodes over a window, from the solver (graph.get_node_quantity,
graph.get_node_derived), shared by the MCP tool node_value and the API's value route.

The plant can change inside a window (design/frontend.md §3, decided 2026-10-22). The window is cut
at graph.change_dates, each piece is solved on the network of its own last day, and the pieces are
combined by the quantity's rule: DELTA totals add. Any other rule (THD_VOLTAGE_LN's P95: a range's
95th percentile can't be rebuilt from its pieces') is solved once, on the network of the window's last
day. Without a change, nearly always, there is one piece and one solve.

The caller converts each piece to the solver's bounds, which depend on the source it reads
(whole site days for the daily summary, naive UTC with the last bucket or minute for the others).
"""
import datetime as dt
import itertools

from . import resolve
from .db import rows

# Rules whose totals over pieces of a window add up to the window's (design/frontend.md §3). A rule
# not listed is solved on one network; a new rule joins only once it says how its pieces combine.
ADDS = ("DELTA",)


def _rules(q, v):
    return [v.quantity(c)["rule"] for c in q["from"]] if q["kind"] == "DERIVED" else [q["rule"]]


def daily(q, v):
    """True when, with no resolution set, the solver reads this quantity from site-time days."""
    return all(r["utility"] == "ELECTRICITY" and r["conserved"] for r in _rules(q, v))


def splits(q, v):
    """True when q is worked out piece by piece where the plant changed inside the window."""
    return all(r["time_agg"] in ADDS for r in _rules(q, v))


def pieces(first, end, cuts):
    """(start, end, as_of) per piece: the days first..end (excluded) cut at each change date, each
    solved on the network of its own last day."""
    bounds = [first, *cuts, end]
    return [(a, b, b - dt.timedelta(days=1)) for a, b in itertools.pairwise(bounds)]


def instant_pieces(start, end, cuts):
    """The same for a window of aware site-time instants: cut at each change date's midnight, each
    piece solved on the network of the day its last instant falls on."""
    tz = start.tzinfo
    bounds = [start, *(dt.datetime.combine(d, dt.time(), tz) for d in cuts), end]
    return [(a, b, (b - dt.timedelta(microseconds=1)).date()) for a, b in itertools.pairwise(bounds)]


def change_days(start, end):
    """The day range graph.change_dates takes for instants [start, end): a change on day d cuts
    when start < midnight of d < end."""
    last = end.date() if end.timetz() == dt.time(tzinfo=end.tzinfo) else end.date() + dt.timedelta(days=1)
    return start.date(), last


async def cuts(conn, tenant, first, end):
    return [r["change_date"] for r in await rows(conn, "SELECT change_date FROM graph.change_dates(%s, %s, %s)",
                                                 (tenant, first, end))]


async def live_nodes(conn, tenant, days):
    """Every node in effect on any of these days, the latest day's first."""
    nodes, seen = [], set()
    for as_of in sorted(set(days), reverse=True):
        for n in await resolve.live_nodes(conn, tenant, as_of):
            if n["id"] not in seen:
                seen.add(n["id"])
                nodes.append(n)
    return nodes


async def solve(conn, tenant, v, q, plan, bounds):
    """One solve per piece of plan, as {node_id: solver row}. bounds(a, b) gives the solver's
    p_start and p_end for a piece."""
    solved = []
    for a, b, as_of in plan:
        p_start, p_end = bounds(a, b)
        if q["kind"] == "DERIVED":
            got = await rows(conn, "SELECT * FROM graph.get_node_derived(%s, %s, %s, %s, %s, %s)",
                             (tenant, q["code"], p_start, p_end, as_of, v.shift_names))
        else:
            got = await rows(conn, "SELECT * FROM graph.get_node_quantity(%s, %s, %s, %s, %s, %s, %s)",
                             (tenant, q["utility"], q["quantity_id"], p_start, p_end, as_of, v.shift_names))
        solved.append({r["node_id"]: r for r in got})
    return solved


def combine(parts, derived):
    """One node's value from its pieces' solver rows, None where it wasn't in that piece's network.
    Returns (value, origin, parts) or None when the node is in no piece's network."""
    got = [r for r in parts if r is not None]
    if not got:
        return None
    if derived:
        p = [r["p_val"] for r in got]
        q = [r["q_val"] for r in got]
        if None in p or None in q:
            return None, "NONE", (None if None in p else sum(p), None if None in q else sum(q))
        p, q = sum(p), sum(q)
        val = None if p == 0 and q == 0 else round(p / (p * p + q * q).sqrt(), 4)
        return val, "DERIVED" if val is not None else "NONE", (p, q)
    if any(r["val"] is None or r["origin"] == "NONE" for r in got):
        return None, "NONE", None
    origins = {r["origin"] for r in got}
    return sum(r["val"] for r in got), origins.pop() if len(origins) == 1 else "ROLLUP", None
