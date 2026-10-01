-- Migration: 032_retire_distribution_class.sql
-- Description: Remove DISTRIBUTION from the node_class check constraints on graph.node and
--              graph.node_type. No node, node type or endpoint rule uses it.
-- Author: Claude
-- Date: 2026-10-01
-- Design: design/graph-network-design.md (node_class table); design/type-property.md
-- Requires: 031_create_vocabulary_alignment.sql
--
-- WHY
-- ---
-- 008 allowed six node classes. DISTRIBUTION was meant as the second level below
-- a bus: sub-panel, MCC, branch manifold, department sub-manifold. 026 put that
-- distinction in node_type instead: MAIN_LV_BOARD and SUB_BOARD are both subtypes
-- of SWITCHBOARD, class BUS, and the readers that care about the level key on the
-- type (harmonics' rating order, the SUPPLY_LV and PV_INJECTION endpoint rules).
--
-- The class cannot come back without breaking that: a subtype must be in its
-- parent's class (fk_node_type_parent), so SUB_BOARD cannot be DISTRIBUTION while
-- it sits under SWITCHBOARD. And since fk_node_node_type ties a typed node's class
-- to its type's class, and no type is DISTRIBUTION, no typed node can be either.
--
-- Left allowed, the value misleads. The o-mcp/subgraph schema lists node classes
-- as an enum; a model asked for "distribution boards" filters on DISTRIBUTION,
-- finds nothing, and concludes there are none, when the answer is the SUB_BOARD
-- nodes. A level below a bus is a node type, never a class.
--
-- The guard covers every row, retired and '-infinity' ones included, on every
-- tenant: tightening the constraint would reject them anyway, and the message
-- here names them.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 graph.node by class, all tenants, all rows ==='
SELECT node_class, tenant_id, count(*) FROM graph.node GROUP BY 1, 2 ORDER BY 1, 2;
-- expect no DISTRIBUTION row

\echo ''
\echo '=== 1.2 graph.node_type by class ==='
SELECT node_class, count(*) FROM graph.node_type GROUP BY 1 ORDER BY 1;
-- expect 24 types: BUS 4, CONVERSION 7, LOAD 7, SOURCE 4, STORAGE 2

\echo ''
\echo '=== 1.3 The two constraints as they stand ==='
SELECT conrelid::regclass, conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conname IN ('ck_node_class', 'ck_node_type_class')
ORDER BY 1;
-- expect 2 rows, each listing DISTRIBUTION


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run if anything still uses the class
-- ----------------------------------------------------------------------------
DO $pre$
DECLARE
    used TEXT;
BEGIN
    SELECT string_agg(format('node %s (tenant %s)', node_code, tenant_id), ', ' ORDER BY tenant_id, node_code)
      INTO used FROM graph.node WHERE node_class = 'DISTRIBUTION';
    IF used IS NOT NULL THEN
        RAISE EXCEPTION 'DISTRIBUTION is still used by: %', used;
    END IF;

    SELECT string_agg(format('node_type %s', code), ', ' ORDER BY code)
      INTO used FROM graph.node_type WHERE node_class = 'DISTRIBUTION';
    IF used IS NOT NULL THEN
        RAISE EXCEPTION 'DISTRIBUTION is still used by: %', used;
    END IF;

    -- endpoint rules name either a node type or a node class
    SELECT string_agg(format('endpoint rule %s %s -> %s', edge_type, from_kind, to_kind), ', ')
      INTO used FROM graph.edge_type_endpoint
     WHERE 'DISTRIBUTION' IN (from_kind, to_kind);
    IF used IS NOT NULL THEN
        RAISE EXCEPTION 'DISTRIBUTION is still used by: %', used;
    END IF;
END
$pre$;

-- ----------------------------------------------------------------------------
-- 2.2 Five classes
-- ----------------------------------------------------------------------------
ALTER TABLE graph.node DROP CONSTRAINT ck_node_class;
ALTER TABLE graph.node ADD CONSTRAINT ck_node_class CHECK (node_class IN
    ('SOURCE','BUS','CONVERSION','STORAGE','LOAD'));

ALTER TABLE graph.node_type DROP CONSTRAINT ck_node_type_class;
ALTER TABLE graph.node_type ADD CONSTRAINT ck_node_type_class CHECK (node_class IN
    ('SOURCE','BUS','CONVERSION','STORAGE','LOAD'));

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 The two constraints now ==='
SELECT conrelid::regclass, conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conname IN ('ck_node_class', 'ck_node_type_class')
ORDER BY 1;
-- expect 2 rows, five classes each, no DISTRIBUTION


-- ============================================================================
-- 4. Undo (commented) -- restores the six classes of 008 and 026
-- ============================================================================
--
-- BEGIN;
-- ALTER TABLE graph.node DROP CONSTRAINT ck_node_class;
-- ALTER TABLE graph.node ADD CONSTRAINT ck_node_class CHECK (node_class IN
--     ('SOURCE','BUS','DISTRIBUTION','CONVERSION','STORAGE','LOAD'));
-- ALTER TABLE graph.node_type DROP CONSTRAINT ck_node_type_class;
-- ALTER TABLE graph.node_type ADD CONSTRAINT ck_node_type_class CHECK (node_class IN
--     ('SOURCE','BUS','DISTRIBUTION','CONVERSION','STORAGE','LOAD'));
-- COMMIT;
