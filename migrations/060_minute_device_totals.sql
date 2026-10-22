-- Migration: 060_minute_device_totals.sql
-- Description: Short windows for the solver: tenant 3's view of telemetry_data,
--              graph.device_totals_minute (minute data, the last 14 days), and
--              graph.device_totals_15min (electricity energy from 15-minute buckets), which
--              graph.device_totals hands a window when the caller asks for that resolution.
-- Author: Claude
-- Date: 2026-10-22
-- Design: design/frontend.md §3 ("The solver on minute data"), §1 decisions 9 and 18
-- Requires: 059_change_dates.sql; superuser (it creates a view in prs and verifies as the role)
--
-- WHY
-- ---
-- The frontend reads ranges of 6 hours or less at minute resolution (decision 9), and its value
-- widgets go through the solver, which reads 15-minute buckets and daily summaries only: an
-- unmetered node would have no minute values. Decided 2026-10-22: a minute counterpart of
-- graph.device_totals, not the solver reading telemetry_data itself, so graph.solve_flow,
-- graph.sankey and the get_node_* functions change resolution without being edited.
--
-- THE SWITCH
-- ----------
-- design/frontend.md §3 had device_totals route by window length. It can't: its callers pass
-- bounds whose meaning depends on the source (node_value reads one site day of the daily summary
-- as p_start = p_end, a zero-length "window"). So the caller asks, for its transaction:
--
--   SET LOCAL graph.resolution = 'minute';
--   SELECT * FROM graph.get_node_quantity(3, 'ELECTRICITY', 124, '2026-10-21 01:00', '2026-10-21 01:29', ...);
--
-- and every device_totals call in that transaction reads minute data. '15min' reads 15-minute
-- buckets for every quantity, electricity energy included (below). Unset, or anything else,
-- changes nothing: Grafana, the agent and node_value read exactly what they read before. SET LOCAL
-- ends with the transaction, so it is safe under PgBouncer's transaction pooling.
--
-- WHICH RESOLUTION (decided 2026-10-22; design/frontend.md §1, 9)
-- ----------------
--   window <= 6 h, starting within the minute data kept   minutes   ('minute')
--   window <= 6 h, older                                  15-minute ('15min'), electricity energy too
--   longer                                                15-minute, or the daily summary for whole
--                                                         days, as before (unset)
-- The caller (the frontend's API) picks and labels the widget with what it drew; nobody sees a
-- refusal. Production keeps telemetry_data for 14 days (a TimescaleDB retention policy, read
-- 2026-10-22), so a 6-hour window from three weeks ago is drawn from 15-minute buckets.
--
-- device_totals_minute refuses a window that starts before the tenant's oldest reading. Nobody
-- should meet that error: it stands where an empty answer would otherwise go, and an empty answer
-- would make the solver show every node as having no value, silently, if a caller misjudged the
-- cutoff or the retention changed.
--
-- 15-MINUTE ELECTRICITY ENERGY
-- ----------------------------
-- Without a switch, electricity energy comes from daily_energy_cost_summary, which can't answer a
-- window shorter than a day. graph.device_totals_15min sums the same intervals the summary is
-- built from, public.telemetry_intervals_cumulative's, but on telemetry_15min_agg directly with
-- one hour of lookback: that view computes its LAG over the whole table, too slow for a short
-- window (and not a tenant view). Bounds as 017's 15-minute branch: p_end is the last bucket.
--
-- MINUTE BOUNDS
-- -------------
-- p_start and p_end are naive UTC, as telemetry stores time, and p_end names the last minute
-- included: readings with p_start <= timestamp < p_end + 1 minute. A half-open window
-- [10:00, 10:30) is p_start 10:00, p_end 10:29, the same convention as the 15-minute path's
-- "last bucket" (end - 15 min). The window may be at most 6 hours (p_end < p_start + 6 h); a
-- longer one is refused, for every caller, since telemetry_data is the largest table. That is the
-- one place the 6-hour rule is enforced.
--
-- WHAT A WINDOW TOTALS
-- --------------------
-- DELTA registers are summed as forward differences between consecutive readings, with 15
-- minutes of lookback so the first reading in the window has a predecessor. Each difference is
-- cleaned by graph.register_step, which restates the rules of the view the coarse path reads for
-- that register (those views are built on telemetry_15min_agg and can't be pointed at
-- telemetry_data). Both the minute and the 15-minute function use it, so they can't drift apart:
--   electricity  public.telemetry_intervals_cumulative (what daily_energy_cost_summary sums):
--                resets, register corrections, tenfold spikes, negatives and steps over
--                999,999 count as zero. The ceiling is per interval; per minute it is looser
--                than per 15 minutes, which the self-test watches.
--   water        public.telemetry_intervals_water (conserved WATER only, flow meters, as there):
--                an int32 rollover is corrected by 2^32, a step over 10^8 is a reset (zero),
--                and a negative step is kept, as the view keeps it.
--   other        017's DELTA guards (air): negatives and steps over 999,999 count as zero.
-- Canonical registers win over aliases per device, as in the daily branch; NaN is dropped.
-- Other rules (AVG, LAST, P95, SUM) aggregate the readings in the window, as 017 does buckets.
-- Cost (p_is_cost) exists only in the daily summary and is refused; the shift filter doesn't
-- apply to minutes and is ignored.
--
-- TENANT VIEW
-- -----------
-- prs.telemetry_data, a security_barrier view of tenant 3's rows, granted to prs_hermes_agent, as
-- 044 did for the other shared tables; the role's search_path puts prs first, so the function's
-- unqualified telemetry_data reads it. public.telemetry_data stays refused.
--
-- Section 3.3 computes one site day both ways, per device and DELTA register, and lists where the
-- minute total and the existing path disagree by more than 1% (and 1 unit). A disagreement is a
-- finding to read, not a failure: the migration doesn't abort on it. Without minute data for a
-- whole site day (tools/dev_refresh.sh --raw), the comparison says so and is skipped.
-- Section 3.4 does the same for the 15-minute electricity route against the daily summary.
--
-- FLAT REGISTERS
-- --------------
-- A device that reports all window but whose register doesn't move totals 0 here. The daily
-- summary leaves such device-days out (it holds no zero rows), so over whole days the same device
-- has no row and the solver treats it as unmeasured, while 017's 15-minute branch gives 0 too.
-- Decided 2026-10-22: the minute path keeps the 0, so a stopped machine reads as measured zero,
-- not as a node to work out from its neighbours. The comparison counts these apart from the
-- disagreements. On dev, 2026-10-21: 458 device registers, 284 agreeing within 1%, the other 174
-- all flat; none differed on a non-zero amount.
-- Dev's telemetry_data has no indexes (no TimescaleDB); read production's before timing.

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'graph'::regnamespace
               AND proname = 'device_totals_minute') THEN
        RAISE EXCEPTION '060: graph.device_totals_minute already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'graph'::regnamespace
               AND proname IN ('device_totals_15min', 'register_step')) THEN
        RAISE EXCEPTION '060: graph.device_totals_15min or graph.register_step already exists';
    END IF;
    IF to_regclass('prs.telemetry_data') IS NOT NULL THEN
        RAISE EXCEPTION '060: prs.telemetry_data already exists';
    END IF;
    IF (SELECT count(*) FROM graph.quantity_rule) <> 10 THEN
        RAISE EXCEPTION '060: expected the 10 quantity rules of 2026-10-22; read the routing below against the rules first';
    END IF;
