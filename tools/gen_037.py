#!/usr/bin/env python3
"""Emit migrations/037_create_quantity_term.sql from design/quantity_terms.csv.

Regenerate from here; do not hand-edit the .sql. Same discipline as gen_030.py:
the CSV the user reviewed is the source of truth and the migration is a
mechanical rendering of it, so the two cannot drift.
"""
import csv
import pathlib
import re
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent.parent          # the o-mcp folder
CSV = HERE / "design/quantity_terms.csv"
OUT = HERE / "migrations/037_create_quantity_term.sql"
CHECKED_ON = "2026-10-02"

UNITS = ["kWh", "kVArh", "kVAh", "kW", "kVAr", "kVA", "A", "V", "Hz", "%",
         "m3", "m3/h", "°C", "Nm3"]
READINGS = ["COUNTER", "SAMPLE"]
BASES = ["DATA", "NAME"]


def lit(s):
    return "NULL" if s is None else "'" + s.replace("'", "''") + "'"


rows = list(csv.DictReader(CSV.open(encoding="utf-8")))
for r in rows:
    where = f"{r['quantity_id']} {r['code']}"
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", r["code"]):
        raise SystemExit(f"{where}: code must be UPPER_SNAKE")
    if r["unit"] and r["unit"] not in UNITS:
        raise SystemExit(f"{where}: unit {r['unit']!r} is not one of {UNITS}")
    if r["reading"] not in READINGS:
        raise SystemExit(f"{where}: reading {r['reading']!r}")
    if r["unit_basis"] not in BASES:
        raise SystemExit(f"{where}: unit_basis {r['unit_basis']!r}")
    if not r["description"].strip():
        raise SystemExit(f"{where}: empty description")
    if r["reading"] == "COUNTER" and not r["unit"]:
        raise SystemExit(f"{where}: a counter needs a unit")
for col in ("quantity_id", "code"):
    dup = [k for k, n in Counter(r[col] for r in rows).items() if n > 1]
    if dup:
        raise SystemExit(f"duplicate {col}: {dup}")

rows.sort(key=lambda r: int(r["quantity_id"]))
n = len(rows)

guard_values = ",\n".join(
    f"        ({int(r['quantity_id']):>4}, {lit(r['quantity_name'])})" for r in rows)

insert_values = ",\n".join(
    f"  ({int(r['quantity_id']):>4}, {lit(r['code'])}, {lit(r['unit'] or None)}, "
    f"{lit(r['reading'])}, {lit(r['unit_basis'])},\n"
    f"         {lit(r['description'])})"
    for r in rows)

tally_unit = "\n".join(
    f"--   {c:>3}  {u or '(dimensionless)'}"
    for u, c in Counter(r["unit"] for r in rows).most_common())
tally_reading = Counter(r["reading"] for r in rows)
tally_basis = Counter(r["unit_basis"] for r in rows)

sql = f"""\
-- Migration: 037_create_quantity_term.sql
-- Description: A vocabulary for the quantities the meters report: a readable code, a unit,
--              how a value is read over time, and a description for each.
-- Author: Claude
-- Date: {CHECKED_ON}
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
-- Scope: the {n - 1} quantities tenant 3's meters reported in the week of
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
-- {tally_reading['COUNTER']} COUNTER and {tally_reading['SAMPLE']} SAMPLE readings;
-- units by {tally_basis['DATA']} DATA and {tally_basis['NAME']} NAME.
{tally_unit}
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

\\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\\echo ''
\\echo '=== 1.1 Quantities with a flow rule, and their names ==='
SELECT qr.quantity_id, q.quantity_name, q.unit, qr.raw_time_agg, qr.network_agg, qr.conserved
FROM graph.quantity_rule qr JOIN quantities q ON q.id = qr.quantity_id
ORDER BY 1;
-- expect 11 rows: 62 89 96 124 131 481 1072 1119 2097 5696 5932

\\echo ''
\\echo '=== 1.2 Units in public.quantities ==='
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
{guard_values}
    ) AS v(id, name)
    LEFT JOIN quantities q ON q.id = v.id
    WHERE q.quantity_name IS DISTINCT FROM v.name;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'quantities that are not what design/quantity_terms.csv describes: %', bad;
    END IF;

    SELECT string_agg(code, ', ') INTO bad FROM graph.derived_quantity
    WHERE code IN ({", ".join(lit(r["code"]) for r in rows)});
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
    CONSTRAINT ck_qt_unit    CHECK (unit IN ({", ".join(lit(u) for u in UNITS)})),
    CONSTRAINT ck_qt_reading CHECK (reading IN ({", ".join(lit(x) for x in READINGS)})),
    CONSTRAINT ck_qt_basis   CHECK (unit_basis IN ({", ".join(lit(x) for x in BASES)})),
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
SELECT v.*, DATE '{CHECKED_ON}' FROM (VALUES
{insert_values}
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

\\echo ''
\\echo '=== 3.1 The vocabulary by reading and unit ==='
SELECT reading, coalesce(unit, '(dimensionless)') AS unit, count(*) AS terms
FROM graph.quantity_term GROUP BY 1, 2 ORDER BY 1, 2;
-- expect {n} terms in all

\\echo ''
\\echo '=== 3.2 Every flow rule has a term ==='
SELECT qr.quantity_id, t.code, t.unit, qr.network_agg
FROM graph.quantity_rule qr LEFT JOIN graph.quantity_term t USING (quantity_id)
ORDER BY 1;
-- expect 11 rows, no NULL code

\\echo ''
\\echo '=== 3.3 Derived quantities ==='
SELECT code, unit, left(description, 70) AS description FROM graph.derived_quantity;
-- expect PF_TRUE, unit NULL, with a description

\\echo ''
\\echo '=== 3.4 Each guard refuses what it should ==='
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
"""

OUT.write_text(sql, encoding="utf-8")
print(f"wrote {OUT.relative_to(HERE)}: {n} terms")
