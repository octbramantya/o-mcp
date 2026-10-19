-- Migration: 047_swap_wtp_names.sql
-- Description: Swap the codes and names of the nodes WTP_1 and WTP_2, so device 92 sits on
--              "WTP 1" and device 91 on "WTP 2", as public.devices has them.
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-reconcile.md §1.3 (rows 91/92), §1.10 (G2)
-- Requires: 046_device28_on_a5_feeder.sql
--
-- WHY
-- ---
-- public.devices is authoritative for which plant is WTP 1 and which WTP 2 (decided
-- 2026-10-14): WTP 1 = device 92, WTP 2 = device 91. The graph has the meters on the right
-- boards but the names the wrong way round: node WTP_1 carries 91 under LVMDB_B2, node WTP_2
-- carries 92 under LVMDB_TF630. The boards confirm the meters: BOILER_MIURA on B2 takes its
-- water from WTP2_RO_PROC, so the B2 plant is WTP 2. The reports already follow devices
-- (factory_b reads 91 on B2, twisting_detail reads 92 on TF630).
--
-- So the fix is the two labels, not the measurements or the edges: each node keeps its id,
-- type, board, meter and children, and only node_code and node_name change places. The graph
-- has no history for labels, so this is an in-place update. Nothing in the graph refers to a
-- node by code (edges, measurements and node_category use ids); the hand-authored seed CSVs in
-- design/ keep the old labels as the record of what was seeded.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 The two nodes, their boards and meters ==='
SELECT n.id, n.node_code, n.node_name, n.node_type, p.node_code AS board,
       string_agg(DISTINCT m.device_id::text, ' ') AS devices
FROM graph.node n
LEFT JOIN graph.edge e ON e.to_node_id = n.id AND e.is_active AND e.effective_from <= CURRENT_DATE
                      AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)
LEFT JOIN graph.node p ON p.id = e.from_node_id
LEFT JOIN graph.measurement m ON m.node_id = n.id AND m.is_active AND m.effective_from <= CURRENT_DATE
                             AND (m.effective_to IS NULL OR m.effective_to >= CURRENT_DATE)
WHERE n.tenant_id = 3 AND n.node_code IN ('WTP_1', 'WTP_2')
GROUP BY 1, 2, 3, 4, 5 ORDER BY 2;
-- expect WTP_1 under LVMDB_B2 with 91, WTP_2 under LVMDB_TF630 with 92

\echo ''
\echo '=== 1.2 What devices calls them ==='
SELECT id, display_name FROM public.devices WHERE id IN (91, 92) ORDER BY id;


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _g2 ON COMMIT DROP AS
SELECT n.id, n.node_code, n.node_name
FROM graph.node n
WHERE n.tenant_id = 3 AND n.node_code IN ('WTP_1', 'WTP_2');

DO $$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n
    FROM _g2 g
    JOIN graph.measurement m ON m.node_id = g.id AND m.is_active
     AND m.effective_from <= CURRENT_DATE
     AND (m.effective_to IS NULL OR m.effective_to >= CURRENT_DATE)
    WHERE (g.node_code = 'WTP_1' AND m.device_id = 91)
       OR (g.node_code = 'WTP_2' AND m.device_id = 92);
    IF n = 0 OR (SELECT count(*) FROM _g2) <> 2 THEN
        RAISE EXCEPTION '047: expected WTP_1 metered by 91 and WTP_2 by 92; the names may already be swapped';
    END IF;

    SELECT count(*) INTO n
    FROM _g2 g
    JOIN graph.measurement m ON m.node_id = g.id AND m.is_active
     AND m.effective_from <= CURRENT_DATE
     AND (m.effective_to IS NULL OR m.effective_to >= CURRENT_DATE)
    WHERE (g.node_code = 'WTP_1' AND m.device_id = 92)
       OR (g.node_code = 'WTP_2' AND m.device_id = 91);
    IF n <> 0 THEN
        RAISE EXCEPTION '047: a node carries the other plant''s meter (% rows); not a plain swap', n;
    END IF;
END
$$;

-- One row at a time through a placeholder: uq_node_tenant_code is checked per row, so a
-- single UPDATE of both rows collides with itself.
UPDATE graph.node SET node_code = 'WTP_SWAP_047'
 WHERE id = (SELECT id FROM _g2 WHERE node_code = 'WTP_1');

UPDATE graph.node n SET node_code = o.node_code, node_name = o.node_name
  FROM _g2 g, _g2 o
 WHERE g.node_code = 'WTP_2' AND o.node_code = 'WTP_1' AND n.id = g.id;

UPDATE graph.node n SET node_code = o.node_code, node_name = o.node_name
  FROM _g2 g, _g2 o
 WHERE g.node_code = 'WTP_1' AND o.node_code = 'WTP_2' AND n.id = g.id;

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 After ==='
SELECT n.id, n.node_code, n.node_name, p.node_code AS board,
       string_agg(DISTINCT m.device_id::text, ' ') AS devices
FROM graph.node n
LEFT JOIN graph.edge e ON e.to_node_id = n.id AND e.is_active AND e.effective_from <= CURRENT_DATE
                      AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)
LEFT JOIN graph.node p ON p.id = e.from_node_id
LEFT JOIN graph.measurement m ON m.node_id = n.id AND m.is_active AND m.effective_from <= CURRENT_DATE
                             AND (m.effective_to IS NULL OR m.effective_to >= CURRENT_DATE)
WHERE n.tenant_id = 3 AND n.node_code IN ('WTP_1', 'WTP_2')
GROUP BY 1, 2, 3, 4 ORDER BY 2;
-- expect WTP_1 under LVMDB_TF630 with 92, WTP_2 under LVMDB_B2 with 91


-- ============================================================================
-- 4. Undo (commented): run section 2 again; the swap is its own inverse once the
--    guard's device numbers are swapped too.
-- ============================================================================
