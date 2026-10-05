-- Migration: 037_create_quantity_term.sql
-- Description: A vocabulary for the quantities the meters report: a readable code, a unit,
--              how a value is read over time, and a description for each.
-- Author: Claude
-- Date: 2026-10-02
-- Design: design/quantity_terms.csv (rendered by tools/gen_037.py; regenerate, never hand-edit);
--         design/mcp-tools.md
-- Requires: 036_redraw_water_exits.sql
--
-- WHY
-- ---
-- public.quantities is the quantity table ported from Schneider Power Monitoring
-- Expert (6746 rows). Its names are clear to an engineer, but 6742 rows have no
-- unit, the descriptions repeat the PME name, and the codes are truncated PME
-- strings (PME_129_ACTIVE_ENERGY_DELIVE). A model reading a meter value through
-- the MCP server needs what an engineer brings without thinking: the unit, what
-- the number means, and which values are meter artefacts rather than readings.
--
-- The table stays as it is: it is shared with the pipelines that were ported
-- with it. The vocabulary is a graph table keyed on its id, like quantity_rule.
--
-- Scope: the 96 quantities tenant 3's meters reported in the week of
-- 2026-09-06 to 2026-09-13 (92 electricity, 4 water), plus quantity 5932, which
-- no meter reports yet but which has a quantity_rule (023). Every reporting
-- device is attached to the graph. A quantity a meter starts reporting later
-- gets a CSV row and a new migration; until then the server returns it with
-- the PME name and no unit, flagged as undescribed.
--
-- Units are taken from the data where a check was possible (unit_basis = DATA)
-- and from the name otherwise (NAME). Checks run on dev, 2026-10-02:
--   * energy against power: the increase of 124 over the week equals the
--     integral of 185 (ratio 1.00 on most meters), so kWh with kW; likewise
--     89 with 179 (kVArh, kVAr) and 481 with 530 (kVAh, kVA).
--   * per-phase apparent power 510 = 1060 x 501 / 1000 (ratio 1.000): kVA, V, A.
--   * 190 = 124 + 131, 183 = 89 + 96 and 62 = 481 + 471 exactly, on every row.
--   * harmonic magnitudes: the root-sum-square of H3..H15 equals THD current
--     (2097) on every meter checked, so both are percent of the fundamental, not
--     amperes, whatever "RMS Current" in the PME name suggests.
--   * water volume 5696 against flow 3787: ratio 0.99, so m3 with m3/h.
--   * power factor (1072): on Schneider meters a quadrant encoding on -2..2,
--     checked against the signs of 185 and 179; the two PV loggers (PLTSC,
--     PLTSD) report a plain signed value. The description says how to decode.
--
-- 13 COUNTER and 84 SAMPLE readings;
-- units by 52 DATA and 45 NAME.
--    47  %
--     8  V
--     8  (dimensionless)
--     5  A
--     4  kVArh
--     4  kWh
--     4  kVAr
--     4  kW
--     4  kVA
--     3  kVAh
--     2  °C
--     1  Hz
--     1  m3/h
--     1  m3
--     1  Nm3
--
-- Two guards keep the vocabulary whole:
--   * quantity_rule.quantity_id references quantity_term: a quantity the solver
--     interprets must be described first.
--   * a quantity_term code may not equal a derived_quantity code, because the
--     MCP server offers both in one list. derived_quantity gains the unit and
--     description it lacked, so PF_TRUE is described like the rest.
--
-- Nothing that reads values changes: quantity_rule keeps its rows and columns,
-- and solve_flow, get_node_quantity and device_totals do not read the new table.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Quantities with a flow rule, and their names ==='
SELECT qr.quantity_id, q.quantity_name, q.unit, qr.raw_time_agg, qr.network_agg, qr.conserved
FROM graph.quantity_rule qr JOIN quantities q ON q.id = qr.quantity_id
ORDER BY 1;
-- expect 11 rows: 62 89 96 124 131 481 1072 1119 2097 5696 5932

