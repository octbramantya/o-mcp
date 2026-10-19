-- Migration: 052_comp_winder_under_lvsdp_comp_23.sql
-- Description: COMP_WINDER is fed from LVSDP_COMP_23, not directly from LVMDP_SPINNING_3
--              (documentation correction).
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-sankey.md §9.4 (G10, Spinning 3); design/graph-reconcile.md §1.10
-- Requires: 051_solver_passthrough_split.sql
--
-- WHY
-- ---
-- LVSDP_COMP_23 ("LVSDP Compressor 2 & 3") feeds both compressor sub-boards, COMP_INTERLACE (73)
-- and COMP_WINDER (72). The user checked this against the site on 2026-10-19. The graph has only
-- COMP_INTERLACE under it, and COMP_WINDER fed straight from LVMDP_SPINNING_3 (edge 134).
-- LVSDP_PROD_ATY -> COMP_AIKI (105) is correct and unchanged.
--
-- The plant did not change; the drawing was wrong. So edge 134 gets effective_to = '-infinity'
-- (kept as the record of the old belief), and the new feed LVSDP_COMP_23 -> COMP_WINDER starts at
-- '-infinity'. COMP_WINDER keeps its node, meter 72 and its five children (COMP_FS_WIND_4,
-- COMP_NVX_WND_3, COM_SCR_WIND_5, DRYER_INT_1, PUMP_COOL_WND), which move with it.
--
-- Solver effect: LVSDP_COMP_23 (unmetered) was valued from its out-edges as 73 alone and becomes
-- 72 + 73. Nothing else moves: 72 is still below LVMDP_SPINNING_3, so the board's residual
-- (74 - 72 - 73 - 105 - 140) is unchanged. That residual is still negative because meter 74 reads
-- about a third of its children (G10, being asked of the site); this migration does not touch it.
-- Section 2.2 solves September before and after and aborts if any other value changes. Category
-- resolution is unaffected: COMP_WINDER and LVSDP_COMP_23 both inherit COMPRESSOR from
-- LVMDP_SPINNING_3 either way.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Spinning 3 boards and their children ==='
SELECT f.node_code AS parent, string_agg(t.node_code, ', ' ORDER BY t.node_code) AS children
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active AND e.effective_from <= CURRENT_DATE
  AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)
  AND f.node_code IN ('LVMDP_SPINNING_3', 'LVSDP_COMP_23', 'LVSDP_PROD_ATY')
GROUP BY 1 ORDER BY 1;
-- expect LVMDP_SPINNING_3: AHU_LINE3, CB_SPINNING_3, COMP_WINDER, LVSDP_COMP_23, LVSDP_PROD_ATY
--        LVSDP_COMP_23: COMP_INTERLACE
--        LVSDP_PROD_ATY: COMP_AIKI


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _g12 ON COMMIT DROP AS
SELECT e.*
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id AND f.node_code = 'LVMDP_SPINNING_3'
JOIN graph.node t ON t.id = e.to_node_id   AND t.node_code = 'COMP_WINDER'
WHERE e.tenant_id = 3 AND e.is_active;

DO $$
BEGIN
    IF (SELECT count(*) FROM _g12) <> 1
       OR NOT EXISTS (SELECT 1 FROM _g12 WHERE effective_from = '-infinity' AND effective_to IS NULL
                                           AND edge_type = 'SUPPLY_LV' AND utility_code = 'ELECTRICITY') THEN
        RAISE EXCEPTION '052: expected one open SUPPLY_LV edge LVMDP_SPINNING_3 -> COMP_WINDER from -infinity';
    END IF;

    IF EXISTS (SELECT 1 FROM graph.edge e
               JOIN graph.node f ON f.id = e.from_node_id AND f.node_code = 'LVSDP_COMP_23'
               JOIN graph.node t ON t.id = e.to_node_id   AND t.node_code = 'COMP_WINDER'
               WHERE e.tenant_id = 3) THEN
        RAISE EXCEPTION '052: an LVSDP_COMP_23 -> COMP_WINDER edge already exists';
    END IF;

    IF EXISTS (SELECT 1 FROM graph.measurement m JOIN _g12 g ON g.id = m.edge_id) THEN
        RAISE EXCEPTION '052: the edge being retired carries a meter; move it explicitly';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 2.1 Capture September before, retire the old feed, add the right one
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _g12_res (ver text, q int, kind text, code text, value numeric) ON COMMIT DROP;

