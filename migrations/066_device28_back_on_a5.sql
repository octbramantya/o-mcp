-- Migration: 066_device28_back_on_a5.sql
-- Description: Put device 28 (the LVMDB A5 meter) back on the node LVMDB_A5, as a documentation
--              correction of 046: its CT is downstream of PLTS A5's junction and reads A5's load.
-- Author: Claude
-- Date: 2026-11-04
-- Design: design/graph-sankey.md §9 (G6); executive report draft §6.4 (local)
-- Requires: 065_minute_totals_probe.sql
--
-- WHY
-- ---
-- 046 moved device 28 to the feeder FACTORY_AB -> LVMDB_A5 on the site's word (2026-10-15) that
-- PLTS A5 (device 27) joins LVMDB A5 after meter 28, so that 28 reads the grid draw and
-- A5 = 28 + 27. The meter says otherwise. Checked on production, 2026-11-04:
--
--   - 28 never sees PV A5's production. In October 2026 it carries a balanced 20-31 A a phase
--     (about 16 kW), all three phases positive, unchanged while 27 pushes about 310 A a phase at
--     noon. In December 2025, with A5 loaded (about 200 kW), it stayed flat while 27 made 210 kW at
--     10:00 (also confirmed by the user on the current data). Its received register (131) has not
--     moved in 15 months; FACTORY_AB's meter (84) registered 21,493 kWh of reverse flow.
--   - 27 is on A5's LV bus: its voltage THD tracks 28's at 0.99 / 1.00 / 0.99 per phase (0.10
--     points apart), the closest of any pair, closer than PV B2 to B2 (0.93-0.95). So PV A5 lands
--     between A5's transformer and CT 28, and its surplus goes back up the transformer to the
--     20 kV FACTORY_AB bus.
--   - With 28 on the feeder, the solver counted PV A5 twice: once in A5's load (28 + 27), and once
--     as gas engine output, because FACTORY_AB's boards then add up to more than 84 by PV A5's
--     output (1.04 x device 27, every day of October). October's hourly solves gave the engine
--     38,464 kWh, all of it between 06:00 and 17:00.
--
-- The site engineer's assumption was that PV A5 always supplies A5's load. A5's load fell from
-- about 230 kW to about 16 kW from May 2026, so PV A5 now mostly exports; that made the error
-- visible, but the equation was wrong at any load (user, 2026-11-04).
--
-- After this migration the solver sets LVMDB_A5 = 28 and the feeder FACTORY_AB -> LVMDB_A5 =
-- 28 - 27 (rule b, exact, never clamped). The feeder is negative whenever PV A5 exceeds A5's load:
-- real reverse flow through A5's transformer. 051's rule (a2) subtracts it as a known out-edge of
-- FACTORY_AB, leaving more of 84 for A1-A3, so the gas engine falls to what it really supplied.
-- Over a window the feeder is the net of import and export; the export inside a day shows only
-- in short-window solves.
--
-- Rows. 046 retired device 28's seven node rows (62 89 96 124 131 481 1072) with
-- effective_to = '-infinity' and added the same seven on the feeder from '-infinity'. Those node
-- rows were true after all, so they are reopened (effective_to = NULL), and the feeder rows were
-- never true (effective_to = '-infinity', kept as the record of what past results used). A new
-- set of node rows can't be added beside the retired ones: uq_meas_node_dev_qty includes
-- effective_from, and both would start at '-infinity'. 1119 (THD) never moved. Past A5 results
-- are retroactively wrong again, in the other direction: every window since 046 was applied.
--
-- IMPACT is enforced in section 2.3: the solver runs the same windows before and after and the
-- migration aborts if anything moves other than LVMDB_A5, the gas engine, FACTORY_AB's feeders to
-- A1, A2, A3 and A5, and the engine's three edges; if A5 differs from device 28's total or the A5
-- feeder from 28 - 27; or if the engine goes up. A database with no telemetry in those windows
-- passes trivially.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Device 28 rows ==='
SELECT m.id, COALESCE(n.node_code, 'edge ' || m.edge_id) AS target, m.quantity_id, m.multiplier,
       m.role, m.is_active, m.effective_from, m.effective_to