\echo ''
\echo '=== 1.2 Units in public.quantities ==='
SELECT count(*) FILTER (WHERE unit IS NULL OR unit = '') AS no_unit, count(*) AS total
FROM quantities;
-- expect 6742 of 6746 on 2026-10-02


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run unless every id still names the quantity the CSV describes
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    bad TEXT;
BEGIN
    SELECT string_agg(format('%s (expected %L, found %L)', v.id, v.name, q.quantity_name), '; '
                      ORDER BY v.id)
      INTO bad
    FROM (VALUES
        (  62, 'Apparent Energy Delivered + Received'),
        (  89, 'Reactive Energy Delivered'),
        (  95, 'Reactive Energy Delivered-Received'),
        (  96, 'Reactive Energy Received'),
        ( 124, 'Active Energy Delivered'),
        ( 130, 'Active Energy Delivered-Received'),
        ( 131, 'Active Energy Received'),
        ( 179, 'Reactive Power'),
        ( 183, 'Reactive Energy Delivered + Received'),
        ( 185, 'Active Power'),
        ( 190, 'Active Energy Delivered+Received'),
        ( 471, 'Apparent Energy Received'),
        ( 481, 'Apparent Energy Delivered'),
        ( 501, 'Current Phase A'),
        ( 502, 'Current Phase B'),
        ( 503, 'Current Phase C'),
        ( 504, 'Active Power Phase A'),
        ( 505, 'Active Power Phase B'),
        ( 506, 'Active Power Phase C'),
        ( 507, 'Reactive Power Phase A'),
        ( 508, 'Reactive Power Phase B'),
        ( 509, 'Reactive Power Phase C'),
        ( 510, 'Apparent Power Phase A'),
        ( 511, 'Apparent Power Phase B'),
        ( 512, 'Apparent Power Phase C'),
        ( 526, 'Frequency'),
        ( 530, 'Apparent Power'),
        (1056, '100ms Current N'),
        (1057, '100ms Voltage A-B'),
        (1058, '100ms Voltage B-C'),
        (1059, '100ms Voltage C-A'),
        (1060, '100ms Voltage A-N'),
        (1061, '100ms Voltage B-N'),
        (1062, '100ms Voltage C-N'),
        (1072, '100ms True Power Factor Total'),
        (1116, 'Voltage Unbalance L-L'),
        (1117, 'Voltage Unbalance L-N'),
        (1118, 'THD Voltage L-L'),
        (1119, 'THD Voltage L-N'),
        (1199, 'Current Unbalance A'),
        (1200, 'Current Unbalance B'),
        (1201, 'Current Unbalance C'),
        (1202, 'Current Unbalance Worst'),
        (1203, 'Displacement Power Factor A'),
        (1204, 'Displacement Power Factor B'),
        (1205, 'Displacement Power Factor C'),
        (1206, 'Displacement Power Factor Total'),
        (1306, 'H11 Current A Magnitude'),
        (1308, 'H11 Current B Magnitude'),
        (1310, 'H11 Current C Magnitude'),
        (1346, 'H13 Current A Magnitude'),
        (1348, 'H13 Current B Magnitude'),
        (1350, 'H13 Current C Magnitude'),
        (1386, 'H15 Current A Magnitude'),
        (1388, 'H15 Current B Magnitude'),
        (1390, 'H15 Current C Magnitude'),
        (1706, 'H3 Current A Magnitude'),
        (1708, 'H3 Current B Magnitude'),
        (1710, 'H3 Current C Magnitude'),
        (1786, 'H5 Current A Magnitude'),
        (1788, 'H5 Current B Magnitude'),
        (1790, 'H5 Current C Magnitude'),
        (1826, 'H7 Current A Magnitude'),
        (1828, 'H7 Current B Magnitude'),
        (1830, 'H7 Current C Magnitude'),
        (1866, 'H9 Current A Magnitude'),
        (1868, 'H9 Current B Magnitude'),
        (1870, 'H9 Current C Magnitude'),
        (2034, 'THD Voltage A-B'),
        (2035, 'THD Voltage A-N'),
        (2036, 'THD Voltage B-C'),
        (2037, 'THD Voltage B-N'),
        (2038, 'THD Voltage C-A'),
        (2039, 'THD Voltage C-N'),
        (2048, 'Voltage Unbalance A-B'),
        (2049, 'Voltage Unbalance A-N'),
        (2050, 'Voltage Unbalance B-C'),
        (2051, 'Voltage Unbalance B-N'),
        (2052, 'Voltage Unbalance C-A'),
        (2053, 'Voltage Unbalance C-N'),
        (2054, 'Voltage Unbalance L-L Worst'),
        (2055, 'Voltage Unbalance L-N Worst'),
        (2097, 'THD RMS Current A'),
        (2098, 'THD RMS Current B'),
        (2099, 'THD RMS Current C'),
        (2100, 'THD RMS Current N'),
        (3324, '100ms Current Avg'),
        (3325, '100ms Power Factor A'),
        (3326, '100ms Power Factor B'),
        (3327, '100ms Power Factor C'),
        (3331, '100ms Voltage L-L Avg'),
        (3332, '100ms Voltage L-N Avg'),
        (3787, 'Water Volume Flow Rate (m^3/h)'),
        (3923, 'Water Temperature Supply (deg C)'),
        (3937, 'Water Temperature Return (deg C)'),
        (5696, 'Water Volume Supply (m^3)'),
        (5932, 'Compressed Air Norm Volume (m^3)')
    ) AS v(id, name)
    LEFT JOIN quantities q ON q.id = v.id
    WHERE q.quantity_name IS DISTINCT FROM v.name;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'quantities that are not what design/quantity_terms.csv describes: %', bad;
    END IF;

    SELECT string_agg(code, ', ') INTO bad FROM graph.derived_quantity
    WHERE code IN ('APPARENT_ENERGY_DEL_PLUS_REC', 'REACTIVE_ENERGY_DELIVERED', 'REACTIVE_ENERGY_NET', 'REACTIVE_ENERGY_RECEIVED', 'ACTIVE_ENERGY_DELIVERED', 'ACTIVE_ENERGY_NET', 'ACTIVE_ENERGY_RECEIVED', 'REACTIVE_POWER', 'REACTIVE_ENERGY_DEL_PLUS_REC', 'ACTIVE_POWER', 'ACTIVE_ENERGY_DEL_PLUS_REC', 'APPARENT_ENERGY_RECEIVED', 'APPARENT_ENERGY_DELIVERED', 'CURRENT_A', 'CURRENT_B', 'CURRENT_C', 'ACTIVE_POWER_A', 'ACTIVE_POWER_B', 'ACTIVE_POWER_C', 'REACTIVE_POWER_A', 'REACTIVE_POWER_B', 'REACTIVE_POWER_C', 'APPARENT_POWER_A', 'APPARENT_POWER_B', 'APPARENT_POWER_C', 'FREQUENCY', 'APPARENT_POWER', 'CURRENT_N', 'VOLTAGE_AB', 'VOLTAGE_BC', 'VOLTAGE_CA', 'VOLTAGE_AN', 'VOLTAGE_BN', 'VOLTAGE_CN', 'PF_TOTAL', 'VOLTAGE_UNBALANCE_LL', 'VOLTAGE_UNBALANCE_LN', 'THD_VOLTAGE_LL', 'THD_VOLTAGE_LN', 'CURRENT_UNBALANCE_A', 'CURRENT_UNBALANCE_B', 'CURRENT_UNBALANCE_C', 'CURRENT_UNBALANCE_WORST', 'DPF_A', 'DPF_B', 'DPF_C', 'DPF_TOTAL', 'H11_CURRENT_A', 'H11_CURRENT_B', 'H11_CURRENT_C', 'H13_CURRENT_A', 'H13_CURRENT_B', 'H13_CURRENT_C', 'H15_CURRENT_A', 'H15_CURRENT_B', 'H15_CURRENT_C', 'H3_CURRENT_A', 'H3_CURRENT_B', 'H3_CURRENT_C', 'H5_CURRENT_A', 'H5_CURRENT_B', 'H5_CURRENT_C', 'H7_CURRENT_A', 'H7_CURRENT_B', 'H7_CURRENT_C', 'H9_CURRENT_A', 'H9_CURRENT_B', 'H9_CURRENT_C', 'THD_VOLTAGE_AB', 'THD_VOLTAGE_AN', 'THD_VOLTAGE_BC', 'THD_VOLTAGE_BN', 'THD_VOLTAGE_CA', 'THD_VOLTAGE_CN', 'VOLTAGE_UNBALANCE_AB', 'VOLTAGE_UNBALANCE_AN', 'VOLTAGE_UNBALANCE_BC', 'VOLTAGE_UNBALANCE_BN', 'VOLTAGE_UNBALANCE_CA', 'VOLTAGE_UNBALANCE_CN', 'VOLTAGE_UNBALANCE_LL_WORST', 'VOLTAGE_UNBALANCE_LN_WORST', 'THD_CURRENT_A', 'THD_CURRENT_B', 'THD_CURRENT_C', 'THD_CURRENT_N', 'CURRENT_AVG', 'PF_A', 'PF_B', 'PF_C', 'VOLTAGE_LL_AVG', 'VOLTAGE_LN_AVG', 'WATER_FLOW_RATE', 'WATER_TEMPERATURE_SUPPLY', 'WATER_TEMPERATURE_RETURN', 'WATER_VOLUME', 'AIR_VOLUME');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'derived quantity codes that clash with a term: %', bad;
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 2.2 The vocabulary
-- ----------------------------------------------------------------------------
CREATE TABLE graph.quantity_term (
    quantity_id  INTEGER     PRIMARY KEY REFERENCES public.quantities (id),
    code         VARCHAR(40) NOT NULL UNIQUE,
    unit         VARCHAR(12),
    reading      VARCHAR(8)  NOT NULL,
    unit_basis   VARCHAR(4)  NOT NULL,
    description  TEXT        NOT NULL,
    checked_on   DATE        NOT NULL,
    CONSTRAINT ck_qt_code    CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    CONSTRAINT ck_qt_unit    CHECK (unit IN ('kWh', 'kVArh', 'kVAh', 'kW', 'kVAr', 'kVA', 'A', 'V', 'Hz', '%', 'm3', 'm3/h', '°C', 'Nm3')),
    CONSTRAINT ck_qt_reading CHECK (reading IN ('COUNTER', 'SAMPLE')),
    CONSTRAINT ck_qt_basis   CHECK (unit_basis IN ('DATA', 'NAME')),
    CONSTRAINT ck_qt_counter CHECK (reading <> 'COUNTER' OR unit IS NOT NULL)
);