END
$$;

-- ============================================================================
-- 1. Tenant 3's view of telemetry_data
-- ============================================================================

CREATE VIEW prs.telemetry_data WITH (security_barrier) AS
    SELECT * FROM public.telemetry_data WHERE tenant_id = 3;
COMMENT ON VIEW prs.telemetry_data IS
    'Tenant 3''s rows, for prs_hermes_agent (060). Read windows of 6 hours or less; '
    'graph.device_totals_minute refuses longer ones.';
GRANT SELECT ON prs.telemetry_data TO prs_hermes_agent;

-- ============================================================================
-- 2. graph.register_step, graph.device_totals_minute, graph.device_totals_15min, and the switch
--    in graph.device_totals
-- ============================================================================

CREATE FUNCTION graph.register_step(p_utility_code VARCHAR, p_conserved BOOLEAN, p_prev NUMERIC, p_cur NUMERIC)
RETURNS NUMERIC
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
      WHEN p_prev IS NULL THEN 0
      WHEN p_utility_code = 'ELECTRICITY' THEN
        -- public.telemetry_intervals_cumulative's interval_value
        CASE
          WHEN (p_cur < 0 AND abs(p_cur) < 1e-20) OR (p_prev < 0 AND abs(p_prev) < 1e-20)
            OR p_cur = 0
            OR (p_prev < 1 AND p_cur > 1000)
            OR (p_prev > 0 AND p_prev < 100 AND p_cur > 10000)
            OR (p_prev > 100 AND p_cur < p_prev * 0.5)
            OR (p_prev > 1000 AND p_cur < 100)      THEN 0   -- reset, register correction
          WHEN p_prev > 100 AND p_cur > p_prev * 10 THEN 0   -- unrealistic spike
          WHEN p_cur - p_prev < 0                   THEN 0
          WHEN p_cur - p_prev > 999999              THEN 0
          ELSE p_cur - p_prev
        END
      WHEN p_utility_code = 'WATER' AND p_conserved THEN
        -- public.telemetry_intervals_water's interval_m3, valid intervals only
        CASE
          WHEN abs(p_prev) > 2000000000 AND abs(p_cur) > 2000000000
               AND sign(p_prev) <> sign(p_cur)      THEN p_cur - p_prev + 4294967296
          WHEN abs(p_cur - p_prev) > 100000000      THEN 0   -- counter reset
          ELSE p_cur - p_prev
        END
      ELSE
        -- 017's DELTA guards
        CASE
          WHEN p_cur - p_prev < 0                   THEN 0
          WHEN p_cur - p_prev > 999999              THEN 0
          ELSE p_cur - p_prev
        END
    END
