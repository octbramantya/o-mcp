"""Which nodes match a set of filters, as of a day: an o-mcp/nodelist v1 document. The MCP server's
plant_find and the API's GET /api/nodes."""
from .db import rows

FILTERS = ("text", "type", "class", "utility", "metered", "site_status")

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
  SELECT n.id, n.node_code AS code, n.node_name AS name, n.node_class AS class, n.node_type AS type,
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


async def nodelist(conn, tenant, vocab, as_of, filters, limit):
    """filters holds any of FILTERS; an absent one doesn't filter. type includes its subtypes."""
    f = {k: filters.get(k) for k in FILTERS}
    params = dict(f, tenant=tenant, as_of=as_of, limit=limit, types=vocab.subtypes(f["type"]) if f["type"] else None)
    found = await rows(conn, SQL, params)
    total = found[0]["total"] if found else 0
    for r in found:
        del r["total"]
    query = {"tenant": tenant, "as_of": as_of, "limit": limit}
    query.update({k: v for k, v in f.items() if v is not None})
    return {"schema": "o-mcp/nodelist", "version": 1, "query": query, "total": total, "returned": len(found),
            "nodes": found}
