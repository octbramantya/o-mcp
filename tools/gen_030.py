#!/usr/bin/env python3
"""Emit ../prs_diags/docs/database/migrations/030_type_loads.sql from design/draft_load_types.csv.

Regenerate from here; do not hand-edit the .sql. Same discipline as gen_028.py:
the CSV the user reviewed is the source of truth and the migration is a
mechanical rendering of it, so the two cannot drift.
"""
import csv
import pathlib
import textwrap
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent.parent          # the o-mcp folder
PRS  = HERE.parent / "prs_diags"                              # the sibling repo
CSV = HERE / "design/draft_load_types.csv"
OUT = PRS / "docs/database/migrations/030_type_loads.sql"

# node_class for each target type. Only AIR_COMPRESSOR and SUB_BOARD are class
# changes; every other target is already LOAD-classed, so the node keeps its class.
CLASS_OF = {
    "PRODUCTION_MACHINE": "LOAD",
    "AHU": "LOAD",
    "LIGHTING": "LOAD",
    "PUMP": "LOAD",
    "GENERIC_LOAD": "LOAD",
    "PROCESS_HEATER": "LOAD",       # new in this migration
    "WATER_PROCESS": "LOAD",        # new in this migration
    "AIR_COMPRESSOR": "CONVERSION",
    "SUB_BOARD": "BUS",
}

rows = list(csv.DictReader(CSV.open()))
plan = []
for r in rows:
    t = r["proposed_type"].replace(" (class change)", "").strip()
    if t not in CLASS_OF:
        raise SystemExit(f"{r['node_code']}: unknown proposed_type {t!r}")
    plan.append((r["node_code"], t, CLASS_OF[t], r["node_class"]))

if len({c for c, *_ in plan}) != len(plan):
    raise SystemExit("duplicate node_code in the CSV")

plan.sort()
moved = [p for p in plan if p[2] != p[3]]
kept = [p for p in plan if p[2] == p[3]]
tally = Counter(t for _, t, _, _ in plan)
width = max(len(c) for c, _, _, _ in plan)

plan_values = ",\n".join(
    f"    ({repr(c):<{width + 2}}, {t!r:<20}, {cls!r})" for c, t, cls, _ in plan
).replace('"', "'")

tally_lines = "\n".join(
    f"--   {n:>3}  {t}" + ("   (node_class change)" if CLASS_OF[t] != "LOAD" else "")
    for t, n in tally.most_common()
)
moved_list = ", ".join(f"'{c}'" for c, _, _, _ in moved)

# Exactly what string_agg(format('%s %s->%s', ...) ORDER BY node_code) must produce
# if this migration did what it says. Anything else aborts.
expected_moves = "; ".join(f"{c} {old}->{new}" for c, _, new, old in moved)

undo_kept = "\n".join(
    "--       " + line
    for line in textwrap.wrap(", ".join(f"'{c}'" for c, _, _, _ in kept), width=78)
)

