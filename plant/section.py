"""One node and what it feeds, or what feeds it, as an o-mcp/subgraph v1 document: the MCP server's
plant_section and the API's GET /api/section. The query is tools/sld.sql, the same file tools/sld.py
draws from."""
from . import sqlfile
from .db import client_rows

DEPTH_MAX = 12
DIRECTIONS = ("down", "up")


async def subgraph(conn, tenant, root, as_of, depth, direction, utility=None):
    """root is a node code in effect on as_of; as_of a date in ISO form."""
    return (await client_rows(conn, sqlfile.load("tools/sld.sql"), {
        "tenant": tenant, "root": root, "as_of": as_of, "depth": depth, "utility": utility or "",
        "direction": direction}))[0]["json_build_object"]
