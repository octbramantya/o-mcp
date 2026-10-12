-- Migration: 044_tenant_agent_role.sql
-- Description: A database role for tenant 3's Hermes agent, kept to tenant 3 by Postgres;
--              drop the decommissioned MCP server's role.
-- Author: Claude
-- Date: 2026-10-12
-- Design: design/mcp-tenancy.md (§4, "What changes in migration 044"); design/mcp-server.md §4
-- Requires: 043_pf_total_description.sql; superuser (it switches roles to verify, and enables
--           row-level security on tables it does not own otherwise)
--
-- WHY
-- ---
-- Each tenant gets its own Hermes agent and its own MCP server, and that server reads the
-- database as its tenant's role. An agent's model can be steered by anyone who can write to
-- it, so no boundary may depend on the server's queries filtering tenant_id correctly. This
-- role is kept to tenant 3 by Postgres itself, three ways, one per kind of object:
--
--   graph tables (node, edge, measurement, category, node_category): row-level security.
--     A permissive policy for every role, USING (true), keeps Grafana, the Lambdas and every
--     other role exactly as before; a RESTRICTIVE policy TO prs_hermes_agent narrows only this
--     role to tenant 3. A restrictive policy tied to a role cannot be talked around, unlike a
--     policy keyed on a setting a session can set for itself.
--   graph views: security_invoker, so they read their tables with the caller's rights. As
--     owner's views (the default) they bypass row-level security: probed on dev 2026-10-12,
--     v_property_gaps gave all 31 rows to a role whose policy allowed none.
--   public tables the server and the solver read: security-barrier views in tenant 3's own
--     schema, prs, under the same names, and the role's search_path set to prs, graph,
--     public. graph.device_totals names these tables without a schema and no graph function
--     pins its search_path, so the solver reads the views unchanged. The role is granted the
--     views, never the base tables: anything that names public.<table> is refused, so a
--     missing filter fails closed. telemetry_15min_agg is a TimescaleDB continuous aggregate
--     on production, which row-level security cannot cover; and a grant on it is copied to
--     every chunk, which is why the role gets only a view of it. security_barrier stops a
--     function the role writes (it may create temporary ones) from seeing rows before the
--     tenant filter; the comparisons the server uses are leakproof, so the window and device
--     conditions still reach the index (EXPLAIN, dev, 2026-10-12).
--
-- The views in prs change what prs and iop functions read for a session that puts prs first
-- on its search_path; no role has one today (production, read 2026-10-12). Accepted by the
-- user 2026-10-12: a tenant schema on a role's search_path makes that role tenant-scoped.
--
-- pfn_mcp_reader belonged to a decommissioned MCP server and held far more than recorded:
-- SELECT on 13 public objects (telemetry_data and tenants among them) and the TimescaleDB
-- internals, and write on the old server's mcp schema. Dropped here; the mcp tables, owned by
-- postgres, stay.
--
-- LOGIN and the password are not set here: by hand on each database, outside the repository,
-- with PgBouncer's userlist (design/mcp-server.md §4). A later tenant repeats sections 2.2-2.5
-- with its own schema and role (iop, iop_hermes_agent, tenant 4).

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Tenants in the tables the role will read ==='
SELECT 'graph.node' AS relation, tenant_id, count(*) FROM graph.node GROUP BY 2
UNION ALL
SELECT 'public.devices', tenant_id, count(*) FROM public.devices GROUP BY 2
ORDER BY 1, 2;
-- expect graph.node tenant 3 only; public.devices tenants 3 (107) and 4 (43)

\echo ''
\echo '=== 1.2 pfn_mcp_reader before ==='
SELECT rolname, rolcanlogin,
       (SELECT count(*) FROM pg_class c, aclexplode(c.relacl) a WHERE a.grantee = r.oid) AS relations_granted
FROM pg_roles r WHERE rolname = 'pfn_mcp_reader';
-- expect 1 row (production: LOGIN, about 120 relations; dev: NOLOGIN, 6)

