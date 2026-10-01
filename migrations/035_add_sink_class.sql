-- Migration: 035_add_sink_class.sql
-- Description: Add the SINK node class and narrow LOAD. New node types WATER_OUTFALL and
--              RECYCLE_CUT (SINK) and WASTEWATER_TREATMENT (TREATMENT), the reenters_at
--              property, the WATER_DISCHARGE edge type and their endpoint rules. Delete the 11
--              SUPPLY_LV rules that let a LOAD feed something. Vocabulary only: no node or
--              edge changes here; 036 redraws the water graph to use it.
-- Author: Claude
-- Date: 2026-10-01
-- Design: design/graph-network-design.md (node_class, cycle prevention 4.5)
-- Requires: 034_add_treatment_class.sql
--
-- WHY
-- ---
-- LOAD said "consumes the utility; a path on that utility ends here". True for all
-- 81 electricity loads. On water, WATER_PROCESS held three different roles:
--
--   process areas      use water, and some return spent water to a tank
--   exits              WTP1_IPAL, WTP2_IPAL, WTP1_OVR: water leaving, not consumed
--   a recycle cut      WTP1_REUSE: stands in for Tandon Bio -> rain tank, the edge
--                      that would close the loop BIO -> RAN -> RAW -> ... -> BIO
--
-- Any total over LOAD counted discharge, and recycled water, as consumption.
--
-- SINK is the mirror of SOURCE: where the utility leaves the graph without being
-- consumed. That is a role in the flow, which is what a class records; a finer kind
-- of an existing role would be a type. Two types:
--
--   WATER_OUTFALL  water leaves the site: to a stream, river or drain, or an overflow.
--   RECYCLE_CUT    not equipment. The graph must stay acyclic (design decision 1, and
--                  008's trg_edge_acyclic), so a recycle return is cut: the flow leaves
--                  at this node and re-enters at another. reenters_at names that node,
--                  so an intake total can subtract what is not new water.
--
-- IPAL is the plant's wastewater treatment: spent water in, cleaned water out to the
-- stream, sludge lost. That is TREATMENT, so it gets a type under WATER_TREATMENT;
-- the stream it discharges into is a WATER_OUTFALL. WATER_DISCHARGE is the edge
-- into an outfall, from IPAL or from a tank's overflow.
--
-- The 11 SUPPLY_LV rules with LOAD as the source (LOAD -> SUB_BOARD, LOAD -> LOAD,
-- LOAD -> AIR_COMPRESSOR, ...) date from before 030, when some boards were still
-- untyped LOADs. No live edge uses them, and they would let a mis-drawn board pass
-- without an edge gap. The water rules naming LOAD stay: WATER_RETURN LOAD ->
-- WATER_TANK is in use, and WATER_SUPPLY LOAD -> LOAD goes in 036 once its one edge
-- is retyped.
--
-- reenters_at is OPTIONAL: no report reads it yet (the REQUIRED-needs-a-reader rule).
-- 036 sets it on WTP1_REUSE regardless.
--
-- Not done here: graph.vocabulary_alignment rows for the three new types. 031 gives
-- every type a Brick verdict, but verdicts come from the parsed TTL
-- (tools/validate_brick.py), not recall; that is a separate check.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 LOAD nodes by type, live, with how many have live children ==='
SELECT n.node_type, count(*) AS nodes,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM graph.edge e
           WHERE e.from_node_id = n.id AND e.is_active AND e.effective_from <= CURRENT_DATE
             AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE))) AS with_children
FROM graph.node n
WHERE n.node_class = 'LOAD' AND n.is_active AND n.effective_from <= CURRENT_DATE
  AND (n.effective_to IS NULL OR n.effective_to >= CURRENT_DATE)
GROUP BY 1 ORDER BY 1;
-- expect children only on WATER_PROCESS (6 of 11)