COMMENT ON TABLE graph.quantity_term IS
  'What a metered quantity means, for a reader who is not an engineer: code, unit, '
  'how to read it over time. Source: design/quantity_terms.csv.';
COMMENT ON COLUMN graph.quantity_term.code IS
  'Stable readable name, offered to MCP clients in place of the PME quantity_code. '
  'Never equal to a graph.derived_quantity code.';
COMMENT ON COLUMN graph.quantity_term.unit IS
  'Unit of the stored value. NULL means dimensionless (power factor), never unknown.';
COMMENT ON COLUMN graph.quantity_term.reading IS
  'COUNTER: a lifetime register; the value over a period is its increase. '
  'SAMPLE: an instantaneous quantity, each 15-minute row aggregating about 15 one-minute samples; '
  'summarise a period with min, mean, max or a percentile, never a sum.';
COMMENT ON COLUMN graph.quantity_term.unit_basis IS
  'DATA: the unit was checked against a related quantity or a nominal value in telemetry. '
  'NAME: taken from the quantity name.';
COMMENT ON COLUMN graph.quantity_term.description IS
  'Written for the model reading a value: what it measures, sign conventions, and meter artefacts to discard.';
COMMENT ON COLUMN graph.quantity_term.checked_on IS
  'When the unit and description were last checked against telemetry.';