$$;

COMMENT ON FUNCTION graph.register_step(VARCHAR, BOOLEAN, NUMERIC, NUMERIC) IS
    'One cleaned step of a cumulative register, prev to cur, by the rules of the view the coarse path '
    'reads: telemetry_intervals_cumulative (electricity), telemetry_intervals_water (conserved water), '
    '017''s guards (else). Shared by device_totals_minute and device_totals_15min (060).';


CREATE FUNCTION graph.device_totals_minute(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_quantity_id   INTEGER,
    p_is_cost       BOOLEAN   DEFAULT FALSE,
    p_shift_periods VARCHAR[] DEFAULT NULL
) RETURNS TABLE (device_id INTEGER, quantity_id INTEGER, total NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_src       INTEGER[];
    v_rule      VARCHAR;
    v_conserved BOOLEAN;
    v_first     TIMESTAMP;
BEGIN
    IF p_quantity_id IS NULL THEN
        RAISE EXCEPTION 'graph.device_totals_minute: p_quantity_id is required';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.quantity_alias a WHERE a.quantity_id = p_quantity_id) THEN
        RAISE EXCEPTION 'graph.device_totals_minute: quantity % is a register alias; pass its canonical id', p_quantity_id;
    END IF;
    IF p_is_cost THEN
        RAISE EXCEPTION 'graph.device_totals_minute: cost exists only in daily_energy_cost_summary, per day and shift; '
                        'it is not estimated for minutes';
    END IF;
    IF p_end < p_start THEN
        RAISE EXCEPTION 'graph.device_totals_minute: p_end (%) is before p_start (%)', p_end, p_start;
    END IF;
    IF p_end >= p_start + INTERVAL '6 hours' THEN
        RAISE EXCEPTION 'graph.device_totals_minute: % to % is longer than 6 hours; read the 15-minute aggregate',
                        p_start, p_end;
    END IF;
    -- minute data is kept for a while only (14 days on production): refuse, never answer empty
    SELECT min(t."timestamp") INTO v_first FROM telemetry_data t WHERE t.tenant_id = p_tenant_id;
    IF v_first IS NULL OR p_start < v_first THEN
        RAISE EXCEPTION 'graph.device_totals_minute: minute data for tenant % starts at %, after %; read 15-minute '
                        'buckets (graph.resolution = ''15min'')', p_tenant_id, coalesce(v_first::text, 'no reading'), p_start;
    END IF;

    SELECT array_agg(s.x) INTO v_src FROM (
        SELECT p_quantity_id AS x
        UNION
        SELECT a.quantity_id FROM graph.quantity_alias a
         WHERE a.canonical_quantity_id = p_quantity_id) s;

    v_conserved := COALESCE((SELECT qr.conserved FROM graph.quantity_rule qr
                              WHERE qr.quantity_id = p_quantity_id), TRUE);
    v_rule := COALESCE((SELECT qr.raw_time_agg FROM graph.quantity_rule qr
                         WHERE qr.quantity_id = p_quantity_id), 'SUM');

    IF v_rule = 'DELTA' THEN
        RETURN QUERY
        WITH raw AS (
            SELECT t.device_id AS did, t.quantity_id AS qsrc, t."timestamp" AS ts, t.value AS v
            FROM telemetry_data t
            JOIN quantities q    ON q.id = t.quantity_id
            JOIN graph.utility u ON u.quantity_category = q.category
            WHERE t.tenant_id = p_tenant_id
              AND u.code = p_utility_code
              AND t."timestamp" >= p_start - INTERVAL '15 minutes'
              AND t."timestamp" <  p_end + INTERVAL '1 minute'
              AND t.quantity_id = ANY (v_src)
              AND t.value IS NOT NULL
              AND t.value <> 'NaN'::NUMERIC
              -- water: flow meters only, as public.telemetry_intervals_water
              AND (p_utility_code <> 'WATER' OR NOT v_conserved
                   OR t.device_id IN (SELECT d.id FROM devices d WHERE d.device_type = 'Flow Meter'))
        ), pref AS (          -- canonical register wins; alias only if canonical absent
            SELECT DISTINCT ON (r.did) r.did, r.qsrc
            FROM raw r ORDER BY r.did, (r.qsrc <> p_quantity_id)
        ), pairs AS (
            SELECT r.did, r.ts, r.v AS cur,
                   LAG(r.v) OVER (PARTITION BY r.did ORDER BY r.ts) AS prev
            FROM raw r JOIN pref p ON p.did = r.did AND p.qsrc = r.qsrc
        ), steps AS (
            SELECT x.did, x.ts, graph.register_step(p_utility_code, v_conserved, x.prev, x.cur) AS d
            FROM pairs x
        )
        SELECT s.did, p_quantity_id, COALESCE(SUM(s.d), 0)::NUMERIC
        FROM steps s
        WHERE s.ts >= p_start AND s.ts < p_end + INTERVAL '1 minute'
        GROUP BY s.did;

    ELSE
        RETURN QUERY
        WITH raw AS (
            SELECT t.device_id AS did, t.quantity_id AS qsrc, t."timestamp" AS ts, t.value AS v
            FROM telemetry_data t
            JOIN quantities q    ON q.id = t.quantity_id
            JOIN graph.utility u ON u.quantity_category = q.category
            WHERE t.tenant_id = p_tenant_id
              AND u.code = p_utility_code
              AND t."timestamp" >= p_start
              AND t."timestamp" <  p_end + INTERVAL '1 minute'
              AND t.quantity_id = ANY (v_src)
              AND t.value IS NOT NULL
              AND t.value <> 'NaN'::NUMERIC
        ), pref AS (
            SELECT DISTINCT ON (r.did) r.did, r.qsrc
            FROM raw r ORDER BY r.did, (r.qsrc <> p_quantity_id)
        )
        SELECT r.did, p_quantity_id,
               (CASE v_rule
                  WHEN 'AVG'  THEN AVG(r.v)
                  WHEN 'LAST' THEN (array_agg(r.v ORDER BY r.ts DESC))[1]
                  WHEN 'P95'  THEN (percentile_cont(0.95) WITHIN GROUP (ORDER BY r.v))::NUMERIC
                  ELSE             SUM(r.v)
                END)::NUMERIC
        FROM raw r JOIN pref p ON p.did = r.did AND p.qsrc = r.qsrc
        GROUP BY r.did;
    END IF;
