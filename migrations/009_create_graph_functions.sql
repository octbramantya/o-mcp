-- Migration: 009_create_graph_functions.sql
-- Description: Flow solver and the read entry points over the graph schema
-- Author: Claude
-- Date: 2026-08-19
-- Phase: 0 -- additive, nothing reads it yet (see §8 of design/graph-network-design.md)
--
-- Every statement below is extracted verbatim from graph-network-design.md.
-- Edit the design document first, then regenerate -- not the other way round.
--
-- Requires 008. graph.solve_flow and graph.get_node_quantity create TEMP
-- tables, so they are VOLATILE, not STABLE, and the calling role needs
-- TEMPORARY on the database (see 010).

BEGIN;

-- ============================================================================
-- Telemetry access, routed by quantity as well as utility (§5.1)
-- ============================================================================
CREATE OR REPLACE FUNCTION graph.device_totals(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_quantity_id   INTEGER,
    p_is_cost       BOOLEAN   DEFAULT FALSE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3']
) RETURNS TABLE (device_id INTEGER, quantity_id INTEGER, total NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_src       INTEGER[];
    v_rule      VARCHAR;
    v_conserved BOOLEAN;
    -- same ceiling public.telemetry_intervals_cumulative uses to reject a
    -- register correction masquerading as one interval of consumption
    c_max_interval CONSTANT NUMERIC := 999999;
BEGIN
    IF p_quantity_id IS NULL THEN
        RAISE EXCEPTION 'graph.device_totals: p_quantity_id is required — a NULL match sums redundant registers (e.g. 130 alongside 124)';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.quantity_alias a WHERE a.quantity_id = p_quantity_id) THEN
        RAISE EXCEPTION 'graph.device_totals: quantity % is a register alias; pass its canonical id', p_quantity_id;
    END IF;

    SELECT array_agg(s.x) INTO v_src FROM (
        SELECT p_quantity_id AS x
        UNION
        SELECT a.quantity_id FROM graph.quantity_alias a
         WHERE a.canonical_quantity_id = p_quantity_id) s;

    -- Route by quantity, not just utility: daily_energy_cost_summary and
    -- telemetry_intervals_water hold *conserved* quantities only. Power quality
    -- for the same utility lives in raw telemetry.
    v_conserved := COALESCE((SELECT qr.conserved FROM graph.quantity_rule qr
                              WHERE qr.quantity_id = p_quantity_id), TRUE);

    IF p_utility_code = 'ELECTRICITY' AND v_conserved THEN
        RETURN QUERY
        WITH src AS (
            SELECT d.device_id AS did, d.quantity_id AS qsrc,
                   (d.quantity_id <> p_quantity_id) AS is_alias,
                   (CASE WHEN p_is_cost THEN d.total_cost ELSE d.total_consumption END) AS v
            FROM daily_energy_cost_summary d
            WHERE d.tenant_id = p_tenant_id
              AND d.daily_bucket >= p_start AND d.daily_bucket <= p_end
              AND d.shift_period = ANY (p_shift_periods)
              AND d.quantity_id = ANY (v_src)
        ), pref AS (          -- canonical register wins; alias only if canonical absent
            SELECT DISTINCT ON (s.did) s.did AS did, s.qsrc AS qsrc
            FROM src s ORDER BY s.did, s.is_alias
        )
        SELECT s.did, p_quantity_id, SUM(s.v)
        FROM src s JOIN pref p ON p.did = s.did AND p.qsrc = s.qsrc
        GROUP BY s.did;

    ELSIF p_utility_code = 'WATER' AND v_conserved THEN
        RETURN QUERY
        SELECT w.device_id, p_quantity_id, SUM(w.interval_m3)
        FROM telemetry_intervals_water w
        WHERE w.tenant_id = p_tenant_id
          AND w.bucket >= p_start AND w.bucket <= p_end
          AND w.is_valid_interval
          AND w.quantity_id = ANY (v_src)
        GROUP BY w.device_id;

    ELSE   -- raw telemetry, collapsed per graph.quantity_rule.raw_time_agg
        v_rule := COALESCE((SELECT qr.raw_time_agg FROM graph.quantity_rule qr
                             WHERE qr.quantity_id = p_quantity_id), 'SUM');

        IF v_rule = 'DELTA' THEN
            -- A cumulative register read straight off the 15-minute aggregate.
            -- MAX(v) - MIN(v) is wrong on live data in two distinct ways:
            --
            --   * a counter reset makes MIN the post-reset value, so the window
            --     reports most of the lifetime total as consumption. Device 55
            --     "MC 9" resets to zero 391 times in 30 days on quantity 481.
            --   * a single NaN bucket poisons MAX, because NaN sorts ABOVE every
            --     real value in NUMERIC. Device 103 "MC 3" has one at
            --     2026-07-28 01:45 on both 131 and 481. The device totals NaN,
            --     and solve_flow then carries that NaN to every node above it.
            --
            -- Sum the forward differences instead and drop the impossible ones.
            -- public.telemetry_intervals_cumulative already does exactly this for
            -- the conserved registers; the raw branch is simply the path that
            -- never got the guard (§5.1).
            RETURN QUERY
            WITH raw AS (
                SELECT t.device_id AS did, t.bucket AS b, t.aggregated_value AS v
                FROM telemetry_15min_agg t
                JOIN quantities q       ON q.id = t.quantity_id
                JOIN graph.utility u    ON u.quantity_category = q.category
                WHERE t.tenant_id = p_tenant_id
                  AND u.code = p_utility_code
                  -- one cadence of lookback, so the first in-window bucket has a
                  -- predecessor and its interval is not silently dropped
                  AND t.bucket >= p_start - INTERVAL '1 hour'
                  AND t.bucket <= p_end
                  AND t.quantity_id = ANY (v_src)
                  AND t.aggregated_value IS NOT NULL
                  AND t.aggregated_value <> 'NaN'::NUMERIC
            ), diff AS (
                SELECT r.did AS did, r.b AS b,
                       r.v - LAG(r.v) OVER (PARTITION BY r.did ORDER BY r.b) AS d
                FROM raw r
            )
            SELECT x.did, p_quantity_id,
                   COALESCE(SUM(
                       CASE
                         WHEN x.d IS NULL          THEN 0   -- no predecessor
                         WHEN x.d < 0              THEN 0   -- reset or rollover
                         WHEN x.d > c_max_interval THEN 0   -- register correction
                         ELSE x.d
                       END), 0)::NUMERIC
            FROM diff x
            WHERE x.b >= p_start AND x.b <= p_end
            GROUP BY x.did;

        ELSE
            RETURN QUERY
            WITH raw AS (
                SELECT t.device_id AS did, t.bucket AS b, t.aggregated_value AS v
                FROM telemetry_15min_agg t
                JOIN quantities q       ON q.id = t.quantity_id
                JOIN graph.utility u    ON u.quantity_category = q.category
                WHERE t.tenant_id = p_tenant_id
                  AND u.code = p_utility_code
                  AND t.bucket >= p_start AND t.bucket <= p_end
                  AND t.quantity_id = ANY (v_src)
                  AND t.aggregated_value IS NOT NULL
                  AND t.aggregated_value <> 'NaN'::NUMERIC
            )
            SELECT r.did, p_quantity_id,
                   (CASE v_rule
                      WHEN 'AVG'   THEN AVG(r.v)
                      WHEN 'LAST'  THEN (array_agg(r.v ORDER BY r.b DESC))[1]
                      WHEN 'P95'   THEN (percentile_cont(0.95)
                                         WITHIN GROUP (ORDER BY r.v))::NUMERIC
                      ELSE              SUM(r.v)
                    END)::NUMERIC
            FROM raw r GROUP BY r.did;
        END IF;
    END IF;