INSERT INTO graph.quantity_term (quantity_id, code, unit, reading, unit_basis, description, checked_on)
SELECT v.*, DATE '2026-10-02' FROM (VALUES
  (  62, 'APPARENT_ENERGY_DEL_PLUS_REC', 'kVAh', 'COUNTER', 'DATA',
         'Lifetime apparent energy in both directions; equals APPARENT_ENERGY_DELIVERED plus APPARENT_ENERGY_RECEIVED. Not additive across meters: a board''s apparent energy is not the sum of its feeders''.'),
  (  89, 'REACTIVE_ENERGY_DELIVERED', 'kVArh', 'COUNTER', 'DATA',
         'Lifetime reactive energy in the meter''s forward direction, normally from supply to load. Conserved: the flow solver sums it through the network, and with ACTIVE_ENERGY_DELIVERED it gives the derived power factor PF_TRUE.'),
  (  95, 'REACTIVE_ENERGY_NET', 'kVArh', 'COUNTER', 'DATA',
         'Lifetime net reactive energy kept by the meter, delivered minus received. Tracks REACTIVE_ENERGY_DELIVERED minus REACTIVE_ENERGY_RECEIVED but not exactly. One meter writes 92233720368547760 when the register is invalid; discard that value.'),
  (  96, 'REACTIVE_ENERGY_RECEIVED', 'kVArh', 'COUNTER', 'DATA',
         'Lifetime reactive energy against the meter''s forward direction: leading reactive energy, typically from capacitor banks overcompensating, or a source exporting.'),
  ( 124, 'ACTIVE_ENERGY_DELIVERED', 'kWh', 'COUNTER', 'DATA',
         'Lifetime active energy in the meter''s forward direction, normally from supply to load. The plant''s energy consumption: conserved, summed through the network by the flow solver, and the basis of cost reporting. Consumption over a period is the counter''s increase.'),
  ( 130, 'ACTIVE_ENERGY_NET', 'kWh', 'COUNTER', 'DATA',
         'Lifetime net active energy, delivered minus received. A redundant register of ACTIVE_ENERGY_DELIVERED (graph.quantity_alias): never use both, or the energy counts twice. One meter writes 92233720368547760 when the register is invalid; discard that value.'),
  ( 131, 'ACTIVE_ENERGY_RECEIVED', 'kWh', 'COUNTER', 'DATA',
         'Lifetime active energy against the meter''s forward direction, i.e. exported. An increase means the node exported in that period, or the meter is installed reversed.'),
  ( 179, 'REACTIVE_POWER', 'kVAr', 'SAMPLE', 'DATA',
         'Total reactive power over the three phases. Positive is lagging (inductive load), negative leading (capacitive).'),
  ( 183, 'REACTIVE_ENERGY_DEL_PLUS_REC', 'kVArh', 'COUNTER', 'DATA',
         'Lifetime reactive energy in both directions; equals REACTIVE_ENERGY_DELIVERED plus REACTIVE_ENERGY_RECEIVED.'),
  ( 185, 'ACTIVE_POWER', 'kW', 'SAMPLE', 'DATA',
         'Total active power over the three phases. Positive is consumption in the meter''s forward direction; negative means the node is exporting at that moment.'),
  ( 190, 'ACTIVE_ENERGY_DEL_PLUS_REC', 'kWh', 'COUNTER', 'DATA',
         'Lifetime active energy in both directions; equals ACTIVE_ENERGY_DELIVERED plus ACTIVE_ENERGY_RECEIVED, so the same as delivered while nothing exports. Use ACTIVE_ENERGY_DELIVERED for consumption.'),
  ( 471, 'APPARENT_ENERGY_RECEIVED', 'kVAh', 'COUNTER', 'DATA',
         'Lifetime apparent energy against the meter''s forward direction. Not additive across meters.'),
  ( 481, 'APPARENT_ENERGY_DELIVERED', 'kVAh', 'COUNTER', 'DATA',
         'Lifetime apparent energy in the meter''s forward direction. Not additive across meters: loads at different power factors do not add their kVAh linearly, so a board''s apparent energy is derived from its summed active and reactive energy, never summed from its feeders.'),
  ( 501, 'CURRENT_A', 'A', 'SAMPLE', 'DATA',
         'RMS current on phase A.'),
  ( 502, 'CURRENT_B', 'A', 'SAMPLE', 'NAME',
         'RMS current on phase B.'),
  ( 503, 'CURRENT_C', 'A', 'SAMPLE', 'NAME',
         'RMS current on phase C.'),
  ( 504, 'ACTIVE_POWER_A', 'kW', 'SAMPLE', 'NAME',
         'Active power on phase A. Negative means export on that phase.'),
  ( 505, 'ACTIVE_POWER_B', 'kW', 'SAMPLE', 'NAME',
         'Active power on phase B. Negative means export on that phase.'),
  ( 506, 'ACTIVE_POWER_C', 'kW', 'SAMPLE', 'NAME',
         'Active power on phase C. Negative means export on that phase.'),
  ( 507, 'REACTIVE_POWER_A', 'kVAr', 'SAMPLE', 'NAME',
         'Reactive power on phase A. Positive lagging, negative leading.'),
  ( 508, 'REACTIVE_POWER_B', 'kVAr', 'SAMPLE', 'NAME',
         'Reactive power on phase B. Positive lagging, negative leading.'),
  ( 509, 'REACTIVE_POWER_C', 'kVAr', 'SAMPLE', 'NAME',
         'Reactive power on phase C. Positive lagging, negative leading.'),
  ( 510, 'APPARENT_POWER_A', 'kVA', 'SAMPLE', 'DATA',
         'Apparent power on phase A: phase-to-neutral voltage times phase current.'),
  ( 511, 'APPARENT_POWER_B', 'kVA', 'SAMPLE', 'NAME',
         'Apparent power on phase B: phase-to-neutral voltage times phase current.'),
  ( 512, 'APPARENT_POWER_C', 'kVA', 'SAMPLE', 'NAME',
         'Apparent power on phase C: phase-to-neutral voltage times phase current.'),
  ( 526, 'FREQUENCY', 'Hz', 'SAMPLE', 'DATA',
         'Supply frequency; nominal 50 Hz. Zero means the meter saw no voltage, not that the frequency was zero.'),
  ( 530, 'APPARENT_POWER', 'kVA', 'SAMPLE', 'DATA',
         'Total apparent power over the three phases. The loading figure: compare it with the board''s rated_kva.'),
  (1056, 'CURRENT_N', 'A', 'SAMPLE', 'NAME',
         'RMS current in the neutral conductor. High values relative to the phase currents point to unbalanced single-phase load or triplen harmonics (H3, H9, H15).'),
  (1057, 'VOLTAGE_AB', 'V', 'SAMPLE', 'DATA',
         'Line-to-line RMS voltage between phases A and B. About 400 V on LV boards and about 20000 V on the 20 kV meters.'),
  (1058, 'VOLTAGE_BC', 'V', 'SAMPLE', 'DATA',
         'Line-to-line RMS voltage between phases B and C. About 400 V on LV boards and about 20000 V on the 20 kV meters.'),
  (1059, 'VOLTAGE_CA', 'V', 'SAMPLE', 'DATA',
         'Line-to-line RMS voltage between phases C and A. About 400 V on LV boards and about 20000 V on the 20 kV meters.'),
  (1060, 'VOLTAGE_AN', 'V', 'SAMPLE', 'DATA',
         'Phase-to-neutral RMS voltage on phase A. About 230 V on LV boards and about 11500 V on the 20 kV meters.'),
  (1061, 'VOLTAGE_BN', 'V', 'SAMPLE', 'DATA',
         'Phase-to-neutral RMS voltage on phase B. About 230 V on LV boards and about 11500 V on the 20 kV meters.'),
  (1062, 'VOLTAGE_CN', 'V', 'SAMPLE', 'DATA',
         'Phase-to-neutral RMS voltage on phase C. About 230 V on LV boards and about 11500 V on the 20 kV meters.'),
  (1072, 'PF_TOTAL', NULL, 'SAMPLE', 'DATA',
         'True power factor over the three phases, as the meter reports it: only at metered nodes. Schneider meters encode it by quadrant on -2 to 2: 0 to 1 is lagging import as is, above 1 is leading import (true PF = 2 minus the value), below -1 is lagging export (true PF = value plus 2), -1 to 0 is leading export (true PF = minus the value), and exactly -2 appears at no load. The PV loggers (PLTSC, PLTSD) report a plain signed PF instead. For a node''s power factor use the derived PF_TRUE.'),
  (1116, 'VOLTAGE_UNBALANCE_LL', '%', 'SAMPLE', 'NAME',
         'Line-to-line voltage unbalance as computed by the meter. A few percent at most on a healthy supply.'),
  (1117, 'VOLTAGE_UNBALANCE_LN', '%', 'SAMPLE', 'NAME',
         'Phase-to-neutral voltage unbalance as computed by the meter.'),
  (1118, 'THD_VOLTAGE_LL', '%', 'SAMPLE', 'NAME',
         'Total harmonic distortion of the line-to-line voltage, percent of the fundamental. A supply-side quantity: an unmetered node experiences its feeder''s value.'),
  (1119, 'THD_VOLTAGE_LN', '%', 'SAMPLE', 'NAME',
         'Total harmonic distortion of the phase-to-neutral voltage, percent of the fundamental. A supply-side quantity: an unmetered node experiences its feeder''s value.'),
  (1199, 'CURRENT_UNBALANCE_A', '%', 'SAMPLE', 'NAME',
         'Deviation of phase A current from the three-phase average, percent. Reads 200 when the current is too low to compute it; discard that value.'),
  (1200, 'CURRENT_UNBALANCE_B', '%', 'SAMPLE', 'NAME',
         'Deviation of phase B current from the three-phase average, percent. Reads 200 when the current is too low to compute it; discard that value.'),
  (1201, 'CURRENT_UNBALANCE_C', '%', 'SAMPLE', 'NAME',
         'Deviation of phase C current from the three-phase average, percent. Reads 200 when the current is too low to compute it; discard that value.'),
  (1202, 'CURRENT_UNBALANCE_WORST', '%', 'SAMPLE', 'NAME',
         'The largest of the three phase current unbalances, percent. Reads 200 when the current is too low to compute it; discard that value.'),
  (1203, 'DPF_A', NULL, 'SAMPLE', 'NAME',
         'Displacement power factor on phase A: the cosine of the angle between fundamental voltage and current, ignoring harmonics. Same -2 to 2 quadrant encoding as PF_TOTAL.'),
  (1204, 'DPF_B', NULL, 'SAMPLE', 'NAME',
         'Displacement power factor on phase B, ignoring harmonics. Same -2 to 2 quadrant encoding as PF_TOTAL.'),
  (1205, 'DPF_C', NULL, 'SAMPLE', 'NAME',
         'Displacement power factor on phase C, ignoring harmonics. Same -2 to 2 quadrant encoding as PF_TOTAL.'),
  (1206, 'DPF_TOTAL', NULL, 'SAMPLE', 'NAME',
         'Displacement power factor over the three phases, ignoring harmonics. Higher than PF_TOTAL on a load with harmonic distortion; the gap is the harmonic share. Same -2 to 2 quadrant encoding as PF_TOTAL.'),
  (1306, 'H11_CURRENT_A', '%', 'SAMPLE', 'DATA',
         '11th harmonic current on phase A, percent of the fundamental current, not amperes.'),
  (1308, 'H11_CURRENT_B', '%', 'SAMPLE', 'DATA',
         '11th harmonic current on phase B, percent of the fundamental current, not amperes.'),
  (1310, 'H11_CURRENT_C', '%', 'SAMPLE', 'DATA',
         '11th harmonic current on phase C, percent of the fundamental current, not amperes.'),
  (1346, 'H13_CURRENT_A', '%', 'SAMPLE', 'DATA',
         '13th harmonic current on phase A, percent of the fundamental current, not amperes.'),
  (1348, 'H13_CURRENT_B', '%', 'SAMPLE', 'DATA',
         '13th harmonic current on phase B, percent of the fundamental current, not amperes.'),
  (1350, 'H13_CURRENT_C', '%', 'SAMPLE', 'DATA',
         '13th harmonic current on phase C, percent of the fundamental current, not amperes.'),
  (1386, 'H15_CURRENT_A', '%', 'SAMPLE', 'DATA',
         '15th harmonic current on phase A, percent of the fundamental current, not amperes. A triplen harmonic: adds in the neutral.'),
  (1388, 'H15_CURRENT_B', '%', 'SAMPLE', 'DATA',
         '15th harmonic current on phase B, percent of the fundamental current, not amperes. A triplen harmonic: adds in the neutral.'),
  (1390, 'H15_CURRENT_C', '%', 'SAMPLE', 'DATA',
         '15th harmonic current on phase C, percent of the fundamental current, not amperes. A triplen harmonic: adds in the neutral.'),
  (1706, 'H3_CURRENT_A', '%', 'SAMPLE', 'DATA',
         '3rd harmonic current on phase A, percent of the fundamental current, not amperes. A triplen harmonic: adds in the neutral; typical of single-phase electronic loads.'),
  (1708, 'H3_CURRENT_B', '%', 'SAMPLE', 'DATA',
         '3rd harmonic current on phase B, percent of the fundamental current, not amperes. A triplen harmonic: adds in the neutral; typical of single-phase electronic loads.'),
  (1710, 'H3_CURRENT_C', '%', 'SAMPLE', 'DATA',
         '3rd harmonic current on phase C, percent of the fundamental current, not amperes. A triplen harmonic: adds in the neutral; typical of single-phase electronic loads.'),
  (1786, 'H5_CURRENT_A', '%', 'SAMPLE', 'DATA',
         '5th harmonic current on phase A, percent of the fundamental current, not amperes. Typical of six-pulse drives (VFDs).'),
  (1788, 'H5_CURRENT_B', '%', 'SAMPLE', 'DATA',
         '5th harmonic current on phase B, percent of the fundamental current, not amperes. Typical of six-pulse drives (VFDs).'),
  (1790, 'H5_CURRENT_C', '%', 'SAMPLE', 'DATA',
         '5th harmonic current on phase C, percent of the fundamental current, not amperes. Typical of six-pulse drives (VFDs).'),
  (1826, 'H7_CURRENT_A', '%', 'SAMPLE', 'DATA',
         '7th harmonic current on phase A, percent of the fundamental current, not amperes. Typical of six-pulse drives (VFDs).'),
  (1828, 'H7_CURRENT_B', '%', 'SAMPLE', 'DATA',
         '7th harmonic current on phase B, percent of the fundamental current, not amperes. Typical of six-pulse drives (VFDs).'),
  (1830, 'H7_CURRENT_C', '%', 'SAMPLE', 'DATA',
         '7th harmonic current on phase C, percent of the fundamental current, not amperes. Typical of six-pulse drives (VFDs).'),
  (1866, 'H9_CURRENT_A', '%', 'SAMPLE', 'DATA',
         '9th harmonic current on phase A, percent of the fundamental current, not amperes. A triplen harmonic: adds in the neutral.'),
  (1868, 'H9_CURRENT_B', '%', 'SAMPLE', 'DATA',
         '9th harmonic current on phase B, percent of the fundamental current, not amperes. A triplen harmonic: adds in the neutral.'),
  (1870, 'H9_CURRENT_C', '%', 'SAMPLE', 'DATA',
         '9th harmonic current on phase C, percent of the fundamental current, not amperes. A triplen harmonic: adds in the neutral.'),
  (2034, 'THD_VOLTAGE_AB', '%', 'SAMPLE', 'NAME',
         'Total harmonic distortion of the A-B line-to-line voltage, percent of the fundamental.'),
  (2035, 'THD_VOLTAGE_AN', '%', 'SAMPLE', 'NAME',
         'Total harmonic distortion of the phase A to neutral voltage, percent of the fundamental.'),
  (2036, 'THD_VOLTAGE_BC', '%', 'SAMPLE', 'NAME',
         'Total harmonic distortion of the B-C line-to-line voltage, percent of the fundamental.'),
  (2037, 'THD_VOLTAGE_BN', '%', 'SAMPLE', 'NAME',
         'Total harmonic distortion of the phase B to neutral voltage, percent of the fundamental.'),
  (2038, 'THD_VOLTAGE_CA', '%', 'SAMPLE', 'NAME',
         'Total harmonic distortion of the C-A line-to-line voltage, percent of the fundamental.'),
  (2039, 'THD_VOLTAGE_CN', '%', 'SAMPLE', 'NAME',
         'Total harmonic distortion of the phase C to neutral voltage, percent of the fundamental.'),
  (2048, 'VOLTAGE_UNBALANCE_AB', '%', 'SAMPLE', 'NAME',
         'Deviation of the A-B voltage from the line-to-line average, percent.'),
  (2049, 'VOLTAGE_UNBALANCE_AN', '%', 'SAMPLE', 'NAME',
         'Deviation of the A-N voltage from the phase-to-neutral average, percent.'),
  (2050, 'VOLTAGE_UNBALANCE_BC', '%', 'SAMPLE', 'NAME',
         'Deviation of the B-C voltage from the line-to-line average, percent.'),
  (2051, 'VOLTAGE_UNBALANCE_BN', '%', 'SAMPLE', 'NAME',
         'Deviation of the B-N voltage from the phase-to-neutral average, percent.'),
  (2052, 'VOLTAGE_UNBALANCE_CA', '%', 'SAMPLE', 'NAME',
         'Deviation of the C-A voltage from the line-to-line average, percent.'),
  (2053, 'VOLTAGE_UNBALANCE_CN', '%', 'SAMPLE', 'NAME',
         'Deviation of the C-N voltage from the phase-to-neutral average, percent.'),
  (2054, 'VOLTAGE_UNBALANCE_LL_WORST', '%', 'SAMPLE', 'NAME',
         'The largest of the three line-to-line voltage unbalances, percent.'),
  (2055, 'VOLTAGE_UNBALANCE_LN_WORST', '%', 'SAMPLE', 'NAME',
         'The largest of the three phase-to-neutral voltage unbalances, percent.'),
  (2097, 'THD_CURRENT_A', '%', 'SAMPLE', 'DATA',
         'Total harmonic distortion of the phase A current, percent of the fundamental. The name says RMS current but the value is a percentage. Reads 1000 when the current is too low to compute it; discard that value. Combines across feeders as root-sum-square, not a sum.'),
  (2098, 'THD_CURRENT_B', '%', 'SAMPLE', 'DATA',
         'Total harmonic distortion of the phase B current, percent of the fundamental, not amperes. Reads 1000 when the current is too low to compute it; discard that value.'),
  (2099, 'THD_CURRENT_C', '%', 'SAMPLE', 'DATA',
         'Total harmonic distortion of the phase C current, percent of the fundamental, not amperes. Reads 1000 when the current is too low to compute it; discard that value.'),
  (2100, 'THD_CURRENT_N', '%', 'SAMPLE', 'NAME',
         'Total harmonic distortion of the neutral current, percent of its fundamental. Large values are normal when the neutral carries little fundamental current.'),
  (3324, 'CURRENT_AVG', 'A', 'SAMPLE', 'NAME',
         'Average RMS current of the three phases.'),
  (3325, 'PF_A', NULL, 'SAMPLE', 'NAME',
         'True power factor on phase A, as the meter reports it. Same -2 to 2 quadrant encoding as PF_TOTAL.'),
  (3326, 'PF_B', NULL, 'SAMPLE', 'NAME',
         'True power factor on phase B, as the meter reports it. Same -2 to 2 quadrant encoding as PF_TOTAL.'),
  (3327, 'PF_C', NULL, 'SAMPLE', 'NAME',
         'True power factor on phase C, as the meter reports it. Same -2 to 2 quadrant encoding as PF_TOTAL.'),
  (3331, 'VOLTAGE_LL_AVG', 'V', 'SAMPLE', 'DATA',
         'Average of the three line-to-line RMS voltages. About 400 V on LV boards and about 20000 V on the 20 kV meters.'),
  (3332, 'VOLTAGE_LN_AVG', 'V', 'SAMPLE', 'DATA',
         'Average of the three phase-to-neutral RMS voltages. About 230 V on LV boards and about 11500 V on the 20 kV meters.'),
  (3787, 'WATER_FLOW_RATE', 'm3/h', 'SAMPLE', 'DATA',
         'Instantaneous water flow through the metered pipe. A rate: never sum it over time; use WATER_VOLUME for how much water passed. Small negative values are meter noise at zero flow.'),
  (3923, 'WATER_TEMPERATURE_SUPPLY', '°C', 'SAMPLE', 'NAME',
         'Water temperature on the supply side of the meter.'),
  (3937, 'WATER_TEMPERATURE_RETURN', '°C', 'SAMPLE', 'NAME',
         'Water temperature on the return side of the meter.'),
  (5696, 'WATER_VOLUME', 'm3', 'COUNTER', 'DATA',
         'Lifetime water volume through the metered pipe. Conserved: the flow solver sums it through the water network. Volume over a period is the counter''s increase, with overflow and resets handled by telemetry_intervals_water. A counter that is negative or does not move points to a faulty meter, not to zero flow.'),
  (5932, 'AIR_VOLUME', 'Nm3', 'COUNTER', 'NAME',
         'Lifetime compressed air volume at normal reference conditions as set in the meter. No meter reports it yet; it is here because its flow rule exists (migration 023).')
) AS v(quantity_id, code, unit, reading, unit_basis, description);

