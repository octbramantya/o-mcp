-- Migration: 016_create_topology_primitives.sql
-- Description: Reusable reachability functions over graph.edge
-- Author: Claude
-- Date: 2026-08-19
-- Phase: 0 -- additive (see §8 and §14 of design/graph-network-design.md)
--
-- Numbered after the Phase 5/6 drops only because it was written later. It is
-- additive and read-only: apply it any time after 009, in any phase.
--
-- WHY THESE LIVE IN SQL AND NOT IN PYTHON
--
-- The graph schema owns topology; analytics scripts own statistics (§14). Every
-- consumer -- the dashboard, the flow solver, the scheduled power-quality jobs --
-- must agree on who is downstream of what. Reimplementing adjacency in a second
-- language is how the Sankey and the weekly report end up disagreeing, so the
-- traversal is defined once, here, and Python calls it rather than rebuilding it.
--
-- All three are STABLE and take no temp tables, so they need no privilege beyond
-- the SELECT granted in 010 -- unlike graph.solve_flow, they are safe to call
-- from a read-only role in a read-only transaction.
--
-- SHARED SEMANTICS
--
--   p_utility_code  NULL traverses every utility, which means a walk MAY cross a
--                   tie point -- from ELECTRICITY into WATER at BOILER_MIURA, for
--                   instance. That is the point of modelling tie points, but it
--                   is rarely what a single-network question wants. Pass a code
--                   to stay inside one network.
--   p_as_of         Honours effective_from / effective_to on both nodes and edges,
--                   so a walk reflects the topology on that date.
--   p_max_depth     Belt and braces. graph.assert_no_cycle already prevents cycles
--                   and the path array prevents revisits; this bounds the walk if
--                   either is ever bypassed.
--   Self            Never returned. Descendants and ancestors both start at depth 1.
--   Multiple paths  A DAG can reach the same node more than one way. One row per
--                   node is returned, at the SHALLOWEST depth, and `path` is that
--                   one representative route -- not an exhaustive path list.

BEGIN;

-- ============================================================================
-- Everything fed from this node. "What goes dark if this breaker opens."
-- ============================================================================
CREATE OR REPLACE FUNCTION graph.descendants(
    p_tenant_id    INTEGER,
    p_node_code    VARCHAR,
    p_utility_code VARCHAR DEFAULT NULL,
    p_as_of        DATE    DEFAULT CURRENT_DATE,
    p_max_depth    INTEGER DEFAULT 20
) RETURNS TABLE (
    node_id     BIGINT,
    node_code   VARCHAR,
    node_name   VARCHAR,
    node_class  VARCHAR,
    depth       INTEGER,
    via_utility VARCHAR,
    path        VARCHAR[]
) LANGUAGE sql STABLE AS $$
WITH RECURSIVE root AS (
    SELECT r.id, r.node_code
    FROM graph.node r
    WHERE r.tenant_id = p_tenant_id AND r.node_code = p_node_code AND r.is_active
      AND r.effective_from <= p_as_of
      AND (r.effective_to IS NULL OR r.effective_to >= p_as_of)
), walk AS (
    SELECT c.id, c.node_code, c.node_name, c.node_class,
           1 AS depth, e.utility_code AS via_utility,
           ARRAY[r.node_code, c.node_code]::VARCHAR[] AS path
    FROM root r
    JOIN graph.edge e
      ON e.from_node_id = r.id AND e.tenant_id = p_tenant_id AND e.is_active
     AND (p_utility_code IS NULL OR e.utility_code = p_utility_code)
     AND e.effective_from <= p_as_of
     AND (e.effective_to IS NULL OR e.effective_to >= p_as_of)
    JOIN graph.node c
      ON c.id = e.to_node_id AND c.is_active
     AND c.effective_from <= p_as_of
     AND (c.effective_to IS NULL OR c.effective_to >= p_as_of)
  UNION ALL
    SELECT c.id, c.node_code, c.node_name, c.node_class,
           w.depth + 1, e.utility_code,
           w.path || c.node_code
    FROM walk w
    JOIN graph.edge e
      ON e.from_node_id = w.id AND e.tenant_id = p_tenant_id AND e.is_active
     AND (p_utility_code IS NULL OR e.utility_code = p_utility_code)
     AND e.effective_from <= p_as_of
     AND (e.effective_to IS NULL OR e.effective_to >= p_as_of)
    JOIN graph.node c
      ON c.id = e.to_node_id AND c.is_active
     AND c.effective_from <= p_as_of
     AND (c.effective_to IS NULL OR c.effective_to >= p_as_of)
    WHERE w.depth < p_max_depth
      AND NOT (c.node_code = ANY (w.path))
)
SELECT DISTINCT ON (w.id)
       w.id, w.node_code, w.node_name, w.node_class, w.depth, w.via_utility, w.path
