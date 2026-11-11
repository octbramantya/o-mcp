-- Migration: 068_pv_ppa_tariffs.sql
-- Description: Price PLTS A4 and PLTS Texture at their PPA rate (PLN LWBP -10%) from 2026-08-18,
--              in public.utility_rates, and reprice their rows in daily_energy_cost_summary since
--              then, which the cost refresh had left at Rp 0.
-- Author: Claude
-- Date: 2026-11-11
-- Design: executive report draft §6.3 (local)
-- Requires: 067_pv_rated_kwp.sql
--
-- WHY
-- ---
-- The site reported the PV tariffs on 2026-11-11. The PV is bought under a PPA, priced at a
-- discount on PLN's LWBP rate (I-3/TM, Rp 1,035.78/kWh since 2025-01-01, unchanged in Q4 2026):
--
--   PLTS_A4       (device 167)  LWBP - 10%    Rp 932.2020
--   PLTS_TEXTURE  (device 168)  LWBP - 10%    Rp 932.2020
--   PLTS_A5       (device 27)   LWBP - 6.5%   Rp 968.45
--   PLTS_B2       (device 11)   LWBP - 6.5%   Rp 968.45
--
-- On production (read as grafReader, 2026-11-11), public.utility_rates had one PV rate (id 4,
-- rate_code PV, Rp 968.45 = LWBP - 6.5%) under the source SOLAR_PV (id 2), and only devices 11 and
-- 27 were mapped to it. Devices 167 and 168 had no mapping, so public.get_utility_rate found no
-- rate and public.refresh_daily_energy_costs priced their energy at 0 from their first reading
-- (2026-08-18): in October 2026 about 240,000 kWh, Rp 223.5 M at the PPA rate.
--
-- The user decided (2026-11-11) that the -10% rate applies from 2026-08-18, and that the past rows
-- are repriced.
--
-- WHAT
-- ----
-- 1. A second PV source, SOLAR_PV_LWBP10, for the -10% PPA, with one FLAT rate, rate_code PV
--    (the prs functions select PV rows by rate_code = 'PV'), Rp 932.2020 from 2026-08-18.
-- 2. Devices 167 and 168 mapped to it as GENERATION from 2026-08-18, as 11 and 27 are to SOLAR_PV.
-- 3. SOLAR_PV renamed for what it is (the -6.5% PPA, not an internal installation); its rate keeps
--    its amount (968.45, LWBP x 0.935 rounded to the cent) and structure.
-- 4. rate_parameters on both PV rates record the basis: {"basis": "LWBP", "basis_rate": 1035.78,
--    "discount_pct": ...}. When PLN changes LWBP, both PV rates change with it, in the same migration.
-- 5. The rows of 167 and 168 in daily_energy_cost_summary since 2026-08-18 that carry no rate are
--    repriced to what the refresh now gives them. The refresh groups by shift and rate; with no rate
--    every hour of a shift fell into one row, and a FLAT rate prices every hour, so each row maps to
--    exactly one repriced row: rate_code PV, the rate, the new source, total_cost = kWh x rate.
--    refresh_method 'MIGRATION_068' marks them. The cron refresh rewrites only the last three days,
--    so without this the past would stay at 0.
--
-- FLAT, not TIME_OF_USE 00-23 like rate 4: rate 4's window ends at 23:00 (end_hour is exclusive and
-- at most 23), so readings in the 23:00 hour of 11 and 27 carry no rate. PV makes nothing then, so
-- it is a few kWh of night-time register noise, but a FLAT rate also makes the backfill in 5 exactly
-- what the refresh produces. Rate 4 is left as it is.
--
-- NOT changed: public.get_utility_rate filters rates and mappings by CURRENT_DATE, not by the
-- reading's time, so effective_from here is a record, not a switch. A refresh of an old day prices
-- it at today's rates. A rate change that must not reach the past needs that function fixed first.
--
-- Not graph: these are public tables, in this repository's migration sequence (user, 2026-11-11).
-- tools/dev_refresh.sh copies the three tariff tables from this migration on.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Sources and rates, tenant 3 ==='
SELECT us.id, us.source_code, us.source_name, ur.id AS rate_id, ur.rate_code, ur.rate_structure,
       ur.start_hour, ur.end_hour, ur.rate_per_unit, ur.effective_from, ur.rate_parameters
