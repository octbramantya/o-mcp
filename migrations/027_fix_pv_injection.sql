-- Migration: 027_fix_pv_injection.sql
-- Description: Re-point the PV plants from the loads to the boards they inject into.
-- Author: Claude
-- Date: 2026-09-28
-- Design: design/edge-type.md §7a
--
-- WHY
-- ---
-- Confirmed from the SLD (2026-09-28): each PLTS array has its own meter, and
-- the board meter -- LVMDB_A5 and the rest -- is tapped AFTER the PV tapping
-- point. The board meter therefore already includes the PV contribution. PV
-- injects into the board; it does not feed machines directly.
--
-- The graph says otherwise. All 36 PV_PLANT edges point at loads, and every one
-- of those loads already has its board as a parent, so the PV edges are a second
-- path to energy the board meter has already counted. get_sankey_flow emits both.
--
-- Measured on live for 2026-09-07..14, quantity 124 (active energy delivered):
--
--     PLTS_B2       generated 22 130.3 kWh, credited 83 481.0 kWh  (+61 350.8)
--     PLTS_A4       generated 30 085.6 kWh, credited 30 085.6 kWh
--     PLTS_A5       generated 12 259.7 kWh, credited 12 259.7 kWh
--     PLTS_TEXTURE  generated 30 942.7 kWh, credited 30 942.7 kWh
--
-- The B2 branch emits every load twice at identical value (LVMDB_B2 ->
-- FINISHING_1 21 118.7 and PLTS_B2 -> FINISHING_1 21 118.7, and so on for all
-- 13). The other three reconcile only by accident of this window -- PLTS_A5's
-- loads measured 0 kWh, so there was nothing to duplicate. The defect is
-- structural.
--
-- DELETE, not deactivate. effective_to means "this asset was decommissioned".
-- These edges never described anything physical, so retiring them would record
-- a history that did not happen. Section 4 recreates them exactly.
--
-- Section 3 captures the Sankey BEFORE the change, applies it, captures it
-- AFTER, and prints the diff -- all inside the transaction, so the correction is
-- visible before COMMIT and a surprise can be rolled back.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only -- run this first, change nothing)
-- ============================================================================

\echo ''
\echo '=== 1.1 The 36 PV edges, and the board each load already has ==='
SELECT f.node_code AS pv, t.node_code AS load_code,
       (SELECT string_agg(f2.node_code, ', ' ORDER BY f2.node_code)
          FROM graph.edge e2 JOIN graph.node f2 ON f2.id = e2.from_node_id
         WHERE e2.to_node_id = t.id AND e2.is_active
           AND f2.node_type IS DISTINCT FROM 'PV_PLANT') AS board_parents
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active AND f.node_type = 'PV_PLANT'
ORDER BY 1, 2;

\echo ''
\echo '=== 1.2 No PV-fed load may be left parentless: every one needs a board ==='
SELECT count(*) AS loads_with_no_board_parent
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active AND f.node_type = 'PV_PLANT'
  AND NOT EXISTS (
      SELECT 1 FROM graph.edge e2 JOIN graph.node f2 ON f2.id = e2.from_node_id
       WHERE e2.to_node_id = t.id AND e2.is_active
         AND f2.node_type IS DISTINCT FROM 'PV_PLANT');
-- expect 0. Any other number means deleting that PV edge would orphan a load,
-- and this migration must not run.

\echo ''
\echo '=== 1.3 Nothing is measured on the edges being deleted ==='
SELECT count(*) AS measurements_on_pv_edges
FROM graph.measurement m
WHERE m.edge_id IN (
    SELECT e.id FROM graph.edge e JOIN graph.node f ON f.id = e.from_node_id
     WHERE e.tenant_id = 3 AND e.is_active AND f.node_type = 'PV_PLANT');
-- expect 0. measurement.edge_id is ON DELETE CASCADE, so a non-zero count here
-- means this migration would silently destroy meter assignments.

\echo ''
\echo '=== 1.4 Inactive PV edges -- these are history and are NOT touched ==='
SELECT e.id, f.node_code AS pv, t.node_code AS target, e.effective_from, e.effective_to
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND f.node_type = 'PV_PLANT' AND NOT e.is_active;
-- expect exactly 1: edge 178, PLTS_TEXTURE -> MC_MOTOR_13, retired 2026-08

