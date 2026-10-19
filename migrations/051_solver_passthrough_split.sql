-- Migration: 051_solver_passthrough_split.sql
-- Description: Solve the gas engine's share of LVMDB A1-A3 from FACTORY_AB's meter instead of
--              splitting each board 50/50: a capped proportional split for passthrough nodes,
--              the even split moved to last resort, and FACTORY_AB flagged passthrough.
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-sankey.md §9.5 (G11); design/graph-network-design.md (solver rules)
-- Requires: 050_lvmdb_texture_last_reading.sql
--
-- WHY
-- ---
-- LVMDB_A1, A2 and A3 each have two unmetered in-edges, FACTORY_AB (TRANSFORMER) and GAS_ENGINE
-- (GENERATOR_INFEED). Rule (b) split each board's metered value evenly between them, so the gas
-- engine was always half of 23 + 24 + 25 and the error landed on FACTORY_AB as a residual. In
-- September 2026 that drew the engine at 279,858 kWh and left FACTORY_AB +44,979.
--
-- FACTORY_AB is an MV_BUS that consumes nothing itself (its out-edges go only to the six boards),
-- so its meter (84) fixes how much it sends A1-A3: 84 minus the A4, A5 and B2 feeders, which the
-- solver already knows. Then gas engine = 23 + 24 + 25 minus that: 234,879 kWh in September. The
-- same balance, hourly, shows the engine runs in campaigns (September 1-15 on, then off), which a
-- fixed 50/50 cannot follow: it invented about 140,000 kWh in the second half of the month.
--
-- WHAT CHANGES IN THE SOLVER
-- --------------------------
-- 1. New rule (a2). A node with is_passthrough, a known value and several out-edges: its unknown
--    out-edges carry value - known out-edges. Once every one of them leads to a valued target that
--    has another unknown in-edge, that sum is split in proportion to the targets' values. It is
--    capped to what is physically possible: never below 0, never above the targets' total, and
--    anything beyond stays on the parent as its residual. The cap matters for reactive energy,
--    which the transformers below meter 84 absorb: uncapped, the engine came out at -5,218 kvarh
--    on 2026-09-20 while it was off; capped, it is 0, and FACTORY_AB keeps the 5,218 as
--    transformer losses. The edges are flagged ambiguous when there is more than one: the
--    per-board split is proportional, only the total is exact.
-- 2. Rule (b) fills an in-edge in the main loop only when it is the target's last unknown, and the
--    value inherits the ambiguity of its siblings (a remainder of a proportional split is as
--    uncertain per board as the split). Splitting evenly across several unknown in-edges moves to
--    the exhaust phase, before rule (d), so it happens only when nothing exact is left. Before,
--    it ran first and pre-empted (a2).
-- 3. FACTORY_AB gets is_passthrough = TRUE. Only solve_flow reads the flag (no view, function or
--    MCP tool does). The 15 water tanks and softeners already flagged passthrough did not trigger
--    (a2) on September's data.
--
-- IMPACT (compared on dev, September 2026, 124 and 89 for the month, 2026-09-05 and 2026-09-20,
-- water 5696 for the month and 2026-09-05): the GAS_ENGINE node and its six edges into A1-A3
-- change, and nothing else. Section 2.3 enforces that on whichever database this runs: it solves
-- the same windows before and after and aborts if any other node or edge moves, or if an engine
-- edge goes negative. A database with no telemetry in those windows passes trivially.
--
-- Known limit: on days the engine is off, about 500 kWh/day (2-5% of A1-A3) is still credited to
-- it, because the LV meters read slightly more than 84 accounts for; that is meter disagreement
-- (transformer losses would have the opposite sign). A meter on the engine's output would remove
-- this and the proportional per-board split.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 FACTORY_AB and the boards it feeds ==='
SELECT f.node_code AS parent, f.node_type, f.is_passthrough, t.node_code AS child, e.edge_type
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND f.node_code IN ('FACTORY_AB', 'GAS_ENGINE')
  AND e.is_active AND e.effective_from <= CURRENT_DATE
  AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)
ORDER BY 1, 4;
-- expect FACTORY_AB (MV_BUS, not passthrough) -> LVMDB_A1..A5, LVMDB_B2;
--        GAS_ENGINE -> LVMDB_A1..A3


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 2.0 Guard, and capture the solver output for the comparison in 2.3
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE
    m TEXT;
