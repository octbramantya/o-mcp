-- Migration: 030_type_loads.sql
-- Description: Give every remaining untyped node a node_type.
-- Author: Claude
-- Date: 2026-09-29
-- Design: design/edge-type.md; design/draft_load_types.csv
-- Requires: 029_fix_edge_gaps_window.sql
--
-- WHY
-- ---
-- 026 created the node_type vocabulary and 028 the edge_type vocabulary, but
-- 100 nodes were still untyped. Each is reachable only by node_code -- which
-- means reachable only by someone who already knows the name -- and each is the
-- reason a graph.v_edge_gaps row reads ENDPOINT_UNTYPED instead of being checked
-- against an endpoint rule.
--
-- The types here are a reviewed first pass, not a site-verified inventory. That
-- is deliberate: a complete assessment would take months, and a type that is
-- mostly right today is worth more than a null that is unarguable. Retyping is
-- one UPDATE and nothing downstream caches it.
--
--    44  PRODUCTION_MACHINE
--    11  AHU
--    11  WATER_PROCESS
--    10  PROCESS_HEATER
--     9  GENERIC_LOAD
--     6  PUMP
--     3  AIR_COMPRESSOR   (node_class change)
--     3  SUB_BOARD   (node_class change)
--     3  LIGHTING
--
-- Two of the 100 are inactive: MC302_BARU and MC303_BARU, whose every edge
-- carries effective_to = '-infinity'. By this graph's convention that means they
-- were never true -- they came from the SLD that was later redrawn, not from a
-- decommissioning. They are typed anyway: node_type is descriptive, a null would
-- put the "every node is typed" invariant permanently out of reach, and an as-of
-- query should still be able to name what the wrong SLD claimed was there.
--
-- WHAT THIS COSTS
-- ---------------
-- Typing has one consequence, and it is the wanted one. The 6 reclassified
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

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Untyped nodes before ==='
SELECT node_class, is_active, count(*) FROM graph.node
WHERE tenant_id = 3 AND node_type IS NULL GROUP BY 1, 2 ORDER BY 1, 2;
-- expect 100 in total, all LOAD, two of them inactive

\echo ''
\echo '=== 1.2 Edge gap counts before ==='
SELECT status, count(*) FROM graph.v_edge_gaps WHERE tenant_id = 3
GROUP BY 1 ORDER BY 1;

