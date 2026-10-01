-- Migration: 029_fix_edge_gaps_window.sql
-- Description: graph.v_edge_gaps must respect the effective window, not just is_active.
-- Author: Claude
-- Date: 2026-09-29
-- Design: design/edge-type.md §8 Q5
-- Requires: 028_create_edge_type.sql
--
-- WHY
-- ---
-- graph.node and graph.edge carry TWO independent retirement mechanisms:
--
--     is_active                     -- the row is switched off
--     effective_from / effective_to -- the row applied over a date range
--
-- graph.solve_flow honours both. v_edge_gaps, as shipped in 028, honours only
-- is_active, so it reports retired edges as live gaps.
--
-- Nine edges on tenant 3 are is_active = true with effective_to = '-infinity':
-- the supply paths superseded when TWIST_PANEL was inserted (2026-09-21) and when
-- MC303_1_9 and MC_RWD moved to LVMDP_SPINNING_1 (2026-09-28). Those re-parents
-- were done correctly. The view, not the data, is wrong.
--
-- This is the same trap that had me report MC303_1_9 as having three parents. It
-- has one: LVMDP_SPINNING_1, then INCOMING_PLN. Leaving the bug in a view means
-- every future reader of the gap list inherits the mistake.
--
-- The view gains p_as_of semantics the only way a view can: CURRENT_DATE. That
-- matches every other default in the graph API.
--
-- NOT fixed here: effective_to = '-infinity' on those nine rows. It excludes them
-- from today correctly, but it also hides them from an as-of query for a date when
-- they WERE the topology, which defeats the column's purpose. Dating them properly
-- is a data change needing confirmation -- see the design note.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Edges that are is_active but no longer effective ==='
SELECT e.id, f.node_code AS parent, t.node_code AS child, e.edge_type,
       e.effective_from, e.effective_to
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active
  AND NOT (e.effective_from <= CURRENT_DATE
           AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE))
ORDER BY 3, 1;
-- expect 9

\echo ''
\echo '=== 1.2 How many of those the current view wrongly lists ==='
SELECT count(*) AS retired_edges_reported_as_gaps
FROM graph.v_edge_gaps g
JOIN graph.edge e ON e.id = g.edge_id
WHERE NOT (e.effective_from <= CURRENT_DATE
           AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE));

\echo ''
\echo '=== 1.3 Gap counts before ==='
SELECT status, count(*) FROM graph.v_edge_gaps WHERE tenant_id = 3
GROUP BY 1 ORDER BY 1;


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

CREATE OR REPLACE VIEW graph.v_edge_gaps AS
WITH e AS (
    SELECT ed.id, ed.tenant_id, ed.edge_type, ed.utility_code, ed.edge_class,
           f.node_code AS from_code, t.node_code AS to_code,
           f.node_type  AS from_type, t.node_type  AS to_type,
           f.node_class AS from_class, t.node_class AS to_class
    FROM graph.edge ed
    JOIN graph.node f ON f.id = ed.from_node_id
    JOIN graph.node t ON t.id = ed.to_node_id
    -- 029: is_active alone is not enough. An edge may be switched on and still be
    -- outside its effective window -- 9 of them are, from two re-parents that were
    -- recorded correctly. graph.solve_flow filters on both; so must this.
    WHERE ed.is_active
      AND ed.effective_from <= CURRENT_DATE
      AND (ed.effective_to IS NULL OR ed.effective_to >= CURRENT_DATE)
      -- and an edge to or from a retired node is not a gap either
      AND f.is_active AND t.is_active
), judged AS (
    SELECT e.*,
           CASE
             WHEN e.edge_type IS NULL THEN 'UNTYPED'
             -- a rule can only be judged when both ends are typed. With 98 loads
             -- still untyped, reporting is the honest answer, not rejection.
             WHEN e.from_type IS NULL OR e.to_type IS NULL THEN 'ENDPOINT_UNTYPED'
             WHEN EXISTS (SELECT 1 FROM graph.edge_type_endpoint x
                           WHERE x.edge_type = e.edge_type
                             AND x.from_kind IN (e.from_type, e.from_class)
                             AND x.to_kind   IN (e.to_type,   e.to_class))
                  THEN NULL
             ELSE 'ILLEGAL_ENDPOINT'
           END AS status
    FROM e
)
-- one CASE, evaluated once, instead of 028's duplicate in the WHERE clause
SELECT tenant_id, id AS edge_id, from_code, to_code, utility_code, edge_type,
       status, from_type, to_type