\echo ''
\echo '=== 1.3 Roles with prs on their search_path (the views would change their prs functions) ==='
SELECT coalesce(r.rolname, '(every role)') AS role, s.setconfig
FROM pg_db_role_setting s LEFT JOIN pg_roles r ON r.oid = s.setrole
WHERE array_to_string(s.setconfig, ',') ~ 'search_path=[^,]*prs';
-- expect 0 rows


-- ============================================================================
-- 2. Change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run unless the database is as described above
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    bad TEXT;
BEGIN
    IF current_setting('is_superuser') <> 'on' THEN
        RAISE EXCEPTION '044: run as a superuser (it switches roles to verify itself)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'prs_hermes_agent') THEN
        RAISE EXCEPTION '044: role prs_hermes_agent already exists';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'prs') THEN
        RAISE EXCEPTION '044: schema prs (tenant 3''s schema) is missing';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'prs'
      AND c.relname IN ('devices', 'quantities', 'telemetry_15min_agg', 'daily_energy_cost_summary',
                        'telemetry_intervals_water', 'tenant_shift_periods');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION '044: prs already has %', bad;
    END IF;
    SELECT string_agg(c.relname, ', ') INTO bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'graph' AND c.relrowsecurity;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION '044: row-level security is already on in graph: %', bad;
    END IF;
    SELECT string_agg(DISTINCT n.nspname || '.' || c.relname, ', ') INTO bad
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relowner = (SELECT oid FROM pg_roles WHERE rolname = 'pfn_mcp_reader');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION '044: pfn_mcp_reader owns %; DROP OWNED would drop it', bad;
    END IF;
    -- security_invoker makes a graph view read its tables with the caller's rights. Refuse if
    -- any role that may read a graph view could not read every table behind it.
    SELECT string_agg(DISTINCT format('%s on %s (needs %s)', pg_get_userbyid(a.grantee), v.relname,
                                      rn.nspname || '.' || r.relname), '; ') INTO bad
    FROM pg_class v
    JOIN pg_namespace vn ON vn.oid = v.relnamespace AND vn.nspname = 'graph'
    CROSS JOIN LATERAL aclexplode(v.relacl) a
    JOIN pg_rewrite w ON w.ev_class = v.oid
    JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = w.oid
    JOIN pg_class r ON r.oid = d.refobjid AND r.oid <> v.oid AND r.relkind IN ('r', 'v', 'm', 'p')
    JOIN pg_namespace rn ON rn.oid = r.relnamespace
    WHERE v.relkind = 'v' AND a.privilege_type = 'SELECT' AND a.grantee <> 0
      AND NOT has_table_privilege(a.grantee, r.oid, 'SELECT');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION '044: security_invoker would lock these readers out of graph views: %', bad;
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2.2 The role, its database privileges and its settings
-- ----------------------------------------------------------------------------
CREATE ROLE prs_hermes_agent NOLOGIN CONNECTION LIMIT 6;
COMMENT ON ROLE prs_hermes_agent IS
    'Tenant 3''s Hermes agent, through its o-mcp server. Reads tenant 3 only, enforced by row-level '
    'security on graph and the views in prs (design/mcp-tenancy.md). LOGIN and password by hand.';

DO $$
BEGIN
    EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO prs_hermes_agent', current_database());
    EXECUTE format('ALTER ROLE prs_hermes_agent IN DATABASE %I SET search_path = prs, graph, public',
                   current_database());
    EXECUTE format('ALTER ROLE prs_hermes_agent IN DATABASE %I SET statement_timeout = ''20s''',
                   current_database());
    EXECUTE format('ALTER ROLE prs_hermes_agent IN DATABASE %I SET idle_in_transaction_session_timeout = ''30s''',
                   current_database());
    EXECUTE format('ALTER ROLE prs_hermes_agent IN DATABASE %I SET work_mem = ''16MB''', current_database());
END $$;

-- ----------------------------------------------------------------------------
-- 2.3 Tenant 3's views of the shared public tables, in prs
-- ----------------------------------------------------------------------------
CREATE VIEW prs.devices WITH (security_barrier) AS
    SELECT * FROM public.devices WHERE tenant_id = 3;