END;
$$;

COMMENT ON FUNCTION graph.device_totals_minute(INTEGER, VARCHAR, TIMESTAMP, TIMESTAMP, INTEGER, BOOLEAN, VARCHAR[]) IS
    'graph.device_totals on telemetry_data: windows of at most 6 hours, p_end the last minute included, '
    'naive UTC; no cost, no shifts. Reached through device_totals when graph.resolution = ''minute'' (060).';

GRANT EXECUTE ON FUNCTION graph.device_totals_minute(INTEGER, VARCHAR, TIMESTAMP, TIMESTAMP, INTEGER, BOOLEAN, VARCHAR[])
    TO "grafReader", prs_hermes_agent;

CREATE FUNCTION graph.device_totals_15min(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_quantity_id   INTEGER,
    p_is_cost       BOOLEAN   DEFAULT FALSE,
    p_shift_periods VARCHAR[] DEFAULT NULL
) RETURNS TABLE (device_id INTEGER, quantity_id INTEGER, total NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_src INTEGER[];
BEGIN
    IF p_quantity_id IS NULL THEN
        RAISE EXCEPTION 'graph.device_totals_15min: p_quantity_id is required';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.quantity_alias a WHERE a.quantity_id = p_quantity_id) THEN
        RAISE EXCEPTION 'graph.device_totals_15min: quantity % is a register alias; pass its canonical id', p_quantity_id;
    END IF;
    IF p_utility_code <> 'ELECTRICITY'
       OR NOT COALESCE((SELECT qr.conserved FROM graph.quantity_rule qr WHERE qr.quantity_id = p_quantity_id), TRUE) THEN
        RAISE EXCEPTION 'graph.device_totals_15min: electricity energy only; % % already reads 15-minute buckets '
                        'in graph.device_totals', p_utility_code, p_quantity_id;
    END IF;
    IF p_is_cost THEN
        RAISE EXCEPTION 'graph.device_totals_15min: cost exists only in daily_energy_cost_summary, per day and shift; '
                        'it is not estimated for shorter windows';
    END IF;
    IF p_end < p_start THEN
        RAISE EXCEPTION 'graph.device_totals_15min: p_end (%) is before p_start (%)', p_end, p_start;
    END IF;

    SELECT array_agg(s.x) INTO v_src FROM (
        SELECT p_quantity_id AS x
        UNION
        SELECT a.quantity_id FROM graph.quantity_alias a
         WHERE a.canonical_quantity_id = p_quantity_id) s;

    RETURN QUERY
    WITH raw AS (
        SELECT t.device_id AS did, t.quantity_id AS qsrc, t.bucket AS b, t.aggregated_value AS v
        FROM telemetry_15min_agg t
        WHERE t.tenant_id = p_tenant_id
          AND t.bucket >= p_start - INTERVAL '1 hour'
          AND t.bucket <= p_end
          AND t.quantity_id = ANY (v_src)
          AND t.aggregated_value IS NOT NULL
          AND t.aggregated_value <> 'NaN'::NUMERIC
    ), pref AS (          -- canonical register wins; alias only if canonical absent
        SELECT DISTINCT ON (r.did) r.did, r.qsrc
        FROM raw r ORDER BY r.did, (r.qsrc <> p_quantity_id)
    ), pairs AS (
        SELECT r.did, r.b, r.v AS cur,
               LAG(r.v) OVER (PARTITION BY r.did ORDER BY r.b) AS prev
        FROM raw r JOIN pref p ON p.did = r.did AND p.qsrc = r.qsrc
    )
    SELECT x.did, p_quantity_id,
           COALESCE(SUM(graph.register_step('ELECTRICITY', TRUE, x.prev, x.cur)), 0)::NUMERIC
    FROM pairs x
    WHERE x.b >= p_start AND x.b <= p_end
    GROUP BY x.did;