\echo ''
\echo '=== 1.2 Endpoint rules with LOAD as the source ==='
SELECT edge_type, from_kind, to_kind FROM graph.edge_type_endpoint
WHERE from_kind = 'LOAD' ORDER BY 1, 3;
-- expect 11 SUPPLY_LV rows (deleted below), WATER_RETURN -> WATER_TANK, WATER_SUPPLY -> LOAD


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run on a database that has drifted from what was reviewed
-- ----------------------------------------------------------------------------
DO $pre$
DECLARE
    got TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM graph.node_class WHERE code = 'SINK') THEN
        RAISE EXCEPTION 'node class SINK already exists';
    END IF;
    SELECT string_agg(code, ', ') INTO got FROM graph.node_type
     WHERE code IN ('WATER_OUTFALL', 'RECYCLE_CUT', 'WASTEWATER_TREATMENT');
    IF got IS NOT NULL THEN
        RAISE EXCEPTION 'node types already exist: %', got;
    END IF;
    IF EXISTS (SELECT 1 FROM graph.edge_type WHERE code = 'WATER_DISCHARGE') THEN
        RAISE EXCEPTION 'edge type WATER_DISCHARGE already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.property WHERE attr_key = 'reenters_at') THEN
        RAISE EXCEPTION 'property reenters_at already exists';
    END IF;

    SELECT string_agg(to_kind, ', ' ORDER BY to_kind) INTO got
    FROM graph.edge_type_endpoint WHERE edge_type = 'SUPPLY_LV' AND from_kind = 'LOAD';
    IF got IS DISTINCT FROM 'AIR_COMPRESSOR, BOILER, CAPACITOR_BANK, CLARIFIER, LOAD, '
                            'REACTION_TANK, RO_UNIT, SOFTENER, SUB_BOARD, WATER_INTAKE, WATER_TANK' THEN
        RAISE EXCEPTION 'SUPPLY_LV rules from LOAD are not the 11 reviewed: %', got;
    END IF;

    -- deleting them must not leave a live edge without a rule
    IF EXISTS (SELECT 1 FROM graph.edge e JOIN graph.node f ON f.id = e.from_node_id
               WHERE e.edge_type = 'SUPPLY_LV' AND f.node_class = 'LOAD'
                 AND e.is_active AND e.effective_from <= CURRENT_DATE
                 AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)) THEN
        RAISE EXCEPTION 'a live SUPPLY_LV edge leaves a LOAD node';
    END IF;
END
$pre$;

-- ----------------------------------------------------------------------------
-- 2.2 The class, and LOAD narrowed
-- ----------------------------------------------------------------------------
INSERT INTO graph.node_class (code, description) VALUES
    ('SINK',
     'Where the utility leaves the graph without being consumed: an outfall or overflow, '
     'where water leaves the site, or a recycle cut, where it leaves only to re-enter at '
     'another node (the type says which). Discharge is not consumption: keep SINK nodes out '
     'of consumption totals.');

UPDATE graph.node_class SET description =
     'Uses the utility for a purpose: a machine, lighting, an air handling unit, a process '
     'area using water. On electricity a path always ends here. On water it may send part of '
     'what it used onward as spent water (a WATER_RETURN to a tank), but what leaves is used '
     'water, not the supply passed on. Water that leaves the site unused is SINK.'
 WHERE code = 'LOAD';

-- ----------------------------------------------------------------------------
-- 2.3 Node types, and the property a recycle cut carries
-- ----------------------------------------------------------------------------
INSERT INTO graph.node_type (code, node_class, parent_code, name, description) VALUES
    ('WATER_OUTFALL', 'SINK', NULL, 'Water outfall',
     'Where water leaves the site: a discharge to a stream, river or drain, or a tank''s '
     'overflow. Discharge, not consumption.'),
    ('RECYCLE_CUT', 'SINK', NULL, 'Recycle cut',
     'Not equipment. Stands in for a recycle return that would close a loop, since the graph '
     'must stay acyclic. The flow does not leave the site: it re-enters at the node named in '
     'reenters_at, whose inflow therefore includes it. Subtract it when totalling site '
     'intake.'),
    ('WASTEWATER_TREATMENT', 'TREATMENT', 'WATER_TREATMENT', 'Wastewater treatment (IPAL)',
     'Treats spent process water before it leaves the site. Its output goes to an outfall, '
     'not back into supply.');

INSERT INTO graph.property (attr_key, datatype, kind, description) VALUES
    ('reenters_at', 'text', 'DESIGN',
     'For a RECYCLE_CUT: the node_code where the recycled flow re-enters the graph. That '
     'node''s inflow includes this flow, so a site intake total overstates new water by it '
     'unless it is subtracted.');

INSERT INTO graph.type_property (node_type, attr_key, requirement, used_by) VALUES
    ('RECYCLE_CUT', 'reenters_at', 'OPTIONAL', NULL);

