-- Migration: 023_seed_air_quantity_rule.sql
-- Description: First AIR quantity_rule (5932 compressed-air norm volume), its
--              is_cumulative flag, and units for the four compressed-air quantities
-- Author: Claude
-- Date: 2026-09-21
--
-- Why: device 171 AM_RWD (JAEJU flow meter, compressed-air line to MC Rewinding)
-- started ingesting 2026-09-21 03:25 UTC. graph.quantity_rule carried only
-- ELECTRICITY and WATER, so attaching it to any AIR node would write zero
-- measurements (W-NO-QUANTITY-RULE) and it would stay invisible to
-- graph.solve_flow.
--
-- 5932 is a totaliser (norm volume, Nm3). It mirrors 5696 WATER exactly:
-- DELTA / SUM / conserved. is_cumulative is flipped in the SAME transaction as
-- the rule insert, because doctor's §12.3 drift check flags a DELTA rule on a
-- non-cumulative column (see 013).
--
-- Blast radius: these four quantities have only ever been reported by device
-- 171 (checked against telemetry_15min_agg, all time). is_cumulative and unit
-- are read by the *_for_user dashboard functions; the energy chain does not
-- read either (013). So the change affects how the dashboard shows device 171,
-- and nothing else.
--
-- Units: unit was NULL on every row of public.quantities before this, so there
-- is no prior convention. Nm3 matches graph.utility.base_unit for AIR.
--
-- NOT changed here, recorded for follow-up:
--   5933 category = 'Water' although it is compressed air (siblings are 'Air');
--   5933 aggregation_method = 'SUM' although it is a rate.
--
-- Status: APPLIED to valkyrie on 2026-09-21 (section 2). Re-running is a no-op.
-- Undo: see section 4.

-- ============================================================================
-- 1. Evidence -- read-only. Expect 0 decreases on 5932.
-- ============================================================================

SELECT 'Before' AS check_name;
SELECT id, quantity_code, unit, category, aggregation_method, is_cumulative
FROM public.quantities WHERE id IN (3951, 4055, 5932, 5933) ORDER BY id;

SELECT '5932 monotonicity (expect 0 decreases)' AS check_name;
WITH s AS (
    SELECT device_id, value AS v,
           LAG(value) OVER (PARTITION BY device_id ORDER BY timestamp) AS prev
    FROM public.telemetry_data WHERE quantity_id = 5932
)
SELECT device_id, COUNT(*) AS samples,
       COUNT(*) FILTER (WHERE v < prev) AS decreases, MIN(v), MAX(v)
FROM s GROUP BY 1;

-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

UPDATE public.quantities SET is_cumulative = TRUE WHERE id = 5932;

UPDATE public.quantities SET unit = 'kPa'   WHERE id = 3951;
UPDATE public.quantities SET unit = '°C'    WHERE id = 4055;
UPDATE public.quantities SET unit = 'Nm3'   WHERE id = 5932;
UPDATE public.quantities SET unit = 'Nm3/h' WHERE id = 5933;

INSERT INTO graph.quantity_rule (quantity_id, utility_code, raw_time_agg, network_agg, conserved)
VALUES (5932, 'AIR', 'DELTA', 'SUM', TRUE)   -- Compressed Air Norm Volume (Nm3)
ON CONFLICT (quantity_id) DO NOTHING;

COMMIT;

-- ============================================================================
-- 3. Verification -- drift check must return zero rows.
-- ============================================================================

SELECT 'After' AS check_name;
SELECT q.id, q.unit, q.is_cumulative, qr.utility_code, qr.raw_time_agg, qr.network_agg, qr.conserved
FROM public.quantities q LEFT JOIN graph.quantity_rule qr ON qr.quantity_id = q.id
WHERE q.id IN (3951, 4055, 5932, 5933) ORDER BY q.id;

SELECT 'Rule vs column drift (expect zero rows)' AS check_name;
SELECT qr.quantity_id, qr.raw_time_agg, q.is_cumulative
FROM graph.quantity_rule qr JOIN public.quantities q ON q.id = qr.quantity_id
WHERE (qr.raw_time_agg = 'DELTA') <> q.is_cumulative;

-- ============================================================================
-- 4. Undo (only valid while no graph.measurement references 5932)
-- ============================================================================

-- BEGIN;
-- DELETE FROM graph.quantity_rule WHERE quantity_id = 5932;
-- UPDATE public.quantities SET is_cumulative = FALSE WHERE id = 5932;
-- UPDATE public.quantities SET unit = NULL WHERE id IN (3951, 4055, 5932, 5933);
-- COMMIT;