END;
$$;

-- ============================================================================
-- The flow solver -- bounded fixed point, four rules (§5.3)
-- ============================================================================
CREATE OR REPLACE FUNCTION graph.solve_flow(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_quantity_id   INTEGER,
    p_is_cost       BOOLEAN   DEFAULT FALSE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3'],
    p_as_of         DATE      DEFAULT CURRENT_DATE,
    p_max_iter      INTEGER   DEFAULT 50
) RETURNS VOID
LANGUAGE plpgsql VOLATILE AS $$
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

        -- (b) split a known node value across its still-unknown in-edges
        WITH t AS (
            SELECT g.to_node_id AS nid,
                   COALESCE(SUM(g.value), 0)               AS known_sum,
                   COUNT(*) FILTER (WHERE g.value IS NULL) AS n_unknown
            FROM _ge g GROUP BY g.to_node_id
        ), upd AS (
            UPDATE _ge g SET value = (n.value - t.known_sum) / t.n_unknown,
                             amb   = (t.n_unknown > 1)
            FROM t JOIN _gn n ON n.id = t.nid
            WHERE g.to_node_id = t.nid AND g.value IS NULL
              AND n.value IS NOT NULL AND t.n_unknown > 0
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
$$;

-- ============================================================================
-- The two flow entry points (§5.4)
-- ============================================================================
CREATE OR REPLACE FUNCTION graph.get_node_values(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_quantity_id   INTEGER,
    p_is_cost       BOOLEAN   DEFAULT FALSE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3'],
    p_as_of         DATE      DEFAULT CURRENT_DATE
) RETURNS TABLE (
    node_id BIGINT, node_code VARCHAR, node_name VARCHAR, node_class VARCHAR,
    measured NUMERIC, value NUMERIC, unaccounted NUMERIC,
    origin VARCHAR, has_data BOOLEAN)
LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    PERFORM graph.solve_flow(p_tenant_id, p_utility_code, p_start, p_end,
                             p_quantity_id, p_is_cost, p_shift_periods, p_as_of);
    RETURN QUERY
    SELECT n.id, n.node_code, n.node_name, n.node_class, n.measured, n.value,
           CASE WHEN n.val_src IN ('MEASURED','IN_EDGES')
                 AND o.out_sum IS NOT NULL AND n.value - o.out_sum > 0
                THEN n.value - o.out_sum END,
           n.val_src, n.has_data
    FROM _gn n
    LEFT JOIN (SELECT g.from_node_id AS nid, SUM(g.value) AS out_sum
               FROM _ge g GROUP BY g.from_node_id) o ON o.nid = n.id;
END;
$$;

CREATE OR REPLACE FUNCTION graph.get_sankey_flow(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_quantity_id   INTEGER,
    p_is_cost       BOOLEAN   DEFAULT FALSE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3'],
    p_as_of         DATE      DEFAULT CURRENT_DATE,
    p_unaccounted_threshold NUMERIC DEFAULT 0
) RETURNS TABLE (
    source TEXT, target TEXT, value NUMERIC,
    is_ambiguous BOOLEAN, is_unaccounted BOOLEAN)
LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    PERFORM graph.solve_flow(p_tenant_id, p_utility_code, p_start, p_end,
                             p_quantity_id, p_is_cost, p_shift_periods, p_as_of);
    RETURN QUERY
    SELECT sn.node_name::TEXT, tn.node_name::TEXT, g.value, g.amb, FALSE
    FROM _ge g JOIN _gn sn ON sn.id = g.from_node_id JOIN _gn tn ON tn.id = g.to_node_id
    WHERE g.value > 0
    UNION ALL
    SELECT n.node_name::TEXT, (n.node_code || '__UNACCOUNTED')::TEXT,
           n.value - o.out_sum, FALSE, TRUE
    FROM _gn n
    JOIN (SELECT g.from_node_id AS nid, SUM(g.value) AS out_sum
          FROM _ge g GROUP BY g.from_node_id) o ON o.nid = n.id
    WHERE n.val_src IN ('MEASURED','IN_EDGES')
      AND n.value - o.out_sum > p_unaccounted_threshold;
END;
$$;

-- ============================================================================
-- Non-flow quantities: power quality never sums across a network (§11)
-- ============================================================================
CREATE OR REPLACE FUNCTION graph.get_node_quantity(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_quantity_id   INTEGER,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_as_of         DATE      DEFAULT CURRENT_DATE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3'],
    p_max_iter      INTEGER   DEFAULT 50
) RETURNS TABLE (
    node_id BIGINT, node_code VARCHAR, node_name VARCHAR,
    val NUMERIC, origin VARCHAR)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_agg       VARCHAR;
    v_conserved BOOLEAN;
    v_iter      INTEGER;
    v_changed   INTEGER;
BEGIN
    SELECT qr.network_agg, qr.conserved INTO v_agg, v_conserved
    FROM graph.quantity_rule qr WHERE qr.quantity_id = p_quantity_id;

    IF v_agg IS NULL THEN
        RAISE EXCEPTION 'graph.get_node_quantity: quantity % has no row in graph.quantity_rule', p_quantity_id;
    END IF;

    IF v_conserved THEN     -- delegate: flow balance is strictly better than a rollup
        PERFORM graph.solve_flow(p_tenant_id, p_utility_code, p_start, p_end,
                                 p_quantity_id, FALSE, p_shift_periods, p_as_of);
        RETURN QUERY
        SELECT n.id, n.node_code, n.node_name, n.value,
               (CASE WHEN n.measured IS NOT NULL THEN 'MEASURED'
                     WHEN n.has_data              THEN 'ROLLUP'
                     ELSE 'NONE' END)::VARCHAR
        FROM _gn n;
        RETURN;
    END IF;

    DROP TABLE IF EXISTS _qe, _qn;

    CREATE TEMP TABLE _qe ON COMMIT DROP AS
    SELECT e.from_node_id, e.to_node_id FROM graph.edge e
    WHERE e.tenant_id = p_tenant_id AND e.is_active AND e.utility_code = p_utility_code
      AND e.effective_from <= p_as_of AND (e.effective_to IS NULL OR e.effective_to >= p_as_of);

    CREATE TEMP TABLE _qn ON COMMIT DROP AS
    SELECT n.id, n.node_code AS ncode, n.node_name AS nname,
           nm.total AS meas, nm.total AS val,
           (CASE WHEN nm.total IS NOT NULL THEN 'MEASURED' ELSE NULL END)::VARCHAR AS org
    FROM graph.node n
    LEFT JOIN (
        SELECT ms.node_id AS nid, AVG(dt.total * ms.multiplier) AS total
        FROM graph.measurement ms
        JOIN graph.device_totals(p_tenant_id, p_utility_code, p_start, p_end,
                                 p_quantity_id, FALSE, p_shift_periods) dt
          ON dt.device_id = ms.device_id AND dt.quantity_id = ms.quantity_id
        WHERE ms.node_id IS NOT NULL AND ms.is_active AND ms.role = 'TOTAL'
          AND ms.utility_code = p_utility_code
          AND ms.effective_from <= p_as_of
          AND (ms.effective_to IS NULL OR ms.effective_to >= p_as_of)
        GROUP BY ms.node_id
    ) nm ON nm.nid = n.id
    WHERE n.tenant_id = p_tenant_id AND n.is_active
      AND n.effective_from <= p_as_of AND (n.effective_to IS NULL OR n.effective_to >= p_as_of)
      AND EXISTS (SELECT 1 FROM _qe g WHERE g.from_node_id = n.id OR g.to_node_id = n.id);

    IF v_agg IN ('SUM','RSS') THEN
        FOR v_iter IN 1..p_max_iter LOOP
            WITH s AS (
                SELECT g.from_node_id AS nid,
                       SUM(c.val)                  AS sum_v,
                       sqrt(SUM(c.val * c.val))    AS rss_v,
                       COUNT(*) FILTER (WHERE c.val IS NULL) AS unk
                FROM _qe g JOIN _qn c ON c.id = g.to_node_id
                GROUP BY g.from_node_id
            ), upd AS (
                UPDATE _qn n
                   SET val = (CASE WHEN v_agg = 'RSS' THEN s.rss_v ELSE s.sum_v END),
                       org = 'ROLLUP'
                FROM s WHERE n.id = s.nid AND n.val IS NULL AND s.unk = 0
                RETURNING 1
            ) SELECT COUNT(*) INTO v_changed FROM upd;
            EXIT WHEN v_changed = 0;
        END LOOP;

    ELSIF v_agg = 'INHERIT' THEN
        FOR v_iter IN 1..p_max_iter LOOP
            -- strict: every feeder resolved
            WITH s AS (
                SELECT g.to_node_id AS nid, MAX(p.val) AS mx,
                       COUNT(*) FILTER (WHERE p.val IS NULL) AS unk
                FROM _qe g JOIN _qn p ON p.id = g.from_node_id
                GROUP BY g.to_node_id
            ), upd AS (
                UPDATE _qn n SET val = s.mx, org = 'INHERITED'
                FROM s WHERE n.id = s.nid AND n.val IS NULL AND s.unk = 0 AND s.mx IS NOT NULL
                RETURNING 1
            ) SELECT COUNT(*) INTO v_changed FROM upd;

            IF v_changed = 0 THEN
                -- relaxed: accept the worst known feeder
                WITH s AS (
                    SELECT g.to_node_id AS nid, MAX(p.val) AS mx
                    FROM _qe g JOIN _qn p ON p.id = g.from_node_id
                    GROUP BY g.to_node_id
                ), upd AS (
                    UPDATE _qn n SET val = s.mx, org = 'INHERITED'
                    FROM s WHERE n.id = s.nid AND n.val IS NULL AND s.mx IS NOT NULL
                    RETURNING 1
                ) SELECT COUNT(*) INTO v_changed FROM upd;
                EXIT WHEN v_changed = 0;
            END IF;
        END LOOP;
    END IF;   -- 'NONE': measured only, no propagation

    RETURN QUERY
    SELECT q.id, q.ncode, q.nname, q.val, COALESCE(q.org, 'NONE')::VARCHAR FROM _qn q;
END;
$$;

CREATE OR REPLACE FUNCTION graph.get_node_derived(
    p_tenant_id     INTEGER,
    p_code          VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_as_of         DATE      DEFAULT CURRENT_DATE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3']
) RETURNS TABLE (
    node_id BIGINT, node_code VARCHAR, node_name VARCHAR,
    p_val NUMERIC, q_val NUMERIC, val NUMERIC)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_util VARCHAR; v_p INTEGER; v_q INTEGER; v_formula VARCHAR;
BEGIN
    SELECT dq.utility_code, dq.p_quantity_id, dq.q_quantity_id, dq.formula
      INTO v_util, v_p, v_q, v_formula
    FROM graph.derived_quantity dq WHERE dq.code = p_code;

    IF v_util IS NULL THEN
        RAISE EXCEPTION 'graph.get_node_derived: no derived quantity %', p_code;
    END IF;

    PERFORM graph.solve_flow(p_tenant_id, v_util, p_start, p_end, v_p,
                             FALSE, p_shift_periods, p_as_of);
    DROP TABLE IF EXISTS _dq;
    CREATE TEMP TABLE _dq ON COMMIT DROP AS
    SELECT g.id, g.node_code AS ncode, g.node_name AS nname,
           (CASE WHEN g.has_data THEN g.value END) AS pv, NULL::NUMERIC AS qv
    FROM _gn g;

    PERFORM graph.solve_flow(p_tenant_id, v_util, p_start, p_end, v_q,
                             FALSE, p_shift_periods, p_as_of);
    UPDATE _dq d SET qv = (CASE WHEN g.has_data THEN g.value END) FROM _gn g WHERE g.id = d.id;

    RETURN QUERY
    SELECT d.id, d.ncode, d.nname, d.pv, d.qv,
           CASE WHEN d.pv IS NULL OR d.qv IS NULL THEN NULL
                WHEN d.pv = 0 AND d.qv = 0        THEN NULL
                ELSE round(d.pv / sqrt(d.pv*d.pv + d.qv*d.qv), 4) END
    FROM _dq d;
END;
$$;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
-- SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'graph' ORDER BY 1;   -- expect 9
