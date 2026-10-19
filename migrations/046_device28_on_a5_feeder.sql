-- Migration: 046_device28_on_a5_feeder.sql
-- Description: Move device 28 (the LVMDB A5 meter) from the node LVMDB_A5 to its feeder edge
--              FACTORY_AB -> LVMDB_A5, as a documentation correction.
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-reconcile.md §1.6.1 and §1.10 (G5, G6); design/graph-sankey.md §3
-- Requires: 045_process_heater_description.sql
--
-- WHY
-- ---
-- A meter on a node reads everything through that node; a meter on a feeder edge reads only
-- that feeder. The site confirmed on 2026-10-15 that PLTS A5 (device 27) joins LVMDB A5
-- *after* meter 28: the meter reads the net grid draw on the A5 feeder, not the board's load.
-- With 28 on the node, the solver set LVMDB_A5 = 28 and the grid feeder = 28 - 27, so the A5
-- load came out short by PLTS A5's output and the grid feeder short by the same amount. On the
-- edge, the solver gives feeder = 28 and LVMDB_A5 = 28 + 27 (checked on dev with synthetic kWh,
-- 2026-10-15). The other three PV boards (A4, B2, Texture 2) have their PV inside the board
-- meter's reach, which the graph already models; they are not touched.
--
-- The meter was always on the feeder, so the node rows were never true: they get
-- effective_to = '-infinity' (kept, not deleted, as the record of what past solver results
-- used), and the edge rows start at '-infinity'. Past A5 results are retroactively wrong.
--
-- Which rows. Device 28 has 8 measurement rows on LVMDB_A5. Seven describe the flow through
-- the meter and move: the conserved 124/131 (active energy delivered/received) and 89/96
-- (reactive), which the solver reads, and 62/481 (apparent energy) and 1072 (PF_TOTAL), which
-- on the node would claim to be the board's. 1119 (THD_VOLTAGE_LN) stays on the node: bus
-- voltage is the same on both sides of the meter. Multiplier, role and utility carry over.
--
-- Readers: server/tools/meters.py already reports feeder meters (attached_to FEEDER);
-- graph.get_node_quantity reads node rows only for non-conserved quantities, so LVMDB_A5 has
-- no PF or apparent energy of its own afterwards, which is correct: nobody measures them.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Device 28 rows ==='
SELECT m.id, n.node_code, m.edge_id, m.quantity_id, m.multiplier, m.role, m.utility_code,
       m.is_active, m.effective_from, m.effective_to
FROM graph.measurement m LEFT JOIN graph.node n ON n.id = m.node_id
WHERE m.tenant_id = 3 AND m.device_id = 28
ORDER BY m.quantity_id;
-- expect 8 rows on LVMDB_A5, all in effect: 62 89 96 124 131 481 1072 1119

\echo ''
\echo '=== 1.2 The feeder ==='
SELECT e.id, f.node_code AS parent, t.node_code AS child, e.edge_type, e.is_active,
       e.effective_from, e.effective_to
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND t.node_code = 'LVMDB_A5'
ORDER BY 2;
-- expect FACTORY_AB -> LVMDB_A5 and PLTS_A5 -> LVMDB_A5, both in effect


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _g6 ON COMMIT DROP AS
SELECT m.*
FROM graph.measurement m JOIN graph.node n ON n.id = m.node_id
WHERE m.tenant_id = 3 AND m.device_id = 28 AND n.node_code = 'LVMDB_A5'
  AND m.quantity_id IN (62, 89, 96, 124, 131, 481, 1072);

DO $$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n FROM _g6
    WHERE is_active AND effective_from <= CURRENT_DATE
      AND (effective_to IS NULL OR effective_to >= CURRENT_DATE);
    IF n <> 7 THEN
        RAISE EXCEPTION '046: expected 7 device-28 rows in effect on LVMDB_A5, found %', n;
    END IF;

    SELECT count(*) INTO n FROM _g6
    WHERE effective_from <> '-infinity' OR effective_to IS NOT NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION '046: % device-28 rows are dated; 046 assumes they all run from -infinity, open-ended', n;
    END IF;

    SELECT count(*) INTO n
    FROM graph.edge e
    JOIN graph.node f ON f.id = e.from_node_id
    JOIN graph.node t ON t.id = e.to_node_id
    WHERE e.tenant_id = 3 AND f.node_code = 'FACTORY_AB' AND t.node_code = 'LVMDB_A5'
      AND e.is_active AND e.effective_from <= CURRENT_DATE
      AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE);
    IF n <> 1 THEN
        RAISE EXCEPTION '046: expected one FACTORY_AB -> LVMDB_A5 edge in effect, found %', n;
    END IF;

    SELECT count(*) INTO n FROM graph.measurement
    WHERE tenant_id = 3 AND device_id = 28 AND edge_id IS NOT NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION '046: device 28 already has % edge rows', n;
    END IF;
END
$$;

-- 2.1 The same seven quantities on the feeder, from -infinity, open-ended
INSERT INTO graph.measurement
       (tenant_id, edge_id, device_id, quantity_id, utility_code, multiplier, role,
        is_active, effective_from, effective_to)
SELECT g.tenant_id, e.id, g.device_id, g.quantity_id, g.utility_code, g.multiplier, g.role,
       TRUE, '-infinity', NULL
FROM _g6 g
JOIN graph.edge e ON e.tenant_id = 3 AND e.is_active
JOIN graph.node f ON f.id = e.from_node_id AND f.node_code = 'FACTORY_AB'
JOIN graph.node t ON t.id = e.to_node_id   AND t.node_code = 'LVMDB_A5'
WHERE e.effective_from <= CURRENT_DATE
  AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE);

-- 2.2 The node rows were never true
UPDATE graph.measurement m SET effective_to = '-infinity'
FROM _g6 g WHERE m.id = g.id;

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Device 28 rows in effect today, by target ==='
SELECT COALESCE(n.node_code, f.node_code || ' -> ' || t.node_code) AS target,
       string_agg(m.quantity_id::text, ' ' ORDER BY m.quantity_id) AS quantities
FROM graph.measurement m
LEFT JOIN graph.node n ON n.id = m.node_id
LEFT JOIN graph.edge e ON e.id = m.edge_id
LEFT JOIN graph.node f ON f.id = e.from_node_id
LEFT JOIN graph.node t ON t.id = e.to_node_id
WHERE m.tenant_id = 3 AND m.device_id = 28
  AND m.is_active AND m.effective_from <= CURRENT_DATE
  AND (m.effective_to IS NULL OR m.effective_to >= CURRENT_DATE)
GROUP BY 1 ORDER BY 1;
-- expect FACTORY_AB -> LVMDB_A5: 62 89 96 124 131 481 1072
--        LVMDB_A5: 1119

\echo ''
\echo '=== 3.2 Device 28 rows never in effect ==='
SELECT count(*) AS corrected FROM graph.measurement
WHERE tenant_id = 3 AND device_id = 28 AND effective_to = '-infinity';
-- expect 7


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- DELETE FROM graph.measurement WHERE tenant_id = 3 AND device_id = 28 AND edge_id IS NOT NULL;
-- UPDATE graph.measurement SET effective_to = NULL
--  WHERE tenant_id = 3 AND device_id = 28 AND effective_to = '-infinity';
-- COMMIT;