FROM graph.measurement m LEFT JOIN graph.node n ON n.id = m.node_id
WHERE m.tenant_id = 3 AND m.device_id = 28
ORDER BY m.quantity_id, m.edge_id NULLS FIRST;
-- expect, for each of 62 89 96 124 131 481 1072: a node row ending '-infinity' and an edge row
-- open-ended; 1119 on the node, open-ended


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _g6_node ON COMMIT DROP AS
SELECT m.* FROM graph.measurement m JOIN graph.node n ON n.id = m.node_id
WHERE m.tenant_id = 3 AND m.device_id = 28 AND n.node_code = 'LVMDB_A5'
  AND m.quantity_id IN (62, 89, 96, 124, 131, 481, 1072);

CREATE TEMP TABLE _g6_edge ON COMMIT DROP AS
SELECT m.* FROM graph.measurement m
JOIN graph.edge e ON e.id = m.edge_id
JOIN graph.node f ON f.id = e.from_node_id AND f.node_code = 'FACTORY_AB'
JOIN graph.node t ON t.id = e.to_node_id   AND t.node_code = 'LVMDB_A5'
WHERE m.tenant_id = 3 AND m.device_id = 28
  AND m.quantity_id IN (62, 89, 96, 124, 131, 481, 1072);

DO $guard$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n FROM _g6_node
    WHERE effective_from = '-infinity' AND effective_to = '-infinity';
    IF n <> 7 OR (SELECT count(*) FROM _g6_node) <> 7 THEN
        RAISE EXCEPTION '066: expected device 28''s seven node rows retired by 046, found % of %',
            n, (SELECT count(*) FROM _g6_node);
    END IF;

    SELECT count(*) INTO n FROM _g6_edge
    WHERE is_active AND effective_from = '-infinity' AND effective_to IS NULL;
    IF n <> 7 OR (SELECT count(*) FROM _g6_edge) <> 7 THEN
        RAISE EXCEPTION '066: expected device 28''s seven feeder rows from 046, open-ended, found % of %',
            n, (SELECT count(*) FROM _g6_edge);
    END IF;

    IF (SELECT array_agg(quantity_id ORDER BY quantity_id) FROM _g6_node)
       IS DISTINCT FROM (SELECT array_agg(quantity_id ORDER BY quantity_id) FROM _g6_edge) THEN
        RAISE EXCEPTION '066: the node and feeder rows are not the same seven quantities';
    END IF;

    -- the feeder rows must carry what 046 copied from the node rows
    SELECT count(*) INTO n FROM _g6_node a JOIN _g6_edge b USING (quantity_id)
    WHERE a.multiplier <> b.multiplier OR a.role <> b.role OR a.utility_code <> b.utility_code;
    IF n <> 0 THEN
        RAISE EXCEPTION '066: % feeder rows differ from their node rows in multiplier, role or utility', n;
    END IF;

    -- PLTS A5 must still feed LVMDB A5, metered by device 27 on its own node
    IF NOT EXISTS (SELECT 1 FROM graph.edge e
                   JOIN graph.node f ON f.id = e.from_node_id AND f.node_code = 'PLTS_A5'
                   JOIN graph.node t ON t.id = e.to_node_id   AND t.node_code = 'LVMDB_A5'
                   WHERE e.tenant_id = 3 AND e.is_active AND e.effective_from <= CURRENT_DATE
                     AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)) THEN
        RAISE EXCEPTION '066: no PLTS_A5 -> LVMDB_A5 edge in effect';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM graph.measurement m JOIN graph.node n ON n.id = m.node_id
                   WHERE n.tenant_id = 3 AND n.node_code = 'PLTS_A5' AND m.device_id = 27
                     AND m.quantity_id = 124 AND m.is_active AND m.effective_from <= CURRENT_DATE
                     AND (m.effective_to IS NULL OR m.effective_to >= CURRENT_DATE)) THEN
        RAISE EXCEPTION '066: device 27 does not meter PLTS_A5';
    END IF;