-- ----------------------------------------------------------------------------
-- 2.3 A quantity the solver interprets must be described
-- ----------------------------------------------------------------------------
ALTER TABLE graph.quantity_rule
    ADD CONSTRAINT fk_quantity_rule_term
    FOREIGN KEY (quantity_id) REFERENCES graph.quantity_term (quantity_id);

-- ----------------------------------------------------------------------------
-- 2.4 Derived quantities get a unit and a description
-- ----------------------------------------------------------------------------
ALTER TABLE graph.derived_quantity ADD COLUMN unit VARCHAR(12), ADD COLUMN description TEXT;

UPDATE graph.derived_quantity
   SET description = 'Power factor of a node over a period, computed from its active energy '
                  || '(ACTIVE_ENERGY_DELIVERED) and reactive energy (REACTIVE_ENERGY_DELIVERED) as '
                  || 'P / sqrt(P^2 + Q^2). Both are solved through the network, so it exists at '
                  || 'every node, metered or not, and a board''s value weights its feeders by their '
                  || 'energy. Dimensionless, 0 to 1; it does not say whether the node was leading '
                  || 'or lagging. Prefer it to the meter''s PF_TOTAL for anything above one meter.'
 WHERE code = 'PF_TRUE';

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM graph.derived_quantity WHERE description IS NULL) THEN
        RAISE EXCEPTION 'derived quantities without a description: %',
            (SELECT string_agg(code, ', ') FROM graph.derived_quantity WHERE description IS NULL);
    END IF;
