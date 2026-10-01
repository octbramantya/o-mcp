-- Migration: 018_create_taxonomy_schema.sql
-- Description: Business taxonomy over the physical graph -- the functional view
-- Author: Claude
-- Date: 2026-08-19
-- Phase: 0 -- additive. Nothing reads it until the port (019) seeds it.
--
-- Requires 008 (graph.node, graph.edge) and 016 (the traversal semantics this
-- mirrors). Adds no dependency on 009.
--
-- ---------------------------------------------------------------------------
-- WHY THIS IS NOT A SECOND TOPOLOGY
--
-- prs.device_hierarchy answers a different question from graph.edge, and the
-- difference is real: 27 of its 102 nodes -- PRODUCTION, UTILITIES, FABRIC,
-- YARN, WJL, SPINNING, HVAC, BOILER -- are business abstractions. None of them
-- is a busbar. A C-level reader wants "how are we using energy", not "which
-- meter feeds which meter", and no amount of physical accuracy answers that.
--
-- But the functional view carries no adjacency of its own. Checked against
-- live: 99 mapping rows over 74 leaves and 76 devices, with exactly ONE device
-- (98) in two leaves. It is a partition, not a graph -- a path string per
-- device, where the 27 abstraction nodes are just the distinct prefixes.
--
-- So this is one topology with two projections, not two topologies:
--
--     graph.edge        physical adjacency   -- solve_flow runs here
--     graph.category    business rollup      -- the Sankey groups here
--
-- The functional Sankey solves ONCE on the physical graph -- which is where
-- unmetered load, dual-source nodes and the residual get handled -- and then
-- rolls the SOLVED node values up the category tree instead of the edge tree.
-- Same total, same unaccounted line, different grouping. The two views cannot
-- disagree about the plant total, which is the failure mode of running the
-- legacy Sankey alongside the graph one (it reaches 76 devices; the graph
-- reaches 98, and neither can explain the other's number).
--
-- WHAT IS DELIBERATELY NOT HERE
--
--   * No materialized path column. The legacy public.assets carried one
--     maintained by update_asset_path(), a trigger 015 drops; path drift is a
--     known failure of that pattern. The tree is ~30 rows. graph.v_category_tree
--     computes path and depth on read.
--   * No inheritance stored as data. A tag on a BUS should cover everything
--     below it, but that is a READ-time resolution over graph.edge, not rows to
--     maintain -- graph.resolve_category does it, and says when it is ambiguous.
-- ---------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. The taxonomies themselves
--
-- Keyed by code so a second cut of the business -- COST_CENTRE, ISO50001
-- boundary, shift ownership -- is a row here, not a new table. graph.category
-- carries taxonomy_code, so the trees never mix.
-- ============================================================================

CREATE TABLE IF NOT EXISTS graph.taxonomy (
    code        VARCHAR(20) PRIMARY KEY,
    name        VARCHAR(60) NOT NULL,
    description TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO graph.taxonomy (code, name, description) VALUES
    ('FUNCTIONAL', 'Functional / business',
     'How the plant is organised for reporting: Production vs Utilities, then department, then process. Ported from prs.device_hierarchy.')
ON CONFLICT (code) DO NOTHING;

-- ============================================================================
-- 2. The category tree
--
-- parent_id only -- no level, no display path. The legacy hierarchy stored
-- `level` and the graph deliberately dropped it (§8): a stored depth is one
-- more thing to get wrong during a reorganisation, and the tree is small
-- enough to walk.
-- ============================================================================

CREATE TABLE IF NOT EXISTS graph.category (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      INTEGER      NOT NULL,
    taxonomy_code  VARCHAR(20)  NOT NULL REFERENCES graph.taxonomy(code),
    category_code  VARCHAR(60)  NOT NULL,
    category_name  VARCHAR(120) NOT NULL,
    parent_id      BIGINT       REFERENCES graph.category(id) ON DELETE RESTRICT,
    display_order  INTEGER      NOT NULL DEFAULT 0,
    display_color  VARCHAR(20),
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_category_code UNIQUE (tenant_id, taxonomy_code, category_code),
    CONSTRAINT uq_category_id_tenant UNIQUE (id, tenant_id)
);

CREATE INDEX IF NOT EXISTS ix_category_parent ON graph.category (parent_id)
    WHERE parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_category_taxonomy ON graph.category (tenant_id, taxonomy_code)
    WHERE is_active;

-- ============================================================================
-- 3. Assignment of graph nodes to categories
--
-- Attaches to graph.node, NOT to public.devices. The legacy mapping was
-- device-keyed, which is why it could never place an unmetered node: those have
-- no device to hang a label on, but solve_flow still gives them a value, and
-- that value has to land somewhere in the business rollup.
--
-- WEIGHT exists because a strict partition breaks the first time shared HVAC has
-- to be split across Fabric and Yarn for energy-intensity reporting. Device 98
-- is already that case in miniature. Adding the column now is free; adding it
-- once reports depend on the table is a migration.
--
-- Effective dating mirrors graph.edge: a reorganisation re-cuts the taxonomy
-- without destroying last year's numbers.
-- ============================================================================

CREATE TABLE IF NOT EXISTS graph.node_category (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      INTEGER   NOT NULL,
    node_id        BIGINT    NOT NULL,
    category_id    BIGINT    NOT NULL,
    weight         NUMERIC   NOT NULL DEFAULT 1.0,
    effective_from DATE      NOT NULL DEFAULT '1900-01-01',
    effective_to   DATE,
    is_active      BOOLEAN   NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMP NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_nc_node     FOREIGN KEY (node_id, tenant_id)
        REFERENCES graph.node (id, tenant_id) ON DELETE CASCADE,
    CONSTRAINT fk_nc_category FOREIGN KEY (category_id, tenant_id)
        REFERENCES graph.category (id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT ck_nc_weight   CHECK (weight > 0 AND weight <= 1),
    CONSTRAINT ck_nc_dates    CHECK (effective_to IS NULL OR effective_to >= effective_from),
    CONSTRAINT uq_node_category UNIQUE (tenant_id, node_id, category_id, effective_from)
);

CREATE INDEX IF NOT EXISTS ix_nc_node     ON graph.node_category (tenant_id, node_id)     WHERE is_active;
CREATE INDEX IF NOT EXISTS ix_nc_category ON graph.node_category (tenant_id, category_id) WHERE is_active;

-- ============================================================================
-- 4. Guards
-- ============================================================================

-- 4a. The category tree must stay a tree, and must not straddle taxonomies or
--     tenants. graph.edge has trg_edge_acyclic for the same reason; a cycle here
--     would hang graph.v_category_tree instead of returning a wrong answer.
CREATE OR REPLACE FUNCTION graph.assert_category_tree()
RETURNS TRIGGER LANGUAGE plpgsql AS $fn$
DECLARE
    v_parent_taxonomy VARCHAR;
    v_parent_tenant   INTEGER;
    v_cursor          BIGINT;
    v_hops            INTEGER := 0;
BEGIN
    IF NEW.parent_id IS NULL THEN
        RETURN NEW;
    END IF;

    SELECT c.taxonomy_code, c.tenant_id INTO v_parent_taxonomy, v_parent_tenant
    FROM graph.category c WHERE c.id = NEW.parent_id;

    IF v_parent_taxonomy IS DISTINCT FROM NEW.taxonomy_code THEN
        RAISE EXCEPTION
          'graph.category: % sits in taxonomy % but its parent is in % — trees may not straddle taxonomies',
          NEW.category_code, NEW.taxonomy_code, v_parent_taxonomy;
    END IF;
    IF v_parent_tenant IS DISTINCT FROM NEW.tenant_id THEN
        RAISE EXCEPTION 'graph.category: parent belongs to tenant %, child to tenant %',
          v_parent_tenant, NEW.tenant_id;
    END IF;

    v_cursor := NEW.parent_id;
    WHILE v_cursor IS NOT NULL LOOP
        IF v_cursor = NEW.id THEN
            RAISE EXCEPTION 'graph.category: % would close a cycle in taxonomy %',
              NEW.category_code, NEW.taxonomy_code;
        END IF;
        v_hops := v_hops + 1;
        IF v_hops > 50 THEN
            RAISE EXCEPTION 'graph.category: parent chain above % exceeds 50 levels — already cyclic',
              NEW.category_code;
        END IF;
        SELECT c.parent_id INTO v_cursor FROM graph.category c WHERE c.id = v_cursor;
    END LOOP;

    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_category_tree ON graph.category;
CREATE TRIGGER trg_category_tree
    BEFORE INSERT OR UPDATE ON graph.category
    FOR EACH ROW EXECUTE FUNCTION graph.assert_category_tree();

-- 4b. Weights for one node in one taxonomy must sum to exactly 1 on any date
--     where the node is assigned at all. A node with NO assignment is fine --
--     that is "unclassified", which graph.v_taxonomy_coverage reports.
--
--     DEFERRABLE INITIALLY DEFERRED so a re-cut can delete the old split and
--     insert the new one inside one transaction without the intermediate state
--     tripping it. The window checked is the one containing the row's own
--     effective_from, which is what makes this precise under effective dating
--     rather than a blunt "sum over everything".
CREATE OR REPLACE FUNCTION graph.assert_category_weights()
RETURNS TRIGGER LANGUAGE plpgsql AS $fn$
DECLARE
    v_row      RECORD;
    v_taxonomy VARCHAR;
    v_sum      NUMERIC;
    v_count    INTEGER;
BEGIN
    v_row := COALESCE(NEW, OLD);

    SELECT c.taxonomy_code INTO v_taxonomy
    FROM graph.category c WHERE c.id = v_row.category_id;

    SELECT COALESCE(SUM(nc.weight), 0), COUNT(*)
      INTO v_sum, v_count
    FROM graph.node_category nc
    JOIN graph.category c ON c.id = nc.category_id AND c.taxonomy_code = v_taxonomy
    WHERE nc.tenant_id = v_row.tenant_id
      AND nc.node_id   = v_row.node_id
      AND nc.is_active
      AND nc.effective_from <= v_row.effective_from
      AND (nc.effective_to IS NULL OR nc.effective_to >= v_row.effective_from);

    IF v_count > 0 AND v_sum <> 1.0 THEN
        RAISE EXCEPTION
          'graph.node_category: node % has weights summing to % in taxonomy % as at % — a split allocation must total exactly 1',
          v_row.node_id, v_sum, v_taxonomy, v_row.effective_from;
    END IF;

    RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS trg_nc_weights ON graph.node_category;
CREATE CONSTRAINT TRIGGER trg_nc_weights
    AFTER INSERT OR UPDATE OR DELETE ON graph.node_category
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION graph.assert_category_weights();

DROP TRIGGER IF EXISTS trg_category_touch ON graph.category;
CREATE TRIGGER trg_category_touch BEFORE UPDATE ON graph.category
    FOR EACH ROW EXECUTE FUNCTION graph.touch_updated_at();
DROP TRIGGER IF EXISTS trg_nc_touch ON graph.node_category;
CREATE TRIGGER trg_nc_touch BEFORE UPDATE ON graph.node_category
    FOR EACH ROW EXECUTE FUNCTION graph.touch_updated_at();

COMMIT;

BEGIN;

-- ============================================================================
-- 5. The tree, with path and depth computed on read
-- ============================================================================

CREATE OR REPLACE VIEW graph.v_category_tree AS
WITH RECURSIVE t AS (
    SELECT c.id, c.tenant_id, c.taxonomy_code, c.category_code, c.category_name,
           c.parent_id, c.display_order, c.display_color, c.is_active,
           0 AS depth,
           c.category_code::TEXT AS path,
           ARRAY[c.display_order] AS sort_key
    FROM graph.category c
    WHERE c.parent_id IS NULL
  UNION ALL
    SELECT c.id, c.tenant_id, c.taxonomy_code, c.category_code, c.category_name,
           c.parent_id, c.display_order, c.display_color, c.is_active,
           t.depth + 1,
           t.path || '/' || c.category_code,
           t.sort_key || c.display_order
    FROM t JOIN graph.category c ON c.parent_id = t.id
)
SELECT * FROM t;

COMMENT ON VIEW graph.v_category_tree IS
  'graph.category with path and depth resolved. Recomputed per query — the tree is tens of rows, and a stored path is the drift that update_asset_path() taught us to avoid.';

-- ============================================================================
-- 6. Resolution: which category does a node report under?
--
-- Explicit assignment wins. Otherwise the node inherits from its NEAREST tagged
-- ancestor along graph.edge, which is what lets one tag on AJL2 cover the
-- twelve loads beneath it instead of twelve rows.
--
-- Two outcomes are distinguished on purpose:
--
--   * an explicitly split node returns several rows at hops = 0, weights summing
--     to 1. That is a deliberate allocation, NOT ambiguity.
--   * a node inheriting from two differently-tagged ancestors at the same
--     distance returns is_ambiguous = TRUE. It is reported, not silently
--     resolved -- same posture as is_ambiguous in the flow solver (§5.3).
--
-- p_utility_code scopes the inheritance walk. Leave it NULL and a tie point
-- would propagate an electrical category into the water network.
-- ============================================================================

CREATE OR REPLACE FUNCTION graph.resolve_category(
    p_tenant_id     INTEGER,
    p_taxonomy_code VARCHAR,
    p_utility_code  VARCHAR DEFAULT NULL,
    p_as_of         DATE    DEFAULT CURRENT_DATE,
    p_max_depth     INTEGER DEFAULT 20
) RETURNS TABLE (
    node_id       BIGINT,
    node_code     VARCHAR,
    node_class    VARCHAR,
    category_id   BIGINT,
    category_code VARCHAR,
    category_path TEXT,
    weight        NUMERIC,
    hops          INTEGER,
    is_inherited  BOOLEAN,
    is_ambiguous  BOOLEAN
)
LANGUAGE sql STABLE AS $fn$
WITH RECURSIVE explicit AS (
    SELECT nc.node_id AS nid, nc.category_id AS cid, nc.weight AS w
    FROM graph.node_category nc
    JOIN graph.category c ON c.id = nc.category_id
                         AND c.taxonomy_code = p_taxonomy_code
                         AND c.is_active
    WHERE nc.tenant_id = p_tenant_id
      AND nc.is_active
      AND nc.effective_from <= p_as_of
      AND (nc.effective_to IS NULL OR nc.effective_to >= p_as_of)
), walk AS (
    SELECT e.nid, e.cid, e.w, 0 AS hops
    FROM explicit e
  UNION ALL
    SELECT ch.id, w.cid, w.w, w.hops + 1
    FROM walk w
    JOIN graph.edge g ON g.from_node_id = w.nid
                     AND g.tenant_id = p_tenant_id
                     AND g.is_active
                     AND (p_utility_code IS NULL OR g.utility_code = p_utility_code)
                     AND g.effective_from <= p_as_of
                     AND (g.effective_to IS NULL OR g.effective_to >= p_as_of)
    JOIN graph.node ch ON ch.id = g.to_node_id
                      AND ch.is_active
                      AND ch.effective_from <= p_as_of
                      AND (ch.effective_to IS NULL OR ch.effective_to >= p_as_of)
    WHERE w.hops < p_max_depth
      -- stop at any node that states its own category; explicit always wins
      AND NOT EXISTS (SELECT 1 FROM explicit e2 WHERE e2.nid = ch.id)
), nearest AS (
    SELECT DISTINCT w.nid, w.cid, w.w, w.hops,
           MIN(w.hops) OVER (PARTITION BY w.nid) AS min_hops
    FROM walk w
), winners AS (
    SELECT n.nid, n.cid, n.w, n.hops,
           COUNT(*) OVER (PARTITION BY n.nid) AS cats_at_this_distance
    FROM nearest n WHERE n.hops = n.min_hops
)
SELECT wn.nid, nd.node_code, nd.node_class,
       wn.cid, ct.category_code, ct.path, wn.w, wn.hops,
       (wn.hops > 0) AS is_inherited,
       (wn.hops > 0 AND wn.cats_at_this_distance > 1) AS is_ambiguous
FROM winners wn
JOIN graph.node nd           ON nd.id = wn.nid
JOIN graph.v_category_tree ct ON ct.id = wn.cid
ORDER BY nd.node_code, ct.path;
$fn$;

-- ============================================================================
-- 7. What is not classified yet
--
-- The port (019) will not reach everything: the graph carries 98 metered
-- electricity devices against the legacy hierarchy's 76, so ~23 arrive with no
-- business home. This view is where that shows up, rather than as a silently
-- missing slice of the Sankey.
-- ============================================================================

CREATE OR REPLACE VIEW graph.v_taxonomy_coverage AS
SELECT t.code AS taxonomy_code,
       n.tenant_id,
       n.node_class,
       COUNT(*)                                            AS nodes,
       COUNT(*) FILTER (WHERE r.node_id IS NOT NULL)       AS classified,
       COUNT(*) FILTER (WHERE r.is_inherited)              AS by_inheritance,
       COUNT(*) FILTER (WHERE r.is_ambiguous)              AS ambiguous,
       COUNT(*) FILTER (WHERE r.node_id IS NULL)           AS unclassified
FROM graph.taxonomy t
CROSS JOIN graph.node n
LEFT JOIN LATERAL (
    SELECT DISTINCT rc.node_id, rc.is_inherited, rc.is_ambiguous
    FROM graph.resolve_category(n.tenant_id, t.code) rc
    WHERE rc.node_id = n.id
) r ON TRUE
WHERE n.is_active AND t.is_active
GROUP BY 1, 2, 3;

COMMENT ON VIEW graph.v_taxonomy_coverage IS
  'Per taxonomy and node class: how many nodes have a business home, how many got it by inheritance, how many are ambiguous, how many have none. Read this after any seed.';

COMMIT;

-- ============================================================================
-- 8. Grants -- guarded, so the file runs on a cluster with no grafReader.
--    010 already set ALTER DEFAULT PRIVILEGES for the schema, so this is
--    belt-and-braces for anything created by a different role.
-- ============================================================================

DO $grant$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafReader') THEN
        EXECUTE 'GRANT SELECT ON ALL TABLES IN SCHEMA graph TO "grafReader"';
        EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graph TO "grafReader"';
    END IF;
END $grant$;

-- ============================================================================
-- Verification
-- ============================================================================
-- SELECT * FROM graph.v_category_tree ORDER BY tenant_id, taxonomy_code, sort_key;
-- SELECT * FROM graph.resolve_category(3, 'FUNCTIONAL', 'ELECTRICITY');
-- SELECT * FROM graph.v_taxonomy_coverage;
-- SELECT * FROM graph.resolve_category(3, 'FUNCTIONAL', 'ELECTRICITY') WHERE is_ambiguous;