END $guard$;

-- ---------------------------------------------------------------------------
-- Before: the windows the post-condition compares
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _g6_runs (q int, s date, e date) ON COMMIT DROP;
INSERT INTO _g6_runs VALUES
    (124, '2026-10-01', '2026-10-31'),   -- October: A5's load far below PV A5
    (124, '2026-10-21', '2026-10-21'),
    (124, '2026-11-01', '2026-11-03'),
    ( 89, '2026-10-01', '2026-10-31');

CREATE TEMP TABLE _g6_res (ver text, q int, s date, kind text, code text, value numeric) ON COMMIT DROP;

CREATE FUNCTION pg_temp.g6_capture(p_ver text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM _g6_runs LOOP
        PERFORM graph.solve_flow(3, 'ELECTRICITY', r.s::timestamp, r.e::timestamp, r.q, false,
                                 ARRAY['SHIFT1','SHIFT2','SHIFT3'], r.e);
        INSERT INTO _g6_res SELECT p_ver, r.q, r.s, 'node', n.node_code, n.value FROM _gn n;
        INSERT INTO _g6_res SELECT p_ver, r.q, r.s, 'edge', f.node_code || ' -> ' || t.node_code, g.value
          FROM _ge g JOIN _gn f ON f.id = g.from_node_id JOIN _gn t ON t.id = g.to_node_id;
        INSERT INTO _g6_res SELECT p_ver, r.q, r.s, 'device', d.device_id::text, d.total
          FROM graph.device_totals(3, 'ELECTRICITY', r.s::timestamp, r.e::timestamp, r.q, false,
                                   ARRAY['SHIFT1','SHIFT2','SHIFT3']) d
          WHERE d.device_id IN (27, 28);
    END LOOP;
END $f$;

SELECT pg_temp.g6_capture('before');

-- ---------------------------------------------------------------------------
-- 2.1 The node rows were true; 046's feeder rows never were
-- ---------------------------------------------------------------------------
UPDATE graph.measurement m SET effective_to = NULL
FROM _g6_node g WHERE m.id = g.id;

UPDATE graph.measurement m SET effective_to = '-infinity'
FROM _g6_edge g WHERE m.id = g.id;

-- ---------------------------------------------------------------------------
-- 2.3 Post-condition
-- ---------------------------------------------------------------------------
SELECT pg_temp.g6_capture('after');

DO $post$
DECLARE
    n INT;
BEGIN
    IF (SELECT count(*) FROM _g6_res WHERE ver = 'before')
       <> (SELECT count(*) FROM _g6_res WHERE ver = 'after') THEN
        RAISE EXCEPTION '066: the solver returned a different set of nodes or edges';
    END IF;

    SELECT count(*) INTO n
    FROM _g6_res b JOIN _g6_res a
      ON a.ver = 'after' AND a.q = b.q AND a.s = b.s AND a.kind = b.kind AND a.code = b.code
    WHERE b.ver = 'before' AND b.kind <> 'device' AND abs(a.value - b.value) >= 0.5
      AND NOT (   (b.kind = 'node' AND b.code IN ('LVMDB_A5', 'GAS_ENGINE'))
               OR (b.kind = 'edge' AND b.code IN (
                      'FACTORY_AB -> LVMDB_A1', 'FACTORY_AB -> LVMDB_A2', 'FACTORY_AB -> LVMDB_A3',
                      'FACTORY_AB -> LVMDB_A5',
                      'GAS_ENGINE -> LVMDB_A1', 'GAS_ENGINE -> LVMDB_A2', 'GAS_ENGINE -> LVMDB_A3')));
    IF n <> 0 THEN
        RAISE EXCEPTION '066: % solver values outside A5, the gas engine and their edges changed', n;
    END IF;

    -- LVMDB_A5 = device 28; its grid feeder = 28 - 27
    SELECT count(*) INTO n
    FROM _g6_runs r
    JOIN _g6_res a5  ON a5.ver = 'after' AND a5.q = r.q AND a5.s = r.s AND a5.kind = 'node' AND a5.code = 'LVMDB_A5'
    JOIN _g6_res fd  ON fd.ver = 'after' AND fd.q = r.q AND fd.s = r.s AND fd.kind = 'edge' AND fd.code = 'FACTORY_AB -> LVMDB_A5'
    LEFT JOIN _g6_res d28 ON d28.ver = 'after' AND d28.q = r.q AND d28.s = r.s AND d28.kind = 'device' AND d28.code = '28'
    LEFT JOIN _g6_res d27 ON d27.ver = 'after' AND d27.q = r.q AND d27.s = r.s AND d27.kind = 'device' AND d27.code = '27'
    WHERE d28.value IS NOT NULL
      AND (abs(a5.value - d28.value) >= 0.5 OR abs(fd.value - (d28.value - COALESCE(d27.value, 0))) >= 0.5);
    IF n <> 0 THEN
        RAISE EXCEPTION '066: in % windows LVMDB_A5 is not device 28, or its feeder is not 28 - 27', n;
    END IF;

    -- the engine can only lose the PV A5 it was credited with
    SELECT count(*) INTO n
    FROM _g6_res b JOIN _g6_res a
      ON a.ver = 'after' AND a.q = b.q AND a.s = b.s AND a.kind = 'node' AND a.code = b.code
    WHERE b.ver = 'before' AND b.kind = 'node' AND b.code = 'GAS_ENGINE' AND a.value > b.value + 0.5;
    IF n <> 0 THEN
        RAISE EXCEPTION '066: the gas engine went up in % windows', n;
    END IF;

    SELECT count(*) INTO n FROM _g6_res
    WHERE ver = 'after' AND kind = 'edge' AND code LIKE 'GAS_ENGINE -> %' AND value < -0.5;
    IF n <> 0 THEN
        RAISE EXCEPTION '066: % gas engine edges came out negative', n;
    END IF;
END $post$;

\echo ''
\echo '=== 2.3 What moved ==='
SELECT b.q, b.s, b.kind, b.code, round(b.value) AS before, round(a.value) AS after
FROM _g6_res b JOIN _g6_res a
  ON a.ver = 'after' AND a.q = b.q AND a.s = b.s AND a.kind = b.kind AND a.code = b.code
WHERE b.ver = 'before' AND abs(a.value - b.value) >= 0.5
ORDER BY b.q, b.s, b.kind DESC, b.code;

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
-- expect LVMDB_A5: 62 89 96 124 131 481 1072 1119

\echo ''
\echo '=== 3.2 Device 28 rows never in effect ==='
SELECT count(*) AS corrected FROM graph.measurement
WHERE tenant_id = 3 AND device_id = 28 AND effective_to = '-infinity' AND edge_id IS NOT NULL;
-- expect 7


-- ============================================================================
-- 4. Undo (commented): back to 046's model
-- ============================================================================
--
-- BEGIN;
-- UPDATE graph.measurement SET effective_to = NULL
--  WHERE tenant_id = 3 AND device_id = 28 AND edge_id IS NOT NULL AND effective_to = '-infinity';
-- UPDATE graph.measurement SET effective_to = '-infinity'
--  WHERE tenant_id = 3 AND device_id = 28 AND node_id IS NOT NULL
--    AND quantity_id IN (62, 89, 96, 124, 131, 481, 1072) AND effective_to IS NULL;
-- COMMIT;
