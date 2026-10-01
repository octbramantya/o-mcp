-- Migration: 010_grant_graph_permissions.sql
-- Description: Grant grafReader read access to the graph schema
-- Author: Claude
-- Date: 2026-08-19
-- Phase: 0 -- mirrors 007 for the new schema (see §8 of design/graph-network-design.md)
--
-- Every statement below is extracted verbatim from graph-network-design.md.
-- Edit the design document first, then regenerate -- not the other way round.

BEGIN;

GRANT USAGE ON SCHEMA graph TO "grafReader";
GRANT SELECT ON ALL TABLES IN SCHEMA graph TO "grafReader";
ALTER DEFAULT PRIVILEGES IN SCHEMA graph GRANT SELECT ON TABLES TO "grafReader";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graph TO "grafReader";
ALTER DEFAULT PRIVILEGES IN SCHEMA graph GRANT EXECUTE ON FUNCTIONS TO "grafReader";

-- graph.solve_flow and graph.get_node_quantity create TEMP tables, so the
-- calling role needs TEMPORARY on the database. If that is unacceptable in
-- your environment, the resolver has to be rewritten using CTEs with a fixed
-- iteration bound instead of temp tables (§6).
DO $$
BEGIN
    EXECUTE format('GRANT TEMPORARY ON DATABASE %I TO "grafReader"', current_database());
END $$;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
-- SELECT grantee, table_name, privilege_type
--   FROM information_schema.table_privileges
--  WHERE grantee = 'grafReader' AND table_schema = 'graph';
