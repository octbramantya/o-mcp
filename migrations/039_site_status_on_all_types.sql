-- Migration: 039_site_status_on_all_types.sql
-- Description: Let any equipment carry site_status (OPTIONAL), and record LVMDB_TEXTURE,
--              HEATER_8 and AIR_DRYER as turned off on site as of 2026-10-02.
-- Author: Claude
-- Date: 2026-10-05
-- Design: design/type-property.md; design/mcp-tools.md (gap item 5)
-- Requires: 038_retire_mc_baru_panels.sql
--
-- WHY
-- ---
-- The site confirmed on 2026-10-02 that LVMDB_TEXTURE, HEATER_8 and AIR_DRYER
-- are deliberately turned off. They are not retired: the site may turn them
-- back on, and retiring or deleting them would mean re-adding nodes, devices
-- and measurement rows later, with a telemetry gap. The node, its edges, its
-- measurement rows, its device and its telemetry all stay as they are; only a
-- note in attrs changes.
--
-- site_status (026) exists only on CAPACITOR_BANK, where pf_report.py needs it
-- (REQUIRED). On any other type assert_node_attrs refuses the key. This adds
-- site_status and site_status_as_of as OPTIONAL to every root node type;
-- subtypes inherit through v_type_property (MAIN_LV_BOARD from SWITCHBOARD,
-- the treatment subtypes from WATER_TREATMENT).
--
-- OPTIONAL, not REQUIRED: no reader needs the status of every AHU or heater,
-- and REQUIRED would list every node as MISSING. The site records exceptions
-- only. Absent means "nothing reported", never "normal". Once set, the value
-- shows as STALE in v_property_gaps after 90 days, like the capacitor banks.
--
-- site_status is kept by hand from what the site reports. It is not observed,
-- and it cannot notice a meter switched off without notice. The MCP server
-- pairs it with each device's last reading (design/mcp-tools.md, gap 5). The
-- property description says so, since it is what the server shows a model.
--
-- NOT given the property: RECYCLE_CUT, which is not equipment (it stands in
-- for a recycle return so the graph stays acyclic) and cannot be turned off.
--
-- NOT marked: AHU_LINE3. It was silent in the dev telemetry week because of a
-- site configuration error, fixed on 2026-10-05; it is running. MC_302_9_11
-- and MC_MOTOR_1 run to an operational schedule, which is normal operation.
-- They carry no status.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Where site_status is a property today ==='
SELECT node_type, attr_key, requirement, used_by
FROM graph.type_property WHERE attr_key IN ('site_status', 'site_status_as_of')
ORDER BY 1, 2;
-- expect CAPACITOR_BANK only, both REQUIRED

\echo ''
\echo '=== 1.2 Root node types ==='
SELECT code, node_class FROM graph.node_type WHERE parent_code IS NULL ORDER BY 1;
-- expect 19

\echo ''
\echo '=== 1.3 The three nodes ==='
SELECT node_code, node_type, attrs FROM graph.node
WHERE tenant_id = 3 AND node_code IN ('LVMDB_TEXTURE', 'HEATER_8', 'AIR_DRYER')
ORDER BY 1;
-- expect no site_status on any


-- ============================================================================
-- 2. Change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run unless the types and nodes are exactly as described above
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    n INT;
    unexpected TEXT;
BEGIN
    SELECT count(*) INTO n FROM graph.type_property
    WHERE attr_key IN ('site_status', 'site_status_as_of');
    IF n <> 2 OR EXISTS (SELECT 1 FROM graph.type_property
                         WHERE attr_key IN ('site_status', 'site_status_as_of')
                           AND (node_type <> 'CAPACITOR_BANK' OR requirement <> 'REQUIRED')) THEN
        RAISE EXCEPTION 'expected site_status on CAPACITOR_BANK only, REQUIRED (% rows)', n;
    END IF;

    -- A root type added after this was written must be decided on, not swept in.
    SELECT string_agg(code, ', ' ORDER BY code) INTO unexpected
    FROM graph.node_type
    WHERE parent_code IS NULL
      AND code NOT IN ('AHU', 'AIR_COMPRESSOR', 'BOILER', 'CAPACITOR_BANK', 'GAS_ENGINE',
                       'GENERIC_LOAD', 'GRID_INCOMER', 'LIGHTING', 'PROCESS_HEATER',
                       'PRODUCTION_MACHINE', 'PUMP', 'PV_PLANT', 'RECYCLE_CUT', 'SWITCHBOARD',
                       'WATER_INTAKE', 'WATER_OUTFALL', 'WATER_PROCESS', 'WATER_TANK',
                       'WATER_TREATMENT');
    IF unexpected IS NOT NULL THEN
        RAISE EXCEPTION 'root node types not covered by 039: %', unexpected;
    END IF;
    SELECT count(*) INTO n FROM graph.node_type WHERE parent_code IS NULL;
    IF n <> 19 THEN
        RAISE EXCEPTION 'expected 19 root node types, found %', n;
    END IF;

    SELECT count(*) INTO n FROM graph.node
    WHERE tenant_id = 3
      AND node_code IN ('LVMDB_TEXTURE', 'HEATER_8', 'AIR_DRYER')
      AND node_type IN ('MAIN_LV_BOARD', 'PROCESS_HEATER', 'AIR_COMPRESSOR')
      AND NOT attrs ? 'site_status' AND NOT attrs ? 'site_status_as_of'
      AND is_active AND effective_from <= CURRENT_DATE
      AND (effective_to IS NULL OR effective_to >= CURRENT_DATE);
    IF n <> 3 THEN
        RAISE EXCEPTION 'expected the three nodes in effect, typed, with no site_status; found %', n;
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 2.2 OPTIONAL on every root type that is equipment
-- ----------------------------------------------------------------------------
INSERT INTO graph.type_property (node_type, attr_key, requirement, used_by)
SELECT t.code, k.attr_key, 'OPTIONAL', NULL
FROM graph.node_type t
CROSS JOIN (VALUES ('site_status'), ('site_status_as_of')) AS k(attr_key)
WHERE t.parent_code IS NULL
  AND t.code NOT IN ('CAPACITOR_BANK', 'RECYCLE_CUT');