\echo ''
\echo '=== 1.5 The four target boards ==='
SELECT node_code, node_class, node_type, (attrs ->> 'rated_kva')::numeric AS rated_kva
FROM graph.node
WHERE tenant_id = 3
  AND node_code IN ('LVMDB_A4','LVMDB_A5','LVMDB_B2','LVMDB_TEXTURE_2')
ORDER BY 1;


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 2.0 Capture the Sankey as it stands, for the before/after diff in section 3.
--     Inside the transaction and before any DML, so it is the true "before".
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _sankey_before ON COMMIT DROP AS
SELECT * FROM graph.get_sankey_flow(
    3, 'ELECTRICITY', '2026-09-07 00:00', '2026-09-14 00:00', 124);

-- retired edges are history; section 2.4 asserts this number has not moved
CREATE TEMP TABLE _inactive_before ON COMMIT DROP AS
SELECT count(*) AS n FROM graph.edge WHERE tenant_id = 3 AND NOT is_active;

CREATE TEMP TABLE _pv_before ON COMMIT DROP AS
SELECT n.node_code,
       (SELECT round(sum(s.value), 1) FROM _sankey_before s WHERE s.source = n.node_name) AS credited
FROM graph.node n
WHERE n.tenant_id = 3 AND n.node_type = 'PV_PLANT';

-- ---------------------------------------------------------------------------
-- 2.1 Guard: refuse to run if the evidence in 1.2 or 1.3 does not hold.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    orphans   INTEGER;
    meas      INTEGER;
    pv_edges  INTEGER;
BEGIN
    SELECT count(*) INTO orphans
      FROM graph.edge e
      JOIN graph.node f ON f.id = e.from_node_id
      JOIN graph.node t ON t.id = e.to_node_id
     WHERE e.tenant_id = 3 AND e.is_active AND f.node_type = 'PV_PLANT'
       AND NOT EXISTS (
           SELECT 1 FROM graph.edge e2 JOIN graph.node f2 ON f2.id = e2.from_node_id
            WHERE e2.to_node_id = t.id AND e2.is_active
              AND f2.node_type IS DISTINCT FROM 'PV_PLANT');
    IF orphans <> 0 THEN
        RAISE EXCEPTION 'ABORT: % PV-fed load(s) have no board parent; deleting '
                        'the PV edge would orphan them', orphans;
    END IF;

    SELECT count(*) INTO meas
      FROM graph.measurement m
     WHERE m.edge_id IN (
         SELECT e.id FROM graph.edge e JOIN graph.node f ON f.id = e.from_node_id
          WHERE e.tenant_id = 3 AND e.is_active AND f.node_type = 'PV_PLANT');
    IF meas <> 0 THEN
        RAISE EXCEPTION 'ABORT: % measurement(s) are attached to the PV edges '
                        'and would be cascade-deleted', meas;
    END IF;

    SELECT count(*) INTO pv_edges
      FROM graph.edge e JOIN graph.node f ON f.id = e.from_node_id
     WHERE e.tenant_id = 3 AND e.is_active AND f.node_type = 'PV_PLANT';
    IF pv_edges <> 36 THEN
        RAISE EXCEPTION 'ABORT: expected 36 PV edges, found %. The graph has '
                        'changed since this migration was written', pv_edges;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2.2 Remove the 36 PV -> load edges
-- ---------------------------------------------------------------------------
-- is_active matters here. Edge 178 (PLTS_TEXTURE -> MC_MOTOR_13) was retired in
-- August and is inactive; it is history and must survive. Without this predicate
-- the statement deletes 37 rows, and every active-edge post-condition below still
-- passes, so the loss would be silent.
DELETE FROM graph.edge e
 USING graph.node f
 WHERE f.id = e.from_node_id
   AND e.tenant_id = 3
   AND e.is_active
   AND f.node_type = 'PV_PLANT';

-- ---------------------------------------------------------------------------
-- 2.3 Add the four PV -> board injections.
--     PLTS_TEXTURE -> LVMDB_TEXTURE_2 per the SLD (its loads sit under both
--     LVMDB_TEXTURE and LVMDB_TEXTURE_2; the array taps the second).
-- ---------------------------------------------------------------------------
INSERT INTO graph.edge (tenant_id, from_node_id, to_node_id, utility_code, edge_class)
SELECT 3, f.id, t.id, 'ELECTRICITY', 'FEEDER'
FROM (VALUES
    ('PLTS_A4',      'LVMDB_A4'),
    ('PLTS_A5',      'LVMDB_A5'),
    ('PLTS_B2',      'LVMDB_B2'),
    ('PLTS_TEXTURE', 'LVMDB_TEXTURE_2')
) AS v (from_code, to_code)
JOIN graph.node f ON f.tenant_id = 3 AND f.node_code = v.from_code
JOIN graph.node t ON t.tenant_id = 3 AND t.node_code = v.to_code;

