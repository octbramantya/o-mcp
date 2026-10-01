-- Migration: 036_redraw_water_exits.sql
-- Description: Redraw where water leaves the WTP-1 and WTP-2 graphs, using 035's vocabulary.
--              The two IPALs become WASTEWATER_TREATMENT, each discharging to a new outfall;
--              WTP1_OVR becomes a WATER_OUTFALL; WTP1_REUSE becomes a RECYCLE_CUT re-entering
--              at WTP1_RAN; WTP1_WJL_REC becomes the tank it is, feeding Tandon Bio.
-- Author: Claude
-- Date: 2026-10-01
-- Design: migrations/035_add_sink_class.sql; design/graph-water-wtp.csv (the P&ID reading)
-- Requires: 035_add_sink_class.sql
--
-- WHY
-- ---
-- From the P&ID, confirmed with the user on 2026-10-01:
--
--   * The plant has two IPALs (one per WTP), each its own wastewater treatment,
--     each discharging to the stream. A flow meter on the pipe into each IPAL is on
--     the P&ID but not integrated (likely analogue), so no measurement row.
--   * The overflow leaves from Tandon Bio (WTP1_BIO -> WTP1_OVR, already drawn).
--     Whether it goes to the river or a drain is not recorded; either way it leaves.
--   * Recycle WJL is a tank, fed by Weaving and feeding Tandon Bio. The graph had it
--     as a dead-end LOAD with no edge to Tandon Bio.
--   * Tandon Bio also returns water to the rain tank WTP1_RAN, which feeds WTP1_RAW.
--     Drawn, that edge closes BIO -> RAN -> RAW -> CLR -> SOFT_x -> SOFT -> SPN/ATY ->
--     BIO, and trg_edge_acyclic refuses it. WTP1_REUSE stands in for it (the cut
--     noted in graph-water-wtp.csv), now typed as what it is.
--
-- These are corrections to what the graph always should have said, not plant
-- changes: new nodes and edges start at '-infinity', and nodes and edges keep their
-- rows, retyped in place (node_type, node_class and edge_type have no history).
-- WTP1_WJL_REC -> WTP1_BIO adds no cycle: nothing leads from Tandon Bio back to
-- Weaving except through the cut.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 The nodes this redraws ==='
SELECT node_code, node_name, node_class, node_type, attrs
FROM graph.node
WHERE tenant_id = 3 AND node_code IN ('WTP1_IPAL', 'WTP2_IPAL', 'WTP1_OVR', 'WTP1_REUSE',
                                      'WTP1_WJL_REC', 'WTP1_RAN', 'WTP1_BIO')
ORDER BY 1;

\echo ''
\echo '=== 1.2 The edges this retypes ==='
SELECT e.id, f.node_code AS from_code, t.node_code AS to_code, e.edge_type
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.utility_code = 'WATER'
  AND t.node_code IN ('WTP1_IPAL', 'WTP2_IPAL', 'WTP1_OVR', 'WTP1_REUSE', 'WTP1_WJL_REC')
ORDER BY 1;
-- expect 5, all WATER_SUPPLY: BIO->IPAL, DEL->IPAL, BIO->OVR, BIO->REUSE, WVN->WJL_REC


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _n ON COMMIT DROP AS
SELECT node_code, id FROM graph.node WHERE tenant_id = 3;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run on a database that has drifted from what was reviewed
-- ----------------------------------------------------------------------------
DO $pre$
DECLARE
    got TEXT;
