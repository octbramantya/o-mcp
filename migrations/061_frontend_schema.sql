-- Migration: 061_frontend_schema.sql
-- Description: The custom frontend's users, sessions, dashboards and audit log in a schema of their
--              own, frontend; the API's role that writes it; and prs_frontend, tenant 3's role for
--              the frontend's plant reads, kept to tenant 3 as prs_hermes_agent is.
-- Author: Claude
-- Date: 2026-10-22
-- Design: design/frontend.md §2 (users and the admin group), §6 (roles), §8 (the schema);
--         design/mcp-tenancy.md §4
-- Requires: 060_minute_device_totals.sql; superuser (it creates roles, alters 044's policies and
--           verifies as each role)
--
-- WHY
-- ---
-- Decided 2026-10-22: users and dashboards live in valkyrie, in their own schema (decision 14);
-- every user belongs to one tenant, internal users are admins who see every tenant (5); a super
-- admin creates accounts, resets passwords and assigns tenants (16); dashboards belong to their
-- owner, readable by an admin (12, 17); the frontend reads the plant through a role per tenant,
-- separate from the agent's (10), under the same row-level security and tenant views.
--
-- ROLES
-- -----
-- frontend_api   writes frontend and nothing else: no graph, no prs, no public tables. The API
--                holds a pool of it for log-in, sessions and dashboards. The audit log is
--                append-only to it (INSERT, SELECT).
-- prs_frontend   reads tenant 3's plant, as prs_hermes_agent does (044): the tenant_3 policies on
--                the six graph tables now name both roles, the prs views are granted, and the
--                search_path puts prs first. It can't reach frontend. Separate from the agent's
--                role so PgBouncer pools them apart and each has its own limits. The policies
--                are found by name, not listed: 053 added node_type_category's to 044's five.
-- Both NOLOGIN; LOGIN and passwords by hand on each database, with PgBouncer's userlist, as 044.
--
-- TABLES
-- ------
-- frontend.tenant      the tenants the frontend serves: the name the top bar shows, the role the
--                      API reads it through, and the time zone relative ranges resolve in. Its own
--                      table because public.tenants isn't readable by the roles dev is refreshed
--                      with, and the API needs the role and zone anyway. Tenant 3 only, so far.
-- frontend.app_user    one row per person. role user / admin / super_admin; a user has exactly
--                      one tenant, an admin or super admin none (they switch). Email is unique
--                      ignoring case. The password hash is the API's (Argon2id); must_change_password
--                      is set when a super admin creates the account or resets the password.
-- frontend.session     server-side sessions, so a password reset or a disabled account ends them.
--                      The cookie carries a random token; only its SHA-256 is stored. tenant_id is
--                      the session's current tenant: a user's own, or what an admin switched to.
-- frontend.dashboard   one row per dashboard: owner, tenant, title, the document (JSONB) and its
--                      format version, migrated on read. A user's dashboards are in their own
--                      tenant, enforced by trigger; an admin's are per tenant, since they name
--                      that tenant's nodes.
-- frontend.audit       log-ins (and failures), log-outs, tenant switches, account changes, and an
--                      admin opening a user's dashboard.
--
-- Who may read which dashboard (the owner; an admin in the same tenant, read-only) is the API's
-- rule (design/frontend.md §2, §7): every dashboard is in one role's reach, so Postgres can't
-- tell users apart here. The tables keep what the rule needs.

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'frontend') THEN
        RAISE EXCEPTION '061: schema frontend already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('frontend_api', 'prs_frontend')) THEN
        RAISE EXCEPTION '061: role frontend_api or prs_frontend already exists';
    END IF;
    IF (SELECT count(*) FROM pg_policy WHERE polname = 'tenant_3'
        AND polroles = ARRAY['prs_hermes_agent'::regrole]::oid[]) <> 6 THEN
        RAISE EXCEPTION '061: expected six tenant_3 policies naming prs_hermes_agent alone (044, 053)';
    END IF;
    IF to_regclass('prs.telemetry_data') IS NULL THEN
        RAISE EXCEPTION '061: needs prs.telemetry_data (060)';
    END IF;
END
$$;

-- ============================================================================
-- 1. The schema and its tables
-- ============================================================================

CREATE SCHEMA frontend;
COMMENT ON SCHEMA frontend IS
    'The custom frontend''s users, sessions, dashboards and audit log (061; design/frontend.md §8). '
    'Written by frontend_api only.';

