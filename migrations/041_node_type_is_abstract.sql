-- Migration: 041_node_type_is_abstract.sql
-- Description: Record which node types are abstract (graph.node_type.is_abstract), and
--              refuse an abstract type on a node.
-- Author: Claude
-- Date: 2026-10-05
-- Design: design/type-property.md §3.2; design/mcp-tools.md (gap 2)
-- Requires: 040_drop_thd_current_rollup.sql
--
-- WHY
-- ---
-- SWITCHBOARD and WATER_TREATMENT (026) exist to hold properties their subtypes
-- inherit through v_type_property: nominal_v once for every board, volume_m3
-- once for every treatment stage. Nothing on site is "a switchboard"; a board
-- is a MAIN_LV_BOARD, MV_BUS or SUB_BOARD. Being abstract is recorded only in
-- the descriptions ("Abstract: ... Not assigned to nodes directly"), which no
-- code reads, and the MCP draft derives it as "has subtypes". That is right
-- today and wrong as soon as an abstract type is added before its subtypes, or
-- a concrete type in use gains one. Nor does anything stop a node being typed
-- SWITCHBOARD: fk_node_node_type accepts any type, and no node is only by
-- convention.
--
-- This adds the column, sets it on the two, and enforces it both ways:
--   - graph.node: an abstract node_type is refused (new trigger, beside
--     trg_node_attrs, which stays as it is);
--   - graph.node_type: is_abstract cannot become TRUE while nodes use the type.
-- Endpoint rules may still name an abstract type; covering every subtype at
-- once is what they are for there.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Types with subtypes, and nodes typed with them directly ==='
SELECT p.code, p.description,
       (SELECT count(*) FROM graph.node_type c WHERE c.parent_code = p.code) AS subtypes,
       (SELECT count(*) FROM graph.node n WHERE n.node_type = p.code) AS nodes
FROM graph.node_type p
WHERE EXISTS (SELECT 1 FROM graph.node_type c WHERE c.parent_code = p.code)
ORDER BY 1;
-- expect SWITCHBOARD 3 subtypes, WATER_TREATMENT 5; 0 nodes each


-- ============================================================================
-- 2. Change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run unless the types are exactly as described above
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    parents TEXT;
    n INT;
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'graph' AND table_name = 'node_type'
                 AND column_name = 'is_abstract') THEN
        RAISE EXCEPTION 'graph.node_type.is_abstract already exists';
    END IF;

    SELECT string_agg(DISTINCT parent_code, ', ' ORDER BY parent_code) INTO parents
    FROM graph.node_type WHERE parent_code IS NOT NULL;
    IF parents IS DISTINCT FROM 'SWITCHBOARD, WATER_TREATMENT' THEN
        RAISE EXCEPTION 'expected parents SWITCHBOARD, WATER_TREATMENT; found %', parents;
    END IF;

    SELECT count(*) INTO n FROM graph.node
    WHERE node_type IN ('SWITCHBOARD', 'WATER_TREATMENT');
    IF n <> 0 THEN
        RAISE EXCEPTION '% nodes are typed SWITCHBOARD or WATER_TREATMENT directly; retype them first', n;
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 2.2 The column
-- ----------------------------------------------------------------------------
ALTER TABLE graph.node_type
    ADD COLUMN is_abstract BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN graph.node_type.is_abstract IS
    'TRUE: the type exists to hold properties and endpoint rules its subtypes inherit, and is '
    'never assigned to a node. Set by hand, not derived from having subtypes: an abstract type '
    'may have none yet, and a concrete type may gain some.';

UPDATE graph.node_type SET is_abstract = TRUE
 WHERE code IN ('SWITCHBOARD', 'WATER_TREATMENT');

-- The descriptions said it in prose; the column says it now. Keep the meaning.
UPDATE graph.node_type
   SET description = 'Any board or bus: holds the properties every board shares. '
                     || 'Use MAIN_LV_BOARD, MV_BUS or SUB_BOARD on a node.'
 WHERE code = 'SWITCHBOARD';
UPDATE graph.node_type
   SET description = 'Any water treatment stage: holds the properties every stage shares. '
                     || 'Use one of its subtypes on a node.'
 WHERE code = 'WATER_TREATMENT';

