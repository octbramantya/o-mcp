-- Migration: 053_node_type_category.sql
-- Description: Category defaults per node type (graph.node_type_category), the FUNCTIONAL root
--              renamed from Purchased Energy to Supply, a colour on every category, and
--              WORKSHOP under Production.
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-sankey.md §4, §5, §8 item 2
-- Requires: 052_comp_winder_under_lvsdp_comp_23.sql
--
-- WHY
-- ---
-- graph.sankey (054) must place a node the day it is inserted, without anyone writing a
-- node_category row for it. Inheritance from the nearest categorised ancestor does most of that,
-- but it puts a utility on a production board into that board's category: AHU_LINE3 under the
-- COMPRESSOR-tagged LVMDP_SPINNING_3 would be drawn as Compressor. A default per node type fixes
-- that class of node by what it is. The order graph.sankey applies is: an explicit node_category
-- row, then the type default, then inheritance, then Unassigned.
--
-- Defaults only where the type alone decides the category (design §4):
--   AIR_COMPRESSOR -> COMPRESSOR, BOILER -> BOILER, AHU -> HVAC, LIGHTING -> LIGHTING.
-- PUMP (chiller side or wastewater), GENERIC_LOAD (workshop or lab), PRODUCTION_MACHINE (its
-- department comes from its board), PROCESS_HEATER and the boards get none and fall through to
-- inheritance.
--
-- The table is per tenant because categories are, and per taxonomy because a COST_CENTRE taxonomy
-- would want different defaults. A composite foreign key keeps each row's category in its
-- taxonomy and tenant; an abstract type is refused, since no node can carry one. Defaults match
-- the node's own type exactly; they are not inherited down node_type.parent_code.
--
-- "Purchased Energy" becomes "Supply" (code SUPPLY): PV and the gas engine are not purchased, and
-- the grid is its own link into the root. Nothing reads the code: graph.resolve_category and
-- v_category_tree work on ids, prs.* does not read graph, and the server has no category tool.
-- Paths in v_category_tree change from PURCHASED_ENERGY/... to SUPPLY/...
--
-- display_color is NULL on all 28 categories. graph.sankey returns each link's colour from the
-- category, so the Grafana panel hardcodes none. The palette groups by branch (Utilities warm,
-- Fabric blue/teal, Yarn violet) and can be changed by updating the rows. Unassigned is not a
-- category; graph.sankey draws it grey.
--
-- WORKSHOP -> PRODUCTION was decided on 2026-10-19 (design §7, G3). It is a GENERIC_LOAD, so no
-- type default reaches it.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 FUNCTIONAL root and colours ==='
SELECT string_agg(category_code || ' / ' || category_name, ', ') FILTER (WHERE parent_id IS NULL) AS root,
       count(*) AS categories, count(display_color) AS with_colour
FROM graph.category WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL';
-- expect PURCHASED_ENERGY / Purchased Energy, 28, 0

\echo ''
\echo '=== 1.2 Nodes in effect of the four default types ==='
SELECT n.node_type, count(*) AS nodes,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM graph.node_category nc WHERE nc.node_id = n.id
                                      AND nc.is_active AND nc.effective_from <= CURRENT_DATE
                                      AND (nc.effective_to IS NULL OR nc.effective_to >= CURRENT_DATE))) AS with_row
FROM graph.node n
WHERE n.tenant_id = 3 AND n.is_active AND n.effective_from <= CURRENT_DATE
  AND (n.effective_to IS NULL OR n.effective_to >= CURRENT_DATE)
  AND n.node_type IN ('AIR_COMPRESSOR', 'BOILER', 'AHU', 'LIGHTING')
GROUP BY 1 ORDER BY 1;


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF (SELECT count(*) FROM graph.category WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL') <> 28 THEN
        RAISE EXCEPTION '053: expected 28 FUNCTIONAL categories for tenant 3';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM graph.category WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL'
                   AND category_code = 'PURCHASED_ENERGY' AND parent_id IS NULL) THEN
        RAISE EXCEPTION '053: PURCHASED_ENERGY is not the FUNCTIONAL root';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.category WHERE display_color IS NOT NULL) THEN
        RAISE EXCEPTION '053: some category already has a colour; this migration assumes none';
    END IF;
    IF to_regclass('graph.node_type_category') IS NOT NULL THEN
        RAISE EXCEPTION '053: graph.node_type_category already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.node_category nc JOIN graph.node n ON n.id = nc.node_id
               WHERE n.tenant_id = 3 AND n.node_code = 'WORKSHOP') THEN
        RAISE EXCEPTION '053: WORKSHOP already has a node_category row';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 2.1 graph.node_type_category
-- ---------------------------------------------------------------------------
ALTER TABLE graph.category
    ADD CONSTRAINT uq_category_id_tenant_taxonomy UNIQUE (id, tenant_id, taxonomy_code);