BEGIN
    SELECT string_agg(node_code || ':' || node_class || '/' || node_type, ', ' ORDER BY node_code) INTO got
    FROM graph.node
    WHERE tenant_id = 3 AND node_code IN ('WTP1_IPAL', 'WTP2_IPAL', 'WTP1_OVR', 'WTP1_REUSE', 'WTP1_WJL_REC')
      AND is_active AND effective_from <= CURRENT_DATE
      AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
      AND attrs = '{}'::jsonb;
    IF got IS DISTINCT FROM 'WTP1_IPAL:LOAD/WATER_PROCESS, WTP1_OVR:LOAD/WATER_PROCESS, '
                            'WTP1_REUSE:LOAD/WATER_PROCESS, WTP1_WJL_REC:LOAD/WATER_PROCESS, '
                            'WTP2_IPAL:LOAD/WATER_PROCESS' THEN
        RAISE EXCEPTION 'the five nodes are not as reviewed (live, LOAD/WATER_PROCESS, no attrs): %', got;
    END IF;

    SELECT string_agg(f.node_code || '->' || t.node_code || ':' || e.edge_type, ', '
                      ORDER BY f.node_code, t.node_code) INTO got
    FROM graph.edge e
    JOIN graph.node f ON f.id = e.from_node_id
    JOIN graph.node t ON t.id = e.to_node_id
    WHERE e.tenant_id = 3 AND e.utility_code = 'WATER'
      AND t.node_code IN ('WTP1_IPAL', 'WTP2_IPAL', 'WTP1_OVR', 'WTP1_REUSE', 'WTP1_WJL_REC')
      AND e.is_active AND e.effective_from <= CURRENT_DATE
      AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE);
    IF got IS DISTINCT FROM 'WTP1_BIO->WTP1_IPAL:WATER_SUPPLY, WTP1_BIO->WTP1_OVR:WATER_SUPPLY, '
                            'WTP1_BIO->WTP1_REUSE:WATER_SUPPLY, WTP1_WVN->WTP1_WJL_REC:WATER_SUPPLY, '
                            'WTP2_DEL->WTP2_IPAL:WATER_SUPPLY' THEN
        RAISE EXCEPTION 'the edges into the five nodes are not as reviewed: %', got;
    END IF;

    IF EXISTS (SELECT 1 FROM graph.edge e JOIN _n f ON f.id = e.from_node_id
               WHERE f.node_code IN ('WTP1_IPAL', 'WTP2_IPAL', 'WTP1_OVR', 'WTP1_REUSE', 'WTP1_WJL_REC')) THEN
        RAISE EXCEPTION 'one of the five nodes already has an out-edge';
    END IF;

    SELECT string_agg(node_code, ', ') INTO got FROM _n
     WHERE node_code IN ('WTP1_OUTFALL', 'WTP2_OUTFALL');
    IF got IS NOT NULL THEN
        RAISE EXCEPTION 'outfall nodes already exist: %', got;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM graph.node WHERE tenant_id = 3 AND node_code = 'WTP1_RAN'
                   AND node_type = 'WATER_INTAKE' AND is_active) THEN
        RAISE EXCEPTION 'WTP1_RAN, where the recycle re-enters, is not a live WATER_INTAKE';
    END IF;
END
$pre$;

-- ----------------------------------------------------------------------------
-- 2.2 Retype the five nodes
-- ----------------------------------------------------------------------------
UPDATE graph.node SET node_class = 'TREATMENT', node_type = 'WASTEWATER_TREATMENT'
 WHERE tenant_id = 3 AND node_code IN ('WTP1_IPAL', 'WTP2_IPAL');

UPDATE graph.node SET node_class = 'SINK', node_type = 'WATER_OUTFALL'
 WHERE tenant_id = 3 AND node_code = 'WTP1_OVR';

UPDATE graph.node SET node_class = 'SINK', node_type = 'RECYCLE_CUT',
                      attrs = jsonb_build_object('reenters_at', 'WTP1_RAN')
 WHERE tenant_id = 3 AND node_code = 'WTP1_REUSE';

UPDATE graph.node SET node_class = 'STORAGE', node_type = 'WATER_TANK'
 WHERE tenant_id = 3 AND node_code = 'WTP1_WJL_REC';

