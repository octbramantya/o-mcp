-- Migration: 025_rename_plts_nodes.sql
-- Description: Rename tenant 3's two PV arrays to the codes site uses:
--              PLTS_A -> PLTS_A5 and PLTS_B -> PLTS_B2
-- Author: Claude
-- Date: 2026-09-28
--
-- Why: site names each array after the board it feeds. The graph calls them
-- PLTS_A and PLTS_B, which read like a matched pair and match nothing on site
-- or on the current-ratings survey (design/draft_current_ratings_mapped.csv,
-- where the panel names are "PLTS A5" and "PLTS B2"). PLTS_A4 and
-- PLTS_TEXTURE already agree with site and are left alone. Confirmed by the
-- user 2026-09-28.
--
-- This ships separately from, and before, 026_create_node_type_property.sql so
-- that 026's explicit node_code lists are written against the final names and
-- either migration can be rolled back without the other. See
-- design/type-property.md 4.5.
--
-- Scope. The rename is safe inside the graph schema: graph.edge references
-- node_id, not node_code (008), as do graph.measurement and the taxonomy
-- tables. No edge, measurement or category row needs re-pointing.
--
-- It is NOT contained to graph. The legacy prs.device_hierarchy carries the
-- same node_code values (002 lines 33-34), prs.device_node_mapping maps device
-- 27 to PLTS_A and device 11 to PLTS_B (002 lines 116-117), and
-- prs.device_hierarchy.parent_code is a plain string reference rather than a
-- foreign key. All three move together here. Section 1 asserts that no other
-- table holds these strings before anything is written.
--
-- Nothing reads the old codes from SQL: graph functions take node_code as a
-- parameter but no function body contains a literal 'PLTS_A'.
--
-- Also needed, outside SQL, after this is applied:
--   * re-run ../pq-analysis/scripts/graph_snapshot.py (regenerates
--     ../prs_diags/docs/graph_nodes.csv, graph_edges.csv, graph_network.md)
--   * reference/graph_sankey_orphan.csv, design/graph-network-seed.csv
--     and graph-seed-v1.csv carry the old codes and are stale afterwards
--   * past outputs under ../pq-analysis/reports/ keep the old code and are left
--     alone: they are records of what was run
--
-- ============================================================================
-- 1. Evidence -- read-only. Run this first and read it.
-- ============================================================================

SELECT 'Nodes to rename (expect exactly 2 rows)' AS check_name;
SELECT id, tenant_id, node_code, node_name, node_class
FROM graph.node
WHERE tenant_id = 3 AND node_code IN ('PLTS_A', 'PLTS_B')
ORDER BY node_code;

SELECT 'Target codes must not already exist (expect 0 rows)' AS check_name;
SELECT id, node_code FROM graph.node
WHERE tenant_id = 3 AND node_code IN ('PLTS_A5', 'PLTS_B2');

SELECT 'Edges that will follow the rename automatically (by node_id)' AS check_name;
SELECT p.node_code AS from_code, c.node_code AS to_code, e.utility_code, e.edge_class
FROM graph.edge e
JOIN graph.node p ON p.id = e.from_node_id
JOIN graph.node c ON c.id = e.to_node_id
WHERE e.tenant_id = 3 AND (p.node_code IN ('PLTS_A','PLTS_B')
                        OR c.node_code IN ('PLTS_A','PLTS_B'))
ORDER BY 1, 2;

SELECT 'Legacy prs rows that must be renamed by hand' AS check_name;
SELECT 'device_hierarchy' AS tbl, node_code AS val FROM prs.device_hierarchy
WHERE tenant_id = 3 AND node_code IN ('PLTS_A','PLTS_B')
UNION ALL
SELECT 'device_hierarchy.parent_code', parent_code FROM prs.device_hierarchy
WHERE tenant_id = 3 AND parent_code IN ('PLTS_A','PLTS_B')
UNION ALL
SELECT 'device_node_mapping', node_code FROM prs.device_node_mapping
WHERE tenant_id = 3 AND node_code IN ('PLTS_A','PLTS_B');

-- Any other table anywhere holding these strings? (expect only the ones above)
SELECT 'Other columns containing the old codes' AS check_name;
DO $$
DECLARE
    r   RECORD;
    n   BIGINT;
BEGIN
    FOR r IN
        SELECT c.relnamespace::regnamespace AS ns, c.relname AS tbl, a.attname AS col
        FROM pg_class c
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
        JOIN pg_type t ON t.oid = a.atttypid
        WHERE c.relkind = 'r'
          AND c.relnamespace::regnamespace::text IN ('graph', 'prs', 'public')
          AND t.typname IN ('varchar', 'text', 'bpchar')
    LOOP
        EXECUTE format('SELECT count(*) FROM %I.%I WHERE %I IN (''PLTS_A'',''PLTS_B'')',
                       r.ns, r.tbl, r.col) INTO n;
        IF n > 0 THEN
            RAISE NOTICE '% .% .% holds % row(s)', r.ns, r.tbl, r.col, n;
        END IF;
    END LOOP;
END $$;

-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- 2.1 The graph. uq_node_tenant_code (tenant_id, node_code) keeps this honest:
--     if PLTS_A5 somehow existed already, this fails rather than merging.
UPDATE graph.node
   SET node_code = 'PLTS_A5', node_name = 'PLTS A5', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code = 'PLTS_A';

UPDATE graph.node
   SET node_code = 'PLTS_B2', node_name = 'PLTS B2', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code = 'PLTS_B';