FROM public.utility_sources us
LEFT JOIN public.utility_rates ur ON ur.utility_source_id = us.id
WHERE us.tenant_id = 3 ORDER BY us.id, ur.id;

\echo ''
\echo '=== 1.2 PV devices and their mapping ==='
SELECT d.id, d.device_name, dum.utility_source_id, dum.mapping_type, dum.effective_from
FROM public.devices d
LEFT JOIN public.device_utility_mappings dum ON dum.device_id = d.id
WHERE d.id IN (11, 27, 167, 168) ORDER BY d.id;
-- expect 11 and 27 on source 2, 167 and 168 unmapped

\echo ''
\echo '=== 1.3 PV energy and cost by month, before (quantity 124) ==='
SELECT device_id, to_char(daily_bucket, 'YYYY-MM') AS month, round(sum(total_consumption)) AS kwh,
       round(sum(total_cost)) AS idr, count(*) FILTER (WHERE utility_source_id IS NULL) AS unpriced_rows
FROM public.daily_energy_cost_summary
WHERE tenant_id = 3 AND device_id IN (11, 27, 167, 168) AND quantity_id = 124
  AND daily_bucket >= '2026-08-18'
GROUP BY 1, 2 ORDER BY 1, 2;


-- ============================================================================
-- 2. Change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run unless the tariffs are as described above
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n FROM public.utility_sources WHERE tenant_id = 3;
    IF n <> 2 OR NOT EXISTS (SELECT 1 FROM public.utility_sources
                             WHERE id = 1 AND tenant_id = 3 AND source_code = 'PLN_MAIN' AND is_active)
              OR NOT EXISTS (SELECT 1 FROM public.utility_sources
                             WHERE id = 2 AND tenant_id = 3 AND source_code = 'SOLAR_PV' AND is_active) THEN
        RAISE EXCEPTION 'expected tenant 3 sources PLN_MAIN (1) and SOLAR_PV (2) only, found % rows', n;
    END IF;

    -- LWBP 1035.78 on both off-peak rows, and one PV rate at LWBP x 0.935
    SELECT count(*) INTO n FROM public.utility_rates
    WHERE tenant_id = 3 AND utility_source_id = 1 AND rate_code IN ('LWBP1', 'LWBP2')
      AND rate_per_unit = 1035.78 AND is_active AND effective_to IS NULL;
    IF n <> 2 THEN
        RAISE EXCEPTION 'expected LWBP1 and LWBP2 at 1035.78 in effect, found %', n;
    END IF;
    SELECT count(*) INTO n FROM public.utility_rates WHERE tenant_id = 3 AND utility_source_id = 2;
    IF n <> 1 OR NOT EXISTS (SELECT 1 FROM public.utility_rates
                             WHERE id = 4 AND utility_source_id = 2 AND rate_code = 'PV'
                               AND rate_per_unit = 968.45 AND is_active AND effective_to IS NULL
                               AND rate_parameters IS NULL) THEN
        RAISE EXCEPTION 'expected one PV rate (id 4, 968.45, no rate_parameters) on SOLAR_PV, found % rows', n;
    END IF;

    -- 11 and 27 on SOLAR_PV; 167 and 168 mapped to nothing
    SELECT count(*) INTO n FROM public.device_utility_mappings
    WHERE device_id IN (11, 27) AND utility_source_id = 2 AND is_active AND effective_to IS NULL;
    IF n <> 2 THEN
        RAISE EXCEPTION 'expected devices 11 and 27 mapped to SOLAR_PV, found %', n;
    END IF;
    SELECT count(*) INTO n FROM public.device_utility_mappings WHERE device_id IN (167, 168);
    IF n <> 0 THEN
        RAISE EXCEPTION 'expected no mapping for devices 167 and 168, found %', n;
    END IF;

    -- 167 and 168 meter PLTS_A4 and PLTS_TEXTURE, in effect
    SELECT count(DISTINCT m.device_id) INTO n
    FROM graph.measurement m JOIN graph.node nd ON nd.id = m.node_id
    WHERE nd.tenant_id = 3 AND nd.node_type = 'PV_PLANT'
      AND ((m.device_id = 167 AND nd.node_code = 'PLTS_A4') OR (m.device_id = 168 AND nd.node_code = 'PLTS_TEXTURE'))
      AND m.quantity_id = 124
      AND m.is_active AND m.effective_from <= CURRENT_DATE AND (m.effective_to IS NULL OR m.effective_to >= CURRENT_DATE)
      AND nd.is_active AND nd.effective_from <= CURRENT_DATE AND (nd.effective_to IS NULL OR nd.effective_to >= CURRENT_DATE);
    IF n <> 2 THEN
        RAISE EXCEPTION 'expected 167 on PLTS_A4 and 168 on PLTS_TEXTURE, found %', n;
    END IF;

    -- the backfill: no priced row of 167 or 168 yet, and nothing before 2026-08-18 to leave behind
    SELECT count(*) INTO n FROM public.daily_energy_cost_summary
    WHERE device_id IN (167, 168) AND (utility_source_id IS NOT NULL OR rate_code IS NOT NULL OR total_cost <> 0);
    IF n <> 0 THEN
        RAISE EXCEPTION 'expected every cost summary row of 167 and 168 unpriced, found % priced', n;
    END IF;
    SELECT count(*) INTO n FROM public.daily_energy_cost_summary
    WHERE device_id IN (167, 168) AND daily_bucket < '2026-08-18';
    IF n <> 0 THEN
        RAISE EXCEPTION 'expected no cost summary row of 167 or 168 before 2026-08-18, found %', n;
    END IF;
    -- one row per day, device, quantity and shift, so each becomes one PV row
    IF EXISTS (SELECT 1 FROM public.daily_energy_cost_summary
               WHERE device_id IN (167, 168) AND grouping_type = 'SHIFT_RATE'
               GROUP BY daily_bucket, device_id, quantity_id, shift_period HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM public.daily_energy_cost_summary
                  WHERE device_id IN (167, 168) AND grouping_type IS DISTINCT FROM 'SHIFT_RATE') THEN
        RAISE EXCEPTION 'expected one SHIFT_RATE row per day, device, quantity and shift for 167 and 168';
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 2.2 The -10% PPA: source, rate, mappings
-- ----------------------------------------------------------------------------
INSERT INTO public.utility_sources (tenant_id, source_code, source_name, source_type, utility_type,
                                    base_unit, measurement_type, provider_name, description)
