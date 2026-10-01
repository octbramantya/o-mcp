-- Migration: 019_port_functional_taxonomy.sql
-- Description: Port prs.device_hierarchy into the FUNCTIONAL taxonomy (018)
-- Author: Claude
-- Date: 2026-08-19
-- Phase: 4 -- the business view moves onto the graph. Read-only until the UI
--            switches, but it is a seed, so it writes.
--
-- Requires 008, 011, 016 and 018. (016 only for the review query in section 5;
-- the port itself needs 008/011/018.)
--
-- ###########################################################################
-- # MUST RUN BEFORE 014.
-- #
-- # This derives from prs.device_hierarchy and prs.device_node_mapping rather
-- # than hardcoding 28 categories and ~70 assignments, because the live tables
-- # ARE the specification and a hand-copy would be one transcription error away
-- # from a wrong departmental total. 014 drops those tables. Once this has run,
-- # the taxonomy lives in graph.category / graph.node_category and no replay is
-- # needed -- but replaying THIS file after 014 is impossible, which is the
-- # trade accepted for fidelity. Section 0 refuses rather than half-running.
-- ###########################################################################
--
-- ---------------------------------------------------------------------------
-- WHAT IS PORTED, AND WHAT IS DELIBERATELY NOT
--
-- The legacy tree has 102 nodes for tenant 3:
--
--     1  ROOT        PURCHASED_ENERGY          -> category
--     3  SOURCE      GRID, PLTS_A, PLTS_B      -> NOT ported (see below)
--     2  CATEGORY    UTILITIES, PRODUCTION     -> category
--     2  DEPARTMENT  FABRIC, YARN              -> category
--     5  GROUP       BOILER, COMPRESSOR, ...   -> category
--    18  PROCESS     WJL, AJL, SPINNING, ...   -> category
--    71  DEVICE      leaves                    -> assignments, via device_id
--
-- so 28 categories and one assignment per graph node the leaves resolve to.
--
-- The three SOURCE nodes are NOT categories. They map one-to-one onto graph
-- SOURCE nodes already -- GRID -> INCOMING_PLN, PLTS_A -> PLTS_A,
-- PLTS_B -> PLTS_B -- so they are the supply side of the Sankey, which the
-- physical graph already models. Re-creating them as business categories would
-- put the same three nodes on both sides of the diagram.
--
-- TWO ROWS ARE EXCLUDED BY NAME. Both were confirmed against live:
--
--   * HVAC_A4 -> device 98 "Compressor SCR 2200". Device 98 is seeded under
--     both COMP_SCR2200 (COMPRESSOR) and HVAC_A4 (HVAC) -- the double-seeding
--     bug already noted in §8. Its real home is COMPRESSOR; HVAC_A4 keeps its
--     other device, 26 "LVMDB A4", so the leaf is not lost. Without this
--     exclusion graph.node COMP_SCR2200 would receive two categories at weight
--     1.0 each and trip the weight guard.
--
--   * COMP_TURBO300HP -> device 53 "Compressor Turbo 300HP". An active Power
--     Meter in the legacy hierarchy with ZERO rows in graph.measurement, so
--     there is no graph node to attach a category to. It is not excluded by a
--     rule here -- the join simply finds nothing -- but it is recorded because
--     the silence is otherwise indistinguishable from success. Either it needs
--     a measurement row in the graph or it is decommissioned; that is an open
--     question for the plant, not something this file should guess.
-- ---------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 0. Refuse rather than half-run
-- ============================================================================

DO $$
DECLARE v_n INTEGER;
BEGIN
    IF to_regclass('prs.device_hierarchy') IS NULL
       OR to_regclass('prs.device_node_mapping') IS NULL THEN
        RAISE EXCEPTION
          'refusing to port the taxonomy: prs.device_hierarchy / prs.device_node_mapping '
          'are gone, so 014 has already run. This file cannot be replayed -- restore from '
          'deprecated_tables.*_20260819 or seed graph.category by hand.';
    END IF;

    SELECT COUNT(*) INTO v_n FROM graph.category
     WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL';
    IF v_n > 0 THEN
        RAISE EXCEPTION
          'refusing to port: graph.category already holds % FUNCTIONAL rows for tenant 3. '
          'Delete them first if you mean to re-port -- appending would duplicate the tree.', v_n;
    END IF;

    SELECT COUNT(*) INTO v_n FROM graph.node WHERE tenant_id = 3 AND is_active;
    IF v_n < 100 THEN
        RAISE EXCEPTION 'refusing to port: graph.node has only % active nodes for tenant 3. Run 011 first.', v_n;
    END IF;
END $$;

-- ============================================================================
-- 1. The abstraction tree, level by level
--
-- Staged rather than recursive because parent_id is a generated key: each
-- level joins to the level already inserted. Four statements cover the tree's
-- actual depth; a fifth level would silently drop, so section 2 counts.
-- ============================================================================