CREATE TABLE graph.node_type_category (
    tenant_id     INTEGER     NOT NULL,
    node_type     VARCHAR(40) NOT NULL REFERENCES graph.node_type (code),
    taxonomy_code VARCHAR(20) NOT NULL REFERENCES graph.taxonomy (code),
    category_id   BIGINT      NOT NULL,
    created_at    TIMESTAMP   NOT NULL DEFAULT now(),
    updated_at    TIMESTAMP   NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, node_type, taxonomy_code),
    CONSTRAINT fk_ntc_category FOREIGN KEY (category_id, tenant_id, taxonomy_code)
        REFERENCES graph.category (id, tenant_id, taxonomy_code) ON DELETE RESTRICT
);

COMMENT ON TABLE graph.node_type_category IS
    'The category a node of this type reports under when it has no node_category row of its own, '
    'per tenant and taxonomy. graph.sankey applies: explicit row > type default > nearest '
    'categorised ancestor > Unassigned. Only for types whose category the type alone decides '
    '(design/graph-sankey.md §4). Matches the node''s own type exactly, not its parent types.';
COMMENT ON COLUMN graph.node_type_category.node_type IS
    'A concrete node type; abstract types are refused (no node can carry one).';
COMMENT ON COLUMN graph.node_type_category.category_id IS
    'The default category, in this row''s tenant and taxonomy (composite foreign key).';

CREATE FUNCTION graph.assert_ntc_concrete() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
    IF (SELECT is_abstract FROM graph.node_type WHERE code = NEW.node_type) THEN
        RAISE EXCEPTION 'graph.node_type_category: % is abstract; give the default to its subtypes',
            NEW.node_type;
    END IF;
    RETURN NEW;
END
$f$;

CREATE TRIGGER trg_ntc_concrete BEFORE INSERT OR UPDATE OF node_type ON graph.node_type_category
    FOR EACH ROW EXECUTE FUNCTION graph.assert_ntc_concrete();
CREATE TRIGGER trg_ntc_touch BEFORE UPDATE ON graph.node_type_category
    FOR EACH ROW EXECUTE FUNCTION graph.touch_updated_at();

-- graph.assert_abstract_unused (041) refuses making a type abstract while nodes use it; a default
-- on that type would be left pointing at an abstract type, so refuse that too.
CREATE FUNCTION graph.assert_abstract_no_default() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
    IF NEW.is_abstract AND NOT OLD.is_abstract
       AND EXISTS (SELECT 1 FROM graph.node_type_category WHERE node_type = NEW.code) THEN
        RAISE EXCEPTION 'graph.node_type: % has a category default; remove it before making the type abstract',
            NEW.code;
    END IF;
    RETURN NEW;
END
$f$;

CREATE TRIGGER trg_node_type_abstract_default BEFORE UPDATE OF is_abstract ON graph.node_type
    FOR EACH ROW EXECUTE FUNCTION graph.assert_abstract_no_default();

-- Same access as the other tenant tables (044): every role as before, prs_hermes_agent to tenant 3.
ALTER TABLE graph.node_type_category ENABLE ROW LEVEL SECURITY;
CREATE POLICY every_role ON graph.node_type_category AS PERMISSIVE FOR ALL TO PUBLIC
    USING (true) WITH CHECK (true);
CREATE POLICY tenant_3 ON graph.node_type_category AS RESTRICTIVE FOR ALL TO prs_hermes_agent
    USING (tenant_id = 3) WITH CHECK (tenant_id = 3);
COMMENT ON POLICY every_role ON graph.node_type_category IS
    'Every role reads and writes as before row-level security (044). Tenant roles are narrowed by '
    'their own restrictive policy.';
COMMENT ON POLICY tenant_3 ON graph.node_type_category IS
    'prs_hermes_agent sees tenant 3 only (044, design/mcp-tenancy.md).';
GRANT SELECT ON graph.node_type_category TO "grafReader", prs_hermes_agent;

INSERT INTO graph.node_type_category (tenant_id, node_type, taxonomy_code, category_id)
SELECT 3, d.node_type, 'FUNCTIONAL', c.id
FROM (VALUES ('AIR_COMPRESSOR', 'COMPRESSOR'), ('BOILER', 'BOILER'),
             ('AHU', 'HVAC'), ('LIGHTING', 'LIGHTING')) AS d(node_type, category_code)
JOIN graph.category c ON c.tenant_id = 3 AND c.taxonomy_code = 'FUNCTIONAL'
                     AND c.category_code = d.category_code;

-- ---------------------------------------------------------------------------
-- 2.2 Supply, colours, WORKSHOP
-- ---------------------------------------------------------------------------
UPDATE graph.category SET category_code = 'SUPPLY', category_name = 'Supply'
WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL' AND category_code = 'PURCHASED_ENERGY';