VALUES (3, 'SOLAR_PV_LWBP10', 'Solar PV PPA, LWBP -10% (PLTS A4, PLTS Texture)', 'PV', 'ELECTRICITY',
        'kWh', 'ENERGY', NULL,
        'PV bought under a PPA at PLN''s LWBP rate less 10% (site, 2026-11-11). Provider not recorded.');

INSERT INTO public.utility_rates (utility_source_id, tenant_id, rate_code, rate_name, rate_structure,
                                  rate_per_unit, currency_code, rate_unit, effective_from, rate_parameters,
                                  description, created_by)
SELECT us.id, 3, 'PV', 'PV PPA, LWBP -10%', 'FLAT', 932.2020, 'IDR', 'kWh', DATE '2026-08-18',
       '{"basis": "LWBP", "basis_rate": 1035.78, "discount_pct": 10}'::jsonb,
       'LWBP (Rp 1,035.78) x 0.90. Moves with LWBP: when PLN changes it, change this rate too.',
       'migration 068'
FROM public.utility_sources us WHERE us.tenant_id = 3 AND us.source_code = 'SOLAR_PV_LWBP10';

INSERT INTO public.device_utility_mappings (device_id, utility_source_id, mapping_type, priority_order,
                                            allocation_percentage, effective_from, mapping_notes, created_by)
SELECT d.id, us.id, 'GENERATION', 1, 100.00, DATE '2026-08-18',
       'PPA LWBP -10% from the plant''s first reading (user, 2026-11-11)', 'migration 068'
FROM (VALUES (167), (168)) AS d(id)
CROSS JOIN public.utility_sources us WHERE us.tenant_id = 3 AND us.source_code = 'SOLAR_PV_LWBP10';

-- ----------------------------------------------------------------------------
-- 2.3 The -6.5% PPA: say what it is; the amount does not change
-- ----------------------------------------------------------------------------
UPDATE public.utility_sources
   SET source_name = 'Solar PV PPA, LWBP -6.5% (PLTS A5, PLTS B2)',
       provider_name = NULL,
       description = 'PV bought under a PPA at PLN''s LWBP rate less 6.5% (site, 2026-11-11). '
                     || 'Provider not recorded; was "Internal Solar Installation".',
       updated_at = now()
 WHERE id = 2 AND tenant_id = 3 AND source_code = 'SOLAR_PV';

