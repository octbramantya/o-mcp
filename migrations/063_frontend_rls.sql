-- Migration: 063_frontend_rls.sql
-- Description: Row-level security on the frontend schema: frontend_api sees and writes every row,
--              grafReader sees frontend.tenant's rows and nothing else, every other role nothing.
--              grafReader gets USAGE and SELECT on the schema, so tools/dev_refresh.sh can copy its
--              structure.
-- Author: Claude
-- Date: 2026-10-26
-- Design: design/frontend.md §8
-- Requires: 062_sankey_energy_only.sql; superuser (it alters 061's tables and verifies as each role)
--
-- WHY
-- ---
-- tools/dev_refresh.sh rebuilds dev from production as grafReader, and leaves out every schema
-- grafReader can't use. 061 kept frontend from grafReader (it holds password hashes and session
-- hashes), so a refreshed dev had no frontend schema while its ledger, copied from production,
-- said 061 had run (found 2026-10-26). pg_dump needs SELECT on a table even to dump its structure:
-- it locks every table it dumps, and an ACCESS SHARE lock needs SELECT.
--
-- Decided 2026-10-26: grafReader gets SELECT, and row-level security keeps the rows from it. The
-- schema's structure then comes across with every other schema's, later frontend migrations
-- included; a data dump is refused ("query would be affected by row-level security policy"), and
-- a plain SELECT returns nothing. Checked on dev with a throwaway role first.
--
-- POLICIES
-- --------
-- frontend_api   FOR ALL on all five tables, USING and WITH CHECK true: the API's role sees what it
--                saw before. Its grants still decide what it may do (the audit log stays
--                INSERT and SELECT only), and the dashboard trigger, which reads app_user as the
--                invoking role, still finds the owner.
-- grafReader     FOR SELECT on frontend.tenant only: the site names, roles and time zones, which the
--                API needs on dev and are no secret. dev_refresh copies those rows.
-- everyone else  no policy, so no rows. A grant on frontend given by mistake later shows nothing.
-- The table owner and superusers bypass row-level security, as before (not FORCE'd): migrations
-- and the dev tests' clean-up run as them.
--
-- A role that is a member of grafReader inherits both its grants and its policy (policies apply to
-- members of the named role), so it too sees the tenant rows only. Section 0 lists such members.

\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
    members TEXT;
BEGIN
    IF (SELECT count(*) FROM pg_class WHERE relnamespace = 'frontend'::regnamespace AND relkind = 'r'
        AND relname IN ('tenant', 'app_user', 'session', 'dashboard', 'audit')) <> 5
       OR (SELECT count(*) FROM pg_class WHERE relnamespace = 'frontend'::regnamespace AND relkind = 'r') <> 5 THEN
        RAISE EXCEPTION '063: expected exactly 061''s five tables in frontend';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class WHERE relnamespace = 'frontend'::regnamespace AND relrowsecurity) THEN
        RAISE EXCEPTION '063: row-level security is already on in frontend';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafReader') THEN
        RAISE EXCEPTION '063: role grafReader does not exist';
    END IF;
    SELECT string_agg(m.rolname, ', ' ORDER BY m.rolname) INTO members
    FROM pg_auth_members a JOIN pg_roles m ON m.oid = a.member WHERE a.roleid = '"grafReader"'::regrole;
    RAISE NOTICE '063: members of grafReader, who inherit its policy: %', coalesce(members, 'none');
END
$$;

-- ============================================================================
-- 1. Row-level security and the policies
-- ============================================================================

DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['tenant', 'app_user', 'session', 'dashboard', 'audit'] LOOP
        EXECUTE format('ALTER TABLE frontend.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY frontend_api ON frontend.%I FOR ALL TO frontend_api USING (true) WITH CHECK (true)', t);
        EXECUTE format('COMMENT ON POLICY frontend_api ON frontend.%I IS %L', t,
                       'The API''s role sees every row; its grants decide what it may do (063).');
    END LOOP;
END
$$;

CREATE POLICY dev_refresh ON frontend.tenant FOR SELECT TO "grafReader" USING (true);
COMMENT ON POLICY dev_refresh ON frontend.tenant IS
    'grafReader reads the tenants (no secrets) so tools/dev_refresh.sh can copy them; no other frontend row (063).';

-- ============================================================================
-- 2. grafReader: the structure, for tools/dev_refresh.sh
-- ============================================================================

GRANT USAGE ON SCHEMA frontend TO "grafReader";
GRANT SELECT ON ALL TABLES IN SCHEMA frontend TO "grafReader";

-- ============================================================================
-- 3. Checks, as each role, before committing
-- ============================================================================

-- 3.1 rows to look for: one of each, by the owner
DO $$
DECLARE
    u BIGINT;