FROM judged
WHERE status IS NOT NULL;

COMMENT ON VIEW graph.v_edge_gaps IS
  'Active, currently-effective edges between active nodes that are untyped, cannot be '
  'checked because an endpoint node is untyped, or connect a pair their relation does '
  'not permit. The edge half of the site-check list; see graph.v_property_gaps.';

DO $post$
DECLARE
    leaked INTEGER;
BEGIN
    SELECT count(*) INTO leaked
      FROM graph.v_edge_gaps g JOIN graph.edge e ON e.id = g.edge_id
     WHERE NOT (e.effective_from <= CURRENT_DATE
                AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE));
    IF leaked <> 0 THEN
        RAISE EXCEPTION '% retired edge(s) still reported by v_edge_gaps', leaked;
    END IF;

    IF EXISTS (SELECT 1 FROM graph.v_edge_gaps WHERE status = 'ILLEGAL_ENDPOINT') THEN
        RAISE EXCEPTION 'ILLEGAL_ENDPOINT appeared; the narrower filter should only '
                        'ever remove rows';
    END IF;

    RAISE NOTICE 'OK: v_edge_gaps now respects the effective window';
END $post$;


-- ============================================================================
-- 3. Verification -- run BEFORE committing
-- ============================================================================

\echo ''
\echo '=== 3.1 Gap counts after ==='
SELECT status, count(*) FROM graph.v_edge_gaps WHERE tenant_id = 3
GROUP BY 1 ORDER BY 1;
-- ENDPOINT_UNTYPED should fall by the retired edges that were being counted

\echo ''
\echo '=== 3.2 No retired edge survives in the view ==='
SELECT count(*) AS must_be_zero
FROM graph.v_edge_gaps g JOIN graph.edge e ON e.id = g.edge_id
WHERE NOT (e.effective_from <= CURRENT_DATE
           AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE));

\echo ''
\echo '=== 3.3 MC303_1_9 has exactly one live parent ==='
SELECT t.node_code AS node, f.node_code AS parent, e.edge_type
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active AND t.id = 90
  AND e.effective_from <= CURRENT_DATE
  AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE);
-- expect 1 row: LVMDP_SPINNING_1

\echo ''
\echo '=== 3.4 grafReader can still read it ==='
SELECT has_table_privilege('grafReader', 'graph.v_edge_gaps', 'SELECT') AS graf_select;

COMMIT;


-- ============================================================================
-- 4. Undo (commented) -- restores 028's view verbatim
-- ============================================================================
--
-- BEGIN;
-- CREATE OR REPLACE VIEW graph.v_edge_gaps AS
-- WITH e AS (
--     SELECT ed.id, ed.tenant_id, ed.edge_type, ed.utility_code, ed.edge_class,
--            f.node_code AS from_code, t.node_code AS to_code,
--            f.node_type  AS from_type, t.node_type  AS to_type,
--            f.node_class AS from_class, t.node_class AS to_class
--     FROM graph.edge ed
--     JOIN graph.node f ON f.id = ed.from_node_id
--     JOIN graph.node t ON t.id = ed.to_node_id
--     WHERE ed.is_active
-- )
-- SELECT e.tenant_id, e.id AS edge_id, e.from_code, e.to_code, e.utility_code,
--        e.edge_type,
--        CASE
--          WHEN e.edge_type IS NULL THEN 'UNTYPED'
--          WHEN e.from_type IS NULL OR e.to_type IS NULL THEN 'ENDPOINT_UNTYPED'
--          WHEN EXISTS (SELECT 1 FROM graph.edge_type_endpoint x
--                        WHERE x.edge_type = e.edge_type
--                          AND x.from_kind IN (e.from_type, e.from_class)
--                          AND x.to_kind   IN (e.to_type,   e.to_class))
--               THEN NULL
--          ELSE 'ILLEGAL_ENDPOINT'
--        END AS status,
--        e.from_type, e.to_type
-- FROM e
-- WHERE CASE
--         WHEN e.edge_type IS NULL THEN TRUE
--         WHEN e.from_type IS NULL OR e.to_type IS NULL THEN TRUE
--         WHEN EXISTS (SELECT 1 FROM graph.edge_type_endpoint x
--                       WHERE x.edge_type = e.edge_type
--                         AND x.from_kind IN (e.from_type, e.from_class)
--                         AND x.to_kind   IN (e.to_type,   e.to_class))
--              THEN FALSE
--         ELSE TRUE
--       END;
-- COMMIT;
