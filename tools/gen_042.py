#!/usr/bin/env python3
"""Emit migrations/042_node_type_descriptions.sql from design/node_type_descriptions.csv.

Regenerate from here; do not hand-edit the .sql. Same discipline as gen_030.py
and gen_037.py: the CSV the user reviewed is the source of truth and the
migration is a mechanical rendering of it, so the two cannot drift.
"""
import csv
import pathlib
import re
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent.parent          # the o-mcp folder
CSV = HERE / "design/node_type_descriptions.csv"
OUT = HERE / "migrations/042_node_type_descriptions.sql"
WRITTEN_ON = "2026-10-06"

BASES = ["ONTOLOGY", "GRAPH", "OPEN"]


def lit(s):
    return "'" + s.replace("'", "''") + "'"


def comment(s, prefix):
    """Wrap s into SQL comment lines of about 90 columns, each starting with prefix."""
    out, line = [], prefix
    for word in s.split():
        if len(line) + len(word) + 1 > 90 and line.strip() != prefix.strip():
            out.append(line.rstrip())
            line = prefix
        line += word + " "
    out.append(line.rstrip())
    return "\n".join(out)


rows = list(csv.DictReader(CSV.open(encoding="utf-8")))
for r in rows:
    where = r["code"]
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", r["code"]):
        raise SystemExit(f"{where}: code must be UPPER_SNAKE")
    for col in ("current", "proposed"):
        if not r[col].strip():
            raise SystemExit(f"{where}: empty {col}")
        if "\n" in r[col]:
            raise SystemExit(f"{where}: {col} must be one line")
    if r["proposed"] == r["current"]:
        raise SystemExit(f"{where}: proposed equals current")
    bad = [b for b in r["basis"].split(";") if b not in BASES]
    if bad:
        raise SystemExit(f"{where}: basis {bad} not in {BASES}")
dup = [k for k, n in Counter(r["code"] for r in rows).items() if n > 1]
if dup:
    raise SystemExit(f"duplicate code: {dup}")

n = len(rows)
codes = ", ".join(r["code"] for r in rows)

guard_values = ",\n".join(
    f"        ({lit(r['code'])}, {lit(r['node_class'])},\n"
    f"         {lit(r['current'])})"
    for r in rows)

updates = "\n\n".join(
    f"-- {r['code']} ({r['node_class']}, {r['nodes']} node{'' if r['nodes'] == '1' else 's'}; "
    f"basis {r['basis'].replace(';', ', ')})\n"
    + comment(r["notes"], "--   ") + "\n"
    f"UPDATE graph.node_type SET description =\n"
    f"    {lit(r['proposed'])}\n"
    f" WHERE code = {lit(r['code'])};"
    for r in rows)

undo = "\n".join(
    f"-- UPDATE graph.node_type SET description = {lit(r['current'])} WHERE code = {lit(r['code'])};"
    for r in rows)

open_codes = ", ".join(r["code"] for r in rows if "OPEN" in r["basis"].split(";"))

sql = f"""\
-- Migration: 042_node_type_descriptions.sql
-- Description: Replace the {n} one-line node type descriptions that restated the type's name.
-- Author: Claude
-- Date: {WRITTEN_ON}
-- Design: design/node_type_descriptions.csv (rendered by tools/gen_042.py; regenerate, never
--         hand-edit); design/type-property.md, "When a new type is justified";
--         design/mcp-tools.md
-- Requires: 041_node_type_is_abstract.sql
--
-- WHY
-- ---
-- graph.node_type.description is what the MCP server gives a model to say what a
-- node is. {n} of the 27 said no more than the code ("Pump load.", "Stored water."),
-- so a model would fill the gap from general knowledge: that a PRODUCTION_MACHINE
-- is one machine, that a WATER_INTAKE is a well, that a PUMP node's energy moves
-- the water on the water graph. Each new description says what the type covers,
-- how it sits in the graph, and what may not be inferred from it.
--
-- Each claim has a basis, recorded per row below and in the CSV:
--   ONTOLOGY  what the type means in any tenant;
--   GRAPH     how its nodes are joined (edge types, metering, what the solver does);
--   OPEN      a question the site has not answered, stated as such so a model
--             does not answer it: {open_codes}.
-- The descriptions are tenant-neutral, since node_type is shared; tenant 3's
-- names and counts stay in the CSV notes, repeated here as comments.
--
-- PRODUCTION_MACHINE and WATER_INTAKE are provisional, not abstract: their nodes
-- keep them until subtypes exist and the nodes are retyped (041 refuses the other
-- order). Descriptions only: no type, class, property or node changes.

\\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\\echo ''
\\echo '=== 1.1 The descriptions being replaced ==='
SELECT code, node_class, description FROM graph.node_type
WHERE code IN ({", ".join(lit(r["code"]) for r in rows)})
ORDER BY 1;
-- expect {n} rows: {codes}


-- ============================================================================
-- 2. Change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run unless each type still has the class and description the
--     CSV's "current" column records
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    bad TEXT;
BEGIN
    SELECT string_agg(format('%s (expected %s %L, found %s %L)',
                             v.code, v.node_class, v.description, t.node_class, t.description),
                      '; ' ORDER BY v.code)
      INTO bad
    FROM (VALUES
{guard_values}
    ) AS v(code, node_class, description)
    LEFT JOIN graph.node_type t ON t.code = v.code
    WHERE t.node_class IS DISTINCT FROM v.node_class
       OR t.description IS DISTINCT FROM v.description;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'node types that are not what design/node_type_descriptions.csv describes: %', bad;
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 2.2 The descriptions
-- ----------------------------------------------------------------------------

{updates}

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\\echo ''
\\echo '=== 3.1 The new descriptions ==='
SELECT code, length(description) AS chars, left(description, 80) AS starts
FROM graph.node_type
WHERE code IN ({", ".join(lit(r["code"]) for r in rows)})
ORDER BY 1;
-- expect {n} rows

\\echo ''
\\echo '=== 3.2 Every type has a description of more than one short sentence ==='
SELECT code, description FROM graph.node_type
WHERE description IS NULL OR length(description) < 60
ORDER BY 1;
-- expect GRID_INCOMER, MAIN_LV_BOARD, PV_PLANT only: short but specific, not part of this pass

\\echo ''
\\echo '=== 3.3 Nothing else moved ==='
SELECT count(*) AS types, count(*) FILTER (WHERE is_abstract) AS abstract FROM graph.node_type;
SELECT status, count(*) FROM graph.v_property_gaps GROUP BY 1 ORDER BY 1;
SELECT count(*) AS edge_gaps FROM graph.v_edge_gaps;
-- expect 27 types, 2 abstract; MISSING 31; 0 edge gaps


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
{undo}
-- COMMIT;
"""

OUT.write_text(sql, encoding="utf-8")
print(f"wrote {OUT.relative_to(HERE)}: {n} descriptions")