END
$$;

ALTER TABLE graph.derived_quantity ALTER COLUMN description SET NOT NULL;
COMMENT ON COLUMN graph.derived_quantity.unit IS
  'Unit of the derived value. NULL means dimensionless, never unknown.';

-- ----------------------------------------------------------------------------
-- 2.5 One namespace for term and derived codes
-- ----------------------------------------------------------------------------
CREATE FUNCTION graph.assert_quantity_code() RETURNS TRIGGER AS $$
BEGIN
    IF TG_TABLE_NAME = 'quantity_term'
       AND EXISTS (SELECT 1 FROM graph.derived_quantity d WHERE d.code = NEW.code) THEN
        RAISE EXCEPTION 'quantity_term: % is already a derived_quantity code', NEW.code;
    END IF;
    IF TG_TABLE_NAME = 'derived_quantity'
       AND EXISTS (SELECT 1 FROM graph.quantity_term t WHERE t.code = NEW.code) THEN
        RAISE EXCEPTION 'derived_quantity: % is already a quantity_term code', NEW.code;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_quantity_term_code
    BEFORE INSERT OR UPDATE OF code ON graph.quantity_term
    FOR EACH ROW EXECUTE FUNCTION graph.assert_quantity_code();
CREATE TRIGGER trg_derived_quantity_code
    BEFORE INSERT OR UPDATE OF code ON graph.derived_quantity
    FOR EACH ROW EXECUTE FUNCTION graph.assert_quantity_code();

