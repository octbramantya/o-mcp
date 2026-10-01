-- Migration: 017_harden_delta_branch.sql
-- Description: Make graph.device_totals survive counter resets and NaN buckets
-- Author: Claude
-- Date: 2026-08-19
-- Phase: 0 -- additive, replaces one function body. No schema change.
--
-- Requires 008 and 009. Signature is unchanged, so this is a CREATE OR REPLACE
-- with no dependent-object churn: nothing has to be dropped and re-granted.
--
-- ---------------------------------------------------------------------------
-- WHY
--
-- graph.device_totals routes conserved quantities to daily_energy_cost_summary
-- (electricity) and telemetry_intervals_water (water). Both of those sit behind
-- views that already handle a cumulative register properly -- forward differences
-- with reset, overflow and spike detection.
--
-- Everything else falls through to the raw branch, which read the 15-minute
-- aggregate directly and collapsed DELTA as MAX(v) - MIN(v). Against tenant 3
-- that is wrong for the two non-conserved DELTA registers, 62 and 481:
--
--   * NaN. NUMERIC sorts NaN ABOVE every real value, so one NaN bucket makes
--     MAX(v) return NaN, the device total NaN, and -- because solve_flow sums
--     children into parents -- every node above it NaN. There is one such
--     bucket live: device 103 "MC 3", 2026-07-28 01:45, on quantities 131
--     and 481.
--
--   * Counter resets. Device 55 "MC 9" resets quantity 481 to zero 391 times
--     in 30 days, largest drop 93,606. MIN then lands after a reset while MAX
--     sits before it, so the window reports a large part of the lifetime
--     counter as consumption. Device 27 "PLTS A" does the same, dropping from
--     1,756,259 to 1.0.
--
-- Both were found by running section 1 of 013 against live on 2026-08-19.
--
-- 009 has been updated to match, so a replay from scratch and 009+017 converge
-- on the same definition.
-- ---------------------------------------------------------------------------

BEGIN;

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

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
-- 1. No NaN can leave the function any more. Expect zero rows.
--
-- SELECT * FROM graph.device_totals(
--            3, 'ELECTRICITY', '2026-07-27'::timestamp, '2026-07-29'::timestamp, 481)
--  WHERE total = 'NaN'::numeric;
--
-- 2. The reset devices should now report a plausible window total rather than a
--    slice of the lifetime counter. Device 55 is the clearest case.
--
-- SELECT * FROM graph.device_totals(
--            3, 'ELECTRICITY', NOW()::timestamp - INTERVAL '1 day', NOW()::timestamp, 481)
--  WHERE device_id IN (55, 27, 103);
--
-- 3. Conserved quantities are untouched -- they never reach this branch.
--    Compare before/after on 124; the numbers must be identical.
