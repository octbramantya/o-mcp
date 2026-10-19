-- Migration: 048_a4_pv_phase_b.sql
-- Description: Add one third of PLTS A4 (device 167) to the LVMDB_A4 node, because meter 26
--              reads the board on two phases and the grid feeder on the third.
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-sankey.md §9.2 (G8); design/graph-reconcile.md §1.10
-- Requires: 047_swap_wtp_names.sql
--
-- WHY
-- ---
-- The 2026-10-15 interview said meter 26 reads grid + PV, i.e. the board's whole load. September
-- 2026 telemetry says otherwise for one phase. Hourly mean active power per phase:
--   26 phase A and C: 85-89 kW day and night;
--   26 phase B: about 92 kW at night, falling to -77 kW at 10:00, a drop of about 169 kW;
--   167 (PLTS A4) phase A, B, C: equal to within 1%, peaking at about 163 kW each.
-- The phase-B drop is PLTS A4's phase-B output. On 2026-10-19 the user traced it to a mistake in
-- A4's point of common coupling: on two phases the PV joins before meter 26 (it reads the load),
-- on one it joins after (it reads the grid). The user named that phase T; the meter labels it B.
--
-- So 26 = A4 load - PV(phase B), and with a balanced inverter A4 load = 26 + 167 / 3. The solver
-- already sums every TOTAL row on a node with its multiplier, so the board's value is two rows:
-- 26 x 1 (unchanged) and 167 x 1/3 (new). Then LVMDB_A4 = 26 + 167/3, the grid feeder
-- FACTORY_AB -> LVMDB_A4 = 26 - 2/3 x 167, and the A4 residual (COOLING2, the chiller side) =
-- 26 + 167/3 - 98 - 135. In September: 152,433 + 36,823 - 161,599 - 867 = 26,790 kWh.
-- The 1/3 is exact to the inverter's phase balance (under 1% in September).
--
-- Only active energy delivered (124) is added: it is the quantity the solver and the sankey read.
-- 26's other quantities stay as they are, and they are mixed by phase: on phase B its power,
-- current and power factor are the grid's, on A and C the board's. Per-phase readers of 26 must
-- know that (design/graph-sankey.md §9.2).
--
-- The wiring has been this way since PLTS A4 was connected, so the row starts at '-infinity'
-- (a documentation correction: past A4 results were wrong). When the site corrects the PCC, end
-- this row on the last day before the fix (valid time); meter 26 then reads the board alone.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Active-energy rows on LVMDB_A4 ==='
SELECT m.id, m.device_id, m.quantity_id, m.multiplier, m.role, m.effective_from, m.effective_to
FROM graph.measurement m JOIN graph.node n ON n.id = m.node_id
WHERE n.tenant_id = 3 AND n.node_code = 'LVMDB_A4' AND m.quantity_id = 124
ORDER BY m.device_id;
-- expect one row: device 26, multiplier 1, in effect


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

DO $$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n
    FROM graph.measurement m JOIN graph.node t ON t.id = m.node_id
    WHERE t.tenant_id = 3 AND t.node_code = 'LVMDB_A4' AND m.quantity_id = 124
      AND m.is_active AND m.effective_from <= CURRENT_DATE
      AND (m.effective_to IS NULL OR m.effective_to >= CURRENT_DATE);
    IF n <> 1 THEN
        RAISE EXCEPTION '048: expected one active-energy row on LVMDB_A4 (device 26), found %', n;
    END IF;

    SELECT count(*) INTO n
    FROM graph.measurement m JOIN graph.node t ON t.id = m.node_id
    WHERE t.tenant_id = 3 AND t.node_code = 'PLTS_A4' AND m.device_id = 167 AND m.quantity_id = 124
      AND m.is_active AND m.effective_from <= CURRENT_DATE
      AND (m.effective_to IS NULL OR m.effective_to >= CURRENT_DATE);
    IF n <> 1 THEN
        RAISE EXCEPTION '048: expected device 167 metering PLTS_A4, found % rows', n;
    END IF;
END
$$;

INSERT INTO graph.measurement
       (tenant_id, node_id, device_id, quantity_id, utility_code, multiplier, role,
        is_active, effective_from, effective_to)
SELECT 3, n.id, 167, 124, 'ELECTRICITY', 1.0 / 3, 'TOTAL', TRUE, '-infinity', NULL
FROM graph.node n
WHERE n.tenant_id = 3 AND n.node_code = 'LVMDB_A4';

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Active-energy rows on LVMDB_A4 ==='
SELECT m.device_id, round(m.multiplier, 6) AS multiplier, m.role, m.effective_from, m.effective_to
FROM graph.measurement m JOIN graph.node n ON n.id = m.node_id
WHERE n.tenant_id = 3 AND n.node_code = 'LVMDB_A4' AND m.quantity_id = 124
  AND m.is_active AND m.effective_from <= CURRENT_DATE
  AND (m.effective_to IS NULL OR m.effective_to >= CURRENT_DATE)
ORDER BY m.device_id;
-- expect 26 x 1 and 167 x 0.333333


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- DELETE FROM graph.measurement m USING graph.node n
--  WHERE n.id = m.node_id AND n.tenant_id = 3 AND n.node_code = 'LVMDB_A4'
--    AND m.device_id = 167 AND m.quantity_id = 124;
