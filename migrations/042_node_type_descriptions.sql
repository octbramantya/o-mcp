-- Migration: 042_node_type_descriptions.sql
-- Description: Replace the 15 one-line node type descriptions that restated the type's name.
-- Author: Claude
-- Date: 2026-10-06
-- Design: design/node_type_descriptions.csv (rendered by tools/gen_042.py; regenerate, never
--         hand-edit); design/type-property.md, "When a new type is justified";
--         design/mcp-tools.md
-- Requires: 041_node_type_is_abstract.sql
--
-- WHY
-- ---
-- graph.node_type.description is what the MCP server gives a model to say what a
-- node is. 15 of the 27 said no more than the code ("Pump load.", "Stored water."),
-- so a model would fill the gap from general knowledge: that a PRODUCTION_MACHINE
-- is one machine, that a WATER_INTAKE is a well, that a PUMP node's energy moves
-- the water on the water graph. Each new description says what the type covers,
-- how it sits in the graph, and what may not be inferred from it.
--
-- Each claim has a basis, recorded per row below and in the CSV:
--   ONTOLOGY  what the type means in any tenant;
--   GRAPH     how its nodes are joined (edge types, metering, what the solver does);
--   OPEN      a question the site has not answered, stated as such so a model
--             does not answer it: BOILER, GENERIC_LOAD, PRODUCTION_MACHINE, WATER_INTAKE.
-- The descriptions are tenant-neutral, since node_type is shared; tenant 3's
-- names and counts stay in the CSV notes, repeated here as comments.
--
-- PRODUCTION_MACHINE and WATER_INTAKE are provisional, not abstract: their nodes
-- keep them until subtypes exist and the nodes are retyped (041 refuses the other
-- order). Descriptions only: no type, class, property or node changes.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 The descriptions being replaced ==='
SELECT code, node_class, description FROM graph.node_type
WHERE code IN ('AIR_COMPRESSOR', 'BOILER', 'AHU', 'GENERIC_LOAD', 'LIGHTING', 'PRODUCTION_MACHINE', 'PUMP', 'GAS_ENGINE', 'WATER_INTAKE', 'CAPACITOR_BANK', 'WATER_TANK', 'CLARIFIER', 'REACTION_TANK', 'RO_UNIT', 'SOFTENER')
ORDER BY 1;
-- expect 15 rows: AIR_COMPRESSOR, BOILER, AHU, GENERIC_LOAD, LIGHTING, PRODUCTION_MACHINE, PUMP, GAS_ENGINE, WATER_INTAKE, CAPACITOR_BANK, WATER_TANK, CLARIFIER, REACTION_TANK, RO_UNIT, SOFTENER


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
        ('AIR_COMPRESSOR', 'CONVERSION',
         'Electricity to compressed air.'),
        ('BOILER', 'CONVERSION',
         'Fuel to steam.'),
        ('AHU', 'LOAD',
         'Air handling unit.'),
        ('GENERIC_LOAD', 'LOAD',
         'A load not yet classified further.'),
        ('LIGHTING', 'LOAD',
         'Lighting load.'),
        ('PRODUCTION_MACHINE', 'LOAD',
         'Process machinery.'),
        ('PUMP', 'LOAD',
         'Pump load.'),
        ('GAS_ENGINE', 'SOURCE',
         'Reciprocating gas engine generator.'),
        ('WATER_INTAKE', 'SOURCE',
         'Raw water entering the site.'),
        ('CAPACITOR_BANK', 'STORAGE',
         'Power factor correction bank.'),
        ('WATER_TANK', 'STORAGE',
         'Stored water.'),
        ('CLARIFIER', 'TREATMENT',
         'Settling stage.'),
        ('REACTION_TANK', 'TREATMENT',
         'Chemical dosing and reaction stage.'),
        ('RO_UNIT', 'TREATMENT',
         'Reverse osmosis stage.'),
        ('SOFTENER', 'TREATMENT',
         'Ion-exchange hardness removal.')
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

