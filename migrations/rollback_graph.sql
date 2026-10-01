-- Rollback: rollback_graph.sql
-- Description: Undo migrations 008-011 (the graph schema)
-- Author: Claude
-- Date: 2026-08-19
--
-- WARNING: drops the entire graph schema and everything seeded into it.
--
-- Safe while the graph is still additive -- through Phase 4, the legacy path
-- (prs.device_hierarchy, prs.device_node_mapping, prs.get_sankey_energy_flow_v2)
-- is untouched and keeps working, so this is a clean revert.
--
-- After 014 it is NOT a revert. 014 drops the legacy tables; running this
-- afterwards leaves the database with no topology at all. Replay 001-006 first,
-- or restore from deprecated_tables.*_20260819.
--
-- 013 is not undone here: it corrects public.quantities.is_cumulative, which is
-- a data fix that outlives the graph. Reverse it by hand if you need to.
-- 015 is not undone here: DROP FUNCTION is not reversible from this file --
-- restore those definitions from a dump.

BEGIN;

-- ============================================================================
-- Guard: refuse to run once the legacy path is gone, since this would leave
-- nothing behind.
-- ============================================================================

DO $$
BEGIN
    IF to_regclass('prs.device_hierarchy') IS NULL THEN
        RAISE EXCEPTION
          'refusing to drop the graph schema: prs.device_hierarchy no longer exists, '
          'so 014 has already run and this is not a rollback -- it would leave the '
          'database with no topology. Replay 001-006 first, or restore from '
          'deprecated_tables.device_hierarchy_20260819.';
    END IF;
END $$;

-- ============================================================================
-- Everything the graph owns lives in one schema, plus one database-level grant.
-- CASCADE takes the tables, indexes, constraints, triggers, functions and the
-- v_coverage view together.
-- ============================================================================

DROP SCHEMA IF EXISTS graph CASCADE;

DO $$
BEGIN
    EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM "grafReader"', current_database());
END $$;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
-- SELECT to_regnamespace('graph');           -- expect NULL
-- SELECT COUNT(*) FROM prs.device_hierarchy; -- legacy path intact