-- ----------------------------------------------------------------------------
-- 2.3 Say what the value is and is not, where the server reads it
-- ----------------------------------------------------------------------------
UPDATE graph.property
   SET description =
       'What the site reports about this unit''s operating state: normal, or inactive '
       || '(deliberately turned off; kept in the graph and may be turned back on). '
       || 'Recorded by hand from site reports, not observed: a unit switched off without '
       || 'notice still reads as before. Absent means nothing has been reported, not normal. '
       || 'Read it together with the device''s last reading.'
 WHERE attr_key = 'site_status';

-- ----------------------------------------------------------------------------
-- 2.4 Turned off on site, confirmed 2026-10-02
-- ----------------------------------------------------------------------------
UPDATE graph.node
   SET attrs = attrs || '{"site_status": "inactive", "site_status_as_of": "2026-10-02"}'::jsonb,
       updated_at = now()
 WHERE tenant_id = 3 AND node_code IN ('LVMDB_TEXTURE', 'HEATER_8', 'AIR_DRYER');

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Node types with site_status, by how they get it ==='
SELECT requirement, count(*) AS types,
       count(*) FILTER (WHERE defined_on <> node_type) AS inherited
FROM graph.v_type_property WHERE attr_key = 'site_status'
GROUP BY 1 ORDER BY 1;
-- expect OPTIONAL 25 (8 inherited), REQUIRED 1

SELECT code FROM graph.node_type t
WHERE NOT EXISTS (SELECT 1 FROM graph.v_type_property v
                  WHERE v.node_type = t.code AND v.attr_key = 'site_status');
-- expect RECYCLE_CUT only

\echo ''
\echo '=== 3.2 Every node with a site_status ==='
SELECT node_code, node_type, attrs ->> 'site_status' AS site_status,
       attrs ->> 'site_status_as_of' AS as_of
FROM graph.node WHERE tenant_id = 3 AND attrs ? 'site_status'
ORDER BY site_status, node_code;
-- expect 4 inactive (AIR_DRYER, CB_MDP3, HEATER_8, LVMDB_TEXTURE), 10 normal

\echo ''
\echo '=== 3.3 Gap view ==='
SELECT status, count(*) FROM graph.v_property_gaps GROUP BY 1 ORDER BY 1;
-- expect MISSING 31 (STALE appears from 2026-12-21 for the banks, 2027-01-01 for these three)

\echo ''
\echo '=== 3.4 The trigger still refuses the key where it does not belong ==='
DO $$
BEGIN
    BEGIN
        UPDATE graph.node SET attrs = attrs || '{"site_status": "inactive"}'::jsonb
         WHERE tenant_id = 3 AND node_type = 'RECYCLE_CUT';
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
-- BEGIN;
-- UPDATE graph.node SET attrs = attrs - 'site_status' - 'site_status_as_of', updated_at = now()
--  WHERE tenant_id = 3 AND node_code IN ('LVMDB_TEXTURE', 'HEATER_8', 'AIR_DRYER');
-- -- clear any other non-bank node given a site_status since, or it shows as INVALID
-- DELETE FROM graph.type_property
--  WHERE attr_key IN ('site_status', 'site_status_as_of') AND node_type <> 'CAPACITOR_BANK';
-- UPDATE graph.property SET description = 'What the site reports about this unit''s operating state.'
--  WHERE attr_key = 'site_status';
-- COMMIT;