-- ----------------------------------------------------------------------------
-- 2.6 Grants -- the reports and the MCP server run as grafReader
-- ----------------------------------------------------------------------------
GRANT SELECT ON graph.quantity_term TO "grafReader";

COMMIT;


-- ============================================================================
-- 3. Verification (read-only: each refusal test runs in a block that is undone)
-- ============================================================================

\echo ''
\echo '=== 3.1 The vocabulary by reading and unit ==='
SELECT reading, coalesce(unit, '(dimensionless)') AS unit, count(*) AS terms
FROM graph.quantity_term GROUP BY 1, 2 ORDER BY 1, 2;
-- expect 97 terms in all

\echo ''
\echo '=== 3.2 Every flow rule has a term ==='
SELECT qr.quantity_id, t.code, t.unit, qr.network_agg
FROM graph.quantity_rule qr LEFT JOIN graph.quantity_term t USING (quantity_id)
ORDER BY 1;
-- expect 11 rows, no NULL code

\echo ''
\echo '=== 3.3 Derived quantities ==='
SELECT code, unit, left(description, 70) AS description FROM graph.derived_quantity;
-- expect PF_TRUE, unit NULL, with a description

\echo ''
\echo '=== 3.4 Each guard refuses what it should ==='
DO $chk$
DECLARE
    probes TEXT[] := ARRAY[
        $$INSERT INTO graph.quantity_rule VALUES (1, 'ELECTRICITY', 'AVG', 'NONE', FALSE)$$,
        $$UPDATE graph.quantity_term SET code = 'PF_TRUE' WHERE quantity_id = 1072$$,
        $$UPDATE graph.derived_quantity SET code = 'PF_TOTAL' WHERE code = 'PF_TRUE'$$,
        $$UPDATE graph.quantity_term SET unit = 'kwh' WHERE quantity_id = 124$$,
        $$UPDATE graph.quantity_term SET unit = NULL WHERE quantity_id = 124$$
    ];
    p TEXT;
BEGIN
    FOREACH p IN ARRAY probes LOOP
        BEGIN
            EXECUTE p;
            RAISE EXCEPTION 'not refused: %', p;
        EXCEPTION
            WHEN raise_exception OR foreign_key_violation OR check_violation THEN
                IF SQLERRM LIKE 'not refused:%' THEN RAISE; END IF;
                RAISE NOTICE 'refused, as it should be: %  (%)', p, SQLERRM;
        END;
    END LOOP;
END
$chk$;
-- expect five "refused" notices: a rule for an undescribed quantity, a term code
-- that is a derived code and the reverse, a unit outside the list, and a counter
-- without a unit


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- DROP TRIGGER trg_derived_quantity_code ON graph.derived_quantity;
-- DROP TRIGGER trg_quantity_term_code ON graph.quantity_term;
-- DROP FUNCTION graph.assert_quantity_code();
-- ALTER TABLE graph.derived_quantity DROP COLUMN description, DROP COLUMN unit;
-- ALTER TABLE graph.quantity_rule DROP CONSTRAINT fk_quantity_rule_term;
-- DROP TABLE graph.quantity_term;
-- COMMIT;
