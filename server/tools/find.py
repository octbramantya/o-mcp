"""plant_find: which nodes match. A list, not a subgraph."""
from .. import tools
from ..db import rows

NAME = "plant_find"
TITLE = "Find plant nodes"
FORMAT = "nodelist-v1.schema.json"
DESCRIPTION = """\
Lists the plant's nodes (boards, machines, sources, tanks, treatment stages) that match every filter \
given, as of a date. Use it to find a node's code before calling another tool, or to answer "which \
nodes are ...". `type` includes its subtypes (SWITCHBOARD finds main boards and sub-boards). Each row \
says whether the node has a meter of its own or on its feeder (`metered`) and how many live feeders it \
has; more than one is an open question for the site, which plant_section shows. \
For how nodes connect, use plant_section; for what a node's meters report, node_meters. \
Rows are capped at `limit`; `total` says how many matched."""

LIMIT_MAX = 200

SQL = """
WITH live_n AS (
  SELECT * FROM graph.node n
  WHERE n.tenant_id = %(tenant)s
    AND n.is_active AND n.effective_from <= %(as_of)s
    AND (n.effective_to IS NULL OR n.effective_to >= %(as_of)s)
), live_e AS (
  SELECT e.*, coalesce(et.carries_flow, true) AS carries_flow
  FROM graph.edge e
  JOIN live_n f ON f.id = e.from_node_id
  JOIN live_n t ON t.id = e.to_node_id
  LEFT JOIN graph.edge_type et ON et.code = e.edge_type
  WHERE e.tenant_id = %(tenant)s
    AND e.is_active AND e.effective_from <= %(as_of)s
    AND (e.effective_to IS NULL OR e.effective_to >= %(as_of)s)
), live_m AS (
  SELECT m.* FROM graph.measurement m
  WHERE m.tenant_id = %(tenant)s
    AND m.is_active AND m.effective_from <= %(as_of)s
    AND (m.effective_to IS NULL OR m.effective_to >= %(as_of)s)
), facts AS (
  SELECT n.id,
         ARRAY(SELECT DISTINCT e.utility_code FROM live_e e
               WHERE n.id IN (e.from_node_id, e.to_node_id) ORDER BY 1) AS utilities,
         EXISTS (SELECT 1 FROM live_m m
                 WHERE m.node_id = n.id
                    OR m.edge_id IN (SELECT e.id FROM live_e e WHERE e.to_node_id = n.id)) AS metered,
         (SELECT count(*) FROM live_e e WHERE e.to_node_id = n.id AND e.carries_flow) AS feeders
  FROM live_n n
), hits AS (
  SELECT n.node_code AS code, n.node_name AS name, n.node_class AS class, n.node_type AS type,
         f.utilities, f.metered, f.feeders::int AS feeders,
         n.attrs->>'site_status' AS site_status, n.attrs->>'site_status_as_of' AS site_status_as_of
  FROM live_n n JOIN facts f ON f.id = n.id
  WHERE (%(text)s::text IS NULL
         OR n.node_code ILIKE '%%' || %(text)s || '%%' OR n.node_name ILIKE '%%' || %(text)s || '%%')
    AND (%(types)s::text[] IS NULL OR n.node_type = ANY (%(types)s::text[]))
    AND (%(class)s::text IS NULL OR n.node_class = %(class)s)
    AND (%(utility)s::text IS NULL OR %(utility)s = ANY (f.utilities))
    AND (%(metered)s::boolean IS NULL OR f.metered = %(metered)s)
    AND (%(site_status)s::text IS NULL
         OR coalesce(n.attrs->>'site_status', 'none') = %(site_status)s)
)
SELECT *, count(*) OVER () AS total FROM hits ORDER BY code LIMIT %(limit)s
"""


def input_schema(ctx):
    v = ctx.vocab
    statuses = next((p["enum_values"] for p in v.properties if p["key"] == "site_status"), None) or []
    return {
        "type": "object",
        "required": ["as_of"],
        "properties": {
            "text": {"type": "string", "minLength": 1,
                     "description": "Part of a code or name, any case, e.g. TEXTURE or compressor."},
            "type": {"enum": [t["code"] for t in v.node_types],
                     "description": "Node type, subtypes included. Meanings: plant_vocabulary kind node_type."},
            "class": {"oneOf": [{"const": c["code"], "description": c["description"]} for c in v.node_classes],
                      "description": "Node class, the broad role."},
            "utility": tools.utility(ctx, "Only nodes with an edge of this utility."),
            "metered": {"type": "boolean",
                        "description": "true: a meter is on the node or its feeder. false: neither; the solver "
                                       "infers its values from its neighbours."},
            "site_status": {"enum": [*statuses, "none"],
                            "description": "Status the site has declared. none: nothing declared, which is not the "
                                           "same as normal."},
            "as_of": tools.as_of(ctx),
            "limit": {"type": "integer", "minimum": 1, "maximum": LIMIT_MAX, "default": 50,
                      "description": "Most rows to return."},
        },
        "additionalProperties": False,
    }


async def run(ctx, args):
    v = ctx.vocab
    params = {"tenant": ctx.config.tenant, "as_of": args["as_of"], "text": args.get("text"),
              "types": v.subtypes(args["type"]) if args.get("type") else None, "class": args.get("class"),
              "utility": args.get("utility"), "metered": args.get("metered"),
              "site_status": args.get("site_status"), "limit": args["limit"]}
    async with ctx.db.tx() as conn:
        found = await rows(conn, SQL, params)
    total = found[0]["total"] if found else 0
    for r in found:
        del r["total"]
    query = {"tenant": ctx.config.tenant, "as_of": args["as_of"], "limit": args["limit"]}
    query.update({k: args[k] for k in ("text", "type", "class", "utility", "metered", "site_status") if k in args})
    doc = {"schema": "o-mcp/nodelist", "version": 1, "query": query, "total": total, "returned": len(found),
           "nodes": found}
    if total > len(found):
        summary = f"{total} nodes match; the first {len(found)} by code are listed. Narrow the filters or raise limit."
    else:
        summary = f"{total} nodes match."
    return doc, summary