\echo ''
\echo '=== 1.3 Property gap counts before ==='
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
    ('AHU_10_11'      , 'AHU'               , 'LOAD'),
    ('AHU_12_13'      , 'AHU'               , 'LOAD'),
    ('AHU_14'         , 'AHU'               , 'LOAD'),
    ('AHU_2_3'        , 'AHU'               , 'LOAD'),
    ('AHU_4_7'        , 'AHU'               , 'LOAD'),
    ('AHU_LINE1'      , 'AHU'               , 'LOAD'),
    ('AHU_LINE2'      , 'AHU'               , 'LOAD'),
    ('AHU_LINE3'      , 'AHU'               , 'LOAD'),
    ('AIR_DRYER'      , 'AIR_COMPRESSOR'    , 'CONVERSION'),
    ('AJL1'           , 'GENERIC_LOAD'      , 'LOAD'),
    ('CELUP_1A'       , 'PRODUCTION_MACHINE', 'LOAD'),
    ('CELUP_1B'       , 'PRODUCTION_MACHINE', 'LOAD'),
    ('CELUP_2'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('CELUP_3'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('COMP_300HP'     , 'AIR_COMPRESSOR'    , 'CONVERSION'),
    ('COMP_400HP'     , 'AIR_COMPRESSOR'    , 'CONVERSION'),
    ('COOLING1'       , 'PUMP'              , 'LOAD'),
    ('COOLING2'       , 'PUMP'              , 'LOAD'),
    ('DRYER_INT_1'    , 'PRODUCTION_MACHINE', 'LOAD'),
    ('FINISHING_1'    , 'PRODUCTION_MACHINE', 'LOAD'),
    ('FINISHING_21'   , 'PRODUCTION_MACHINE', 'LOAD'),
    ('FLR_124'        , 'GENERIC_LOAD'      , 'LOAD'),
    ('GARUK'          , 'PRODUCTION_MACHINE', 'LOAD'),
    ('HEATER_1'       , 'PROCESS_HEATER'    , 'LOAD'),
    ('HEATER_10'      , 'PROCESS_HEATER'    , 'LOAD'),
    ('HEATER_11'      , 'PROCESS_HEATER'    , 'LOAD'),
    ('HEATER_2'       , 'PROCESS_HEATER'    , 'LOAD'),
    ('HEATER_3'       , 'PROCESS_HEATER'    , 'LOAD'),
    ('HEATER_4'       , 'PROCESS_HEATER'    , 'LOAD'),
    ('HEATER_5'       , 'PROCESS_HEATER'    , 'LOAD'),
    ('HEATER_6'       , 'PROCESS_HEATER'    , 'LOAD'),
    ('HEATER_7'       , 'PROCESS_HEATER'    , 'LOAD'),
    ('HEATER_8'       , 'PROCESS_HEATER'    , 'LOAD'),
    ('HEATER_TOTAL'   , 'SUB_BOARD'         , 'BUS'),
    ('HVAC_AHU'       , 'AHU'               , 'LOAD'),
    ('HVAC_CHILLER1'  , 'AHU'               , 'LOAD'),
    ('HVAC_CHILLER2'  , 'AHU'               , 'LOAD'),
    ('LABKNIT'        , 'GENERIC_LOAD'      , 'LOAD'),
    ('LAB_DEVICE'     , 'GENERIC_LOAD'      , 'LOAD'),
    ('LIGHTING_MAIN'  , 'LIGHTING'          , 'LOAD'),
    ('LIGHT_INT_1'    , 'LIGHTING'          , 'LOAD'),
    ('LIGHT_INT_2'    , 'LIGHTING'          , 'LOAD'),
    ('MC302_1_8'      , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC302_BARU'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC303_1_9'      , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC303_BARU'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_302_9_11'    , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_ATY'         , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_1'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_10'    , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_11'    , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_12'    , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_13'    , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_2'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_3'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_4'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_5'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_6'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_7'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_8'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_MOTOR_9'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_SP_A'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_SP_B'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_SP_C'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_SP_D'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_SP_E'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_SP_F'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_SP_G'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_SP_H'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_SP_I'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MC_SP_J'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('MDP_MC_13'      , 'SUB_BOARD'         , 'BUS'),
    ('OFFICE'         , 'GENERIC_LOAD'      , 'LOAD'),
    ('OFFICE_2'       , 'GENERIC_LOAD'      , 'LOAD'),
    ('PACKING_DEVICE' , 'PRODUCTION_MACHINE', 'LOAD'),
    ('PKN_DEVICE'     , 'PRODUCTION_MACHINE', 'LOAD'),
    ('PUMP_COOL_WND'  , 'PUMP'              , 'LOAD'),
    ('RAINCOAT_DEVICE', 'PRODUCTION_MACHINE', 'LOAD'),
    ('SIPPA'          , 'PRODUCTION_MACHINE', 'LOAD'),
    ('SIZING'         , 'PRODUCTION_MACHINE', 'LOAD'),
    ('TRICOT1'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('TRICOT2'        , 'PRODUCTION_MACHINE', 'LOAD'),
    ('WJL2'           , 'GENERIC_LOAD'      , 'LOAD'),
    ('WJL3'           , 'SUB_BOARD'         , 'BUS'),
    ('WJL4'           , 'GENERIC_LOAD'      , 'LOAD'),
    ('WORKSHOP'       , 'GENERIC_LOAD'      , 'LOAD'),
    ('WTP1_ATY'       , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP1_IPAL'      , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP1_OVR'       , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP1_REUSE'     , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP1_SPN'       , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP1_WJL_REC'   , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP1_WVN'       , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP2_BEAM'      , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP2_IPAL'      , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP2_PROC'      , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP2_RPD'       , 'WATER_PROCESS'     , 'LOAD'),
    ('WTP_1'          , 'PUMP'              , 'LOAD'),
    ('WTP_2'          , 'PUMP'              , 'LOAD'),
    ('WWTP'           , 'PUMP'              , 'LOAD');

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
-- For the 94 nodes that keep their class the class assignment is a no-op.
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
    IF COALESCE(bad, '(none)') <> 'AIR_DRYER LOAD->CONVERSION; COMP_300HP LOAD->CONVERSION; COMP_400HP LOAD->CONVERSION; HEATER_TOTAL LOAD->BUS; MDP_MC_13 LOAD->BUS; WJL3 LOAD->BUS' THEN
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

    RAISE NOTICE 'OK: % nodes typed, 6 reclassified; edge gaps % -> %, '
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

\echo ''
\echo '=== 3.1 Every node is typed; distribution by class and type ==='
SELECT node_class, node_type, count(*) FROM graph.node
WHERE tenant_id = 3 GROUP BY 1, 2 ORDER BY 1, 2;

\echo ''
\echo '=== 3.2 The reclassified nodes, with their live neighbours ==='
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
WHERE n.tenant_id = 3 AND n.node_code IN ('AIR_DRYER', 'COMP_300HP', 'COMP_400HP', 'HEATER_TOTAL', 'MDP_MC_13', 'WJL3')
ORDER BY n.node_class, n.node_code;

\echo ''
\echo '=== 3.3 Edge gap counts after ==='
SELECT status, count(*) FROM graph.v_edge_gaps WHERE tenant_id = 3
GROUP BY 1 ORDER BY 1;
-- ENDPOINT_UNTYPED must be gone. Any UNTYPED left is an edge with no edge_type,
-- which this migration does not touch.

\echo ''
\echo '=== 3.4 The new site questions typing has created ==='
SELECT node_code, node_type, attr_key, status, used_by
FROM graph.v_property_gaps
WHERE tenant_id = 3 AND node_code IN ('AIR_DRYER', 'COMP_300HP', 'COMP_400HP', 'HEATER_TOTAL', 'MDP_MC_13', 'WJL3')
ORDER BY node_code, attr_key;
-- expect rated_kw on the three compressors, and main_breaker_a plus nominal_v on
-- the three boards -- except WJL3, which already has main_breaker_a

\echo ''
\echo '=== 3.5 Property gap counts after ==='
SELECT status, count(*) FROM graph.v_property_gaps WHERE tenant_id = 3
GROUP BY 1 ORDER BY 1;
-- UNTYPED gone; MISSING up by exactly the rows listed in 3.4

\echo ''
\echo '=== 3.6 What the vocabulary can now answer that node_code could not ==='
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
--  WHERE tenant_id = 3 AND node_code IN ('AIR_DRYER', 'COMP_300HP', 'COMP_400HP', 'HEATER_TOTAL', 'MDP_MC_13', 'WJL3');
-- UPDATE graph.node SET node_type = NULL
--  WHERE tenant_id = 3 AND node_code IN (
--       'AHU_10_11', 'AHU_12_13', 'AHU_14', 'AHU_2_3', 'AHU_4_7', 'AHU_LINE1',
--       'AHU_LINE2', 'AHU_LINE3', 'AJL1', 'CELUP_1A', 'CELUP_1B', 'CELUP_2',
--       'CELUP_3', 'COOLING1', 'COOLING2', 'DRYER_INT_1', 'FINISHING_1',
--       'FINISHING_21', 'FLR_124', 'GARUK', 'HEATER_1', 'HEATER_10', 'HEATER_11',
--       'HEATER_2', 'HEATER_3', 'HEATER_4', 'HEATER_5', 'HEATER_6', 'HEATER_7',
--       'HEATER_8', 'HVAC_AHU', 'HVAC_CHILLER1', 'HVAC_CHILLER2', 'LABKNIT',
--       'LAB_DEVICE', 'LIGHTING_MAIN', 'LIGHT_INT_1', 'LIGHT_INT_2', 'MC302_1_8',
--       'MC302_BARU', 'MC303_1_9', 'MC303_BARU', 'MC_302_9_11', 'MC_ATY',
--       'MC_MOTOR_1', 'MC_MOTOR_10', 'MC_MOTOR_11', 'MC_MOTOR_12', 'MC_MOTOR_13',
--       'MC_MOTOR_2', 'MC_MOTOR_3', 'MC_MOTOR_4', 'MC_MOTOR_5', 'MC_MOTOR_6',
--       'MC_MOTOR_7', 'MC_MOTOR_8', 'MC_MOTOR_9', 'MC_SP_A', 'MC_SP_B', 'MC_SP_C',
--       'MC_SP_D', 'MC_SP_E', 'MC_SP_F', 'MC_SP_G', 'MC_SP_H', 'MC_SP_I', 'MC_SP_J',
--       'OFFICE', 'OFFICE_2', 'PACKING_DEVICE', 'PKN_DEVICE', 'PUMP_COOL_WND',
--       'RAINCOAT_DEVICE', 'SIPPA', 'SIZING', 'TRICOT1', 'TRICOT2', 'WJL2', 'WJL4',
--       'WORKSHOP', 'WTP1_ATY', 'WTP1_IPAL', 'WTP1_OVR', 'WTP1_REUSE', 'WTP1_SPN',
--       'WTP1_WJL_REC', 'WTP1_WVN', 'WTP2_BEAM', 'WTP2_IPAL', 'WTP2_PROC', 'WTP2_RPD',
--       'WTP_1', 'WTP_2', 'WWTP'
--  );
-- DELETE FROM graph.type_property WHERE node_type IN ('PROCESS_HEATER', 'WATER_PROCESS');
-- DELETE FROM graph.node_type     WHERE code      IN ('PROCESS_HEATER', 'WATER_PROCESS');
-- COMMIT;