-- ----------------------------------------------------------------------------
-- 2.4 The edge type, and endpoint rules
-- ----------------------------------------------------------------------------
INSERT INTO graph.edge_type (code, edge_class, utility_code, carries_flow, is_transform, description) VALUES
    ('WATER_DISCHARGE', 'PIPE', 'WATER', TRUE, FALSE,
     'Water leaving the site, into an outfall: treated effluent from wastewater treatment, '
     'or a tank''s overflow. Discharge, not consumption.');

INSERT INTO graph.edge_type_endpoint (edge_type, from_kind, to_kind) VALUES
    ('WATER_DISCHARGE', 'WASTEWATER_TREATMENT', 'WATER_OUTFALL'),
    ('WATER_DISCHARGE', 'WATER_TANK',           'WATER_OUTFALL'),
    ('WATER_TREATMENT', 'WATER_TANK',           'WASTEWATER_TREATMENT'),
    ('WATER_RETURN',    'WATER_TANK',           'RECYCLE_CUT');

DELETE FROM graph.edge_type_endpoint WHERE edge_type = 'SUPPLY_LV' AND from_kind = 'LOAD';

-- ----------------------------------------------------------------------------
-- 2.5 Post-conditions
-- ----------------------------------------------------------------------------
DO $post$
BEGIN
    IF (SELECT count(*) FROM graph.v_edge_gaps) <> 0 THEN
        RAISE EXCEPTION 'v_edge_gaps is not empty after the rule changes';
    END IF;
END
$post$;

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Node classes ==='
SELECT code, left(description, 70) AS description FROM graph.node_class ORDER BY 1;
-- expect 7: BUS CONVERSION LOAD SINK SOURCE STORAGE TREATMENT

\echo ''
\echo '=== 3.2 The new types and rules ==='
SELECT t.code, t.node_class, t.parent_code FROM graph.node_type t
WHERE t.code IN ('WATER_OUTFALL', 'RECYCLE_CUT', 'WASTEWATER_TREATMENT') ORDER BY 1;
SELECT edge_type, from_kind, to_kind FROM graph.edge_type_endpoint
WHERE 'WATER_OUTFALL' IN (from_kind, to_kind) OR 'RECYCLE_CUT' IN (from_kind, to_kind)
   OR 'WASTEWATER_TREATMENT' IN (from_kind, to_kind) OR from_kind = 'LOAD'
ORDER BY 1, 2, 3;
-- expect the 4 new rules, plus WATER_RETURN LOAD -> WATER_TANK and WATER_SUPPLY LOAD -> LOAD


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- INSERT INTO graph.edge_type_endpoint (edge_type, from_kind, to_kind) VALUES
--     ('SUPPLY_LV', 'LOAD', 'AIR_COMPRESSOR'), ('SUPPLY_LV', 'LOAD', 'BOILER'),
--     ('SUPPLY_LV', 'LOAD', 'CAPACITOR_BANK'), ('SUPPLY_LV', 'LOAD', 'CLARIFIER'),
--     ('SUPPLY_LV', 'LOAD', 'LOAD'),           ('SUPPLY_LV', 'LOAD', 'REACTION_TANK'),
--     ('SUPPLY_LV', 'LOAD', 'RO_UNIT'),        ('SUPPLY_LV', 'LOAD', 'SOFTENER'),
--     ('SUPPLY_LV', 'LOAD', 'SUB_BOARD'),      ('SUPPLY_LV', 'LOAD', 'WATER_INTAKE'),
--     ('SUPPLY_LV', 'LOAD', 'WATER_TANK');
-- DELETE FROM graph.edge_type_endpoint
--  WHERE 'WATER_OUTFALL' IN (from_kind, to_kind) OR 'RECYCLE_CUT' IN (from_kind, to_kind)
--     OR 'WASTEWATER_TREATMENT' IN (from_kind, to_kind);
-- DELETE FROM graph.edge_type WHERE code = 'WATER_DISCHARGE';
-- DELETE FROM graph.type_property WHERE attr_key = 'reenters_at';
-- DELETE FROM graph.property WHERE attr_key = 'reenters_at';
-- DELETE FROM graph.node_type WHERE code IN ('WATER_OUTFALL', 'RECYCLE_CUT', 'WASTEWATER_TREATMENT');
-- UPDATE graph.node_class SET description =
--      'Consumes the utility: a machine, lighting, an air handling unit, a point where '
--      'treated water is used. A path on that utility ends here.'
--  WHERE code = 'LOAD';
-- DELETE FROM graph.node_class WHERE code = 'SINK';
-- COMMIT;