-- 1a. root
INSERT INTO graph.category (tenant_id, taxonomy_code, category_code, category_name, parent_id, display_order)
SELECT 3, 'FUNCTIONAL', dh.node_code, dh.node_name, NULL, dh.display_order
FROM prs.device_hierarchy dh
WHERE dh.tenant_id = 3 AND dh.is_active AND dh.node_type = 'ROOT';

-- 1b. CATEGORY under the root
INSERT INTO graph.category (tenant_id, taxonomy_code, category_code, category_name, parent_id, display_order)
SELECT 3, 'FUNCTIONAL', dh.node_code, dh.node_name, p.id, dh.display_order
FROM prs.device_hierarchy dh
JOIN graph.category p ON p.tenant_id = 3 AND p.taxonomy_code = 'FUNCTIONAL'
                     AND p.category_code = dh.parent_code
WHERE dh.tenant_id = 3 AND dh.is_active AND dh.node_type = 'CATEGORY';

-- 1c. DEPARTMENT and GROUP under CATEGORY
INSERT INTO graph.category (tenant_id, taxonomy_code, category_code, category_name, parent_id, display_order)
SELECT 3, 'FUNCTIONAL', dh.node_code, dh.node_name, p.id, dh.display_order
FROM prs.device_hierarchy dh
JOIN graph.category p ON p.tenant_id = 3 AND p.taxonomy_code = 'FUNCTIONAL'
                     AND p.category_code = dh.parent_code
WHERE dh.tenant_id = 3 AND dh.is_active AND dh.node_type IN ('DEPARTMENT', 'GROUP');

-- 1d. PROCESS under DEPARTMENT
INSERT INTO graph.category (tenant_id, taxonomy_code, category_code, category_name, parent_id, display_order)
SELECT 3, 'FUNCTIONAL', dh.node_code, dh.node_name, p.id, dh.display_order
FROM prs.device_hierarchy dh
JOIN graph.category p ON p.tenant_id = 3 AND p.taxonomy_code = 'FUNCTIONAL'
                     AND p.category_code = dh.parent_code
WHERE dh.tenant_id = 3 AND dh.is_active AND dh.node_type = 'PROCESS';

-- ============================================================================
-- 2. Every abstraction node must have landed
--
-- The staged inserts above assume the tree is exactly ROOT / CATEGORY /
-- (DEPARTMENT|GROUP) / PROCESS. If the legacy tree ever grew another level this
-- would quietly drop it, so count instead of assuming.
-- ============================================================================

DO $$
DECLARE v_expected INTEGER; v_got INTEGER; v_missing TEXT;
BEGIN
    SELECT COUNT(*) INTO v_expected FROM prs.device_hierarchy
     WHERE tenant_id = 3 AND is_active
       AND node_type IN ('ROOT','CATEGORY','DEPARTMENT','GROUP','PROCESS');
    SELECT COUNT(*) INTO v_got FROM graph.category
     WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL';

    IF v_got <> v_expected THEN
        SELECT string_agg(dh.node_code || ' (' || dh.node_type || ')', ', ')
          INTO v_missing
        FROM prs.device_hierarchy dh
        WHERE dh.tenant_id = 3 AND dh.is_active
          AND dh.node_type IN ('ROOT','CATEGORY','DEPARTMENT','GROUP','PROCESS')
          AND NOT EXISTS (SELECT 1 FROM graph.category c
                           WHERE c.tenant_id = 3 AND c.taxonomy_code = 'FUNCTIONAL'
                             AND c.category_code = dh.node_code);
        RAISE EXCEPTION
          'taxonomy port incomplete: expected % abstraction nodes, inserted %. Missing: %',
          v_expected, v_got, COALESCE(v_missing, '(none named — check for duplicates)');
    END IF;
END $$;

-- ============================================================================
-- 3. Refuse a split we did not author
--
-- Exactly one graph node is reached from two different categories, and it is
-- the device-98 double-seed excluded in section 4. Anything else is new, and
-- it must be a decision -- with a weight -- not an accident. Checking here
-- gives a readable message instead of the weight trigger's arithmetic one.
-- ============================================================================

DO $$
DECLARE v_conflicts TEXT;
BEGIN
    SELECT string_agg(x.node_code || ' <- ' || x.cats, '; ')
      INTO v_conflicts
    FROM (
        SELECT gn.node_code, string_agg(DISTINCT dh.parent_code, ' + ') AS cats
        FROM prs.device_hierarchy dh
        JOIN prs.device_node_mapping dnm ON dnm.node_code = dh.node_code
                                        AND dnm.tenant_id = dh.tenant_id
        JOIN graph.measurement gm ON gm.device_id = dnm.device_id
                                 AND gm.tenant_id = 3 AND gm.is_active
                                 AND gm.utility_code = 'ELECTRICITY'
        JOIN graph.node gn ON gn.id = gm.node_id
        WHERE dh.tenant_id = 3 AND dh.is_active AND dh.node_type = 'DEVICE'
          AND NOT (dh.node_code = 'HVAC_A4' AND dnm.device_id = 98)
        GROUP BY gn.node_code
        HAVING COUNT(DISTINCT dh.parent_code) > 1
    ) x;

    IF v_conflicts IS NOT NULL THEN
        RAISE EXCEPTION
          'refusing to port: these graph nodes are claimed by more than one category — %. '
          'Each needs an explicit weight, or the legacy seeding is wrong. Do not resolve this '
          'by picking one arbitrarily.', v_conflicts;
    END IF;