BEGIN
    SELECT md5(pg_get_functiondef('graph.solve_flow'::regproc)) INTO m;
    IF m IS DISTINCT FROM 'e4057d0e8639e2607444b59db90ccba4' THEN
        RAISE EXCEPTION '051: graph.solve_flow is not the version this migration was written against '
                        '(md5 %, expected e4057d0e8639e2607444b59db90ccba4, the body from 028 §2.6)', m;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM graph.node WHERE tenant_id = 3 AND node_code = 'FACTORY_AB'
                   AND node_type = 'MV_BUS' AND NOT is_passthrough) THEN
        RAISE EXCEPTION '051: expected FACTORY_AB as an MV_BUS not yet flagged passthrough';
    END IF;

    -- passthrough means it consumes nothing: every live out-edge must go to a board
    IF EXISTS (SELECT 1 FROM graph.edge e
               JOIN graph.node f ON f.id = e.from_node_id AND f.node_code = 'FACTORY_AB'
               JOIN graph.node t ON t.id = e.to_node_id
               WHERE e.tenant_id = 3 AND e.is_active AND e.effective_from <= CURRENT_DATE
                 AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)
                 AND t.node_type <> 'MAIN_LV_BOARD') THEN
        RAISE EXCEPTION '051: FACTORY_AB feeds something other than a MAIN_LV_BOARD; it may consume itself';
    END IF;
END $guard$;

CREATE TEMP TABLE _g11_runs (u text, q int, s date, e date) ON COMMIT DROP;
INSERT INTO _g11_runs VALUES
    ('ELECTRICITY', 124, '2026-09-01', '2026-09-30'),
    ('ELECTRICITY', 124, '2026-09-05', '2026-09-05'),
    ('ELECTRICITY', 124, '2026-09-20', '2026-09-20'),
    ('ELECTRICITY',  89, '2026-09-01', '2026-09-30'),
    ('ELECTRICITY',  89, '2026-09-20', '2026-09-20'),
    ('WATER',      5696, '2026-09-01', '2026-09-30');

CREATE TEMP TABLE _g11_res (ver text, u text, q int, s date, kind text, code text, value numeric)
    ON COMMIT DROP;

