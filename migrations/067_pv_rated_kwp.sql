-- Migration: 067_pv_rated_kwp.sql
-- Description: Record the four PV plants' DC peak capacity (rated_kwp), as the site reported it
--              on 2026-11-11, and make rated_kwp REQUIRED on PV_PLANT.
-- Author: Claude
-- Date: 2026-11-11
-- Design: design/type-property.md (rated_kwp, PV_PLANT); executive report draft §3 row 5 (local)
-- Requires: 066_device28_back_on_a5.sql
--
-- WHY
-- ---
-- 026 created rated_kwp (number, kWp, NAMEPLATE) and linked it to PV_PLANT as OPTIONAL, with no
-- value on any node. The site gave the four plants' capacity on 2026-11-11:
--
--   PLTS_A4       1,082.75 kWp
--   PLTS_A5         495.72 kWp
--   PLTS_B2         845.64 kWp
--   PLTS_TEXTURE  1,094.34 kWp      (total 3,518.45 kWp)
--
-- A reader now needs it: tools/exec_report.py divides each plant's energy by its rated_kwp
-- (specific yield, kWh/kWp, and capacity factor). The four plants share one site's sun, so the
-- comparison between them shows a plant underperforming (soiling, inverter trips, shading,
-- clipping) without an irradiance sensor. That makes it REQUIRED, with that reader in used_by:
-- a PV plant added later without a capacity shows as MISSING in graph.v_property_gaps.
--
-- rated_kwp is the DC array rating, not the inverters' AC rating. A plant whose inverters are
-- smaller than the array clips at noon, and its capacity factor reads low for that reason.
--
-- The value goes in attrs on the node in effect. It is nameplate, not a change of the plant on a
-- date: the capacity was true before it was recorded, so no node row is retired or added.
--
-- The PV tariffs the site reported the same day are in public.utility_rates, not here: the cost
-- refresh reads them from there. That fix is a separate migration.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 rated_kwp today ==='
SELECT node_type, attr_key, requirement, used_by
FROM graph.type_property WHERE attr_key = 'rated_kwp' ORDER BY 1;
-- expect PV_PLANT only, OPTIONAL

\echo ''
\echo '=== 1.2 The PV plants in effect ==='
SELECT node_code, node_name, attrs FROM graph.node
WHERE tenant_id = 3 AND node_type = 'PV_PLANT'
  AND is_active AND effective_from <= CURRENT_DATE
  AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
ORDER BY 1;
-- expect PLTS_A4, PLTS_A5, PLTS_B2, PLTS_TEXTURE, none with rated_kwp


-- ============================================================================
-- 2. Change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run unless the property and the plants are as described above
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    n INT;
    plants TEXT;
BEGIN
    SELECT count(*) INTO n FROM graph.type_property
    WHERE attr_key = 'rated_kwp' AND node_type = 'PV_PLANT' AND requirement = 'OPTIONAL';
    IF n <> 1 OR EXISTS (SELECT 1 FROM graph.type_property
                         WHERE attr_key = 'rated_kwp' AND node_type <> 'PV_PLANT') THEN
        RAISE EXCEPTION 'expected rated_kwp on PV_PLANT only, OPTIONAL';
    END IF;

    SELECT string_agg(node_code, ',' ORDER BY node_code) INTO plants
    FROM graph.node
    WHERE tenant_id = 3 AND node_type = 'PV_PLANT'
      AND is_active AND effective_from <= CURRENT_DATE
      AND (effective_to IS NULL OR effective_to >= CURRENT_DATE);
    IF plants IS DISTINCT FROM 'PLTS_A4,PLTS_A5,PLTS_B2,PLTS_TEXTURE' THEN
        RAISE EXCEPTION 'expected PV plants PLTS_A4,PLTS_A5,PLTS_B2,PLTS_TEXTURE in effect, found %', plants;
    END IF;

    -- every PV_PLANT row, in effect or not, any tenant: REQUIRED must not leave one MISSING unseen
    SELECT count(*) INTO n FROM graph.node WHERE node_type = 'PV_PLANT' AND attrs ? 'rated_kwp';
    IF n <> 0 THEN
        RAISE EXCEPTION 'expected no PV_PLANT node with rated_kwp, found %', n;
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 2.2 The site's figures, 2026-11-11
-- ----------------------------------------------------------------------------
UPDATE graph.node AS n
   SET attrs = n.attrs || jsonb_build_object('rated_kwp', v.kwp),
       updated_at = now()
  FROM (VALUES ('PLTS_A4', 1082.75), ('PLTS_A5', 495.72),
               ('PLTS_B2', 845.64), ('PLTS_TEXTURE', 1094.34)) AS v(node_code, kwp)
 WHERE n.tenant_id = 3 AND n.node_code = v.node_code AND n.node_type = 'PV_PLANT'
   AND n.is_active AND n.effective_from <= CURRENT_DATE
   AND (n.effective_to IS NULL OR n.effective_to >= CURRENT_DATE);

-- ----------------------------------------------------------------------------
-- 2.3 REQUIRED, with its reader
-- ----------------------------------------------------------------------------
UPDATE graph.type_property
   SET requirement = 'REQUIRED',
       used_by = 'tools/exec_report.py: specific yield (kWh/kWp) and capacity factor per plant'
 WHERE node_type = 'PV_PLANT' AND attr_key = 'rated_kwp';

UPDATE graph.property
   SET description =
       'PV array DC peak power, the sum of the modules'' STC ratings. Not the inverters'' AC '
       || 'rating: a plant whose inverters are smaller than its array clips at noon. Energy over '
       || 'rated_kwp is the specific yield (kWh/kWp), comparable between plants on one site.'
 WHERE attr_key = 'rated_kwp';

-- ----------------------------------------------------------------------------
-- 2.4 Check
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    total NUMERIC;
    n INT;
BEGIN
    SELECT sum((attrs->>'rated_kwp')::numeric), count(*) INTO total, n
    FROM graph.node
    WHERE tenant_id = 3 AND node_type = 'PV_PLANT' AND attrs ? 'rated_kwp'
      AND is_active AND effective_from <= CURRENT_DATE
      AND (effective_to IS NULL OR effective_to >= CURRENT_DATE);
    IF n <> 4 OR total <> 3518.45 THEN
        RAISE EXCEPTION 'expected 4 plants totalling 3518.45 kWp, found % totalling %', n, total;
    END IF;

    SELECT count(*) INTO n FROM graph.v_property_gaps WHERE attr_key = 'rated_kwp';
    IF n <> 0 THEN
        RAISE EXCEPTION 'expected no rated_kwp gap, found %', n;
    END IF;
END
$$;

COMMIT;

\echo ''
\echo '=== 3. After ==='
SELECT node_code, attrs->>'rated_kwp' AS rated_kwp FROM graph.node
WHERE tenant_id = 3 AND node_type = 'PV_PLANT'
  AND is_active AND effective_from <= CURRENT_DATE
  AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
ORDER BY 1;