-- ----------------------------------------------------------------------------
-- 2.3 Retype the edges into them
-- ----------------------------------------------------------------------------
UPDATE graph.edge e SET edge_type = v.edge_type
FROM (VALUES
    ('WTP1_BIO', 'WTP1_IPAL',    'WATER_TREATMENT'),
    ('WTP2_DEL', 'WTP2_IPAL',    'WATER_TREATMENT'),
    ('WTP1_BIO', 'WTP1_OVR',     'WATER_DISCHARGE'),
    ('WTP1_BIO', 'WTP1_REUSE',   'WATER_RETURN'),
    ('WTP1_WVN', 'WTP1_WJL_REC', 'WATER_RETURN')
) v (from_code, to_code, edge_type), _n f, _n t
WHERE f.node_code = v.from_code AND t.node_code = v.to_code
  AND e.from_node_id = f.id AND e.to_node_id = t.id
  AND e.tenant_id = 3 AND e.utility_code = 'WATER';

-- ----------------------------------------------------------------------------
-- 2.4 The two outfalls, and the edges the graph was missing
-- ----------------------------------------------------------------------------
INSERT INTO graph.node (tenant_id, node_code, node_name, node_class, node_type) VALUES
    (3, 'WTP1_OUTFALL', 'WTP-1 IPAL outfall (stream)', 'SINK', 'WATER_OUTFALL'),
    (3, 'WTP2_OUTFALL', 'WTP-2 IPAL outfall (stream)', 'SINK', 'WATER_OUTFALL');

INSERT INTO _n SELECT node_code, id FROM graph.node
 WHERE tenant_id = 3 AND node_code IN ('WTP1_OUTFALL', 'WTP2_OUTFALL');

INSERT INTO graph.edge (tenant_id, from_node_id, to_node_id, utility_code, edge_class, edge_type)
SELECT 3, f.id, t.id, 'WATER', 'PIPE', v.edge_type
FROM (VALUES
    ('WTP1_IPAL',    'WTP1_OUTFALL', 'WATER_DISCHARGE'),
    ('WTP2_IPAL',    'WTP2_OUTFALL', 'WATER_DISCHARGE'),
    ('WTP1_WJL_REC', 'WTP1_BIO',     'WATER_TRANSFER')
) v (from_code, to_code, edge_type)
JOIN _n f ON f.node_code = v.from_code
JOIN _n t ON t.node_code = v.to_code;

-- ----------------------------------------------------------------------------
-- 2.5 The water rule that let a LOAD feed a LOAD, now unused
-- ----------------------------------------------------------------------------
DELETE FROM graph.edge_type_endpoint
 WHERE edge_type = 'WATER_SUPPLY' AND from_kind = 'LOAD' AND to_kind = 'LOAD';

-- ----------------------------------------------------------------------------
-- 2.6 WATER_PROCESS now means only a process area
-- ----------------------------------------------------------------------------
UPDATE graph.node_type SET description =
     'A process area on the water graph where treated water is used (weaving, spinning, '
     'dyeing). It may return spent water to a tank. Has no electrical parent: it consumes '
     'water, not electricity.'
 WHERE code = 'WATER_PROCESS';

-- ----------------------------------------------------------------------------
-- 2.7 Post-conditions
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    n INTEGER;
BEGIN
    IF (SELECT count(*) FROM graph.v_edge_gaps) <> 0 THEN
        RAISE EXCEPTION 'v_edge_gaps is not empty: %',
            (SELECT string_agg(from_code || '->' || to_code || ' ' || status, ', ')
               FROM graph.v_edge_gaps);
    END IF;

    SELECT count(*) INTO n FROM graph.edge
     WHERE tenant_id = 3 AND utility_code = 'WATER' AND edge_type = 'WATER_SUPPLY'
       AND to_node_id IN (SELECT id FROM _n WHERE node_code IN
                          ('WTP1_IPAL', 'WTP2_IPAL', 'WTP1_OVR', 'WTP1_REUSE', 'WTP1_WJL_REC'));
    IF n <> 0 THEN
        RAISE EXCEPTION '% edge(s) into the five nodes kept WATER_SUPPLY', n;
    END IF;

    IF (SELECT attrs->>'reenters_at' FROM graph.node WHERE tenant_id = 3 AND node_code = 'WTP1_REUSE')
       NOT IN (SELECT node_code FROM graph.node WHERE tenant_id = 3 AND is_active) THEN
        RAISE EXCEPTION 'WTP1_REUSE.reenters_at does not name a live node';
    END IF;