-- 2.2 The legacy hierarchy. parent_code is a bare string, so children have to
--     be re-pointed explicitly; device_node_mapping has an FK onto
--     (tenant_id, node_code), so its rows move with the parent row. Order
--     matters only in that all three land in one transaction.
UPDATE prs.device_hierarchy
   SET node_code = 'PLTS_A5', node_name = 'PLTS A5'
 WHERE tenant_id = 3 AND node_code = 'PLTS_A';

UPDATE prs.device_hierarchy
   SET node_code = 'PLTS_B2', node_name = 'PLTS B2'
 WHERE tenant_id = 3 AND node_code = 'PLTS_B';

UPDATE prs.device_hierarchy
   SET parent_code = 'PLTS_A5'
 WHERE tenant_id = 3 AND parent_code = 'PLTS_A';

UPDATE prs.device_hierarchy
   SET parent_code = 'PLTS_B2'
 WHERE tenant_id = 3 AND parent_code = 'PLTS_B';

UPDATE prs.device_node_mapping
   SET node_code = 'PLTS_A5'
 WHERE tenant_id = 3 AND node_code = 'PLTS_A';

UPDATE prs.device_node_mapping
   SET node_code = 'PLTS_B2'
 WHERE tenant_id = 3 AND node_code = 'PLTS_B';

-- 2.3 Nothing may be left holding the old codes.
DO $$
DECLARE
    leftover BIGINT;
BEGIN
    SELECT count(*) INTO leftover FROM graph.node
     WHERE tenant_id = 3 AND node_code IN ('PLTS_A','PLTS_B');
    IF leftover > 0 THEN
        RAISE EXCEPTION 'graph.node still holds % old PLTS code(s)', leftover;
    END IF;

    SELECT count(*) INTO leftover FROM prs.device_hierarchy
     WHERE tenant_id = 3 AND (node_code IN ('PLTS_A','PLTS_B')
                           OR parent_code IN ('PLTS_A','PLTS_B'));
    IF leftover > 0 THEN
        RAISE EXCEPTION 'prs.device_hierarchy still holds % old PLTS code(s)', leftover;
    END IF;

    SELECT count(*) INTO leftover FROM prs.device_node_mapping
     WHERE tenant_id = 3 AND node_code IN ('PLTS_A','PLTS_B');
    IF leftover > 0 THEN
        RAISE EXCEPTION 'prs.device_node_mapping still holds % old PLTS code(s)', leftover;
    END IF;

    SELECT count(*) INTO leftover FROM graph.node
     WHERE tenant_id = 3 AND node_code IN ('PLTS_A5','PLTS_B2');
    IF leftover <> 2 THEN
        RAISE EXCEPTION 'expected 2 renamed nodes, found %', leftover;
    END IF;
END $$;

COMMIT;

-- ============================================================================
-- 3. Verification
-- ============================================================================

SELECT 'Renamed nodes (expect PLTS_A5 and PLTS_B2, SOURCE)' AS check_name;
SELECT id, node_code, node_name, node_class
FROM graph.node
WHERE tenant_id = 3 AND node_code LIKE 'PLTS%'
ORDER BY node_code;

SELECT 'Edges still intact (expect the same rows as section 1)' AS check_name;
SELECT p.node_code AS from_code, c.node_code AS to_code, e.utility_code, e.edge_class
FROM graph.edge e
JOIN graph.node p ON p.id = e.from_node_id
JOIN graph.node c ON c.id = e.to_node_id
WHERE e.tenant_id = 3 AND (p.node_code IN ('PLTS_A5','PLTS_B2')
                        OR c.node_code IN ('PLTS_A5','PLTS_B2'))
ORDER BY 1, 2;

SELECT 'Legacy mapping follows (expect devices 27 and 11)' AS check_name;
SELECT node_code, device_id FROM prs.device_node_mapping
WHERE tenant_id = 3 AND node_code IN ('PLTS_A5','PLTS_B2')
ORDER BY node_code;

-- The solver must be unchanged: renaming a code cannot move energy. Capture
-- get_node_values / get_sankey_flow before and after and diff row for row,
-- joining on node_code with the old codes mapped to the new ones.

-- ============================================================================
-- 4. Undo
-- ============================================================================

-- BEGIN;
-- UPDATE graph.node SET node_code = 'PLTS_A', node_name = 'PLTS A'
--  WHERE tenant_id = 3 AND node_code = 'PLTS_A5';
-- UPDATE graph.node SET node_code = 'PLTS_B', node_name = 'PLTS B'
--  WHERE tenant_id = 3 AND node_code = 'PLTS_B2';
-- UPDATE prs.device_hierarchy SET node_code = 'PLTS_A', node_name = 'PLTS A'
--  WHERE tenant_id = 3 AND node_code = 'PLTS_A5';
-- UPDATE prs.device_hierarchy SET node_code = 'PLTS_B', node_name = 'PLTS B'
--  WHERE tenant_id = 3 AND node_code = 'PLTS_B2';
-- UPDATE prs.device_hierarchy SET parent_code = 'PLTS_A'
--  WHERE tenant_id = 3 AND parent_code = 'PLTS_A5';
-- UPDATE prs.device_hierarchy SET parent_code = 'PLTS_B'
--  WHERE tenant_id = 3 AND parent_code = 'PLTS_B2';
-- UPDATE prs.device_node_mapping SET node_code = 'PLTS_A'
--  WHERE tenant_id = 3 AND node_code = 'PLTS_A5';
-- UPDATE prs.device_node_mapping SET node_code = 'PLTS_B'
--  WHERE tenant_id = 3 AND node_code = 'PLTS_B2';
-- COMMIT;