CREATE VIEW prs.quantities WITH (security_barrier) AS
    SELECT * FROM public.quantities;                       -- no tenant_id: the quantity catalogue
CREATE VIEW prs.telemetry_15min_agg WITH (security_barrier) AS
    SELECT * FROM public.telemetry_15min_agg WHERE tenant_id = 3;
CREATE VIEW prs.daily_energy_cost_summary WITH (security_barrier) AS
    SELECT * FROM public.daily_energy_cost_summary WHERE tenant_id = 3;
CREATE VIEW prs.telemetry_intervals_water WITH (security_barrier) AS
    SELECT * FROM public.telemetry_intervals_water WHERE tenant_id = 3;
CREATE VIEW prs.tenant_shift_periods WITH (security_barrier) AS
    SELECT * FROM public.tenant_shift_periods WHERE tenant_id = 3;

COMMENT ON VIEW prs.devices IS
    'Tenant 3''s rows of public.devices, for prs_hermes_agent (044). Same name, so the graph solver '
    'reads it through the role''s search_path. Do not grant public.devices to tenant roles.';
COMMENT ON VIEW prs.quantities IS 'public.quantities as is (no tenant_id), for prs_hermes_agent (044).';
COMMENT ON VIEW prs.telemetry_15min_agg IS
    'Tenant 3''s rows of the continuous aggregate, for prs_hermes_agent (044). Grant this, never the '
    'aggregate: TimescaleDB copies a grant on it to every chunk.';
COMMENT ON VIEW prs.daily_energy_cost_summary IS 'Tenant 3''s rows, for prs_hermes_agent (044).';
COMMENT ON VIEW prs.telemetry_intervals_water IS 'Tenant 3''s rows, for prs_hermes_agent (044).';
COMMENT ON VIEW prs.tenant_shift_periods IS 'Tenant 3''s rows, for prs_hermes_agent (044).';

-- ----------------------------------------------------------------------------
-- 2.4 Grants: graph, and the views. Nothing in public; no default privileges, so a table
--     added to graph later is not readable by the role until a migration decides how
-- ----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA graph, prs TO prs_hermes_agent;
GRANT SELECT ON ALL TABLES IN SCHEMA graph TO prs_hermes_agent;
GRANT SELECT ON prs.devices, prs.quantities, prs.telemetry_15min_agg, prs.daily_energy_cost_summary,
                prs.telemetry_intervals_water, prs.tenant_shift_periods TO prs_hermes_agent;

-- ----------------------------------------------------------------------------
-- 2.5 Row-level security on the graph tables that hold tenant rows
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['node', 'edge', 'measurement', 'category', 'node_category'] LOOP
        EXECUTE format('ALTER TABLE graph.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY every_role ON graph.%I AS PERMISSIVE FOR ALL TO PUBLIC '
                       'USING (true) WITH CHECK (true)', t);
        EXECUTE format('CREATE POLICY tenant_3 ON graph.%I AS RESTRICTIVE FOR ALL TO prs_hermes_agent '
                       'USING (tenant_id = 3) WITH CHECK (tenant_id = 3)', t);
        EXECUTE format('COMMENT ON POLICY every_role ON graph.%I IS %L', t,
                       'Every role reads and writes as before row-level security (044). Tenant roles '
                       'are narrowed by their own restrictive policy.');
        EXECUTE format('COMMENT ON POLICY tenant_3 ON graph.%I IS %L', t,
                       'prs_hermes_agent sees tenant 3 only (044, design/mcp-tenancy.md).');
    END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 2.6 graph views read with the caller's rights, so the policies apply through them
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    v TEXT;
BEGIN
    FOR v IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'graph' AND c.relkind = 'v' ORDER BY 1 LOOP
        EXECUTE format('ALTER VIEW graph.%I SET (security_invoker = true)', v);
    END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 2.7 Drop pfn_mcp_reader: revoke everything it holds in this database, then the role. If it
