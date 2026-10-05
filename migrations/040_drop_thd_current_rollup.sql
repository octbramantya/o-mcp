-- Migration: 040_drop_thd_current_rollup.sql
-- Description: Stop the solver treating THD current phase A (2097) as a node quantity:
--              delete its quantity_rule row and its 99 measurement rows.
-- Author: Claude
-- Date: 2026-10-05
-- Design: design/graph-network-design.md §4.7, §11.3
-- Requires: 039_site_status_on_all_types.sql
--
-- WHY
-- ---
-- 008 seeded quantity_rule (2097, P95, RSS): an unmetered node gets sqrt(sum x^2)
-- of its children's THD current. Three things are wrong with it.
--
--  1. THD is a percent of each load's own fundamental current. Percentages of
--     different currents cannot be combined without those currents; the RSS of
--     6% and 8% is 10%, but two equal loads at 6% and 8% give about 5%, and no
--     combination of real currents exceeds the worst child. On the dev week
--     (as of 2026-09-10) GAS_ENGINE rolled up to 59.5% from boards at 13.9,
--     7.6 and 57.3.
--  2. The rollup runs into every parent, sources included: PLTS_A4,
--     PLTS_TEXTURE and GAS_ENGINE were given their board's value, though the
--     board's harmonic current does not come from them.
--  3. 2097 is phase A only. The same 89 meters report B (2098) and C (2099);
--     on the dev week A was not the worst phase on 52 of them, and on 18 the
--     worst phase was at least 25% and 2 points above it (SIPPA: A 6.5,
--     C 162.8; LVMDB A4: A 34.6, B 102.6).
--
-- Harmonic current is assessed where it is done right: harmonics_report.py
-- (all three phases, TDD against the board's rated current, worst phase) and
-- the Grafana panels, which read 2097-2099 directly and take the worst phase
-- themselves. Nothing calls get_node_quantity for 2097.
--
-- DELETE, not effective_to. The meters still measure phase A THD, so a date
-- (the plant changed) and '-infinity' (never true) would both be false. What
-- changes is the decision that the solver uses it, and the rows carry no
-- evidence beyond that: every one of the 99 (node, device) pairs also has
-- other measurement rows, so no meter loses its node, and v_coverage,
-- v_device_attachment and node_code_of_device do not filter by quantity.
-- Deleting the rule also stops wages_sync.py, which writes one measurement
-- row per quantity_rule, from recreating them.
--
-- Kept: graph.quantity_term for 2097-2100 (vocabulary, not a solver rule);
-- the telemetry; and 'RSS' as a network_agg value, which stays right for
-- harmonic currents in amperes combined per order, the basis a correct
-- rollup would need. get_node_quantity(..., 2097) now raises "no row in
-- graph.quantity_rule" instead of returning a wrong value.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 The rule ==='
SELECT * FROM graph.quantity_rule WHERE quantity_id = 2097;
-- expect (2097, ELECTRICITY, P95, RSS, f)

\echo ''
\echo '=== 1.2 Its measurement rows ==='
SELECT count(*) AS rows_2097,
       count(*) FILTER (WHERE is_active AND effective_from <= CURRENT_DATE
                          AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)) AS in_effect,
       count(*) FILTER (WHERE edge_id IS NOT NULL) AS on_edges