FROM walk w
ORDER BY w.id, w.depth;
$$;

COMMENT ON FUNCTION graph.descendants(INTEGER, VARCHAR, VARCHAR, DATE, INTEGER) IS
  'Every node fed from p_node_code, shallowest path per node. Excludes self.';

-- ============================================================================
-- The path back towards source. "Whose fault is this, upstream."
-- ============================================================================
CREATE OR REPLACE FUNCTION graph.ancestors(
    p_tenant_id    INTEGER,
    p_node_code    VARCHAR,
    p_utility_code VARCHAR DEFAULT NULL,
    p_as_of        DATE    DEFAULT CURRENT_DATE,
    p_max_depth    INTEGER DEFAULT 20
) RETURNS TABLE (
    node_id     BIGINT,
    node_code   VARCHAR,
    node_name   VARCHAR,
    node_class  VARCHAR,
    depth       INTEGER,
    via_utility VARCHAR,
    path        VARCHAR[]
) LANGUAGE sql STABLE AS $$
WITH RECURSIVE root AS (
    SELECT r.id, r.node_code
    FROM graph.node r
    WHERE r.tenant_id = p_tenant_id AND r.node_code = p_node_code AND r.is_active
      AND r.effective_from <= p_as_of
      AND (r.effective_to IS NULL OR r.effective_to >= p_as_of)
), walk AS (
    SELECT f.id, f.node_code, f.node_name, f.node_class,
           1 AS depth, e.utility_code AS via_utility,
           ARRAY[r.node_code, f.node_code]::VARCHAR[] AS path
    FROM root r
    JOIN graph.edge e
      ON e.to_node_id = r.id AND e.tenant_id = p_tenant_id AND e.is_active
     AND (p_utility_code IS NULL OR e.utility_code = p_utility_code)
     AND e.effective_from <= p_as_of
     AND (e.effective_to IS NULL OR e.effective_to >= p_as_of)
    JOIN graph.node f
      ON f.id = e.from_node_id AND f.is_active
     AND f.effective_from <= p_as_of
     AND (f.effective_to IS NULL OR f.effective_to >= p_as_of)
  UNION ALL
    SELECT f.id, f.node_code, f.node_name, f.node_class,
           w.depth + 1, e.utility_code,
           w.path || f.node_code
    FROM walk w
    JOIN graph.edge e
      ON e.to_node_id = w.id AND e.tenant_id = p_tenant_id AND e.is_active
     AND (p_utility_code IS NULL OR e.utility_code = p_utility_code)
     AND e.effective_from <= p_as_of
     AND (e.effective_to IS NULL OR e.effective_to >= p_as_of)
    JOIN graph.node f
      ON f.id = e.from_node_id AND f.is_active
     AND f.effective_from <= p_as_of
     AND (f.effective_to IS NULL OR f.effective_to >= p_as_of)
    WHERE w.depth < p_max_depth
      AND NOT (f.node_code = ANY (w.path))
)
SELECT DISTINCT ON (w.id)
       w.id, w.node_code, w.node_name, w.node_class, w.depth, w.via_utility, w.path
FROM walk w
ORDER BY w.id, w.depth;
$$;