UPDATE public.utility_rates
   SET rate_name = 'PV PPA, LWBP -6.5%',
       rate_parameters = '{"basis": "LWBP", "basis_rate": 1035.78, "discount_pct": 6.5}'::jsonb,
       description = 'LWBP (Rp 1,035.78) x 0.935, rounded to the cent. Moves with LWBP: when PLN changes it, '
                     || 'change this rate too.',
       updated_at = now()
 WHERE id = 4 AND tenant_id = 3;

-- ----------------------------------------------------------------------------
-- 2.4 Reprice 167 and 168 since 2026-08-18
-- ----------------------------------------------------------------------------
UPDATE public.daily_energy_cost_summary AS s
   SET rate_code = 'PV',
       rate_per_unit = ur.rate_per_unit,
       utility_source_id = ur.utility_source_id,
       grouping_value = s.shift_period || '-PV',
       total_cost = s.total_consumption * ur.rate_per_unit,
       last_refreshed = now(),
       refresh_method = 'MIGRATION_068'
  FROM public.utility_rates ur
  JOIN public.utility_sources us ON us.id = ur.utility_source_id
 WHERE us.tenant_id = 3 AND us.source_code = 'SOLAR_PV_LWBP10'
   AND s.tenant_id = 3 AND s.device_id IN (167, 168) AND s.daily_bucket >= '2026-08-18'
   AND s.utility_source_id IS NULL AND s.rate_code IS NULL;

-- ----------------------------------------------------------------------------
-- 2.5 Check
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    r RECORD;
    n INT;
BEGIN
    -- the rate the refresh will now find, at noon today (the function takes UTC)
    FOR r IN SELECT d.id, g.rate_per_unit, g.rate_code
             FROM (VALUES (11, 968.45), (27, 968.45), (167, 932.2020), (168, 932.2020)) AS d(id, expect)
             LEFT JOIN LATERAL public.get_utility_rate(3, d.id,
                 ((CURRENT_DATE + TIME '12:00') AT TIME ZONE 'Asia/Jakarta') AT TIME ZONE 'UTC') g ON true
             WHERE g.rate_per_unit IS DISTINCT FROM d.expect OR g.rate_code IS DISTINCT FROM 'PV'
    LOOP
        RAISE EXCEPTION 'device %: get_utility_rate gives % %', r.id, r.rate_code, r.rate_per_unit;
    END LOOP;
    -- 167 and 168 at any hour (FLAT)
    SELECT count(*) INTO n FROM generate_series(0, 23) h, (VALUES (167), (168)) d(id),
         LATERAL public.get_utility_rate(3, d.id,
             ((CURRENT_DATE + make_interval(hours => h)) AT TIME ZONE 'Asia/Jakarta') AT TIME ZONE 'UTC') g
    WHERE g.rate_per_unit = 932.2020;
    IF n <> 48 THEN
        RAISE EXCEPTION 'expected 167 and 168 priced at every hour, found % of 48', n;
    END IF;

    SELECT count(*) INTO n FROM public.daily_energy_cost_summary
    WHERE device_id IN (167, 168) AND (utility_source_id IS NULL OR rate_code IS DISTINCT FROM 'PV'
                                       OR total_cost IS DISTINCT FROM total_consumption * 932.2020);
    IF n <> 0 THEN
        RAISE EXCEPTION 'expected every cost summary row of 167 and 168 at 932.2020, found % not', n;
    END IF;
END
$$;

COMMIT;

\echo ''
\echo '=== 3. PV energy and cost by month, after (quantity 124) ==='
SELECT device_id, to_char(daily_bucket, 'YYYY-MM') AS month, round(sum(total_consumption)) AS kwh,
       round(sum(total_cost)) AS idr, count(*) FILTER (WHERE utility_source_id IS NULL) AS unpriced_rows
FROM public.daily_energy_cost_summary
WHERE tenant_id = 3 AND device_id IN (11, 27, 167, 168) AND quantity_id = 124
  AND daily_bucket >= '2026-08-18'
GROUP BY 1, 2 ORDER BY 1, 2;