-- ---------------------------------------------------------------------------
-- 2.4 Post-conditions, still inside the transaction
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    pv_edges  INTEGER;
    to_boards INTEGER;
    total     INTEGER;
    inactive  INTEGER;
BEGIN
    SELECT count(*) INTO pv_edges
      FROM graph.edge e JOIN graph.node f ON f.id = e.from_node_id
     WHERE e.tenant_id = 3 AND e.is_active AND f.node_type = 'PV_PLANT';
    IF pv_edges <> 4 THEN
        RAISE EXCEPTION 'expected 4 PV edges after the change, found %', pv_edges;
    END IF;

    SELECT count(*) INTO to_boards
      FROM graph.edge e
      JOIN graph.node f ON f.id = e.from_node_id
      JOIN graph.node t ON t.id = e.to_node_id
     WHERE e.tenant_id = 3 AND e.is_active AND f.node_type = 'PV_PLANT'
       AND t.node_type IN ('MAIN_LV_BOARD','SUB_BOARD');
    IF to_boards <> 4 THEN
        RAISE EXCEPTION 'all 4 PV edges must land on a board, only % do', to_boards;
    END IF;

    SELECT count(*) INTO total
      FROM graph.edge WHERE tenant_id = 3 AND is_active;
    IF total <> 218 THEN
        RAISE EXCEPTION 'expected 218 active edges (250 - 36 + 4), found %', total;
    END IF;

    -- the check the active-edge counts above cannot make: retired edges are
    -- history and this migration must not touch them
    SELECT count(*) INTO inactive
      FROM graph.edge WHERE tenant_id = 3 AND NOT is_active;
    IF inactive <> (SELECT n FROM _inactive_before) THEN
        RAISE EXCEPTION 'inactive edge count moved from % to % -- retired edges '
                        'must be left alone', (SELECT n FROM _inactive_before), inactive;
    END IF;

    RAISE NOTICE 'OK: 36 PV->load edges removed, 4 PV->board added, % active edges', total;
END $$;


-- ============================================================================
-- 3. Verification -- run BEFORE committing
-- ============================================================================

\echo ''
\echo '=== 3.1 The four PV injections ==='
SELECT f.node_code AS pv, t.node_code AS board, t.node_type, e.edge_class
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active AND f.node_type = 'PV_PLANT'
ORDER BY 1;

\echo ''
\echo '=== 3.2 PV credit: measured generation vs Sankey, before and after ==='
\echo '    (the whole point of this migration)'
WITH after_sankey AS (
    SELECT * FROM graph.get_sankey_flow(
        3, 'ELECTRICITY', '2026-09-07 00:00', '2026-09-14 00:00', 124)
),
after_pv AS (
    SELECT n.node_code,
           (SELECT round(sum(s.value), 1) FROM after_sankey s WHERE s.source = n.node_name) AS credited
    FROM graph.node n WHERE n.tenant_id = 3 AND n.node_type = 'PV_PLANT'
)
SELECT b.node_code,
       round(v.value, 1)                     AS measured_kwh,
       b.credited                            AS credited_before,
       a.credited                            AS credited_after,
       round(COALESCE(a.credited, 0) - v.value, 1) AS error_after
FROM _pv_before b
JOIN after_pv a USING (node_code)
JOIN graph.get_node_values(
        3, 'ELECTRICITY', '2026-09-07 00:00', '2026-09-14 00:00', 124) v
  ON v.node_code = b.node_code
ORDER BY 1;
-- credited_after must equal measured_kwh for every array: a PV plant cannot
-- deliver more than it generated. error_after should be 0 (or a rounding tail).

\echo ''
\echo '=== 3.3 Loads that were emitted twice are now emitted once ==='
WITH after_sankey AS (
    SELECT * FROM graph.get_sankey_flow(
        3, 'ELECTRICITY', '2026-09-07 00:00', '2026-09-14 00:00', 124)
)
SELECT 'before' AS phase, count(*) AS duplicated_targets
FROM (SELECT target FROM _sankey_before WHERE NOT is_unaccounted
       GROUP BY target HAVING count(*) > 1) x