CREATE FUNCTION pg_temp.g12_capture(p_ver text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE q int;
BEGIN
    FOREACH q IN ARRAY ARRAY[124, 89] LOOP
        PERFORM graph.solve_flow(3, 'ELECTRICITY', '2026-09-01', '2026-09-30', q, false,
                                 ARRAY['SHIFT1','SHIFT2','SHIFT3'], '2026-09-30');
        INSERT INTO _g12_res SELECT p_ver, q, 'node', n.node_code, n.value FROM _gn n;
    END LOOP;
END $f$;

SELECT pg_temp.g12_capture('before');

UPDATE graph.edge e SET effective_to = '-infinity' FROM _g12 g WHERE e.id = g.id;

INSERT INTO graph.edge (tenant_id, from_node_id, to_node_id, utility_code, edge_class, edge_type,
                        attrs, is_active, effective_from, effective_to)
SELECT 3, p.id, c.id, 'ELECTRICITY', 'FEEDER', 'SUPPLY_LV', '{}'::jsonb, TRUE, '-infinity', NULL
FROM graph.node p, graph.node c
WHERE p.tenant_id = 3 AND p.node_code = 'LVSDP_COMP_23'
  AND c.tenant_id = 3 AND c.node_code = 'COMP_WINDER';

-- ---------------------------------------------------------------------------
-- 2.2 Post-condition: only LVSDP_COMP_23's value may move
-- ---------------------------------------------------------------------------
SELECT pg_temp.g12_capture('after');

DO $$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n
    FROM _g12_res b JOIN _g12_res a ON a.ver = 'after' AND a.q = b.q AND a.kind = b.kind AND a.code = b.code
    WHERE b.ver = 'before' AND abs(a.value - b.value) >= 0.5 AND b.code <> 'LVSDP_COMP_23';
    IF n <> 0 THEN
        RAISE EXCEPTION '052: % node values other than LVSDP_COMP_23 changed', n;
    END IF;
    IF (SELECT count(*) FROM _g12_res WHERE ver = 'before') <> (SELECT count(*) FROM _g12_res WHERE ver = 'after') THEN
        RAISE EXCEPTION '052: the solver returned a different set of nodes';
    END IF;
END
$$;

\echo ''
\echo '=== 2.2 What moved (September 2026) ==='
SELECT b.q, b.code, round(b.value) AS before, round(a.value) AS after
FROM _g12_res b JOIN _g12_res a ON a.ver = 'after' AND a.q = b.q AND a.kind = b.kind AND a.code = b.code
WHERE b.ver = 'before' AND abs(a.value - b.value) >= 0.5
ORDER BY 1, 2;
-- on dev: LVSDP_COMP_23, 124: 42,696 -> 154,373 (73 + 72)

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Spinning 3 boards and their children, after ==='
SELECT f.node_code AS parent, string_agg(t.node_code, ', ' ORDER BY t.node_code) AS children
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active AND e.effective_from <= CURRENT_DATE
  AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)
  AND f.node_code IN ('LVMDP_SPINNING_3', 'LVSDP_COMP_23', 'LVSDP_PROD_ATY')
GROUP BY 1 ORDER BY 1;
-- expect LVMDP_SPINNING_3: AHU_LINE3, CB_SPINNING_3, LVSDP_COMP_23, LVSDP_PROD_ATY
--        LVSDP_COMP_23: COMP_INTERLACE, COMP_WINDER
--        LVSDP_PROD_ATY: COMP_AIKI

\echo ''
\echo '=== 3.2 Edge gaps ==='
SELECT count(*) AS edge_gaps FROM graph.v_edge_gaps;
-- expect 0


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- DELETE FROM graph.edge e USING graph.node p, graph.node c
--  WHERE p.id = e.from_node_id AND c.id = e.to_node_id AND e.tenant_id = 3
--    AND p.node_code = 'LVSDP_COMP_23' AND c.node_code = 'COMP_WINDER';
-- UPDATE graph.edge e SET effective_to = NULL FROM graph.node p, graph.node c
--  WHERE p.id = e.from_node_id AND c.id = e.to_node_id AND e.tenant_id = 3
--    AND p.node_code = 'LVMDP_SPINNING_3' AND c.node_code = 'COMP_WINDER'
--    AND e.effective_to = '-infinity';
-- COMMIT;