END $$;

-- ============================================================================
-- 4. The assignments
--
-- DISTINCT because graph.measurement holds one row per (device, quantity) --
-- a device with eight registers must not produce eight identical assignments.
-- Attaches to gm.node_id, so a node fed by several metered devices in the same
-- category collapses to one row, which is correct.
-- ============================================================================

INSERT INTO graph.node_category (tenant_id, node_id, category_id, weight)
SELECT DISTINCT 3, gm.node_id, c.id, 1.0
FROM prs.device_hierarchy dh
JOIN prs.device_node_mapping dnm ON dnm.node_code = dh.node_code
                                AND dnm.tenant_id = dh.tenant_id
JOIN graph.measurement gm ON gm.device_id = dnm.device_id
                         AND gm.tenant_id = 3 AND gm.is_active
                         AND gm.utility_code = 'ELECTRICITY'
JOIN graph.category c ON c.tenant_id = 3 AND c.taxonomy_code = 'FUNCTIONAL'
                     AND c.category_code = dh.parent_code
WHERE dh.tenant_id = 3 AND dh.is_active AND dh.node_type = 'DEVICE'
  AND NOT (dh.node_code = 'HVAC_A4' AND dnm.device_id = 98);   -- see header

COMMIT;

-- ============================================================================
-- 5. Report -- read-only. Run it and read it; none of this raises.
-- ============================================================================

\echo ''
\echo '--- Categories ported ---'
SELECT depth, COUNT(*) AS categories, string_agg(category_code, ', ' ORDER BY category_code) AS codes
FROM graph.v_category_tree
WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL'
GROUP BY depth ORDER BY depth;

\echo ''
\echo '--- Coverage after the port (SOURCE is expected to be 0: supply, not consumption) ---'
SELECT node_class, nodes, classified, by_inheritance, ambiguous, unclassified
FROM graph.v_taxonomy_coverage
WHERE tenant_id = 3 AND taxonomy_code = 'FUNCTIONAL'
ORDER BY node_class;

\echo ''
\echo '--- Anything ambiguous? (expect none; inheritance conflicts show here) ---'
SELECT node_code, node_class, category_path, hops
FROM graph.resolve_category(3, 'FUNCTIONAL', 'ELECTRICITY')
WHERE is_ambiguous ORDER BY node_code, category_path;

\echo ''
\echo '--- REVIEW: assignments obtained by inheritance, and the tagged node they came from ---'
\echo '--- A tag on a distribution board propagates to everything it feeds. Where that board  ---'
\echo '--- serves mixed loads, the inherited category is wrong and needs an explicit override. ---'
WITH r AS (
    SELECT node_id, node_code, node_class, category_code, hops
    FROM graph.resolve_category(3, 'FUNCTIONAL', 'ELECTRICITY') WHERE is_inherited
)
SELECT r.category_code, r.node_code, r.node_class,
       (SELECT string_agg(a.node_code, ', ')
          FROM graph.ancestors(3, r.node_code, 'ELECTRICITY'::VARCHAR) a
         WHERE a.depth = r.hops
           AND EXISTS (SELECT 1 FROM graph.node_category nc WHERE nc.node_id = a.node_id)) AS inherited_from
FROM r ORDER BY r.category_code, r.node_code;

\echo ''
\echo '--- Metered electricity nodes with no business home ---'
SELECT gn.node_code, gn.node_class, gn.node_name
FROM (SELECT DISTINCT m.node_id FROM graph.measurement m
       WHERE m.tenant_id = 3 AND m.is_active AND m.utility_code = 'ELECTRICITY') mm
JOIN graph.node gn ON gn.id = mm.node_id
WHERE NOT EXISTS (SELECT 1 FROM graph.resolve_category(3, 'FUNCTIONAL', 'ELECTRICITY') r
                   WHERE r.node_id = gn.id)
ORDER BY gn.node_class, gn.node_code;

\echo ''
\echo '--- Legacy leaves that reached no graph node (expect COMP_TURBO300HP / device 53) ---'
SELECT DISTINCT dh.node_code, dh.parent_code AS category, dnm.device_id, d.device_name
FROM prs.device_hierarchy dh
JOIN prs.device_node_mapping dnm ON dnm.node_code = dh.node_code AND dnm.tenant_id = dh.tenant_id
JOIN public.devices d ON d.id = dnm.device_id
WHERE dh.tenant_id = 3 AND dh.is_active AND dh.node_type = 'DEVICE'
  AND NOT EXISTS (SELECT 1 FROM graph.measurement gm
                   WHERE gm.device_id = dnm.device_id AND gm.tenant_id = 3
                     AND gm.is_active AND gm.utility_code = 'ELECTRICITY')
ORDER BY 1;