END;
$$;

COMMENT ON FUNCTION graph.device_totals_15min(INTEGER, VARCHAR, TIMESTAMP, TIMESTAMP, INTEGER, BOOLEAN, VARCHAR[]) IS
    'Electricity energy per device from 15-minute buckets, for windows the daily summary can''t answer: '
    'naive UTC, p_end the last bucket; no cost, no shifts. Reached through device_totals when '
    'graph.resolution = ''15min'' (060).';

GRANT EXECUTE ON FUNCTION graph.device_totals_15min(INTEGER, VARCHAR, TIMESTAMP, TIMESTAMP, INTEGER, BOOLEAN, VARCHAR[]),
                          graph.register_step(VARCHAR, BOOLEAN, NUMERIC, NUMERIC)
    TO "grafReader", prs_hermes_agent;

-- graph.device_totals: 017's body unchanged, with the switch at the top.
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
    -- 060: a caller that set graph.resolution for its transaction gets that resolution: 'minute'
    -- minute data; '15min' 15-minute buckets, electricity energy included, which otherwise comes
    -- from the daily summary. The switch is explicit because the bounds callers pass differ by
    -- source (a one-day read of the daily summary is p_start = p_end), and a window's length
    -- can't tell them apart.
    IF current_setting('graph.resolution', true) = 'minute' THEN
        RETURN QUERY SELECT * FROM graph.device_totals_minute(p_tenant_id, p_utility_code, p_start, p_end,
                                                               p_quantity_id, p_is_cost, p_shift_periods);
        RETURN;
    END IF;
    IF current_setting('graph.resolution', true) = '15min' AND p_utility_code = 'ELECTRICITY'
       AND COALESCE((SELECT qr.conserved FROM graph.quantity_rule qr WHERE qr.quantity_id = p_quantity_id), TRUE) THEN
        RETURN QUERY SELECT * FROM graph.device_totals_15min(p_tenant_id, p_utility_code, p_start, p_end,
                                                              p_quantity_id, p_is_cost, p_shift_periods);
        RETURN;
    END IF;

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
-- 3. Checks
-- ============================================================================

-- 3.1 the switch: unset reads as before; 'minute' is device_totals_minute, refusing long windows,
--     cost and windows older than the minute data; '15min' is device_totals_15min for electricity
--     energy. Dates come from whatever the database holds.
DO $$
DECLARE
    a TEXT;
    b TEXT;
    d TIMESTAMP;
    e TIMESTAMP;