CREATE TABLE frontend.tenant (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    db_role     NAME NOT NULL UNIQUE,
    time_zone   TEXT NOT NULL CHECK (now() AT TIME ZONE time_zone IS NOT NULL),
    is_active   BOOLEAN NOT NULL DEFAULT TRUE
);
COMMENT ON TABLE frontend.tenant IS
    'Tenants the frontend serves: the name the top bar shows, the database role the API reads the '
    'tenant through (a pool per role), and the zone relative ranges resolve in.';

INSERT INTO frontend.tenant (id, name, db_role, time_zone) VALUES (3, 'PRS', 'prs_frontend', 'Asia/Jakarta');

CREATE TABLE frontend.app_user (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email                TEXT NOT NULL CHECK (email = btrim(email) AND email LIKE '_%@_%'),
    display_name         TEXT,
    password_hash        TEXT NOT NULL,
    role                 TEXT NOT NULL CHECK (role IN ('user', 'admin', 'super_admin')),
    tenant_id            INTEGER REFERENCES frontend.tenant (id),
    must_change_password BOOLEAN NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by           BIGINT REFERENCES frontend.app_user (id),
    password_changed_at  TIMESTAMPTZ,
    last_login_at        TIMESTAMPTZ,
    disabled_at          TIMESTAMPTZ,
    CONSTRAINT app_user_one_tenant CHECK ((role = 'user') = (tenant_id IS NOT NULL))
);
CREATE UNIQUE INDEX app_user_email_key ON frontend.app_user (lower(email));
COMMENT ON TABLE frontend.app_user IS
    'One row per person. A user has exactly one tenant; admins and super admins none, and switch. '
    'Created, reset and assigned by a super admin; nobody signs up.';
COMMENT ON COLUMN frontend.app_user.password_hash IS 'Argon2id, encoded by the API (PHC string).';
COMMENT ON COLUMN frontend.app_user.must_change_password IS
    'Set when a super admin creates the account or resets the password; cleared when the user sets their own.';