-- AIR_COMPRESSOR (CONVERSION, 22 nodes; basis ONTOLOGY, GRAPH)
--   Tenant 3: no AIR edges, so every compressor is effectively an electrical load.
--   AIR_DRYER is typed here on purpose though wrong (edge-type.md §9); the last sentence
--   is the warning. 7 of 22 metered.
UPDATE graph.node_type SET description =
    'Converts electricity into compressed air. Fed by a board over SUPPLY_LV. Where the air network is not modelled (no AIR edges), the graph shows only its electrical consumption, not the air it delivers. Air dryers and other air-treatment equipment are not compressors.'
 WHERE code = 'AIR_COMPRESSOR';

-- BOILER (CONVERSION, 1 node; basis ONTOLOGY, GRAPH, OPEN)
--   BOILER_MIURA: SUPPLY_LV in, RO water in, fuel not recorded. If an electric
--   (electrode) boiler is ever added it needs its own type: the electrical feed would
--   then be the steam energy.
UPDATE graph.node_type SET description =
    'Produces steam from fuel, recorded in fuel when known. Its electrical feed supplies auxiliaries (pumps, fans, controls), not the energy that raises the steam. Takes treated feed water from the water graph. Its steam output is not modelled until the STEAM utility has edges, and its fuel input is not metered in the graph.'
 WHERE code = 'BOILER';