END
$post$;

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Where water leaves, after ==='
SELECT f.node_code AS from_code, e.edge_type, t.node_code AS to_code, t.node_class, t.node_type
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.utility_code = 'WATER'
  AND (t.node_class IN ('SINK', 'TREATMENT') AND t.node_type IN ('WATER_OUTFALL', 'RECYCLE_CUT', 'WASTEWATER_TREATMENT')
       OR f.node_code = 'WTP1_WJL_REC' OR t.node_code = 'WTP1_WJL_REC')
ORDER BY 1, 3;
-- expect 8 rows: BIO->IPAL, BIO->OVR, BIO->REUSE, DEL->IPAL, two IPAL->OUTFALL,
-- WVN->WJL_REC, WJL_REC->BIO

\echo ''
\echo '=== 3.2 LOAD and SINK on the water graph ==='
SELECT node_class, node_type, string_agg(node_code, ', ' ORDER BY node_code) AS nodes
FROM graph.node
WHERE tenant_id = 3 AND node_type IN ('WATER_PROCESS', 'WATER_OUTFALL', 'RECYCLE_CUT')
GROUP BY 1, 2 ORDER BY 1, 2;
-- expect WATER_PROCESS: WTP1_ATY WTP1_SPN WTP1_WVN WTP2_BEAM WTP2_PROC WTP2_RPD


-- ============================================================================
-- 4. Undo (commented) -- the nodes and edges as 030 left them
-- ============================================================================
--
-- BEGIN;
-- DELETE FROM graph.edge WHERE tenant_id = 3 AND edge_type = 'WATER_DISCHARGE'
--    AND to_node_id IN (SELECT id FROM graph.node WHERE node_code IN ('WTP1_OUTFALL', 'WTP2_OUTFALL'));
-- DELETE FROM graph.edge WHERE tenant_id = 3 AND edge_type = 'WATER_TRANSFER'
--    AND from_node_id = (SELECT id FROM graph.node WHERE tenant_id = 3 AND node_code = 'WTP1_WJL_REC');
-- DELETE FROM graph.node WHERE tenant_id = 3 AND node_code IN ('WTP1_OUTFALL', 'WTP2_OUTFALL');
-- INSERT INTO graph.edge_type_endpoint VALUES ('WATER_SUPPLY', 'LOAD', 'LOAD');
-- UPDATE graph.edge SET edge_type = 'WATER_SUPPLY'
--  WHERE tenant_id = 3 AND utility_code = 'WATER' AND to_node_id IN (SELECT id FROM graph.node
--        WHERE tenant_id = 3 AND node_code IN ('WTP1_IPAL', 'WTP2_IPAL', 'WTP1_OVR', 'WTP1_REUSE', 'WTP1_WJL_REC'));
-- UPDATE graph.node SET node_class = 'LOAD', node_type = 'WATER_PROCESS', attrs = '{}'
--  WHERE tenant_id = 3 AND node_code IN ('WTP1_IPAL', 'WTP2_IPAL', 'WTP1_OVR', 'WTP1_REUSE', 'WTP1_WJL_REC');
-- UPDATE graph.node_type SET description =
--      'A destination for treated water on the water graph: a process area, a reuse '
--      'or recycle return, an overflow, or an IPAL discharge. Has no electrical '
--      'parent -- it consumes water, not electricity.'
--  WHERE code = 'WATER_PROCESS';
-- COMMIT;