BEGIN
    SELECT max(daily_bucket)::date::timestamp INTO d FROM daily_energy_cost_summary WHERE tenant_id = 3;
    IF d IS NULL THEN
        RAISE EXCEPTION '060 check: daily_energy_cost_summary has no tenant 3 rows';
    END IF;
    PERFORM set_config('graph.resolution', '', true);
    SELECT md5(string_agg(t::text, ',' ORDER BY t.device_id)) INTO a
    FROM graph.device_totals(3, 'ELECTRICITY', d, d, 124) t;
    IF a IS NULL THEN
        RAISE EXCEPTION '060 check: device_totals unset returned nothing for % from the daily summary', d::date;
    END IF;

    -- minutes, on the last 6 hours of minute data the database holds
    PERFORM set_config('graph.resolution', 'minute', true);
    SELECT date_trunc('minute', max("timestamp")) INTO e FROM public.telemetry_data WHERE tenant_id = 3;
    IF e IS NULL THEN
        RAISE NOTICE '060 check: no telemetry_data; the minute path is checked for its refusal only';
    ELSE
        SELECT md5(string_agg(t::text, ',' ORDER BY t.device_id)) INTO a
        FROM graph.device_totals(3, 'ELECTRICITY', e - INTERVAL '5 hours 59 minutes', e, 124) t;
        SELECT md5(string_agg(t::text, ',' ORDER BY t.device_id)) INTO b
        FROM graph.device_totals_minute(3, 'ELECTRICITY', e - INTERVAL '5 hours 59 minutes', e, 124) t;
        IF a IS NULL OR a IS DISTINCT FROM b THEN
            RAISE EXCEPTION '060 check: with graph.resolution = minute, device_totals differs from device_totals_minute';
        END IF;
        BEGIN
            PERFORM * FROM graph.device_totals(3, 'ELECTRICITY', e - INTERVAL '6 hours', e, 124);
            RAISE EXCEPTION '060 check: a 6-hour-and-one-minute window was not refused';
        EXCEPTION WHEN raise_exception THEN
            IF SQLERRM NOT LIKE '%longer than 6 hours%' THEN RAISE; END IF;
        END;
        BEGIN
            PERFORM * FROM graph.device_totals(3, 'ELECTRICITY', e - INTERVAL '29 minutes', e, 124, TRUE);
            RAISE EXCEPTION '060 check: cost on minutes was not refused';
        EXCEPTION WHEN raise_exception THEN
            IF SQLERRM NOT LIKE '%cost exists only%' THEN RAISE; END IF;
        END;
        PERFORM * FROM graph.get_node_quantity(3, 'ELECTRICITY', 124, e - INTERVAL '29 minutes', e, e::date);
    END IF;
    BEGIN
        PERFORM * FROM graph.device_totals(3, 'ELECTRICITY', '2000-01-01 00:00', '2000-01-01 00:29', 124);
        RAISE EXCEPTION '060 check: a minute window older than the minute data was not refused';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%minute data for tenant 3 starts at%' THEN RAISE; END IF;
    END;

    -- 15 minutes, on the last 6 hours of the daily summary's last day (UTC, buckets)
    PERFORM set_config('graph.resolution', '15min', true);
    e := d + INTERVAL '17 hours' - INTERVAL '15 minutes';      -- the site day's last bucket, in UTC
    SELECT md5(string_agg(t::text, ',' ORDER BY t.device_id)) INTO a
    FROM graph.device_totals(3, 'ELECTRICITY', e - INTERVAL '5 hours 45 minutes', e, 124) t;
    SELECT md5(string_agg(t::text, ',' ORDER BY t.device_id)) INTO b
    FROM graph.device_totals_15min(3, 'ELECTRICITY', e - INTERVAL '5 hours 45 minutes', e, 124) t;
    IF a IS NULL OR a IS DISTINCT FROM b THEN
        RAISE EXCEPTION '060 check: with graph.resolution = 15min, device_totals differs from device_totals_15min';
    END IF;
    BEGIN
        PERFORM * FROM graph.device_totals(3, 'ELECTRICITY', e - INTERVAL '45 minutes', e, 124, TRUE);
        RAISE EXCEPTION '060 check: cost on 15-minute buckets was not refused';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%cost exists only%' THEN RAISE; END IF;
    END;
    -- other quantities read 15-minute buckets as before
    SELECT md5(string_agg(t::text, ',' ORDER BY t.device_id)) INTO a
    FROM graph.device_totals(3, 'ELECTRICITY', e - INTERVAL '5 hours 45 minutes', e, 1119) t;
    PERFORM set_config('graph.resolution', '', true);
    SELECT md5(string_agg(t::text, ',' ORDER BY t.device_id)) INTO b
    FROM graph.device_totals(3, 'ELECTRICITY', e - INTERVAL '5 hours 45 minutes', e, 1119) t;
    IF a IS DISTINCT FROM b THEN
        RAISE EXCEPTION '060 check: graph.resolution = 15min changed THD_VOLTAGE_LN, which already reads 15-minute buckets';
    END IF;
    PERFORM set_config('graph.resolution', '15min', true);
    PERFORM * FROM graph.get_node_quantity(3, 'ELECTRICITY', 124, e - INTERVAL '45 minutes', e, d::date);
    PERFORM set_config('graph.resolution', '', true);