--     still holds privileges in another database of the cluster, DROP ROLE refuses; the role is
--     then left NOLOGIN with nothing here, and a NOTICE says so.
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pfn_mcp_reader') THEN
        EXECUTE 'ALTER ROLE pfn_mcp_reader NOLOGIN';
        EXECUTE 'DROP OWNED BY pfn_mcp_reader';
        BEGIN
            EXECUTE 'DROP ROLE pfn_mcp_reader';
        EXCEPTION WHEN dependent_objects_still_exist THEN
            RAISE NOTICE '044: pfn_mcp_reader holds privileges in another database (%); left NOLOGIN '
                         'with nothing in this one. Run DROP OWNED BY there, then DROP ROLE.', SQLERRM;
        END;
    END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2.8 Verify as the role, before committing: anything wrong rolls the whole migration back
-- ----------------------------------------------------------------------------
SET LOCAL ROLE prs_hermes_agent;
SET LOCAL search_path = prs, graph, public;      -- what the role's setting gives a login session

DO $$
DECLARE
    n BIGINT;
    other BIGINT;
    t TEXT;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE tenant_id <> 3) INTO n, other FROM devices;
    IF n = 0 OR other > 0 THEN
        RAISE EXCEPTION '044 check: devices shows % rows, % of another tenant', n, other;
    END IF;
    SELECT count(*), count(*) FILTER (WHERE tenant_id <> 3) INTO n, other FROM tenant_shift_periods;
    IF other > 0 THEN
        RAISE EXCEPTION '044 check: tenant_shift_periods shows another tenant';
    END IF;
    SELECT count(*) FILTER (WHERE tenant_id <> 3) INTO other
    FROM telemetry_15min_agg WHERE bucket >= now()::timestamp - interval '2 days';
    IF other > 0 THEN
        RAISE EXCEPTION '044 check: telemetry_15min_agg shows another tenant';
    END IF;
    FOREACH t IN ARRAY ARRAY['node', 'edge', 'measurement', 'category', 'node_category'] LOOP
        EXECUTE format('SELECT count(*) FILTER (WHERE tenant_id <> 3) FROM graph.%I', t) INTO other;
        IF other > 0 THEN
            RAISE EXCEPTION '044 check: graph.% shows another tenant', t;
        END IF;
    END LOOP;
    SELECT count(*) INTO n FROM graph.node;
    IF n = 0 THEN
        RAISE EXCEPTION '044 check: graph.node shows no rows of tenant 3';
    END IF;
    SELECT count(*) INTO other FROM graph.v_property_gaps WHERE tenant_id <> 3;
    IF other > 0 THEN
        RAISE EXCEPTION '044 check: graph.v_property_gaps shows another tenant';
    END IF;

    -- the base tables are refused
    FOREACH t IN ARRAY ARRAY['devices', 'telemetry_15min_agg', 'daily_energy_cost_summary', 'telemetry_data'] LOOP
        BEGIN
            EXECUTE format('SELECT 1 FROM public.%I LIMIT 1', t);
            RAISE EXCEPTION '044 check: public.% is readable by prs_hermes_agent', t;
        EXCEPTION WHEN insufficient_privilege THEN
            NULL;
        END;
    END LOOP;

    -- the solver answers for tenant 3, and for no other tenant
    SELECT count(*) INTO n FROM graph.get_node_quantity(3, 'ELECTRICITY', 1119,
        date_trunc('day', now())::timestamp - interval '1 day', date_trunc('day', now())::timestamp, current_date);
    IF n = 0 THEN
        RAISE EXCEPTION '044 check: the solver returned no tenant 3 nodes';
    END IF;
    SELECT count(*) INTO n FROM graph.get_node_quantity(4, 'ELECTRICITY', 1119,
        date_trunc('day', now())::timestamp - interval '1 day', date_trunc('day', now())::timestamp, current_date);
    IF n > 0 THEN
        RAISE EXCEPTION '044 check: the solver returned % nodes of tenant 4', n;
    END IF;
END $$;

RESET ROLE;
RESET search_path;