UNION ALL
SELECT 'after', count(*)
FROM (SELECT target FROM after_sankey WHERE NOT is_unaccounted
       GROUP BY target HAVING count(*) > 1) y;

\echo ''
\echo '=== 3.4 Every former PV-fed load still has a board parent ==='
SELECT count(*) AS loads_without_parent
FROM graph.node n
WHERE n.tenant_id = 3 AND n.is_active AND n.node_class = 'LOAD'
  AND NOT EXISTS (SELECT 1 FROM graph.edge e
                   WHERE e.to_node_id = n.id AND e.is_active);

\echo ''
\echo '=== 3.5 Edge counts by class ==='
SELECT utility_code, edge_class, count(*) AS n
FROM graph.edge WHERE tenant_id = 3 AND is_active
GROUP BY 1, 2 ORDER BY 1, 2;
-- expect ELECTRICITY/FEEDER 168, ELECTRICITY/COMPENSATION 11, WATER/PIPE 39

COMMIT;


-- ============================================================================
-- 4. Undo (commented; restores the 36 edges exactly as they were)
-- ============================================================================
--
-- BEGIN;
--
-- DELETE FROM graph.edge e USING graph.node f, graph.node t
--  WHERE f.id = e.from_node_id AND t.id = e.to_node_id AND e.tenant_id = 3
--    AND f.node_type = 'PV_PLANT' AND t.node_type IN ('MAIN_LV_BOARD','SUB_BOARD');
--
-- INSERT INTO graph.edge (tenant_id, from_node_id, to_node_id, utility_code, edge_class)
-- SELECT 3, f.id, t.id, 'ELECTRICITY', 'FEEDER'
-- FROM (VALUES
--     ('PLTS_A4','COOLING2'),          ('PLTS_A4','WORKSHOP'),
--     ('PLTS_A5','AIR_DRYER'),         ('PLTS_A5','COMP_300HP'),
--     ('PLTS_A5','COMP_400HP'),
--     ('PLTS_B2','BOILER_MIURA'),      ('PLTS_B2','CELUP_1A'),
--     ('PLTS_B2','CELUP_1B'),          ('PLTS_B2','CELUP_2'),
--     ('PLTS_B2','CELUP_3'),           ('PLTS_B2','COMP_100HP'),
--     ('PLTS_B2','FINISHING_1'),       ('PLTS_B2','FINISHING_21'),
--     ('PLTS_B2','FINISHING_22'),      ('PLTS_B2','LAB_DEVICE'),
--     ('PLTS_B2','PACKING_DEVICE'),    ('PLTS_B2','RAINCOAT_DEVICE'),
--     ('PLTS_B2','WTP_1'),
--     ('PLTS_TEXTURE','COMP_ELITE'),   ('PLTS_TEXTURE','COMP_FUSHENG300HP'),
--     ('PLTS_TEXTURE','HEATER_TOTAL'), ('PLTS_TEXTURE','HVAC_AHU'),
--     ('PLTS_TEXTURE','LABKNIT'),      ('PLTS_TEXTURE','MDP_MC_13'),
--     ('PLTS_TEXTURE','MC_MOTOR_1'),   ('PLTS_TEXTURE','MC_MOTOR_2'),
--     ('PLTS_TEXTURE','MC_MOTOR_3'),   ('PLTS_TEXTURE','MC_MOTOR_4'),
--     ('PLTS_TEXTURE','MC_MOTOR_5'),   ('PLTS_TEXTURE','MC_MOTOR_6'),
--     ('PLTS_TEXTURE','MC_MOTOR_7'),   ('PLTS_TEXTURE','MC_MOTOR_8'),
--     ('PLTS_TEXTURE','MC_MOTOR_9'),   ('PLTS_TEXTURE','MC_MOTOR_10'),
--     ('PLTS_TEXTURE','MC_MOTOR_11'),  ('PLTS_TEXTURE','MC_MOTOR_12')
-- ) AS v (from_code, to_code)
-- JOIN graph.node f ON f.tenant_id = 3 AND f.node_code = v.from_code
-- JOIN graph.node t ON t.tenant_id = 3 AND t.node_code = v.to_code;
--
-- COMMIT;