CREATE TABLE frontend.session (
    token_sha256  BYTEA PRIMARY KEY CHECK (length(token_sha256) = 32),
    user_id       BIGINT NOT NULL REFERENCES frontend.app_user (id),
    tenant_id     INTEGER REFERENCES frontend.tenant (id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ NOT NULL,
    revoked_at    TIMESTAMPTZ,
    CHECK (expires_at > created_at)
);
CREATE INDEX session_user_idx ON frontend.session (user_id) WHERE revoked_at IS NULL;
COMMENT ON TABLE frontend.session IS
    'Server-side sessions; the cookie holds a random token, this table its SHA-256. tenant_id is the '
    'session''s current tenant: a user''s own, or the one an admin switched to (NULL before choosing). '
    'A password reset or a disabled account revokes every open session.';

CREATE TABLE frontend.dashboard (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    owner_id        BIGINT NOT NULL REFERENCES frontend.app_user (id),
    tenant_id       INTEGER NOT NULL REFERENCES frontend.tenant (id),
    title           TEXT NOT NULL CHECK (btrim(title) <> ''),
    document        JSONB NOT NULL CHECK (jsonb_typeof(document) = 'object'),
    format_version  INTEGER NOT NULL CHECK (format_version >= 1),
    from_template   TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    deleted_at      TIMESTAMPTZ
);
CREATE INDEX dashboard_owner_idx ON frontend.dashboard (owner_id, tenant_id) WHERE deleted_at IS NULL;
COMMENT ON TABLE frontend.dashboard IS
    'A user''s own dashboard (design/frontend.md §8): time range, refresh, channels, and each widget''s '
    'type, position, size, channel and settings, in document. Nodes are stored by graph.node.id. '
    'Returned to its owner, and read-only to an admin in the same tenant; the API enforces that.';
COMMENT ON COLUMN frontend.dashboard.format_version IS 'The document''s format version; older ones are migrated on read.';
COMMENT ON COLUMN frontend.dashboard.from_template IS 'The static template it was copied from, if any. Later template changes don''t reach it.';

CREATE FUNCTION frontend.assert_dashboard_tenant() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_role TEXT;
    v_tenant INTEGER;
BEGIN
    SELECT role, tenant_id INTO v_role, v_tenant FROM frontend.app_user WHERE id = NEW.owner_id;
    IF v_role = 'user' AND NEW.tenant_id <> v_tenant THEN
        RAISE EXCEPTION 'frontend.dashboard: user % belongs to tenant %, not %', NEW.owner_id, v_tenant, NEW.tenant_id;
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;
CREATE TRIGGER dashboard_tenant BEFORE INSERT OR UPDATE ON frontend.dashboard
    FOR EACH ROW EXECUTE FUNCTION frontend.assert_dashboard_tenant();

CREATE TABLE frontend.audit (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    event           TEXT NOT NULL CHECK (event IN (
                        'login', 'login_failed', 'logout', 'password_changed',
                        'tenant_switched',
                        'account_created', 'password_reset', 'account_disabled', 'account_enabled',
                        'tenant_assigned', 'role_changed',
                        'dashboard_opened_by_admin', 'dashboard_copied_by_admin')),
    actor_id        BIGINT REFERENCES frontend.app_user (id),
    email           TEXT,
    tenant_id       INTEGER REFERENCES frontend.tenant (id),
    target_user_id  BIGINT REFERENCES frontend.app_user (id),
    dashboard_id    BIGINT REFERENCES frontend.dashboard (id),
    client_ip       INET,
    detail          JSONB
);
CREATE INDEX audit_at_idx ON frontend.audit (at);
COMMENT ON TABLE frontend.audit IS
    'Append-only: log-ins, failed log-ins (email as typed, actor NULL when it matches no account), '
    'tenant switches, a super admin''s account changes, and an admin opening or copying a user''s dashboard.';

-- ============================================================================
-- 2. frontend_api: writes frontend, nothing else
-- ============================================================================

CREATE ROLE frontend_api NOLOGIN CONNECTION LIMIT 4;
COMMENT ON ROLE frontend_api IS
    'The frontend API''s own role: users, sessions, dashboards and the audit log in schema frontend. '
    'No plant data. LOGIN and password by hand (061).';

DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO frontend_api', current_database());
    EXECUTE format('ALTER ROLE frontend_api IN DATABASE %I SET search_path = frontend', current_database());
    EXECUTE format('ALTER ROLE frontend_api IN DATABASE %I SET statement_timeout = ''5s''', current_database());
    EXECUTE format('ALTER ROLE frontend_api IN DATABASE %I SET idle_in_transaction_session_timeout = ''30s''',
                   current_database());
END $$;

GRANT USAGE ON SCHEMA frontend TO frontend_api;
GRANT SELECT ON frontend.tenant TO frontend_api;
GRANT SELECT, INSERT, UPDATE ON frontend.app_user, frontend.session, frontend.dashboard TO frontend_api;
GRANT DELETE ON frontend.session TO frontend_api;
GRANT SELECT, INSERT ON frontend.audit TO frontend_api;

-- ============================================================================
-- 3. prs_frontend: tenant 3's plant, as prs_hermes_agent reads it (044, 060)
-- ============================================================================

CREATE ROLE prs_frontend NOLOGIN CONNECTION LIMIT 6;
COMMENT ON ROLE prs_frontend IS
    'Tenant 3''s plant reads for the frontend API. Kept to tenant 3 by row-level security on graph and '
    'the views in prs, as prs_hermes_agent (design/mcp-tenancy.md). LOGIN and password by hand (061).';

DO $$
BEGIN
    EXECUTE format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO prs_frontend', current_database());
    EXECUTE format('ALTER ROLE prs_frontend IN DATABASE %I SET search_path = prs, graph, public', current_database());
    EXECUTE format('ALTER ROLE prs_frontend IN DATABASE %I SET statement_timeout = ''20s''', current_database());
    EXECUTE format('ALTER ROLE prs_frontend IN DATABASE %I SET idle_in_transaction_session_timeout = ''30s''',
                   current_database());
    EXECUTE format('ALTER ROLE prs_frontend IN DATABASE %I SET work_mem = ''16MB''', current_database());
END $$;

GRANT USAGE ON SCHEMA graph, prs TO prs_frontend;
GRANT SELECT ON ALL TABLES IN SCHEMA graph TO prs_frontend;
GRANT SELECT ON prs.devices, prs.quantities, prs.telemetry_15min_agg, prs.daily_energy_cost_summary,
                prs.telemetry_intervals_water, prs.tenant_shift_periods, prs.telemetry_data TO prs_frontend;
GRANT EXECUTE ON FUNCTION
    graph.change_dates(integer, date, date),
    graph.device_totals_minute(integer, varchar, timestamp, timestamp, integer, boolean, varchar[]),
    graph.device_totals_15min(integer, varchar, timestamp, timestamp, integer, boolean, varchar[]),
    graph.register_step(varchar, boolean, numeric, numeric),
    graph.sankey(integer, date, date, date, integer, boolean, varchar, boolean),
    graph.sankey_diagnostics(integer, date, date, date, integer, boolean, varchar),
    graph.sankey_nodes(integer, date, date, date, integer, boolean, varchar),
    graph.sld_devices(integer, integer, integer, date)
    TO prs_frontend;

DO $$
DECLARE
    t REGCLASS;
BEGIN
    FOR t IN SELECT polrelid::regclass FROM pg_policy WHERE polname = 'tenant_3' LOOP
        EXECUTE format('ALTER POLICY tenant_3 ON %s TO prs_hermes_agent, prs_frontend', t);
        EXECUTE format('COMMENT ON POLICY tenant_3 ON %s IS %L', t,
                       'Tenant 3''s roles (prs_hermes_agent, 044; prs_frontend, 061) see tenant 3''s rows only.');
    END LOOP;
END $$;

-- ============================================================================
-- 4. Checks, as each role, before committing
-- ============================================================================

-- 4.1 the tables' own rules
DO $$
DECLARE
    u BIGINT;
    a BIGINT;
BEGIN
    INSERT INTO frontend.app_user (email, password_hash, role, tenant_id)
    VALUES ('check.user@example.invalid', 'x', 'user', 3) RETURNING id INTO u;
    INSERT INTO frontend.app_user (email, password_hash, role)
    VALUES ('check.admin@example.invalid', 'x', 'admin') RETURNING id INTO a;
    BEGIN
        INSERT INTO frontend.app_user (email, password_hash, role) VALUES ('nobody@example.invalid', 'x', 'user');
        RAISE EXCEPTION '061 check: a user without a tenant was accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO frontend.app_user (email, password_hash, role) VALUES ('CHECK.USER@example.invalid', 'x', 'admin');
        RAISE EXCEPTION '061 check: an email differing only in case was accepted';
    EXCEPTION WHEN unique_violation THEN NULL;
    END;
    INSERT INTO frontend.dashboard (owner_id, tenant_id, title, document, format_version)
    VALUES (u, 3, 'check', '{}', 1);
    BEGIN
        INSERT INTO frontend.tenant (id, name, db_role, time_zone) VALUES (99, 'check', 'check_role', 'Asia/Jkarta');
        RAISE EXCEPTION '061 check: an unknown time zone was accepted';
    EXCEPTION WHEN invalid_parameter_value THEN NULL;
    END;
    DELETE FROM frontend.dashboard WHERE owner_id = u;
    DELETE FROM frontend.app_user WHERE id IN (u, a);
END
$$;

-- 4.2 frontend_api: frontend only, the audit log append-only
SET LOCAL ROLE frontend_api;
SET LOCAL search_path = frontend;
DO $$
DECLARE
    u BIGINT;
BEGIN
    INSERT INTO app_user (email, password_hash, role, tenant_id)
    VALUES ('check.api@example.invalid', 'x', 'user', 3) RETURNING id INTO u;
    INSERT INTO session (token_sha256, user_id, tenant_id, expires_at)
    VALUES (sha256('check'::bytea), u, 3, now() + interval '1 hour');
    UPDATE session SET revoked_at = now() WHERE user_id = u;
    INSERT INTO audit (event, actor_id, tenant_id) VALUES ('login', u, 3);
    BEGIN
        UPDATE audit SET event = 'logout' WHERE actor_id = u;
        RAISE EXCEPTION '061 check: frontend_api can rewrite the audit log';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        INSERT INTO dashboard (owner_id, tenant_id, title, document, format_version)
        VALUES (u, 4, 'check', '{}', 1);
        RAISE EXCEPTION '061 check: a dashboard was saved outside its user''s tenant';
    EXCEPTION WHEN foreign_key_violation OR raise_exception THEN
        IF SQLERRM LIKE '061 check:%' THEN RAISE; END IF;
    END;
    BEGIN
        PERFORM 1 FROM graph.node LIMIT 1;
        RAISE EXCEPTION '061 check: frontend_api can read graph';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
    BEGIN
        PERFORM 1 FROM public.devices LIMIT 1;
        RAISE EXCEPTION '061 check: frontend_api can read public.devices';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END
$$;
RESET ROLE;
RESET search_path;
DELETE FROM frontend.audit WHERE actor_id IN (SELECT id FROM frontend.app_user WHERE email = 'check.api@example.invalid');
DELETE FROM frontend.session WHERE user_id IN (SELECT id FROM frontend.app_user WHERE email = 'check.api@example.invalid');
DELETE FROM frontend.app_user WHERE email = 'check.api@example.invalid';

-- 4.3 prs_frontend: tenant 3 only, nothing of frontend, the base tables refused
SET LOCAL ROLE prs_frontend;
SET LOCAL search_path = prs, graph, public;
DO $$
DECLARE
    n BIGINT;
    other BIGINT;
    t TEXT;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE tenant_id <> 3) INTO n, other FROM devices;
    IF n = 0 OR other > 0 THEN
        RAISE EXCEPTION '061 check: devices shows % rows to prs_frontend, % of another tenant', n, other;
    END IF;
    FOREACH t IN ARRAY ARRAY['node', 'edge', 'measurement', 'category', 'node_category', 'node_type_category'] LOOP
        EXECUTE format('SELECT count(*), count(*) FILTER (WHERE tenant_id <> 3) FROM graph.%I', t) INTO n, other;
        IF other > 0 OR (t = 'node' AND n = 0) THEN
            RAISE EXCEPTION '061 check: graph.% shows % rows to prs_frontend, % of another tenant', t, n, other;
        END IF;
    END LOOP;
    FOREACH t IN ARRAY ARRAY['public.devices', 'public.telemetry_15min_agg', 'public.daily_energy_cost_summary',
                             'public.telemetry_data', 'frontend.app_user', 'frontend.dashboard'] LOOP
        BEGIN
            EXECUTE format('SELECT 1 FROM %s LIMIT 1', t);
            RAISE EXCEPTION '061 check: % is readable by prs_frontend', t;
        EXCEPTION WHEN insufficient_privilege THEN NULL;
        END;
    END LOOP;
    SELECT count(*) INTO n FROM graph.get_node_quantity(3, 'ELECTRICITY', 124, '2026-10-01', '2026-10-01', '2026-10-01');
    IF n = 0 THEN
        RAISE EXCEPTION '061 check: the solver returned no tenant 3 nodes to prs_frontend';
    END IF;
    SELECT count(*) INTO n FROM graph.get_node_quantity(4, 'ELECTRICITY', 124, '2026-10-01', '2026-10-01', '2026-10-01');
    IF n > 0 THEN
        RAISE EXCEPTION '061 check: the solver returned % nodes of tenant 4 to prs_frontend', n;
    END IF;