-- every other role sees what it saw before: Grafana's reader counts every row the owner does,
-- in the tables and through the views now read with the caller's rights
DO $$
DECLARE
    t TEXT;
    mine BIGINT;
    theirs BIGINT;
BEGIN
    FOREACH t IN ARRAY ARRAY['node', 'edge', 'measurement', 'category', 'node_category',
                             'v_property_gaps', 'v_edge_gaps', 'v_coverage'] LOOP
        EXECUTE format('SELECT count(*) FROM graph.%I', t) INTO mine;
        EXECUTE 'SET LOCAL ROLE "grafReader"';
        EXECUTE format('SELECT count(*) FROM graph.%I', t) INTO theirs;
        EXECUTE 'RESET ROLE';
        IF mine <> theirs THEN
            RAISE EXCEPTION '044 check: grafReader sees % rows of graph.%, the owner %', theirs, t, mine;
        END IF;
    END LOOP;
END $$;

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 The role and its settings ==='
SELECT r.rolname, r.rolcanlogin, r.rolconnlimit, s.setconfig
FROM pg_roles r LEFT JOIN pg_db_role_setting s ON s.setrole = r.oid
WHERE r.rolname IN ('prs_hermes_agent', 'pfn_mcp_reader');
-- expect prs_hermes_agent, NOLOGIN, 6, search_path prs, graph, public and the three limits;
-- no pfn_mcp_reader (or a NOTICE above said why it stays)

\echo ''
\echo '=== 3.2 Policies ==='
SELECT tablename, policyname, permissive, roles, qual FROM pg_policies WHERE schemaname = 'graph'
ORDER BY 1, 2;
-- expect 10 rows: every_role (PERMISSIVE, public, true) and tenant_3 (RESTRICTIVE,
-- prs_hermes_agent, tenant_id = 3) on category, edge, measurement, node, node_category

\echo ''
\echo '=== 3.3 Every role that read the graph tables reads the same rows ==='
SELECT 'graph.node' AS relation, count(*) FROM graph.node
UNION ALL SELECT 'graph.edge', count(*) FROM graph.edge
UNION ALL SELECT 'graph.measurement', count(*) FROM graph.measurement;
-- expect the counts of 1.1 and before: 190 nodes, 225 edges on dev 2026-10-12

\echo ''
\echo '=== 3.4 Views ==='
SELECT n.nspname || '.' || c.relname AS view, array_to_string(c.reloptions, ', ') AS options
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'v' AND (n.nspname = 'graph' OR (n.nspname = 'prs' AND c.relname IN
      ('devices', 'quantities', 'telemetry_15min_agg', 'daily_energy_cost_summary',
       'telemetry_intervals_water', 'tenant_shift_periods')))
ORDER BY 1;
-- expect 7 graph views with security_invoker=true, 6 prs views with security_barrier=true


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- DO $$ DECLARE t TEXT; BEGIN
--   FOREACH t IN ARRAY ARRAY['node', 'edge', 'measurement', 'category', 'node_category'] LOOP
--     EXECUTE format('DROP POLICY tenant_3 ON graph.%I', t);
--     EXECUTE format('DROP POLICY every_role ON graph.%I', t);
--     EXECUTE format('ALTER TABLE graph.%I DISABLE ROW LEVEL SECURITY', t);
--   END LOOP;
--   FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--            WHERE n.nspname = 'graph' AND c.relkind = 'v' LOOP
--     EXECUTE format('ALTER VIEW graph.%I RESET (security_invoker)', t);
--   END LOOP;
-- END $$;
-- DROP VIEW prs.devices, prs.quantities, prs.telemetry_15min_agg, prs.daily_energy_cost_summary,
--           prs.telemetry_intervals_water, prs.tenant_shift_periods;
-- DROP OWNED BY prs_hermes_agent;
-- DROP ROLE prs_hermes_agent;
-- COMMIT;
-- pfn_mcp_reader is not recreated: its server is decommissioned, and its grants are recorded
-- in design/mcp-tenancy.md ("What production showed").