FROM graph.measurement WHERE quantity_id = 2097;
-- expect 99, 97 (the two BARU panels' rows ended 2026-09-27), 0

\echo ''
\echo '=== 1.3 Pairs that 2097 alone attaches ==='
SELECT count(*) AS pairs_only_2097 FROM (
    SELECT node_id, device_id FROM graph.measurement
    WHERE node_id IS NOT NULL GROUP BY 1, 2
    HAVING bool_and(quantity_id = 2097)) x;
-- expect 0

\echo ''
\echo '=== 1.4 The rows being deleted, in full (the record for undo; kept in logs/<label>/) ==='
SELECT m.id, m.tenant_id, m.node_id, n.node_code, m.device_id, m.quantity_id, m.utility_code,
       m.multiplier, m.role, m.is_active, m.effective_from, m.effective_to, m.created_at
FROM graph.measurement m JOIN graph.node n ON n.id = m.node_id
WHERE m.quantity_id = 2097 ORDER BY m.id;


-- ============================================================================
-- 2. Change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run unless the rows are exactly as described above
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n FROM graph.quantity_rule
    WHERE quantity_id = 2097 AND utility_code = 'ELECTRICITY'
      AND raw_time_agg = 'P95' AND network_agg = 'RSS' AND NOT conserved;
    IF n <> 1 THEN
        RAISE EXCEPTION 'expected quantity_rule (2097, ELECTRICITY, P95, RSS, f), found % matching', n;
    END IF;

    SELECT count(*) INTO n FROM graph.measurement WHERE quantity_id = 2097;
    IF n <> 99 THEN
        RAISE EXCEPTION 'expected 99 measurement rows for 2097, found %', n;
    END IF;

    SELECT count(*) INTO n FROM graph.measurement
    WHERE quantity_id = 2097 AND edge_id IS NOT NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION '040 assumes no 2097 measurement on an edge, found %', n;
    END IF;

    SELECT count(*) INTO n FROM (
        SELECT node_id, device_id FROM graph.measurement
        WHERE node_id IS NOT NULL GROUP BY 1, 2
        HAVING bool_and(quantity_id = 2097)) x;
    IF n <> 0 THEN
        RAISE EXCEPTION '% (node, device) pairs are attached by 2097 alone; deleting would detach them', n;
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 2.2 Delete the measurement rows, then the rule
-- ----------------------------------------------------------------------------
DELETE FROM graph.measurement WHERE quantity_id = 2097;
DELETE FROM graph.quantity_rule WHERE quantity_id = 2097;

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Rules and rows left ==='
SELECT count(*) AS rules FROM graph.quantity_rule;
SELECT count(*) AS rows_2097 FROM graph.measurement WHERE quantity_id = 2097;
SELECT count(*) AS term_2097 FROM graph.quantity_term WHERE quantity_id = 2097;
-- expect 10 rules, 0 rows, 1 term

\echo ''
\echo '=== 3.2 Meters attached to nodes, in effect ==='
SELECT count(DISTINCT node_id) AS metered_nodes, count(DISTINCT device_id) AS devices
FROM graph.measurement
WHERE node_id IS NOT NULL AND is_active AND effective_from <= CURRENT_DATE
  AND (effective_to IS NULL OR effective_to >= CURRENT_DATE);
-- expect 97 nodes, 97 devices, as before (the other 6 devices meter water edges)

\echo ''
\echo '=== 3.3 The solver refuses 2097 ==='
DO $$
BEGIN
    BEGIN
        PERFORM * FROM graph.get_node_quantity(3, 'ELECTRICITY', 2097,
                                               '2026-09-07', '2026-09-14');
        RAISE EXCEPTION 'probe not refused';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM = 'probe not refused' THEN RAISE; END IF;
        RAISE NOTICE 'refused as expected: %', SQLERRM;
    END;
END
$$;


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- The 99 rows are printed in full by section 1.4, in the run's log under
-- logs/<label>/. Re-insert them from there, rule first:
--
-- BEGIN;
-- INSERT INTO graph.quantity_rule (quantity_id, utility_code, raw_time_agg, network_agg, conserved)
--     VALUES (2097, 'ELECTRICITY', 'P95', 'RSS', FALSE);
-- INSERT INTO graph.measurement (id, tenant_id, node_id, device_id, quantity_id, utility_code,
--                                multiplier, role, is_active, effective_from, effective_to, created_at)
--     VALUES ...;   -- the 99 rows from 1.4
-- COMMIT;
