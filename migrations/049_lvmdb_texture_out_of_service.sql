-- Migration: 049_lvmdb_texture_out_of_service.sql
-- Description: End LVMDB_TEXTURE's 20 live edges on 2026-08-17: the board was out of service
--              by 2026-08-18, its loads fed from LVMDB_TEXTURE_2.
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-sankey.md §9.3 (G9); design/graph-reconcile.md §1.10
-- Requires: 048_a4_pv_phase_b.sql
--
-- WHY
-- ---
-- LVMDB_TEXTURE and LVMDB_TEXTURE_2 both feed the same 18 loads, every edge live, which is the
-- "two live board parents" question in the README. The user settled it on 2026-10-19:
-- LVMDB_TEXTURE_2 is the board in operation and LVMDB_TEXTURE is switched off. The earliest
-- document, dated 2026-08-18, says LVMDB_TEXTURE_2's meter is "installed and ready to be
-- onboarded", which implies LVMDB_TEXTURE was already out of service by then. Its meter (107) has
-- no data in September 2026.
--
-- With both parents live, the solver split each load evenly between the boards and valued
-- LVMDB_TEXTURE from its children, so in September 115,972 kWh entered it and left nowhere, and
-- LVMDB_TEXTURE_2's residual was overstated (139,533 against 23,561).
--
-- The board did operate, so this is valid time, not a documentation correction: its edges end on
-- 2026-08-17, the last day it can have been in service on the evidence held. If its meter's last
-- reading shows an earlier date, a later migration moves effective_to back. Edges ended:
--   INCOMING_PLN -> LVMDB_TEXTURE (TRANSFORMER), the 18 SUPPLY_LV feeds, and
--   LVMDB_TEXTURE -> CB_TEXTURE_1600 (PF_COMPENSATION): a board out of service takes its
--   capacitor bank with it.
-- Not changed: the inactive untyped edge already out of effect; LVMDB_TEXTURE_2's edges, which
-- start at '-infinity' (when they began is not known, so before 2026-08-18 both boards still
-- appear as parents); the nodes themselves, which stay whole with site_status = inactive (039),
-- and device 107's measurement rows.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 LVMDB_TEXTURE edges in effect today ==='
SELECT e.edge_type, count(*) AS edges
FROM graph.edge e JOIN graph.node b ON b.node_code = 'LVMDB_TEXTURE' AND b.tenant_id = 3
WHERE (e.from_node_id = b.id OR e.to_node_id = b.id)
  AND e.is_active AND e.effective_from <= CURRENT_DATE
  AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)
GROUP BY 1 ORDER BY 1;
-- expect PF_COMPENSATION 1, SUPPLY_LV 18, TRANSFORMER 1


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _g9 ON COMMIT DROP AS
SELECT e.id, e.edge_type, e.to_node_id, e.from_node_id
FROM graph.edge e JOIN graph.node b ON b.node_code = 'LVMDB_TEXTURE' AND b.tenant_id = 3
WHERE (e.from_node_id = b.id OR e.to_node_id = b.id)
  AND e.is_active AND e.effective_from <= CURRENT_DATE
  AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE);

DO $$
DECLARE
    n INT;
BEGIN
    IF (SELECT count(*) FROM _g9) <> 20
       OR (SELECT count(*) FROM _g9 WHERE edge_type = 'SUPPLY_LV') <> 18 THEN
        RAISE EXCEPTION '049: expected 20 live LVMDB_TEXTURE edges (18 SUPPLY_LV), found %',
            (SELECT count(*) FROM _g9);
    END IF;

    -- every load keeps a live feed from LVMDB_TEXTURE_2
    SELECT count(*) INTO n
    FROM _g9 g
    WHERE g.edge_type = 'SUPPLY_LV'
      AND NOT EXISTS (
          SELECT 1 FROM graph.edge e2 JOIN graph.node p ON p.id = e2.from_node_id
          WHERE p.node_code = 'LVMDB_TEXTURE_2' AND p.tenant_id = 3 AND e2.to_node_id = g.to_node_id
            AND e2.is_active AND e2.effective_from <= CURRENT_DATE
            AND (e2.effective_to IS NULL OR e2.effective_to >= CURRENT_DATE));
    IF n <> 0 THEN
        RAISE EXCEPTION '049: % LVMDB_TEXTURE loads have no live LVMDB_TEXTURE_2 feed', n;
    END IF;

    SELECT count(*) INTO n FROM graph.edge e JOIN _g9 g ON g.id = e.id
    WHERE e.effective_from > DATE '2026-08-17';
    IF n <> 0 THEN
        RAISE EXCEPTION '049: % edges start after 2026-08-17', n;
    END IF;
END
$$;

UPDATE graph.edge e SET effective_to = DATE '2026-08-17'
FROM _g9 g WHERE e.id = g.id;

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Live LVMDB_TEXTURE edges on its last day and the day after ==='
SELECT d.as_of, count(e.id) AS edges
FROM (VALUES (DATE '2026-08-17'), (DATE '2026-08-18')) AS d(as_of)
CROSS JOIN graph.node b
LEFT JOIN graph.edge e ON (e.from_node_id = b.id OR e.to_node_id = b.id)
      AND e.is_active AND e.effective_from <= d.as_of
      AND (e.effective_to IS NULL OR e.effective_to >= d.as_of)
WHERE b.tenant_id = 3 AND b.node_code = 'LVMDB_TEXTURE'
GROUP BY 1 ORDER BY 1;
-- expect 20, then 0

\echo ''
\echo '=== 3.2 Nodes with more than one live feeder today ==='
SELECT count(*) AS multi_parent_nodes FROM (
  SELECT e.to_node_id FROM graph.edge e
  JOIN graph.edge_type et ON et.code = e.edge_type AND et.carries_flow
  WHERE e.tenant_id = 3 AND e.is_active AND e.effective_from <= CURRENT_DATE
    AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)
  GROUP BY 1 HAVING count(*) > 1) x;
-- expect 14, all utilities: 7 electrical (a transformer plus PV or the gas engine, as drawn;
-- 25 before, with the 18 Texture loads), 6 water merges, and BOILER_MIURA (electricity + water)

\echo ''
\echo '=== 3.3 Edge gaps ==='
SELECT count(*) AS edge_gaps FROM graph.v_edge_gaps;


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- UPDATE graph.edge e SET effective_to = NULL FROM graph.node b
--  WHERE b.tenant_id = 3 AND b.node_code = 'LVMDB_TEXTURE'
--    AND (e.from_node_id = b.id OR e.to_node_id = b.id)
--    AND e.is_active AND e.effective_to = DATE '2026-08-17';