UPDATE graph.category c SET display_color = p.color
FROM (VALUES
    ('SUPPLY',     '#5B6770'),
    ('UTILITIES',  '#E07B39'),
    ('BOILER',     '#C0392B'),
    ('COMPRESSOR', '#E67E22'),
    ('HVAC',       '#16A085'),
    ('LIGHTING',   '#F1C40F'),
    ('WTP',        '#2980B9'),
    ('PRODUCTION', '#2E7D32'),
    ('FABRIC',     '#1F618D'),
    ('WJL',        '#2874A6'),
    ('PKN',        '#3498DB'),
    ('AJL',        '#5DADE2'),
    ('TRICOT',     '#85C1E9'),
    ('WSBC',       '#117A65'),
    ('BEAM',       '#148F77'),
    ('RAPID',      '#1ABC9C'),
    ('PRESS',      '#48C9B0'),
    ('RAINCOAT',   '#76D7C4'),
    ('PACKING',    '#0E6655'),
    ('LAB',        '#45B39D'),
    ('PKR',        '#21618C'),
    ('GARUK',      '#5499C7'),
    ('YARN',       '#6C3483'),
    ('SPINNING',   '#7D3C98'),
    ('MC_MOTOR',   '#8E44AD'),
    ('REWINDING',  '#A569BD'),
    ('HEATER',     '#BB8FCE'),
    ('TWISTING',   '#5B2C6F')
) AS p(code, color)
WHERE c.tenant_id = 3 AND c.taxonomy_code = 'FUNCTIONAL' AND c.category_code = p.code;

INSERT INTO graph.node_category (tenant_id, node_id, category_id, weight, effective_from)
SELECT 3, n.id, c.id, 1.0, '1900-01-01'
FROM graph.node n, graph.category c
WHERE n.tenant_id = 3 AND n.node_code = 'WORKSHOP'
  AND c.tenant_id = 3 AND c.taxonomy_code = 'FUNCTIONAL' AND c.category_code = 'PRODUCTION';

DO $$
BEGIN
    IF (SELECT count(*) FROM graph.node_type_category WHERE tenant_id = 3) <> 4 THEN
        RAISE EXCEPTION '053: expected 4 type defaults';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.category WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL'
               AND display_color IS NULL) THEN
        RAISE EXCEPTION '053: a FUNCTIONAL category has no colour';
    END IF;
    IF (SELECT count(*) FROM graph.node_category nc JOIN graph.node n ON n.id = nc.node_id
        WHERE n.tenant_id = 3 AND n.node_code = 'WORKSHOP') <> 1 THEN
        RAISE EXCEPTION '053: WORKSHOP row not added';
    END IF;
END
$$;

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Type defaults ==='
SELECT t.node_type, c.category_code, c.display_color
FROM graph.node_type_category t JOIN graph.category c ON c.id = t.category_id
WHERE t.tenant_id = 3 ORDER BY 1;

\echo ''
\echo '=== 3.2 The FUNCTIONAL tree ==='
SELECT repeat('  ', depth) || category_name AS category, path, display_color
FROM graph.v_category_tree WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL'
ORDER BY sort_key;
-- expect the root as Supply, path SUPPLY/...

\echo ''
\echo '=== 3.3 An abstract type is refused (rolled back) ==='
BEGIN;
DO $$
BEGIN
    BEGIN
        INSERT INTO graph.node_type_category (tenant_id, node_type, taxonomy_code, category_id)
        SELECT 3, 'SWITCHBOARD', 'FUNCTIONAL', id FROM graph.category
        WHERE tenant_id = 3 AND category_code = 'UTILITIES';
        RAISE EXCEPTION '053: an abstract type was accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM LIKE '053:%' THEN RAISE; END IF;
        RAISE NOTICE 'refused as expected: %', SQLERRM;
    END;
END
$$;
ROLLBACK;


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- DELETE FROM graph.node_category nc USING graph.node n, graph.category c
--  WHERE n.id = nc.node_id AND c.id = nc.category_id AND n.tenant_id = 3
--    AND n.node_code = 'WORKSHOP' AND c.category_code = 'PRODUCTION';
-- UPDATE graph.category SET display_color = NULL WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL';
-- UPDATE graph.category SET category_code = 'PURCHASED_ENERGY', category_name = 'Purchased Energy'
--  WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL' AND category_code = 'SUPPLY';
-- DROP TRIGGER trg_node_type_abstract_default ON graph.node_type;
-- DROP FUNCTION graph.assert_abstract_no_default();
-- DROP TABLE graph.node_type_category;
-- DROP FUNCTION graph.assert_ntc_concrete();
-- ALTER TABLE graph.category DROP CONSTRAINT uq_category_id_tenant_taxonomy;
-- COMMIT;