END
$$;

-- 3.2 as the role: the view shows tenant 3 only, the base table stays refused
SET LOCAL ROLE prs_hermes_agent;
SET LOCAL search_path = prs, graph, public;
DO $$
DECLARE
    e TIMESTAMP;
BEGIN
    IF EXISTS (SELECT 1 FROM telemetry_data WHERE tenant_id <> 3
               AND "timestamp" >= now()::timestamp - INTERVAL '1 hour') THEN
        RAISE EXCEPTION '060 check: prs.telemetry_data shows another tenant';
    END IF;
    BEGIN
        PERFORM 1 FROM public.telemetry_data LIMIT 1;
        RAISE EXCEPTION '060 check: public.telemetry_data is readable by prs_hermes_agent';
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    -- the function reads the view through the role's search_path (the solver can't be called
    -- here: 3.1's temporary tables belong to the migration's owner)
    SELECT date_trunc('minute', max("timestamp")) INTO e FROM telemetry_data;
    IF e IS NOT NULL THEN
        PERFORM * FROM graph.device_totals_minute(3, 'ELECTRICITY', e - INTERVAL '29 minutes', e, 124);
    END IF;
END
$$;
RESET ROLE;
RESET search_path;

-- 3.3 one site day both ways (Asia/Jakarta, tenant 3), per device and DELTA register: the minute
--     total in four 6-hour windows against the existing path. Disagreements are listed, not fatal.
DO $$
DECLARE
    d DATE;
    r RECORD;
    n_cmp INTEGER := 0;
    n_off INTEGER := 0;
    n_flat INTEGER := 0;
    u0 TIMESTAMP;