CREATE FUNCTION pg_temp.g11_capture(p_ver text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM _g11_runs LOOP
        PERFORM graph.solve_flow(3, r.u, r.s::timestamp, r.e::timestamp, r.q, false,
                                 ARRAY['SHIFT1','SHIFT2','SHIFT3'], r.e);
        INSERT INTO _g11_res SELECT p_ver, r.u, r.q, r.s, 'node', n.node_code, n.value FROM _gn n;
        INSERT INTO _g11_res SELECT p_ver, r.u, r.q, r.s, 'edge', f.node_code || ' -> ' || t.node_code, g.value
          FROM _ge g JOIN _gn f ON f.id = g.from_node_id JOIN _gn t ON t.id = g.to_node_id;
    END LOOP;
END $f$;

SELECT pg_temp.g11_capture('before');

-- ---------------------------------------------------------------------------
-- 2.1 FACTORY_AB consumes nothing itself
-- ---------------------------------------------------------------------------
UPDATE graph.node SET is_passthrough = TRUE
WHERE tenant_id = 3 AND node_code = 'FACTORY_AB';

-- ---------------------------------------------------------------------------
-- 2.2 The solver: 028's body plus rule (a2) and the deferred even split
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION graph.solve_flow(p_tenant_id integer, p_utility_code character varying, p_start timestamp without time zone, p_end timestamp without time zone, p_quantity_id integer, p_is_cost boolean DEFAULT false, p_shift_periods character varying[] DEFAULT ARRAY['SHIFT1'::text, 'SHIFT2'::text, 'SHIFT3'::text], p_as_of date DEFAULT CURRENT_DATE, p_max_iter integer DEFAULT 50)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_iter    INTEGER;
    v_changed INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM graph.quantity_rule qr
                    WHERE qr.quantity_id = p_quantity_id AND qr.conserved) THEN
        RAISE EXCEPTION
          'graph.solve_flow: quantity % is not declared conserved in graph.quantity_rule — flow balance does not apply (use graph.get_node_quantity)',
          p_quantity_id;
    END IF;

    DROP TABLE IF EXISTS _gn, _ge;

    CREATE TEMP TABLE _ge ON COMMIT DROP AS
    SELECT e.id, e.from_node_id, e.to_node_id,
           em.total AS meas, em.total AS value, FALSE AS amb
    FROM graph.edge e
    LEFT JOIN (
        SELECT ms.edge_id AS eid, SUM(dt.total * ms.multiplier) AS total
        FROM graph.measurement ms
        JOIN graph.device_totals(p_tenant_id, p_utility_code, p_start, p_end,
                                 p_quantity_id, p_is_cost, p_shift_periods) dt
          ON dt.device_id = ms.device_id AND dt.quantity_id = ms.quantity_id
        WHERE ms.edge_id IS NOT NULL AND ms.is_active AND ms.role = 'TOTAL'
          AND ms.utility_code = p_utility_code
          AND ms.effective_from <= p_as_of
          AND (ms.effective_to IS NULL OR ms.effective_to >= p_as_of)
        GROUP BY ms.edge_id
    ) em ON em.eid = e.id
    WHERE e.tenant_id = p_tenant_id AND e.is_active
      AND e.utility_code = p_utility_code
      -- 028: was e.edge_class <> 'COMPENSATION'. The rule is now data on
      -- graph.edge_type. COALESCE keeps an untyped edge carrying flow, which
      -- is what the old predicate did for everything except COMPENSATION.
      AND COALESCE((SELECT et.carries_flow FROM graph.edge_type et
                     WHERE et.code = e.edge_type), TRUE)
      AND e.effective_from <= p_as_of
      AND (e.effective_to IS NULL OR e.effective_to >= p_as_of);

    CREATE TEMP TABLE _gn ON COMMIT DROP AS
    SELECT n.id, n.node_code, n.node_name, n.node_class, n.is_passthrough,
           nm.total AS measured, nm.total AS value,
           (CASE WHEN nm.total IS NOT NULL THEN 'MEASURED' END)::VARCHAR(10) AS val_src,
           (SELECT COUNT(*) FROM _ge g WHERE g.to_node_id   = n.id) AS in_deg,
           (SELECT COUNT(*) FROM _ge g WHERE g.from_node_id = n.id) AS out_deg,
           TRUE AS has_data
    FROM graph.node n
    LEFT JOIN (
        SELECT ms.node_id AS nid, SUM(dt.total * ms.multiplier) AS total
        FROM graph.measurement ms
        JOIN graph.device_totals(p_tenant_id, p_utility_code, p_start, p_end,
                                 p_quantity_id, p_is_cost, p_shift_periods) dt
          ON dt.device_id = ms.device_id AND dt.quantity_id = ms.quantity_id
        WHERE ms.node_id IS NOT NULL AND ms.is_active AND ms.role = 'TOTAL'
          AND ms.utility_code = p_utility_code
          AND ms.effective_from <= p_as_of
          AND (ms.effective_to IS NULL OR ms.effective_to >= p_as_of)
        GROUP BY ms.node_id
    ) nm ON nm.nid = n.id
    WHERE n.tenant_id = p_tenant_id AND n.is_active
      AND n.effective_from <= p_as_of
      AND (n.effective_to IS NULL OR n.effective_to >= p_as_of)
      AND EXISTS (SELECT 1 FROM _ge g WHERE g.from_node_id = n.id OR g.to_node_id = n.id);

    FOR v_iter IN 1..p_max_iter LOOP
        v_changed := 0;

        -- (a) a node that cannot consume anything itself -- a graph head (in_deg = 0)
        --     or one declared is_passthrough -- with a single out-edge sends its whole
        --     value down that feeder. Skipped where rule (b) can resolve the target
        --     from the target's own meter, which would otherwise erase a real residual.
        WITH tgt AS (
            SELECT g.to_node_id AS nid,
                   COUNT(*) FILTER (WHERE g.value IS NULL) AS n_unknown
            FROM _ge g GROUP BY g.to_node_id
        ), upd AS (
            UPDATE _ge g SET value = n.value
            FROM _gn n, _gn c, tgt t
            WHERE g.from_node_id = n.id AND g.value IS NULL
              AND n.value IS NOT NULL AND n.out_deg = 1
              AND (n.in_deg = 0 OR n.is_passthrough)
              AND c.id = g.to_node_id AND t.nid = g.to_node_id
              AND (c.value IS NULL OR t.n_unknown > 1)
            RETURNING 1
        ) SELECT v_changed + COUNT(*) INTO v_changed FROM upd;

        -- (a2) G11: a passthrough node with a known value and several out-edges. Its unknown
        --      out-edges carry value - known out-edges. Once every one of them goes to a valued
        --      target that has another unknown in-edge, split that sum in proportion to the
        --      targets' values; rule (b) then gives each target's remainder to its other parent.
        WITH outs AS (
            SELECT g.from_node_id AS nid, COALESCE(SUM(g.value), 0) AS known,
                   COUNT(*) FILTER (WHERE g.value IS NULL) AS k
            FROM _ge g GROUP BY g.from_node_id
        ), tin AS (
            SELECT g.to_node_id AS nid, COUNT(*) FILTER (WHERE g.value IS NULL) AS n_unknown
            FROM _ge g GROUP BY g.to_node_id
        ), par AS (
            SELECT n.id, n.value - o.known AS r, o.k
            FROM _gn n JOIN outs o ON o.nid = n.id
            WHERE n.is_passthrough AND n.value IS NOT NULL AND n.out_deg > 1 AND o.k >= 1
              AND NOT EXISTS (
                  SELECT 1 FROM _ge g JOIN _gn c ON c.id = g.to_node_id JOIN tin t ON t.nid = g.to_node_id
                  WHERE g.from_node_id = n.id AND g.value IS NULL
                    AND (c.value IS NULL OR t.n_unknown < 2))
        ), w AS (
            SELECT g.id, p.r, p.k, c.value AS cv, SUM(c.value) OVER (PARTITION BY p.id) AS sw
            FROM par p JOIN _ge g ON g.from_node_id = p.id AND g.value IS NULL
            JOIN _gn c ON c.id = g.to_node_id
        ), upd AS (
            -- capped to what the targets can take: never below 0, never above their
            -- total; anything beyond stays on the parent as its residual (losses)
            UPDATE _ge g SET value = CASE WHEN w.sw > 0 THEN LEAST(GREATEST(w.r, 0), w.sw) * w.cv / w.sw
                                          ELSE GREATEST(w.r, 0) / w.k END,
                             amb   = (w.k > 1)
            FROM w WHERE g.id = w.id
            RETURNING 1
        ) SELECT v_changed + COUNT(*) INTO v_changed FROM upd;

        -- (b) split a known node value across its still-unknown in-edges
        WITH t AS (
            SELECT g.to_node_id AS nid,
                   COALESCE(SUM(g.value), 0)               AS known_sum,
                   COUNT(*) FILTER (WHERE g.value IS NULL) AS n_unknown
            FROM _ge g GROUP BY g.to_node_id
        ), upd AS (
            -- G11: a remainder taken from an ambiguous sibling is itself ambiguous
            UPDATE _ge g SET value = (n.value - t.known_sum) / t.n_unknown,
                             amb   = EXISTS (SELECT 1 FROM _ge s WHERE s.to_node_id = t.nid AND s.amb)
            FROM t JOIN _gn n ON n.id = t.nid
            WHERE g.to_node_id = t.nid AND g.value IS NULL
              AND n.value IS NOT NULL AND t.n_unknown = 1      -- G11: exact only; even split deferred
            RETURNING 1
        ) SELECT v_changed + COUNT(*) INTO v_changed FROM upd;

        -- (c) node value from fully-known in-edges, else fully-known out-edges.
        --     val_src records which, so §5.4 only claims a residual where the
        --     inflow was known independently of the out-edges.
        WITH ins AS (
            SELECT g.to_node_id AS nid, SUM(g.value) AS s,
                   COUNT(*) FILTER (WHERE g.value IS NULL) AS unk
            FROM _ge g GROUP BY g.to_node_id
        ), upd AS (
            UPDATE _gn n SET value = ins.s, val_src = 'IN_EDGES' FROM ins
            WHERE n.id = ins.nid AND n.value IS NULL AND ins.unk = 0
            RETURNING 1
        ) SELECT v_changed + COUNT(*) INTO v_changed FROM upd;

        WITH outs AS (
            SELECT g.from_node_id AS nid, SUM(g.value) AS s,
                   COUNT(*) FILTER (WHERE g.value IS NULL) AS unk
            FROM _ge g GROUP BY g.from_node_id
        ), upd AS (
            UPDATE _gn n SET value = outs.s, val_src = 'OUT_EDGES' FROM outs
            WHERE n.id = outs.nid AND n.value IS NULL AND outs.unk = 0
            RETURNING 1
        ) SELECT v_changed + COUNT(*) INTO v_changed FROM upd;

        IF v_changed = 0 THEN
            -- (b') G11: the even split, deferred until nothing exact is left
            WITH t AS (
                SELECT g.to_node_id AS nid,
                       COALESCE(SUM(g.value), 0)               AS known_sum,
                       COUNT(*) FILTER (WHERE g.value IS NULL) AS n_unknown
                FROM _ge g GROUP BY g.to_node_id
            ), upd AS (
                UPDATE _ge g SET value = (n.value - t.known_sum) / t.n_unknown,
                                 amb   = TRUE
                FROM t JOIN _gn n ON n.id = t.nid
                WHERE g.to_node_id = t.nid AND g.value IS NULL
                  AND n.value IS NOT NULL AND t.n_unknown > 1
                RETURNING 1
            ) SELECT COUNT(*) INTO v_changed FROM upd;
        END IF;

        IF v_changed = 0 THEN
            -- (d) last resort, only once a-c are exhausted
            WITH kids AS (
                SELECT g.from_node_id AS nid, SUM(c.value) AS s
                FROM _ge g JOIN _gn c ON c.id = g.to_node_id
                WHERE c.value IS NOT NULL GROUP BY g.from_node_id
            ), upd AS (
                UPDATE _gn n SET value = kids.s, val_src = 'CHILDREN' FROM kids
                WHERE n.id = kids.nid AND n.value IS NULL AND n.out_deg > 0
                RETURNING 1
            ) SELECT COUNT(*) INTO v_changed FROM upd;
            EXIT WHEN v_changed = 0;
        END IF;
    END LOOP;

    UPDATE _gn SET has_data = FALSE WHERE _gn.value IS NULL;
    UPDATE _gn SET value    = 0     WHERE _gn.value IS NULL;
    UPDATE _ge SET value    = 0     WHERE _ge.value IS NULL;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2.3 Post-condition: only the gas engine and its six edges may move
-- ---------------------------------------------------------------------------
SELECT pg_temp.g11_capture('after');

DO $post$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n
    FROM _g11_res b JOIN _g11_res a
      ON a.ver = 'after' AND a.u = b.u AND a.q = b.q AND a.s = b.s AND a.kind = b.kind AND a.code = b.code
    WHERE b.ver = 'before' AND abs(a.value - b.value) >= 0.5
      AND NOT (   (b.kind = 'node' AND b.code = 'GAS_ENGINE')
               OR (b.kind = 'edge' AND b.code IN (
                      'FACTORY_AB -> LVMDB_A1', 'FACTORY_AB -> LVMDB_A2', 'FACTORY_AB -> LVMDB_A3',
                      'GAS_ENGINE -> LVMDB_A1', 'GAS_ENGINE -> LVMDB_A2', 'GAS_ENGINE -> LVMDB_A3')));
    IF n <> 0 THEN
        RAISE EXCEPTION '051: % solver values outside the gas engine and its edges changed', n;
    END IF;

    IF (SELECT count(*) FROM _g11_res WHERE ver = 'before')
       <> (SELECT count(*) FROM _g11_res WHERE ver = 'after') THEN
        RAISE EXCEPTION '051: the solver returned a different set of nodes or edges';
    END IF;

    SELECT count(*) INTO n FROM _g11_res
    WHERE ver = 'after' AND kind = 'edge' AND code LIKE 'GAS_ENGINE -> %' AND value < -0.5;
    IF n <> 0 THEN
        RAISE EXCEPTION '051: % gas engine edges came out negative', n;
    END IF;
END $post$;

\echo ''
\echo '=== 2.3 What moved ==='
SELECT b.u, b.q, b.s, b.kind, b.code, round(b.value) AS before, round(a.value) AS after
FROM _g11_res b JOIN _g11_res a
  ON a.ver = 'after' AND a.u = b.u AND a.q = b.q AND a.s = b.s AND a.kind = b.kind AND a.code = b.code
WHERE b.ver = 'before' AND abs(a.value - b.value) >= 0.5
ORDER BY b.u, b.q, b.s, b.kind DESC, b.code;
-- on dev (September 2026): gas engine 124 month 279,858 -> 234,879; 09-05 9,376 -> 16,371;
-- 09-20 8,643 -> 559; 89 month 234,273 -> 45,487; 89 09-20 7,753 -> 0

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Passthrough nodes ==='
SELECT utility_code, count(*) FROM (
    SELECT DISTINCT n.id, e.utility_code FROM graph.node n
    JOIN graph.edge e ON e.from_node_id = n.id OR e.to_node_id = n.id
    WHERE n.tenant_id = 3 AND n.is_passthrough) x
GROUP BY 1 ORDER BY 1;
-- expect ELECTRICITY 1 (FACTORY_AB), WATER 15


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- UPDATE graph.node SET is_passthrough = FALSE WHERE tenant_id = 3 AND node_code = 'FACTORY_AB';
-- -- then re-run the CREATE OR REPLACE FUNCTION graph.solve_flow in
-- -- 028_create_edge_type.sql §2.6 (lines 375-522); its md5 is the one 2.0 asserts.
-- COMMIT;