-- AHU (LOAD, 11 nodes; basis ONTOLOGY, GRAPH)
--   HVAC_CHILLER1 and HVAC_CHILLER2 are typed AHU; HVAC_AHU covers AHU 1 & 2, AHU_10_11
--   etc. cover two or more units. CHILLER is a justified type (type-property.md, 'When a
--   new type is justified').
UPDATE graph.node_type SET description =
    'Air handling unit: fans, coils and filters conditioning air for a space or process area. An electrical load. Other HVAC plant such as chillers may be typed here until it has a type of its own, so a node typed AHU is not necessarily a single air handler; check its name.'
 WHERE code = 'AHU';

-- GENERIC_LOAD (LOAD, 9 nodes; basis ONTOLOGY, OPEN)
--   Includes AJL1, WJL2, WJL4 (air-jet and water-jet looms by name), which look like
--   PRODUCTION_MACHINE; retyping is a separate decision for the site.
UPDATE graph.node_type SET description =
    'Holding type for a load whose kind has not been identified: offices, laboratories, workshops, mixed work panels, or equipment awaiting typing. Being typed GENERIC_LOAD says nothing about what the load is; do not infer its kind from it. Which area or process it serves, if known, is its category.'
 WHERE code = 'GENERIC_LOAD';

-- LIGHTING (LOAD, 3 nodes; basis ONTOLOGY, GRAPH)
--   LIGHTING_MAIN and two Interlace lighting panels; 1 of 3 metered.
UPDATE graph.node_type SET description =
    'Lighting circuits. An electrical load; a node stands for a lighting panel or group of circuits, not a single luminaire.'
 WHERE code = 'LIGHTING';

-- PRODUCTION_MACHINE (LOAD, 42 nodes; basis ONTOLOGY, OPEN)
--   Provisional, not abstract (type-property.md, 'When a new type is justified'). Future
--   subtypes: MACHINE_PANEL, MACHINE_<process> where the physics differs. Names mix
--   machines (TRICOT1) and panels (MC302_1_8, MC_SP_A, DRYER_INT_1 'Dryer Interlace 1,
--   2, 3').
UPDATE graph.node_type SET description =
    'Production equipment on a line. A node may be a single machine or a machine panel feeding several machines; the graph does not record which. Do not infer a number of machines from a number of nodes, and do not compare one node''s consumption with another''s as if both were single machines. Which process a node serves (spinning, weaving, dyeing) is its category, not its type.'
 WHERE code = 'PRODUCTION_MACHINE';

-- PUMP (LOAD, 6 nodes; basis ONTOLOGY, GRAPH)
--   WTP_1, WTP_2 and WWTP are the water plants' electrical feeds; COOLING1, COOLING2 are
--   cooling towers. The electrical and water graphs share no edges.
UPDATE graph.node_type SET description =
    'Electrically driven pumping: water supply and transfer, cooling-water circulation and similar. A node may be one pump or the electrical feed of a plant whose load is mostly pumping, such as a water treatment plant or a cooling tower with its fans. It is on the electrical graph only; the water it moves is on the water graph, which is not linked to it.'
 WHERE code = 'PUMP';

-- GAS_ENGINE (SOURCE, 1 node; basis ONTOLOGY, GRAPH)
--   Tenant 3: feeds LVMDB_A1, A2, A3; fuel NATURAL_GAS; not metered on its own node.
UPDATE graph.node_type SET description =
    'Reciprocating engine generator running on gas (fuel recorded in fuel). Feeds one or more main LV boards over GENERATOR_INFEED, alongside their transformer supply. Its fuel input is not modelled; on the electrical graph it is a source of the energy it feeds into the boards.'
 WHERE code = 'GAS_ENGINE';

-- WATER_INTAKE (SOURCE, 5 nodes; basis ONTOLOGY, GRAPH, OPEN)
--   Provisional, not abstract. Future subtypes WATER_INTAKE_WELL, WATER_INTAKE_PDAM etc.
--   WTP1_RAN is 'Tandon Air Hujan' (rainwater tank), and WTP1_REUSE re-enters there
--   (reenters_at), hence rainwater and the last sentence.
UPDATE graph.node_type SET description =
    'Where raw water enters the site''s water graph. A node may be a deep well, the municipal supply (PDAM), a river intake or rainwater collection; the graph does not record which. Do not state the source of an intake unless its name or attributes say so. An intake may also receive recycled water re-entering from a RECYCLE_CUT, so its inflow is not necessarily all raw water.'
 WHERE code = 'WATER_INTAKE';

-- CAPACITOR_BANK (STORAGE, 11 nodes; basis ONTOLOGY, GRAPH)
--   From graph-network-design.md (COMPENSATION) and 024/026. 0 of 11 metered.
UPDATE graph.node_type SET description =
    'Power factor correction bank on a board, joined to it by a PF_COMPENSATION edge. It carries no energy and the solver skips it: its effect shows as lower reactive energy on its board. Not metered on its own. Classed STORAGE because it exchanges reactive energy with the network each cycle; it is not a load. pf_report.py needs its rated_kvar, step_kvar, control, target_pf and site_status.'
 WHERE code = 'CAPACITOR_BANK';

-- WATER_TANK (STORAGE, 11 nodes; basis ONTOLOGY, GRAPH)
--   Tenant 3 tanks are WTP1_* and WTP2_*; none metered; volume_m3 OPTIONAL and unset.
UPDATE graph.node_type SET description =
    'Holds water between stages: raw, soft, RO, hot, delivery, equalisation or recycle water. What flows in and out over a period differs by the change in stored volume, which the graph does not record, so a tank''s balance need not close over short periods.'
 WHERE code = 'WATER_TANK';

-- CLARIFIER (TREATMENT, 2 nodes; basis ONTOLOGY, GRAPH)
--   WTP1_CLR and WTP2_CLR.
UPDATE graph.node_type SET description =
    'Settling stage that removes suspended solids from raw water. Sits between a raw-water tank and the softeners. Not metered on its own; flow through it is inferred from the meters around it. Water lost with the sludge is not modelled.'
 WHERE code = 'CLARIFIER';

-- REACTION_TANK (TREATMENT, 1 node; basis ONTOLOGY, GRAPH)
--   WTP2_REACT: in from a tank; out by WATER_RETURN to a tank.
UPDATE graph.node_type SET description =
    'Chemical dosing and reaction stage, such as coagulation or pH adjustment. Its output may return to a tank rather than flow on to the next stage.'
 WHERE code = 'REACTION_TANK';

-- RO_UNIT (TREATMENT, 1 node; basis ONTOLOGY, GRAPH)
--   WTP2_RO_PROC feeds BOILER_MIURA.
UPDATE graph.node_type SET description =
    'Reverse-osmosis stage producing low-salt water, for example boiler feed water. Part of its inflow leaves as concentrate (reject), which is not modelled, so its outflow is less than its inflow.'
 WHERE code = 'RO_UNIT';

-- SOFTENER (TREATMENT, 5 nodes; basis ONTOLOGY, GRAPH)
--   WTP1_SOFT_1, _2 and WTP2_SOFT_3 to _5, each fed by a clarifier.
UPDATE graph.node_type SET description =
    'Ion-exchange stage removing hardness (calcium and magnesium). Several usually run in parallel. Water used to regenerate the resin is not modelled.'
 WHERE code = 'SOFTENER';

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 The new descriptions ==='
SELECT code, length(description) AS chars, left(description, 80) AS starts
FROM graph.node_type
WHERE code IN ('AIR_COMPRESSOR', 'BOILER', 'AHU', 'GENERIC_LOAD', 'LIGHTING', 'PRODUCTION_MACHINE', 'PUMP', 'GAS_ENGINE', 'WATER_INTAKE', 'CAPACITOR_BANK', 'WATER_TANK', 'CLARIFIER', 'REACTION_TANK', 'RO_UNIT', 'SOFTENER')
ORDER BY 1;
-- expect 15 rows

\echo ''
\echo '=== 3.2 Every type has a description of more than one short sentence ==='
SELECT code, description FROM graph.node_type
WHERE description IS NULL OR length(description) < 60
ORDER BY 1;
-- expect GRID_INCOMER, MAIN_LV_BOARD, PV_PLANT only: short but specific, not part of this pass

\echo ''
\echo '=== 3.3 Nothing else moved ==='
SELECT count(*) AS types, count(*) FILTER (WHERE is_abstract) AS abstract FROM graph.node_type;
SELECT status, count(*) FROM graph.v_property_gaps GROUP BY 1 ORDER BY 1;
SELECT count(*) AS edge_gaps FROM graph.v_edge_gaps;
-- expect 27 types, 2 abstract; MISSING 31; 0 edge gaps


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- UPDATE graph.node_type SET description = 'Electricity to compressed air.' WHERE code = 'AIR_COMPRESSOR';
-- UPDATE graph.node_type SET description = 'Fuel to steam.' WHERE code = 'BOILER';
-- UPDATE graph.node_type SET description = 'Air handling unit.' WHERE code = 'AHU';
-- UPDATE graph.node_type SET description = 'A load not yet classified further.' WHERE code = 'GENERIC_LOAD';
-- UPDATE graph.node_type SET description = 'Lighting load.' WHERE code = 'LIGHTING';
-- UPDATE graph.node_type SET description = 'Process machinery.' WHERE code = 'PRODUCTION_MACHINE';
-- UPDATE graph.node_type SET description = 'Pump load.' WHERE code = 'PUMP';
-- UPDATE graph.node_type SET description = 'Reciprocating gas engine generator.' WHERE code = 'GAS_ENGINE';
-- UPDATE graph.node_type SET description = 'Raw water entering the site.' WHERE code = 'WATER_INTAKE';
-- UPDATE graph.node_type SET description = 'Power factor correction bank.' WHERE code = 'CAPACITOR_BANK';
-- UPDATE graph.node_type SET description = 'Stored water.' WHERE code = 'WATER_TANK';
-- UPDATE graph.node_type SET description = 'Settling stage.' WHERE code = 'CLARIFIER';
-- UPDATE graph.node_type SET description = 'Chemical dosing and reaction stage.' WHERE code = 'REACTION_TANK';
-- UPDATE graph.node_type SET description = 'Reverse osmosis stage.' WHERE code = 'RO_UNIT';
-- UPDATE graph.node_type SET description = 'Ion-exchange hardness removal.' WHERE code = 'SOFTENER';
-- COMMIT;
