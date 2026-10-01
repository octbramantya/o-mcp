-- Migration: 034_add_treatment_class.sql
-- Description: Add the TREATMENT node class and move the water treatment types (WATER_TREATMENT
--              and its subtypes) and their nodes into it. CONVERSION narrows to nodes whose
--              output is a different utility from the energy they take in.
-- Author: Claude
-- Date: 2026-10-01
-- Design: design/graph-network-design.md (node_class); design/edge-type.md section 9 (AIR_DRYER)
-- Requires: 033_create_class_tables.sql
--
-- WHY
-- ---
-- 033 gave CONVERSION one description covering two different things. Seen one
-- utility at a time, which is how the solver works, they behave differently:
--
--   AIR_COMPRESSOR, BOILER        a load on the electricity graph and a source
--                                 on the air or steam graph. What leaves is a
--                                 different utility from what went in.
--   CLARIFIER, SOFTENER, RO_UNIT, a load on the electricity graph (pumps,
--   REACTION_TANK                 dosing), and on the water graph water passes
--                                 through: water in, water out, in > out. What
--                                 leaves is the same utility, changed in
--                                 quality, minus reject, backwash or sludge.
--
-- A softener's electricity is auxiliary, as a WATER_INTAKE's pumps are to a
-- SOURCE. Its defining flow stays on one utility, so it is not a conversion. The
-- WATER_TREATMENT edge type already says so ("Volume in does not equal volume
-- out"); only the node class lumped it in with compressors.
--
-- TREATMENT is utility-neutral on purpose. Compressed-air treatment is the same
-- shape: an air dryer takes compressed air and delivers drier air, losing some to
-- purge. AIR_DRYER is typed AIR_COMPRESSOR today, knowingly wrong (edge-type.md
-- section 9); its fix, a new AIR_DRYER type, now has a correct class to go into.
-- That fix is not part of this migration.
--
-- Moving a type's class has to move its subtypes and its nodes in the same step:
-- fk_node_type_parent ties a subtype to its parent's class, fk_node_node_type a
-- node to its type's, and neither cascades. Both are dropped, the rows moved, and
-- both re-added with their original definitions, which re-checks every row.
-- Endpoint rules name the treatment types themselves, never the CONVERSION class
-- (033 section 1.3: LOAD is the only class any rule names), so none changes.
-- Neither the solver nor any reader branches on CONVERSION.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Types of class CONVERSION, with their node counts (all rows, all tenants) ==='
SELECT t.code, t.parent_code, count(n.id) AS nodes
FROM graph.node_type t
LEFT JOIN graph.node n ON n.node_type = t.code
WHERE t.node_class = 'CONVERSION'
GROUP BY 1, 2 ORDER BY 2 NULLS FIRST, 1;
-- expect AIR_COMPRESSOR, BOILER, WATER_TREATMENT (0 nodes: abstract), and its four
-- subtypes CLARIFIER, REACTION_TANK, RO_UNIT, SOFTENER

\echo ''
\echo '=== 1.2 Nodes of class CONVERSION by type, all rows ==='
SELECT node_type, count(*) FROM graph.node WHERE node_class = 'CONVERSION' GROUP BY 1 ORDER BY 1;
-- expect 32 in all on tenant 3


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
    IF EXISTS (SELECT 1 FROM graph.node_class WHERE code = 'TREATMENT') THEN
        RAISE EXCEPTION 'node class TREATMENT already exists';
    END IF;

    SELECT string_agg(code || ':' || node_class, ', ' ORDER BY code) INTO got
    FROM graph.node_type WHERE code = 'WATER_TREATMENT' OR parent_code = 'WATER_TREATMENT';
    IF got IS DISTINCT FROM 'CLARIFIER:CONVERSION, REACTION_TANK:CONVERSION, RO_UNIT:CONVERSION, '
                            'SOFTENER:CONVERSION, WATER_TREATMENT:CONVERSION' THEN
        RAISE EXCEPTION 'WATER_TREATMENT and its subtypes are not the five reviewed CONVERSION types: %', got;
    END IF;

    -- a grandchild would be left behind by the parent_code test below
    IF EXISTS (SELECT 1 FROM graph.node_type c JOIN graph.node_type p ON p.code = c.parent_code
               WHERE p.parent_code = 'WATER_TREATMENT') THEN
        RAISE EXCEPTION 'WATER_TREATMENT has subtypes below its direct children';
    END IF;

    SELECT string_agg(DISTINCT kind, ', ') INTO got
    FROM (SELECT from_kind AS kind FROM graph.edge_type_endpoint
          UNION ALL SELECT to_kind FROM graph.edge_type_endpoint) k
    WHERE kind IN ('CONVERSION', 'TREATMENT');
    IF got IS NOT NULL THEN
        RAISE EXCEPTION 'endpoint rules name the class %; they would need review', got;
    END IF;
END
$pre$;

-- ----------------------------------------------------------------------------
-- 2.2 The class, and CONVERSION narrowed
-- ----------------------------------------------------------------------------
INSERT INTO graph.node_class (code, description) VALUES
    ('TREATMENT',
     'The same utility passes through and leaves changed in quality, with some of it lost: '
     'a clarifier, softener, RO unit or reaction tank on water; an air dryer or filter on '
     'compressed air. Inflow minus outflow is a real loss (reject, backwash, sludge, purge), '
     'not unmetered consumption. Any electricity it draws is auxiliary, as a water intake''s '
     'pumps are.');

UPDATE graph.node_class SET description =
     'Takes energy in one utility and delivers a different one: an air compressor takes '
     'electricity and delivers compressed air; a boiler delivers steam. It ends a path on one '
     'utility and starts one on another, and may be metered on both. A node whose output is '
     'the same utility, changed, is TREATMENT.'
 WHERE code = 'CONVERSION';

-- ----------------------------------------------------------------------------
-- 2.3 Move the types and their nodes together
-- ----------------------------------------------------------------------------
ALTER TABLE graph.node      DROP CONSTRAINT fk_node_node_type;
ALTER TABLE graph.node_type DROP CONSTRAINT fk_node_type_parent;

UPDATE graph.node_type SET node_class = 'TREATMENT'
 WHERE code = 'WATER_TREATMENT' OR parent_code = 'WATER_TREATMENT';

UPDATE graph.node n SET node_class = 'TREATMENT'
  FROM graph.node_type t
 WHERE t.code = n.node_type AND t.node_class = 'TREATMENT';

ALTER TABLE graph.node_type ADD CONSTRAINT fk_node_type_parent
    FOREIGN KEY (parent_code, node_class) REFERENCES graph.node_type (code, node_class);
ALTER TABLE graph.node ADD CONSTRAINT fk_node_node_type
    FOREIGN KEY (node_type, node_class) REFERENCES graph.node_type (code, node_class);

-- ----------------------------------------------------------------------------
-- 2.4 Post-conditions
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    got TEXT;
BEGIN
    SELECT string_agg(code, ', ' ORDER BY code) INTO got
    FROM graph.node_type WHERE node_class = 'CONVERSION';
    IF got IS DISTINCT FROM 'AIR_COMPRESSOR, BOILER' THEN
        RAISE EXCEPTION 'CONVERSION types after the move: %', got;
    END IF;

    IF EXISTS (SELECT 1 FROM graph.node n JOIN graph.node_type t ON t.code = n.node_type
               WHERE n.node_class <> t.node_class) THEN
        RAISE EXCEPTION 'a node''s class differs from its type''s';
    END IF;
END
$post$;

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Node classes with their types and node counts ==='
SELECT t.node_class, t.code, count(n.id) AS nodes
FROM graph.node_type t
LEFT JOIN graph.node n ON n.node_type = t.code
WHERE t.node_class IN ('CONVERSION', 'TREATMENT')
GROUP BY 1, 2 ORDER BY 1, 2;
-- expect CONVERSION: AIR_COMPRESSOR, BOILER
--        TREATMENT:  CLARIFIER, REACTION_TANK, RO_UNIT, SOFTENER, WATER_TREATMENT (0)
-- node counts per type as in 1.1

\echo ''
\echo '=== 3.2 v_edge_gaps is still empty ==='
SELECT count(*) AS edge_gaps FROM graph.v_edge_gaps;
-- expect 0


-- ============================================================================
-- 4. Undo (commented) -- moves the types and nodes back to CONVERSION
-- ============================================================================
--
-- BEGIN;
-- ALTER TABLE graph.node      DROP CONSTRAINT fk_node_node_type;
-- ALTER TABLE graph.node_type DROP CONSTRAINT fk_node_type_parent;
-- UPDATE graph.node_type SET node_class = 'CONVERSION' WHERE node_class = 'TREATMENT';
-- UPDATE graph.node      SET node_class = 'CONVERSION' WHERE node_class = 'TREATMENT';
-- ALTER TABLE graph.node_type ADD CONSTRAINT fk_node_type_parent
--     FOREIGN KEY (parent_code, node_class) REFERENCES graph.node_type (code, node_class);
-- ALTER TABLE graph.node ADD CONSTRAINT fk_node_node_type
--     FOREIGN KEY (node_type, node_class) REFERENCES graph.node_type (code, node_class);
-- UPDATE graph.node_class SET description =
--      'A node whose output differs from its input. Either the utility changes (an air '
--      'compressor takes electricity and delivers compressed air; a boiler delivers steam), '
--      'so the node ends a path on one utility and starts one on another and may be metered '
--      'on both; or the same utility leaves changed and with some volume lost (a clarifier, '
--      'softener or RO unit). Inflow need not equal outflow.'
--  WHERE code = 'CONVERSION';
-- DELETE FROM graph.node_class WHERE code = 'TREATMENT';
-- COMMIT;