-- ----------------------------------------------------------------------------
-- 2.3 A node may not carry an abstract type
-- ----------------------------------------------------------------------------
CREATE FUNCTION graph.assert_node_type_concrete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.node_type IS NOT NULL AND EXISTS (
           SELECT 1 FROM graph.node_type t WHERE t.code = NEW.node_type AND t.is_abstract) THEN
        RAISE EXCEPTION 'graph.node %: % is abstract and is not assigned to nodes. Use one of: %',
            NEW.node_code, NEW.node_type,
            COALESCE((SELECT string_agg(c.code, ', ' ORDER BY c.code)
                        FROM graph.node_type c
                       WHERE c.parent_code = NEW.node_type AND NOT c.is_abstract),
                     '(no subtype yet)');
    END IF;
    RETURN NEW;
END;
$$;

-- Named to sort before trg_node_attrs: triggers fire in name order, and an
-- abstract type should be refused as such, not for its attrs.
CREATE TRIGGER trg_node_abstract_type
    BEFORE INSERT OR UPDATE OF node_type ON graph.node
    FOR EACH ROW EXECUTE FUNCTION graph.assert_node_type_concrete();

-- ----------------------------------------------------------------------------
-- 2.4 A type in use may not be made abstract
-- ----------------------------------------------------------------------------
CREATE FUNCTION graph.assert_abstract_unused() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    n INT;
BEGIN
    IF NEW.is_abstract THEN
        SELECT count(*) INTO n FROM graph.node WHERE node_type = NEW.code;
        IF n > 0 THEN
            RAISE EXCEPTION 'graph.node_type %: % nodes carry this type; retype them before making it abstract',
                NEW.code, n;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_node_type_abstract
    BEFORE UPDATE OF is_abstract ON graph.node_type
    FOR EACH ROW EXECUTE FUNCTION graph.assert_abstract_unused();

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Abstract types ==='
SELECT code, node_class, is_abstract,
       (SELECT count(*) FROM graph.node_type c WHERE c.parent_code = t.code) AS subtypes
FROM graph.node_type t WHERE is_abstract ORDER BY 1;
SELECT count(*) AS concrete FROM graph.node_type WHERE NOT is_abstract;
-- expect SWITCHBOARD (3), WATER_TREATMENT (5); 25 concrete

\echo ''
\echo '=== 3.2 Refusals (each rolled back) ==='
DO $$
DECLARE
    probes TEXT[] := ARRAY[
        $p$UPDATE graph.node SET node_type = 'SWITCHBOARD' WHERE node_code = 'LVMDB_TEXTURE_2' AND tenant_id = 3$p$,
        $p$UPDATE graph.node_type SET is_abstract = TRUE WHERE code = 'PUMP'$p$
    ];
    p TEXT;
BEGIN
    FOREACH p IN ARRAY probes LOOP
        BEGIN
            EXECUTE p;
            RAISE EXCEPTION 'probe not refused: %', p;
        EXCEPTION WHEN raise_exception THEN
            IF SQLERRM LIKE 'probe not refused%' THEN RAISE; END IF;
            RAISE NOTICE 'refused as expected: %', SQLERRM;
        END;
    END LOOP;
END
$$;

\echo ''
\echo '=== 3.3 Nothing else moved ==='
SELECT status, count(*) FROM graph.v_property_gaps GROUP BY 1 ORDER BY 1;
SELECT count(*) AS edge_gaps FROM graph.v_edge_gaps;
-- expect MISSING 31, 0 edge gaps


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- DROP TRIGGER trg_node_type_abstract ON graph.node_type;
-- DROP TRIGGER trg_node_abstract_type ON graph.node;
-- DROP FUNCTION graph.assert_abstract_unused();
-- DROP FUNCTION graph.assert_node_type_concrete();
-- ALTER TABLE graph.node_type DROP COLUMN is_abstract;
-- UPDATE graph.node_type SET description = 'Abstract: any board or bus. Not assigned to nodes directly.'
--  WHERE code = 'SWITCHBOARD';
-- UPDATE graph.node_type SET description = 'Abstract: any water treatment stage.'
--  WHERE code = 'WATER_TREATMENT';
-- COMMIT;