COMMENT ON FUNCTION graph.ancestors(INTEGER, VARCHAR, VARCHAR, DATE, INTEGER) IS
  'Every node feeding p_node_code, shallowest path per node. Excludes self.';

-- ============================================================================
-- Nodes sharing a direct feeder. "Did the whole bus dip, or just this branch."
--
-- One row per (sibling, shared parent) pair -- a node with two feeders can be a
-- sibling of the same node twice, via different buses, and which bus it was
-- matters for the diagnosis. Both hops are forced onto the SAME utility, so a
-- tie point does not make an electrical load the sibling of a water vessel.
-- ============================================================================
CREATE OR REPLACE FUNCTION graph.siblings(
    p_tenant_id    INTEGER,
    p_node_code    VARCHAR,
    p_utility_code VARCHAR DEFAULT NULL,
    p_as_of        DATE    DEFAULT CURRENT_DATE
) RETURNS TABLE (
    node_id          BIGINT,
    node_code        VARCHAR,
    node_name        VARCHAR,
    node_class       VARCHAR,
    via_parent_id    BIGINT,
    via_parent_code  VARCHAR,
    via_utility      VARCHAR
) LANGUAGE sql STABLE AS $$
SELECT DISTINCT
       s.id, s.node_code, s.node_name, s.node_class,
       p.id, p.node_code, e_up.utility_code
FROM graph.node r
JOIN graph.edge e_up
  ON e_up.to_node_id = r.id AND e_up.tenant_id = p_tenant_id AND e_up.is_active
 AND (p_utility_code IS NULL OR e_up.utility_code = p_utility_code)
 AND e_up.effective_from <= p_as_of
 AND (e_up.effective_to IS NULL OR e_up.effective_to >= p_as_of)
JOIN graph.node p
  ON p.id = e_up.from_node_id AND p.is_active
 AND p.effective_from <= p_as_of
 AND (p.effective_to IS NULL OR p.effective_to >= p_as_of)
JOIN graph.edge e_dn
  ON e_dn.from_node_id = p.id AND e_dn.tenant_id = p_tenant_id AND e_dn.is_active
 AND e_dn.utility_code = e_up.utility_code
 AND e_dn.effective_from <= p_as_of
 AND (e_dn.effective_to IS NULL OR e_dn.effective_to >= p_as_of)
JOIN graph.node s
  ON s.id = e_dn.to_node_id AND s.is_active AND s.id <> r.id
 AND s.effective_from <= p_as_of
 AND (s.effective_to IS NULL OR s.effective_to >= p_as_of)
WHERE r.tenant_id = p_tenant_id AND r.node_code = p_node_code AND r.is_active
  AND r.effective_from <= p_as_of
  AND (r.effective_to IS NULL OR r.effective_to >= p_as_of);
$$;

COMMENT ON FUNCTION graph.siblings(INTEGER, VARCHAR, VARCHAR, DATE) IS
  'Nodes sharing a direct feeder with p_node_code, one row per shared feeder.';

-- ============================================================================
-- Grants. 010 already sets ALTER DEFAULT PRIVILEGES for functions in this
-- schema, so this is belt and braces for the case where 016 is applied by a
-- different role than 010 was. Guarded so the file runs on a cluster that has
-- no grafReader -- a local test cluster, typically.
-- ============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafReader') THEN
        EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graph TO "grafReader"';
    END IF;
END $$;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
-- SELECT COUNT(*) FROM graph.descendants(3, 'INCOMING_PLN', 'ELECTRICITY');
-- SELECT * FROM graph.ancestors(3, 'AHU_4_7', 'ELECTRICITY') ORDER BY depth;
-- SELECT * FROM graph.siblings(3, 'AHU_4_7', 'ELECTRICITY');
--
-- Cross-utility tie point: with a utility, only that network is walked;
-- without one, the walk crosses into WATER at the boiler.
-- SELECT via_utility, COUNT(*) FROM graph.ancestors(3, 'BOILER_MIURA')
--  GROUP BY 1;