sql = f"""\
-- Migration: 030_type_loads.sql
-- Description: Give every remaining untyped node a node_type.
-- Author: Claude
-- Date: 2026-09-29
-- Design: ../o-mcp/design/edge-type.md; ../o-mcp/design/draft_load_types.csv
-- Requires: 029_fix_edge_gaps_window.sql
--
-- WHY
-- ---
-- 026 created the node_type vocabulary and 028 the edge_type vocabulary, but
-- {len(plan)} nodes were still untyped. Each is reachable only by node_code -- which
-- means reachable only by someone who already knows the name -- and each is the
-- reason a graph.v_edge_gaps row reads ENDPOINT_UNTYPED instead of being checked
-- against an endpoint rule.
--
-- The types here are a reviewed first pass, not a site-verified inventory. That
-- is deliberate: a complete assessment would take months, and a type that is
-- mostly right today is worth more than a null that is unarguable. Retyping is
-- one UPDATE and nothing downstream caches it.
--
{tally_lines}
--
-- Two of the {len(plan)} are inactive: MC302_BARU and MC303_BARU, whose every edge
-- carries effective_to = '-infinity'. By this graph's convention that means they
-- were never true -- they came from the SLD that was later redrawn, not from a
-- decommissioning. They are typed anyway: node_type is descriptive, a null would
-- put the "every node is typed" invariant permanently out of reach, and an as-of
-- query should still be able to name what the wrong SLD claimed was there.
--
-- WHAT THIS COSTS
-- ---------------
-- Typing has one consequence, and it is the wanted one. The {len(moved)} reclassified
-- nodes acquire REQUIRED properties they do not have:
--
--   AIR_COMPRESSOR needs rated_kw       (harmonics_report.py rating fallback)
--   SUB_BOARD      needs main_breaker_a (harmonics_report.py loading denominator)
--                  and nominal_v        (harmonics_report.py, layered_report.py)
--
-- so graph.v_property_gaps gains MISSING rows while losing every UNTYPED one.
-- That is the payoff: "I do not know what this is" becomes a named question with
-- a named reader. Section 3.4 prints the exact list rather than asserting a count.
--
-- SAFETY
-- ------
-- 1. node_class is NOT read by graph.solve_flow or graph.get_node_quantity. Both
--    function bodies were dumped and checked: node_class is carried through the
--    result set and never branched on. The class changes cannot move a number.
-- 2. Every endpoint rule that terminates at a load uses the kind 'LOAD', and
--    graph.v_edge_gaps matches from_kind/to_kind against (node_type, node_class).
--    A LOAD-classed node keeps matching after typing, so no rule can start
--    failing. The class changes are checked by name in 2.5 and by rule in 2.5.
-- 3. graph.assert_node_attrs() rejects an attrs key that is not a property of the
--    new type, which would abort the UPDATE on the first offender. Section 2.2
--    tests the same condition for every row up front, so a failure names all of
--    them at once instead of one per attempt.
-- 4. PROCESS_HEATER and WATER_PROCESS are seeded with parent_code NULL, so they
--    inherit nothing. PROCESS_HEATER gets two OPTIONAL properties and therefore
--    still contributes no gap rows.

\\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\\echo ''
\\echo '=== 1.1 Untyped nodes before ==='
SELECT node_class, is_active, count(*) FROM graph.node
WHERE tenant_id = 3 AND node_type IS NULL GROUP BY 1, 2 ORDER BY 1, 2;
-- expect {len(plan)} in total, all LOAD, two of them inactive

\\echo ''
\\echo '=== 1.2 Edge gap counts before ==='
SELECT status, count(*) FROM graph.v_edge_gaps WHERE tenant_id = 3
GROUP BY 1 ORDER BY 1;

\\echo ''
\\echo '=== 1.3 Property gap counts before ==='
SELECT status, count(*) FROM graph.v_property_gaps WHERE tenant_id = 3
GROUP BY 1 ORDER BY 1;


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 The plan, as data
-- ----------------------------------------------------------------------------
-- One list, used by the precondition, the UPDATE and the post-conditions alike,
-- so the three cannot disagree about what was supposed to happen.

CREATE TEMP TABLE _plan (
    node_code  VARCHAR(60) PRIMARY KEY,
    node_type  VARCHAR(40) NOT NULL,
    node_class VARCHAR(20) NOT NULL
) ON COMMIT DROP;

INSERT INTO _plan (node_code, node_type, node_class) VALUES
{plan_values};

CREATE TEMP TABLE _before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM graph.node WHERE tenant_id = 3)        AS nodes,
       (SELECT count(*) FROM graph.edge WHERE tenant_id = 3)        AS edges,
       (SELECT count(*) FROM graph.v_edge_gaps WHERE tenant_id = 3) AS edge_gaps,
       (SELECT count(*) FROM graph.v_property_gaps
         WHERE tenant_id = 3 AND status <> 'UNTYPED')               AS prop_gaps_typed;

-- The node_class each planned node has right now, so 2.5 can prove that exactly
-- the intended nodes moved and nothing else did.
CREATE TEMP TABLE _class_before ON COMMIT DROP AS
SELECT n.node_code, n.node_class FROM graph.node n
JOIN _plan p ON p.node_code = n.node_code WHERE n.tenant_id = 3;

-- ----------------------------------------------------------------------------
-- 2.2 Preconditions
-- ----------------------------------------------------------------------------

DO $pre$
DECLARE
    n   INTEGER;
    bad TEXT;
BEGIN
    -- The CSV must describe exactly the nodes that are untyped. Fewer means the
    -- database moved on; more means the CSV names something that no longer exists.
    SELECT string_agg(node_code, ', ' ORDER BY node_code) INTO bad
      FROM (SELECT node_code FROM graph.node
             WHERE tenant_id = 3 AND node_type IS NULL
            EXCEPT SELECT node_code FROM _plan) q;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'untyped in the database but absent from the plan: %', bad;
    END IF;

    SELECT string_agg(p.node_code, ', ' ORDER BY p.node_code) INTO bad
      FROM _plan p LEFT JOIN graph.node n
        ON n.tenant_id = 3 AND n.node_code = p.node_code AND n.node_type IS NULL
     WHERE n.id IS NULL;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'in the plan but not an untyped node: %', bad;
    END IF;

    -- The same test graph.assert_node_attrs() applies, but for every row at once.
    SELECT string_agg(format('%s.%s -> %s', p.node_code, a.k, p.node_type), '; '
                      ORDER BY p.node_code) INTO bad
      FROM _plan p
      JOIN graph.node n ON n.tenant_id = 3 AND n.node_code = p.node_code
      CROSS JOIN LATERAL jsonb_object_keys(n.attrs) AS a (k)
     WHERE NOT EXISTS (SELECT 1 FROM graph.v_type_property t
                        WHERE t.node_type = p.node_type AND t.attr_key = a.k);
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'attrs the target type does not permit: %', bad;
    END IF;

    SELECT count(*) INTO n FROM _plan;
    RAISE NOTICE 'preconditions OK: % nodes to type', n;
END $pre$;

-- ----------------------------------------------------------------------------
-- 2.3 Two new types under LOAD
-- ----------------------------------------------------------------------------
-- Neither gets a parent_code. PROCESS_HEATER could sit under a future
-- THERMAL_LOAD and WATER_PROCESS under a WATER_LOAD, but an abstract parent with
-- one child is vocabulary nobody reads. Add the parent when a second child exists.

INSERT INTO graph.node_type (code, node_class, parent_code, name, description, external_ref) VALUES
    ('PROCESS_HEATER', 'LOAD', NULL, 'Process heater',
     'Electric heater serving a process line, not space heating. The ten Texture '
     'heaters sit under HEATER_TOTAL.', NULL),
    ('WATER_PROCESS', 'LOAD', NULL, 'Water process point',
     'A destination for treated water on the water graph: a process area, a reuse '
     'or recycle return, an overflow, or an IPAL discharge. Has no electrical '
     'parent -- it consumes water, not electricity.', NULL);

-- OPTIONAL, so they add nothing to v_property_gaps. A heater has a breaker and a
-- rating; recording them later should not need a schema change. A water process
-- point has neither, so it gets neither.
INSERT INTO graph.type_property (node_type, attr_key, requirement, used_by) VALUES
    ('PROCESS_HEATER', 'main_breaker_a', 'OPTIONAL', NULL),
    ('PROCESS_HEATER', 'rated_kw',       'OPTIONAL', NULL);

-- ----------------------------------------------------------------------------
-- 2.4 Type every planned node
-- ----------------------------------------------------------------------------
-- node_type and node_class are set together because fk_node_node_type is
-- composite on (node_type, node_class); splitting them fails the FK mid-update.
-- For the {len(kept)} nodes that keep their class the class assignment is a no-op.
--
--   AIR_DRYER, COMP_300HP, COMP_400HP  LOAD -> CONVERSION/AIR_COMPRESSOR
--     16 peers on this site are already CONVERSION/AIR_COMPRESSOR; these three
--     were the outliers. REVIEW: AIR_DRYER is a dryer, not a compressor, and
--     typing it AIR_COMPRESSOR will inflate any aggregate that sums the type as
--     "compressed air production". Kept as the reviewed value; the fix is one
--     UPDATE plus an AIR_DRYER type and its endpoint rows.
--
--   WJL3, HEATER_TOTAL, MDP_MC_13      LOAD -> BUS/SUB_BOARD
--     All three have children, which is what a board is. HEATER_TOTAL feeds ten
--     heaters; MDP_MC_13 and WJL3 one each. Still to check at site: WJL2, WJL4
--     and AJL1, which look like the same pattern but have no children recorded.

UPDATE graph.node n
   SET node_type = p.node_type, node_class = p.node_class
  FROM _plan p
 WHERE n.tenant_id = 3 AND n.node_code = p.node_code AND n.node_type IS NULL;

-- ----------------------------------------------------------------------------
-- 2.5 Post-conditions
-- ----------------------------------------------------------------------------

DO $post$
DECLARE
    b   RECORD;
    n   INTEGER;
    bad TEXT;
BEGIN
    SELECT * INTO b FROM _before;

    IF (SELECT count(*) FROM graph.node WHERE tenant_id = 3) <> b.nodes THEN
        RAISE EXCEPTION 'node count moved; this migration only UPDATEs';
    END IF;
    IF (SELECT count(*) FROM graph.edge WHERE tenant_id = 3) <> b.edges THEN
        RAISE EXCEPTION 'edge count moved; this migration touches no edges';
    END IF;

    SELECT count(*) INTO n FROM graph.node WHERE tenant_id = 3 AND node_type IS NULL;
    IF n <> 0 THEN
        RAISE EXCEPTION '% node(s) still untyped', n;
    END IF;

    -- Exactly the intended nodes changed class, to exactly the intended values.
    SELECT string_agg(format('%s %s->%s', c.node_code, c.node_class, n.node_class), '; '
                      ORDER BY c.node_code) INTO bad
      FROM _class_before c
      JOIN graph.node n ON n.tenant_id = 3 AND n.node_code = c.node_code
     WHERE n.node_class IS DISTINCT FROM c.node_class;
    IF COALESCE(bad, '(none)') <> {expected_moves!r} THEN
        RAISE EXCEPTION 'unexpected set of node_class changes: %', COALESCE(bad, '(none)');
    END IF;

    -- Endpoint rules are now checkable on every edge. A pair the vocabulary
    -- forbids is either a wrong type above or a missing rule; both need a human,
    -- so refuse rather than commit a graph that contradicts itself.
    SELECT string_agg(format('%s -%s-> %s', from_code, edge_type, to_code), '; ') INTO bad
      FROM graph.v_edge_gaps WHERE tenant_id = 3 AND status = 'ILLEGAL_ENDPOINT';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'ILLEGAL_ENDPOINT after typing: %', bad;
    END IF;

    IF EXISTS (SELECT 1 FROM graph.v_edge_gaps
                WHERE tenant_id = 3 AND status = 'ENDPOINT_UNTYPED') THEN
        RAISE EXCEPTION 'ENDPOINT_UNTYPED survives although no node is untyped';
    END IF;

    -- INVALID would mean an attrs value the new type forbids. 2.2 should have
    -- caught it and the trigger before that, so reaching here is a real surprise.
    SELECT string_agg(node_code || ': ' || detail, '; ') INTO bad
      FROM graph.v_property_gaps WHERE tenant_id = 3 AND status = 'INVALID';
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'INVALID attrs after typing: %', bad;
    END IF;

    IF EXISTS (SELECT 1 FROM graph.v_property_gaps
                WHERE tenant_id = 3 AND status = 'UNTYPED') THEN
        RAISE EXCEPTION 'v_property_gaps still reports UNTYPED nodes';
    END IF;

    RAISE NOTICE 'OK: % nodes typed, {len(moved)} reclassified; edge gaps % -> %, '
                 'property gaps (excl. UNTYPED) % -> %',
                 (SELECT count(*) FROM _plan),
                 b.edge_gaps,
                 (SELECT count(*) FROM graph.v_edge_gaps WHERE tenant_id = 3),
                 b.prop_gaps_typed,
                 (SELECT count(*) FROM graph.v_property_gaps
                   WHERE tenant_id = 3 AND status <> 'UNTYPED');
END $post$;


-- ============================================================================
-- 3. Verification -- read this BEFORE committing
-- ============================================================================

\\echo ''
\\echo '=== 3.1 Every node is typed; distribution by class and type ==='
SELECT node_class, node_type, count(*) FROM graph.node
WHERE tenant_id = 3 GROUP BY 1, 2 ORDER BY 1, 2;

\\echo ''
\\echo '=== 3.2 The reclassified nodes, with their live neighbours ==='
SELECT n.node_code, n.node_class, n.node_type,
       (SELECT string_agg(f.node_code, '/' ORDER BY f.node_code)
          FROM graph.edge e JOIN graph.node f ON f.id = e.from_node_id
         WHERE e.to_node_id = n.id AND e.is_active
           AND e.effective_from <= CURRENT_DATE
           AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)) AS fed_by,
       (SELECT count(*) FROM graph.edge e
         WHERE e.from_node_id = n.id AND e.is_active
           AND e.effective_from <= CURRENT_DATE
           AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)) AS children
FROM graph.node n
WHERE n.tenant_id = 3 AND n.node_code IN ({moved_list})
ORDER BY n.node_class, n.node_code;

\\echo ''
\\echo '=== 3.3 Edge gap counts after ==='
SELECT status, count(*) FROM graph.v_edge_gaps WHERE tenant_id = 3
GROUP BY 1 ORDER BY 1;
-- ENDPOINT_UNTYPED must be gone. Any UNTYPED left is an edge with no edge_type,
-- which this migration does not touch.

\\echo ''
\\echo '=== 3.4 The new site questions typing has created ==='
SELECT node_code, node_type, attr_key, status, used_by
FROM graph.v_property_gaps
WHERE tenant_id = 3 AND node_code IN ({moved_list})
ORDER BY node_code, attr_key;
-- expect rated_kw on the three compressors, and main_breaker_a plus nominal_v on
-- the three boards -- except WJL3, which already has main_breaker_a

\\echo ''
\\echo '=== 3.5 Property gap counts after ==='
SELECT status, count(*) FROM graph.v_property_gaps WHERE tenant_id = 3
GROUP BY 1 ORDER BY 1;
-- UNTYPED gone; MISSING up by exactly the rows listed in 3.4

\\echo ''
\\echo '=== 3.6 What the vocabulary can now answer that node_code could not ==='
SELECT node_type, count(*) AS nodes,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM graph.measurement m
            WHERE m.node_id = node.id AND m.is_active)) AS metered
FROM graph.node
WHERE tenant_id = 3 AND is_active
  AND node_type IN ('AIR_COMPRESSOR', 'PROCESS_HEATER', 'WATER_PROCESS', 'PUMP',
                    'PRODUCTION_MACHINE', 'AHU')
GROUP BY 1 ORDER BY 1;

COMMIT;


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- UPDATE graph.node SET node_class = 'LOAD', node_type = NULL
--  WHERE tenant_id = 3 AND node_code IN ({moved_list});
-- UPDATE graph.node SET node_type = NULL
--  WHERE tenant_id = 3 AND node_code IN (
{undo_kept}
--  );
-- DELETE FROM graph.type_property WHERE node_type IN ('PROCESS_HEATER', 'WATER_PROCESS');
-- DELETE FROM graph.node_type     WHERE code      IN ('PROCESS_HEATER', 'WATER_PROCESS');
-- COMMIT;
"""

OUT.write_text(sql)
print(f"wrote {OUT}  ({len(sql.splitlines())} lines)")
print(f"  {len(plan)} nodes: {len(kept)} typed in place, {len(moved)} reclassified")
for t, n in tally.most_common():
    print(f"  {n:>3}  {t}  -> node_class {CLASS_OF[t]}")