BEGIN
    -- the latest site day in the daily summary that telemetry_data covers from 15 minutes before
    -- its start to its last minute (one scan for the span: dev's copy has no index)
    SELECT max(s.daily_bucket)::date INTO d
    FROM daily_energy_cost_summary s,
         (SELECT min("timestamp") AS lo, max("timestamp") AS hi FROM public.telemetry_data WHERE tenant_id = 3) t
    WHERE s.tenant_id = 3
      AND t.lo <= s.daily_bucket::date - INTERVAL '7 hours' - INTERVAL '15 minutes'
      AND t.hi >= s.daily_bucket::date + INTERVAL '17 hours' - INTERVAL '1 minute';
    IF d IS NULL THEN
        RAISE NOTICE '060 comparison: no site day of tenant 3 is covered by both telemetry_data and the daily summary; not compared';
        RETURN;
    END IF;
    u0 := d::timestamp - INTERVAL '7 hours';          -- the site day's start, in UTC
    FOR r IN
        WITH rules AS (
            SELECT qr.quantity_id AS qid, qr.utility_code AS util, qr.conserved
            FROM graph.quantity_rule qr WHERE qr.raw_time_agg = 'DELTA'
        ), minute AS (
            SELECT ru.qid, m.device_id AS did, sum(m.total) AS total
            FROM rules ru, generate_series(0, 3) k,
                 LATERAL graph.device_totals_minute(3, ru.util, u0 + k * INTERVAL '6 hours',
                                                    u0 + (k + 1) * INTERVAL '6 hours' - INTERVAL '1 minute', ru.qid) m
            GROUP BY 1, 2
        ), coarse AS (
            SELECT ru.qid, c.device_id AS did, c.total
            FROM rules ru,
                 LATERAL graph.device_totals(3, ru.util,
                     CASE WHEN ru.util = 'ELECTRICITY' AND ru.conserved THEN d::timestamp ELSE u0 END,
                     CASE WHEN ru.util = 'ELECTRICITY' AND ru.conserved THEN d::timestamp
                          ELSE u0 + INTERVAL '1 day' - INTERVAL '15 minutes' END,
                     ru.qid, FALSE,
                     (SELECT array_agg(DISTINCT s.shift_period)::varchar[] || '{UNKNOWN}'::varchar[]
                        FROM daily_energy_cost_summary s WHERE s.tenant_id = 3)) c
        )
        SELECT coalesce(m.qid, c.qid) AS qid, coalesce(m.did, c.did) AS did, m.total AS minute, c.total AS coarse
        FROM minute m FULL JOIN coarse c ON c.qid = m.qid AND c.did = m.did
        ORDER BY 1, 2
    LOOP
        n_cmp := n_cmp + 1;
        IF r.minute = 0 AND r.coarse IS NULL THEN
            n_flat := n_flat + 1;          -- a flat register: kept as 0 here, left out of the daily summary
        ELSIF r.minute IS NULL OR r.coarse IS NULL
           OR abs(r.minute - r.coarse) > greatest(1, 0.01 * abs(r.coarse)) THEN
            n_off := n_off + 1;
            RAISE NOTICE '060 comparison %: quantity % device %: minute % against %', d, r.qid, r.did,
                         round(r.minute, 3), round(r.coarse, 3);
        END IF;
    END LOOP;
    RAISE NOTICE '060 comparison %: % device registers, % disagree by more than 1%%, % flat (0 against no row)',
                 d, n_cmp, n_off, n_flat;
END
$$;

-- 3.4 the 15-minute electricity route over one whole site day against the daily summary, per
--     device and energy register. Disagreements are listed, flat registers counted, neither fatal.
DO $$
DECLARE
    d DATE;
    r RECORD;
    n_cmp INTEGER := 0;
    n_off INTEGER := 0;
    n_flat INTEGER := 0;
    u0 TIMESTAMP;
BEGIN
    SELECT max(s.daily_bucket)::date INTO d
    FROM daily_energy_cost_summary s,
         (SELECT min(bucket) AS lo, max(bucket) AS hi FROM public.telemetry_15min_agg WHERE tenant_id = 3) t
    WHERE s.tenant_id = 3
      AND t.lo <= s.daily_bucket::date - INTERVAL '8 hours'
      AND t.hi >= s.daily_bucket::date + INTERVAL '17 hours' - INTERVAL '15 minutes';
    IF d IS NULL THEN
        RAISE NOTICE '060 comparison 15min: no site day covered by both the 15-minute buckets and the daily summary; not compared';
        RETURN;
    END IF;
    u0 := d::timestamp - INTERVAL '7 hours';
    FOR r IN
        WITH rules AS (
            SELECT qr.quantity_id AS qid FROM graph.quantity_rule qr
            WHERE qr.utility_code = 'ELECTRICITY' AND qr.conserved
        ), fine AS (
            SELECT ru.qid, f.device_id AS did, f.total
            FROM rules ru, LATERAL graph.device_totals_15min(3, 'ELECTRICITY', u0,
                                       u0 + INTERVAL '1 day' - INTERVAL '15 minutes', ru.qid) f
        ), daily AS (
            SELECT ru.qid, c.device_id AS did, c.total
            FROM rules ru, LATERAL graph.device_totals(3, 'ELECTRICITY', d::timestamp, d::timestamp, ru.qid, FALSE,
                     (SELECT array_agg(DISTINCT s.shift_period)::varchar[] || '{UNKNOWN}'::varchar[]
                        FROM daily_energy_cost_summary s WHERE s.tenant_id = 3)) c
        )
        SELECT coalesce(f.qid, c.qid) AS qid, coalesce(f.did, c.did) AS did, f.total AS fine, c.total AS daily
        FROM fine f FULL JOIN daily c ON c.qid = f.qid AND c.did = f.did
        ORDER BY 1, 2
    LOOP
        n_cmp := n_cmp + 1;
        IF r.fine = 0 AND r.daily IS NULL THEN
            n_flat := n_flat + 1;
        ELSIF r.fine IS NULL OR r.daily IS NULL
           OR abs(r.fine - r.daily) > greatest(1, 0.01 * abs(r.daily)) THEN
            n_off := n_off + 1;
            RAISE NOTICE '060 comparison 15min %: quantity % device %: 15-minute % against daily %', d, r.qid, r.did,
                         round(r.fine, 3), round(r.daily, 3);
        END IF;
    END LOOP;
    RAISE NOTICE '060 comparison 15min %: % device registers, % disagree by more than 1%%, % flat (0 against no row)',
                 d, n_cmp, n_off, n_flat;
END
$$;

COMMIT;


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- Re-run 017's CREATE OR REPLACE FUNCTION graph.device_totals (the body without the switch), then:
-- DROP FUNCTION graph.device_totals_15min(integer, varchar, timestamp, timestamp, integer, boolean, varchar[]);
-- DROP FUNCTION graph.device_totals_minute(integer, varchar, timestamp, timestamp, integer, boolean, varchar[]);
-- DROP FUNCTION graph.register_step(varchar, boolean, numeric, numeric);
-- DROP VIEW prs.telemetry_data;
