-- Migration: 043_pf_total_description.sql
-- Description: Describe PF_TOTAL's encodings by kind of device, not by tenant 3's device codes.
-- Author: Claude
-- Date: 2026-10-12
-- Design: design/mcp-tenancy.md §5 (shared vocabulary describes types, never one tenant's plant);
--         design/quantity_terms.csv (the current description; 037 rendered the old one)
-- Requires: 042_node_type_descriptions.sql
--
-- WHY
-- ---
-- graph.quantity_term is shared by every tenant, and the MCP server gives each
-- tenant's agent its descriptions. PF_TOTAL's said "The PV loggers (PLTSC, PLTSD)
-- report a plain signed PF instead": two of tenant 3's device codes, which tenant
-- 4's agent would read as well.
--
-- What the sentence was for is a fact about devices, not about tenant 3. Checked on
-- dev, per model in public.devices.metadata.device_info, 2026-10-12: only the
-- Schneider meters (PM2220, PM5110, PM2200, PM5560) report outside -1..1, coded
-- by quadrant on -2..2; Lovato DMG610 and Schneider PM710 report 0..1; PLTSC and
-- PLTSD, a custom PLC, report a signed -1..1. So the new text says Schneider meters
-- code by quadrant and generic power meters and PLCs report on -1..1, whose
-- magnitude is the power factor. One decoding fits all of them, which the
-- MCP server uses (server/tools/readings.py).
--
-- One description only. DPF_* and PF_A..C say "Same -2 to 2 quadrant encoding as
-- PF_TOTAL", which stays true of the Schneider meters it refers to.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 The description being replaced ==='
SELECT quantity_id, code, description FROM graph.quantity_term WHERE code = 'PF_TOTAL';
-- expect 1 row, quantity_id 1072, ending "The PV loggers (PLTSC, PLTSD) report a plain signed PF
-- instead. For a node's power factor use the derived PF_TRUE."


-- ============================================================================
-- 2. Change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run unless PF_TOTAL still has the description 037 wrote
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM graph.quantity_term
        WHERE quantity_id = 1072 AND code = 'PF_TOTAL'
          AND description = 'True power factor over the three phases, as the meter reports it: only at metered nodes. Schneider meters encode it by quadrant on -2 to 2: 0 to 1 is lagging import as is, above 1 is leading import (true PF = 2 minus the value), below -1 is lagging export (true PF = value plus 2), -1 to 0 is leading export (true PF = minus the value), and exactly -2 appears at no load. The PV loggers (PLTSC, PLTSD) report a plain signed PF instead. For a node''s power factor use the derived PF_TRUE.'
    ) THEN
        RAISE EXCEPTION '043: PF_TOTAL (1072) does not have the description 037 wrote; check what changed it';
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2.2 The new description
-- ----------------------------------------------------------------------------
UPDATE graph.quantity_term
SET description = 'True power factor over the three phases, as the meter reports it: only at metered nodes. Schneider meters encode it by quadrant on -2 to 2: 0 to 1 is lagging import as is, above 1 is leading import (true PF = 2 minus the value), below -1 is lagging export (true PF = value plus 2), -1 to 0 is leading export (true PF = minus the value), and exactly -2 appears at no load. Generic power meters and PLCs report it on -1 to 1 instead, signed or not; its magnitude is the power factor, and what a sign means depends on the device. For a node''s power factor use the derived PF_TRUE.'
WHERE quantity_id = 1072 AND code = 'PF_TOTAL';

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 No shared quantity description names a device code ==='
SELECT t.code FROM graph.quantity_term t
WHERE EXISTS (SELECT 1 FROM public.devices d WHERE t.description ~ ('\m' || d.device_code || '\M'));
-- expect 0 rows

\echo ''
\echo '=== 3.2 Nothing else moved ==='
SELECT count(*) AS terms FROM graph.quantity_term;
-- expect 97


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- UPDATE graph.quantity_term SET description = 'True power factor over the three phases, as the meter reports it: only at metered nodes. Schneider meters encode it by quadrant on -2 to 2: 0 to 1 is lagging import as is, above 1 is leading import (true PF = 2 minus the value), below -1 is lagging export (true PF = value plus 2), -1 to 0 is leading export (true PF = minus the value), and exactly -2 appears at no load. The PV loggers (PLTSC, PLTSD) report a plain signed PF instead. For a node''s power factor use the derived PF_TRUE.'
-- WHERE quantity_id = 1072;
-- COMMIT;
