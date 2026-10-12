"""Which node a person meant. Node codes are plant data, not vocabulary, so they are never an enum;
the server resolves what it is given, and never guesses past an exact match.

Order: the code exactly, the code ignoring case and separators (`lvmdb a5`, `LVMDB-A5`), the name
ignoring case. Anything else is a miss, answered with the nearest codes and names.
"""
import difflib
import re

from .db import rows
from .errors import ToolError

LIVE_NODES = """
    SELECT n.id, n.node_code AS code, n.node_name AS name, n.node_class AS class, n.node_type AS type, n.attrs
    FROM graph.node n
    WHERE n.tenant_id = %(tenant)s
      AND n.is_active AND n.effective_from <= %(as_of)s
      AND (n.effective_to IS NULL OR n.effective_to >= %(as_of)s)
"""


class NotFound(ToolError):
    """A tool error the model can act on: the message names the nearest nodes."""


def _norm(s):
    return re.sub(r"[\s_\-./]+", "_", s.strip()).upper()


async def live_nodes(conn, tenant, as_of):
    return await rows(conn, LIVE_NODES, {"tenant": tenant, "as_of": as_of})


def pick(nodes, given, as_of):
    """The node `given` names, or NotFound with candidates. Returns (node, how) where how says what
    matched, for the response to state."""
    by_code = {n["code"]: n for n in nodes}
    if given in by_code:
        return by_code[given], None
    norm = [n for n in nodes if _norm(n["code"]) == _norm(given)]
    if len(norm) == 1:
        return norm[0], f"{given!r} was read as the code {norm[0]['code']}"
    named = [n for n in nodes if n["name"] and n["name"].strip().lower() == given.strip().lower()]
    if len(named) == 1:
        return named[0], f"{given!r} is the name of {named[0]['code']}"
    raise NotFound(f"No node {given!r} in effect on {as_of}. " + nearest(nodes, given))


def nearest(nodes, given, n=5):
    keys = {}
    for node in nodes:
        keys[_norm(node["code"])] = node
        if node["name"]:
            keys[_norm(node["name"])] = node
    hits = []
    for k in difflib.get_close_matches(_norm(given), list(keys), n=n * 2, cutoff=0.5):
        if keys[k] not in hits:
            hits.append(keys[k])
    if not hits:
        return "Nothing is close; use plant_find to search by text, type or class."
    return "Nearest: " + "; ".join(f"{h['code']} ({h['name']})" for h in hits[:n]) + "."