END
$$;
RESET ROLE;
RESET search_path;

-- 4.4 the agent's role sees what it saw before
SET LOCAL ROLE prs_hermes_agent;
DO $$
BEGIN
    IF (SELECT count(*) FILTER (WHERE tenant_id <> 3) FROM graph.node) > 0
       OR (SELECT count(*) FROM graph.node) = 0 THEN
        RAISE EXCEPTION '061 check: prs_hermes_agent no longer sees exactly tenant 3''s nodes';
    END IF;
    BEGIN
        PERFORM 1 FROM frontend.app_user LIMIT 1;
        RAISE EXCEPTION '061 check: prs_hermes_agent can read frontend';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END
$$;
RESET ROLE;

COMMIT;


-- ============================================================================
-- 5. Results (read-only)
-- ============================================================================

\echo ''
\echo '=== 5.1 Roles ==='
SELECT r.rolname, r.rolcanlogin, r.rolconnlimit, s.setconfig
FROM pg_roles r LEFT JOIN pg_db_role_setting s ON s.setrole = r.oid
 AND s.setdatabase = (SELECT oid FROM pg_database WHERE datname = current_database())
WHERE r.rolname IN ('frontend_api', 'prs_frontend', 'prs_hermes_agent') ORDER BY 1;

\echo ''
\echo '=== 5.2 tenant_3 policies ==='
SELECT polrelid::regclass, polroles::regrole[] FROM pg_policy WHERE polname = 'tenant_3' ORDER BY 1;


-- ============================================================================
-- 6. Undo (commented)
-- ============================================================================
--
-- DO $$ DECLARE t TEXT; BEGIN
--   FOREACH t IN ARRAY ARRAY['node', 'edge', 'measurement', 'category', 'node_category', 'node_type_category'] LOOP
--     EXECUTE format('ALTER POLICY tenant_3 ON graph.%I TO prs_hermes_agent', t);
--   END LOOP; END $$;
-- DROP SCHEMA frontend CASCADE;
-- DROP OWNED BY frontend_api, prs_frontend;
-- DROP ROLE frontend_api, prs_frontend;