BEGIN
    INSERT INTO frontend.app_user (email, password_hash, role, tenant_id)
    VALUES ('check063@example.invalid', 'x', 'user', 3) RETURNING id INTO u;
    INSERT INTO frontend.session (token_sha256, user_id, tenant_id, expires_at)
    VALUES (sha256('check063'::bytea), u, 3, now() + interval '1 hour');
    INSERT INTO frontend.dashboard (owner_id, tenant_id, title, document, format_version) VALUES (u, 3, 'check', '{}', 1);
    INSERT INTO frontend.audit (event, actor_id, tenant_id) VALUES ('login', u, 3);
END
$$;

-- 3.2 grafReader: the tenants, nothing else, and no writes
SET LOCAL ROLE "grafReader";
DO $$
DECLARE
    t TEXT;
    n BIGINT;
BEGIN
    FOREACH t IN ARRAY ARRAY['app_user', 'session', 'dashboard', 'audit'] LOOP
        EXECUTE format('SELECT count(*) FROM frontend.%I', t) INTO n;
        IF n > 0 THEN
            RAISE EXCEPTION '063 check: grafReader sees % rows of frontend.%', n, t;
        END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM frontend.tenant WHERE id = 3) THEN
        RAISE EXCEPTION '063 check: grafReader doesn''t see tenant 3 in frontend.tenant';
    END IF;
    BEGIN
        UPDATE frontend.tenant SET name = name WHERE id = 3;
        RAISE EXCEPTION '063 check: grafReader can write frontend.tenant';
    EXCEPTION WHEN insufficient_privilege THEN NULL;
    END;
END
$$;
RESET ROLE;

-- 3.3 frontend_api: every row, and writes through the dashboard trigger as before
SET LOCAL ROLE frontend_api;
DO $$
DECLARE
    u BIGINT;
    t TEXT;
    n BIGINT;
BEGIN
    FOREACH t IN ARRAY ARRAY['tenant', 'app_user', 'session', 'dashboard', 'audit'] LOOP
        EXECUTE format('SELECT count(*) FROM frontend.%I', t) INTO n;
        IF n = 0 THEN
            RAISE EXCEPTION '063 check: frontend_api sees no rows of frontend.%', t;
        END IF;
    END LOOP;
    SELECT id INTO u FROM frontend.app_user WHERE email = 'check063@example.invalid';
    UPDATE frontend.dashboard SET title = 'check 2' WHERE owner_id = u;
    UPDATE frontend.session SET revoked_at = now() WHERE user_id = u;
    INSERT INTO frontend.audit (event, actor_id, tenant_id) VALUES ('logout', u, 3);
    BEGIN
        UPDATE frontend.dashboard SET tenant_id = 4 WHERE owner_id = u;
        RAISE EXCEPTION '063 check: a dashboard was moved outside its user''s tenant';
    EXCEPTION WHEN foreign_key_violation OR raise_exception THEN
        IF SQLERRM LIKE '063 check:%' THEN RAISE; END IF;
    END;
END
$$;
RESET ROLE;

-- 3.4 the plant roles still can't reach frontend
DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['prs_frontend', 'prs_hermes_agent'] LOOP
        IF has_schema_privilege(r, 'frontend', 'USAGE') OR has_table_privilege(r, 'frontend.app_user', 'SELECT') THEN
            RAISE EXCEPTION '063 check: % can reach frontend', r;
        END IF;
    END LOOP;
END
$$;

DELETE FROM frontend.audit WHERE actor_id IN (SELECT id FROM frontend.app_user WHERE email = 'check063@example.invalid');
DELETE FROM frontend.session WHERE user_id IN (SELECT id FROM frontend.app_user WHERE email = 'check063@example.invalid');
DELETE FROM frontend.dashboard WHERE owner_id IN (SELECT id FROM frontend.app_user WHERE email = 'check063@example.invalid');
DELETE FROM frontend.app_user WHERE email = 'check063@example.invalid';

COMMIT;


-- ============================================================================
-- 4. Results (read-only)
-- ============================================================================

\echo ''
\echo '=== 4.1 Policies on frontend ==='
SELECT tablename, policyname, cmd, roles FROM pg_policies WHERE schemaname = 'frontend' ORDER BY 1, 2;


-- ============================================================================
-- 5. Undo (commented)
-- ============================================================================
--
-- REVOKE SELECT ON ALL TABLES IN SCHEMA frontend FROM "grafReader";
-- REVOKE USAGE ON SCHEMA frontend FROM "grafReader";
-- DROP POLICY dev_refresh ON frontend.tenant;
-- DO $$ DECLARE t TEXT; BEGIN
--     FOREACH t IN ARRAY ARRAY['tenant', 'app_user', 'session', 'dashboard', 'audit'] LOOP
--         EXECUTE format('DROP POLICY frontend_api ON frontend.%I', t);
--         EXECUTE format('ALTER TABLE frontend.%I DISABLE ROW LEVEL SECURITY', t);
--     END LOOP;
-- END $$;
