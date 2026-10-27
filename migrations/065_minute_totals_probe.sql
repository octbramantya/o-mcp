-- Migration: 065_minute_totals_probe.sql
-- Description: graph.device_totals_minute checks that the minute data reaches back to the window
--              with one index probe in place of min(timestamp) over telemetry_data, which the
--              tenants' roles read as a full scan of every chunk.
-- Author: Claude
-- Date: 2026-10-27
-- Design: design/frontend.md §3 ("The solver on minute data"); design/frontend-review.md §6
-- Requires: 060_minute_device_totals.sql; superuser (it reads public.telemetry_data)
--
-- WHY
-- ---
-- 060's device_totals_minute refuses a window that starts before the tenant's oldest minute
-- reading, found with SELECT min("timestamp") FROM telemetry_data WHERE tenant_id = ... . The
-- function runs as its caller, so for prs_frontend and prs_hermes_agent telemetry_data is
-- prs.telemetry_data, a security_barrier view (060). The planner keeps the view as a subquery and
-- can't take the minimum from an index: on production (2026-10-27) the plan is a parallel
-- sequential scan of all 15 chunks, about 74 M rows, and EXPLAIN ANALYZE as prs_frontend was
-- cancelled at 25 s. Every minute-resolution solve calls the function once per rule and piece, so
-- the frontend's short windows (6 hours or less) and the agent's could not be answered. The API's
-- own copy of the check (api/values.py) failed first, with the same query, and was changed with
-- this migration.
--
-- THE CHANGE
-- ----------
-- "p_start >= the oldest reading" is "a reading exists at or before p_start". Asked that way the
-- planner excludes the chunks after p_start and reads one entry of idx_telemetry_tenant_time:
-- 0.05 ms on production through the view, for a start an hour ago, 13½ days ago, and before
-- retention (no chunk left, no row). The refusal's message no longer names the oldest reading,
-- which it would take the scan to find. Nothing else in the function changes; CREATE OR REPLACE
-- keeps its comment and grants.
--
-- CHECKS
-- ------
-- Before replacing: the function is 060's (it holds the min() check). After: every quantity
-- rule's totals over one 6-hour window inside the minute data are the same rows as before, a
-- window starting in 2000 is still refused, and the min() is gone.

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF position('min(t."timestamp")' IN pg_get_functiondef(
            'graph.device_totals_minute(integer, varchar, timestamp, timestamp, integer, boolean, varchar[])'::regprocedure)) = 0 THEN
        RAISE EXCEPTION '065: graph.device_totals_minute is not 060''s (no min() check); not replaced';
    END IF;
END $$;

-- the window: the 6 hours before the last whole hour of tenant 3's minute data
CREATE TEMP TABLE w065 ON COMMIT DROP AS
SELECT date_trunc('hour', hi) - INTERVAL '6 hours' AS s, date_trunc('hour', hi) - INTERVAL '1 minute' AS e
FROM (SELECT max("timestamp") AS hi FROM public.telemetry_data WHERE tenant_id = 3) t;

DO $$
BEGIN
    IF (SELECT s FROM w065) IS NULL THEN
        RAISE EXCEPTION '065: tenant 3 has no minute reading; nothing to compare';
    END IF;
END $$;

CREATE TEMP TABLE before065 ON COMMIT DROP AS
SELECT qr.quantity_id AS qid, m.device_id, m.total
FROM graph.quantity_rule qr, w065,
     LATERAL graph.device_totals_minute(3, qr.utility_code, w065.s, w065.e, qr.quantity_id) m;

CREATE OR REPLACE FUNCTION graph.device_totals_minute(
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
    -- minute data is kept for a while only (14 days on production): refuse, never answer empty.
    -- A reading at or before p_start is p_start >= the oldest reading, from one index entry (065)
    IF NOT EXISTS (SELECT 1 FROM telemetry_data t WHERE t.tenant_id = p_tenant_id AND t."timestamp" <= p_start) THEN
        RAISE EXCEPTION 'graph.device_totals_minute: tenant % has no minute reading at or before %; read 15-minute '
                        'buckets (graph.resolution = ''15min'')', p_tenant_id, p_start;
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

DO $$
DECLARE
    n_before INTEGER;
    n_diff   INTEGER;
    refused  BOOLEAN := FALSE;
BEGIN
    SELECT count(*) INTO n_before FROM before065;
    WITH after AS (
        SELECT qr.quantity_id AS qid, m.device_id, m.total
        FROM graph.quantity_rule qr, w065,
             LATERAL graph.device_totals_minute(3, qr.utility_code, w065.s, w065.e, qr.quantity_id) m
    )
    SELECT count(*) INTO n_diff FROM (
        (SELECT * FROM after EXCEPT ALL SELECT * FROM before065)
        UNION ALL
        (SELECT * FROM before065 EXCEPT ALL SELECT * FROM after)) x;
    IF n_diff <> 0 THEN
        RAISE EXCEPTION '065: % rows differ from before over %', n_diff, (SELECT s || ' to ' || e FROM w065);
    END IF;
    IF n_before = 0 THEN
        RAISE EXCEPTION '065: no totals over %; nothing compared', (SELECT s || ' to ' || e FROM w065);
    END IF;
    RAISE NOTICE '065: % device totals over % unchanged', n_before, (SELECT s || ' to ' || e FROM w065);

    BEGIN
        PERFORM graph.device_totals_minute(3, 'ELECTRICITY', '2000-01-01 00:00', '2000-01-01 05:59',
                                           (SELECT min(quantity_id) FROM graph.quantity_rule WHERE utility_code = 'ELECTRICITY'));
    EXCEPTION WHEN raise_exception THEN
        refused := SQLERRM LIKE '%no minute reading at or before%';
    END;
    IF NOT refused THEN
        RAISE EXCEPTION '065: a window in 2000 was not refused';
    END IF;

    IF position('min(t."timestamp")' IN pg_get_functiondef(
            'graph.device_totals_minute(integer, varchar, timestamp, timestamp, integer, boolean, varchar[])'::regprocedure)) > 0 THEN
        RAISE EXCEPTION '065: the min() check is still there';
    END IF;
END $$;

COMMIT;

-- ROLLBACK: re-run 060's CREATE FUNCTION graph.device_totals_minute as CREATE OR REPLACE.
