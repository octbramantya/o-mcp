-- The neighbourhood of one node down to :depth levels, as one o-mcp/subgraph v1 document.
-- The format is defined in design/subgraph-format.md; tools/sld.py renders it.
--
--   psql -v tenant=3 -v root=INCOMING_PLN -v as_of=2026-10-01 -v depth=2 -v utility= -f tools/sld.sql
--
-- Nodes and edges are filtered to the effective window at :as_of. :utility, when not empty, keeps
-- only that utility's edges. The walk goes down from the root; every live edge INTO a reached node
-- is returned, from anywhere, so second parents and injecting sources (PV, generators: heads a
-- downward walk never reaches) come back too. Those unreached parents are included with
-- scope = 'parent', together with their own incoming edges, one hop further up; the far end of
-- such an edge is included with scope = 'context', so every edge's two ends are in 'nodes'.
WITH RECURSIVE
live_n AS (
  SELECT * FROM graph.node n
  WHERE n.tenant_id = :tenant
    AND n.is_active AND n.effective_from <= :'as_of'::date
    AND (n.effective_to IS NULL OR n.effective_to >= :'as_of'::date)
), live_e AS (
  SELECT e.*, coalesce(et.carries_flow, true) AS carries_flow
  FROM graph.edge e
  JOIN live_n f ON f.id = e.from_node_id
  JOIN live_n t ON t.id = e.to_node_id
  LEFT JOIN graph.edge_type et ON et.code = e.edge_type
  WHERE e.tenant_id = :tenant
    AND e.is_active AND e.effective_from <= :'as_of'::date
    AND (e.effective_to IS NULL OR e.effective_to >= :'as_of'::date)
    AND (nullif(:'utility', '') IS NULL OR e.utility_code = :'utility')
), root AS (
  SELECT * FROM live_n WHERE node_code = :'root'
), walk(node_id, depth) AS (
  SELECT id, 0 FROM root
  UNION
  SELECT e.to_node_id, w.depth + 1
  FROM walk w JOIN live_e e ON e.from_node_id = w.node_id
  WHERE w.depth < :depth
), reached AS (
  SELECT node_id, min(depth) AS depth FROM walk GROUP BY node_id
), parent AS (       -- unreached parents of reached nodes
  SELECT DISTINCT e.from_node_id AS node_id
  FROM live_e e JOIN reached rt ON rt.node_id = e.to_node_id
  WHERE e.from_node_id NOT IN (SELECT node_id FROM reached)
), doc_e AS (         -- every live edge into a reached or parent node
  SELECT e.* FROM live_e e
  WHERE e.to_node_id IN (SELECT node_id FROM reached UNION ALL SELECT node_id FROM parent)
), incl AS (          -- every node in the document; every edge's two ends are among them
  SELECT node_id, depth, 'reached' AS scope FROM reached
  UNION ALL
  SELECT node_id, NULL::int, 'parent' FROM parent
  UNION ALL
  SELECT DISTINCT e.from_node_id, NULL::int, 'context'   -- far end of a parent's own supply
  FROM doc_e e
  WHERE e.from_node_id NOT IN (SELECT node_id FROM reached UNION ALL SELECT node_id FROM parent)
), findings AS (
  SELECT 'MULTIPLE_LIVE_PARENTS' AS code, t.node_code AS sort_key,
         json_build_object('code', 'MULTIPLE_LIVE_PARENTS', 'node', t.node_code,
                           'parents', json_agg(f.node_code ORDER BY f.node_code),
                           'message', format('%s has %s live parents (%s). The plant may have only one; '
                                             'confirm on site which board feeds it.', t.node_code, count(*),
                                             string_agg(f.node_code, ', ' ORDER BY f.node_code))) AS body
  FROM live_e e
  JOIN reached r ON r.node_id = e.to_node_id
  JOIN live_n t ON t.id = e.to_node_id
  JOIN live_n f ON f.id = e.from_node_id
  WHERE f.node_class <> 'SOURCE'
    AND t.node_class <> 'STORAGE'   -- a tank with several inflows is ordinary
  GROUP BY t.node_code
  HAVING count(*) > 1
  UNION ALL
  SELECT 'IMPLICIT_BUS', n.node_code,
         json_build_object('code', 'IMPLICIT_BUS', 'node', n.node_code, 'children', count(*),
                           'message', format('%s is not a bus but feeds %s children directly, so the busbar '
                                             'they share on site has no node of its own.', n.node_code, count(*)))
  FROM incl i
  JOIN live_n n ON n.id = i.node_id
  JOIN live_e e ON e.from_node_id = n.id AND e.carries_flow
  WHERE n.node_class NOT IN ('BUS', 'STORAGE')   -- a tank pools what it holds; no busbar is missing
  GROUP BY n.node_code
  HAVING count(*) > 1
  UNION ALL
  SELECT 'PROPERTY_GAP', g.node_code || '.' || g.attr_key,
         json_build_object('code', 'PROPERTY_GAP', 'node', g.node_code, 'property', g.attr_key,
                           'kind', g.kind, 'status', g.status, 'used_by', g.used_by, 'detail', g.detail,
                           'message', format('%s has no %s (%s), which %s needs.', g.node_code, g.attr_key,
                                             lower(g.status), coalesce(g.used_by, 'a registered reader')))
  FROM graph.v_property_gaps g
  JOIN live_n n ON n.tenant_id = g.tenant_id AND n.node_code = g.node_code
  JOIN incl i ON i.node_id = n.id
  UNION ALL
  SELECT 'EDGE_GAP', g.edge_id::text,
         json_build_object('code', 'EDGE_GAP', 'edge', g.edge_id, 'from', g.from_code, 'to', g.to_code,
                           'status', g.status,
                           'message', format('Edge %s (%s -> %s) %s.', g.edge_id, g.from_code, g.to_code,
                                             CASE g.status
                                               WHEN 'UNTYPED' THEN 'has no edge type'
                                               WHEN 'ENDPOINT_UNTYPED' THEN 'joins a node that has no node type'
                                               WHEN 'ILLEGAL_ENDPOINT' THEN 'connects node types its edge type does not allow'
                                               ELSE 'fails the edge ontology: ' || g.status END))
  FROM graph.v_edge_gaps g
  JOIN doc_e e ON e.id = g.edge_id
)
SELECT json_build_object(
  'schema', 'o-mcp/subgraph',
  'version', 1,
  'query', json_build_object('tenant', :tenant, 'root', :'root', 'as_of', :'as_of',
                             'depth', :depth, 'utility', nullif(:'utility', '')),
  'nodes', coalesce((
    SELECT json_agg(json_build_object(
             'code', n.node_code, 'name', n.node_name, 'class', n.node_class, 'type', n.node_type,
             'attrs', n.attrs, 'scope', i.scope, 'depth', i.depth,
             'children_total', (SELECT count(*) FROM live_e e WHERE e.from_node_id = n.id),
             'children_not_included', (SELECT count(*) FROM live_e e
                                       WHERE e.from_node_id = n.id
                                         AND e.to_node_id NOT IN (SELECT node_id FROM incl)))
           ORDER BY array_position(ARRAY['reached', 'parent', 'context'], i.scope), i.depth, n.node_code)
    FROM incl i JOIN live_n n ON n.id = i.node_id), '[]'::json),
  'edges', coalesce((
    SELECT json_agg(json_build_object(
             'id', e.id, 'from', f.node_code, 'to', t.node_code, 'type', e.edge_type,
             'class', e.edge_class, 'utility', e.utility_code, 'carries_flow', e.carries_flow,
             'effective_from', e.effective_from, 'effective_to', e.effective_to)
           ORDER BY f.node_code, t.node_code, e.id)
    FROM doc_e e JOIN live_n f ON f.id = e.from_node_id JOIN live_n t ON t.id = e.to_node_id), '[]'::json),
  'findings', coalesce((SELECT json_agg(body ORDER BY code, sort_key) FROM findings), '[]'::json)
);
