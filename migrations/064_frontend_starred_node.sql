-- Migration: 064_frontend_starred_node.sql
-- Description: frontend.starred_node, each account's starred nodes per tenant, for the left panel's
--              starred list; written by frontend_api only, under 063's row-level security.
-- Author: Claude
-- Date: 2026-10-27
-- Design: design/frontend.md §5 (the frame's left panel), §8 (the schema)
-- Requires: 063_frontend_rls.sql; superuser (it verifies as each role)
--
-- WHY
-- ---
-- Decided 2026-10-27: starred nodes are kept per account in the database, not per browser, so they
-- follow a person between browsers and devices (web/ slice 3).
--
-- THE TABLE
-- ---------
-- One row per account, tenant and node. An admin's stars are per tenant, as their dashboards are,
-- since node ids are a tenant's; a user's are in their own tenant, enforced by trigger as on
-- frontend.dashboard. node_id is graph.node.id with no foreign key, as nodes in a dashboard
-- document are stored (design/frontend.md §1, decision 19): a node that leaves the plant stays
-- starred and the frontend says it is no longer in the plant, and graph keeps no dependency on
-- frontend. A star means nothing without its account, so deleting an account deletes its stars
-- (frontend_api never deletes accounts; the dev tests' clean-up does).
--
-- ACCESS
-- ------
-- frontend_api   SELECT, INSERT, DELETE; the same FOR ALL policy as 063's five tables.
-- grafReader     SELECT, so tools/dev_refresh.sh copies the structure, and no policy, so no rows.
-- The plant roles have no grant on frontend.

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF to_regclass('frontend.starred_node') IS NOT NULL THEN
        RAISE EXCEPTION '064: frontend.starred_node already exists';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policy WHERE polname = 'frontend_api'
                   AND polrelid = 'frontend.dashboard'::regclass) THEN
        RAISE EXCEPTION '064: needs 063''s row-level security on frontend';
    END IF;
END
$$;

-- ============================================================================
-- 1. The table
-- ============================================================================

CREATE TABLE frontend.starred_node (
    user_id     BIGINT NOT NULL REFERENCES frontend.app_user (id) ON DELETE CASCADE,
    tenant_id   INTEGER NOT NULL REFERENCES frontend.tenant (id),
    node_id     BIGINT NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, tenant_id, node_id)
);
COMMENT ON TABLE frontend.starred_node IS
    'An account''s starred nodes in a tenant, the frontend''s left panel (064; design/frontend.md §5). '
    'node_id is graph.node.id, with no foreign key: a node that leaves the plant stays starred.';

CREATE FUNCTION frontend.assert_starred_tenant() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_role TEXT;
    v_tenant INTEGER;
BEGIN
    SELECT role, tenant_id INTO v_role, v_tenant FROM frontend.app_user WHERE id = NEW.user_id;
    IF v_role = 'user' AND NEW.tenant_id <> v_tenant THEN
        RAISE EXCEPTION 'frontend.starred_node: user % belongs to tenant %, not %', NEW.user_id, v_tenant, NEW.tenant_id;
    END IF;
    RETURN NEW;
END
$$;
CREATE TRIGGER starred_tenant BEFORE INSERT OR UPDATE ON frontend.starred_node
    FOR EACH ROW EXECUTE FUNCTION frontend.assert_starred_tenant();

-- ============================================================================
-- 2. Access
-- ============================================================================

ALTER TABLE frontend.starred_node ENABLE ROW LEVEL SECURITY;
CREATE POLICY frontend_api ON frontend.starred_node FOR ALL TO frontend_api USING (true) WITH CHECK (true);
COMMENT ON POLICY frontend_api ON frontend.starred_node IS
    'The API''s role sees every row; its grants decide what it may do (063, 064).';

GRANT SELECT, INSERT, DELETE ON frontend.starred_node TO frontend_api;
GRANT SELECT ON frontend.starred_node TO "grafReader";

-- ============================================================================
-- 3. Checks, as each role, before committing
-- ============================================================================

DO $$
BEGIN
    INSERT INTO frontend.app_user (email, password_hash, role, tenant_id)
    VALUES ('check064@example.invalid', 'x', 'user', 3);
END
$$;

-- 3.1 frontend_api: star, read, unstar; not outside the user's tenant
SET LOCAL ROLE frontend_api;
DO $$
DECLARE
    u BIGINT;
BEGIN
    SELECT id INTO u FROM frontend.app_user WHERE email = 'check064@example.invalid';
    INSERT INTO frontend.starred_node (user_id, tenant_id, node_id) VALUES (u, 3, 1), (u, 3, 2);
    IF (SELECT count(*) FROM frontend.starred_node WHERE user_id = u) <> 2 THEN
        RAISE EXCEPTION '064 check: frontend_api doesn''t see its two stars';
    END IF;
    DELETE FROM frontend.starred_node WHERE user_id = u AND node_id = 2;
    BEGIN
        INSERT INTO frontend.starred_node (user_id, tenant_id, node_id) VALUES (u, 4, 1);
        RAISE EXCEPTION '064 check: a star was saved outside its user''s tenant';
    EXCEPTION WHEN foreign_key_violation OR raise_exception THEN
        IF SQLERRM LIKE '064 check:%' THEN RAISE; END IF;
    END;
END
$$;
RESET ROLE;

-- 3.2 grafReader: no rows
SET LOCAL ROLE "grafReader";
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM frontend.starred_node) THEN
        RAISE EXCEPTION '064 check: grafReader sees stars';
    END IF;
END
$$;
RESET ROLE;

-- 3.3 the plant roles can't reach it; deleting the account deletes its star
DO $$
DECLARE
    r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['prs_frontend', 'prs_hermes_agent'] LOOP
        IF has_table_privilege(r, 'frontend.starred_node', 'SELECT') THEN
            RAISE EXCEPTION '064 check: % can read frontend.starred_node', r;
        END IF;
    END LOOP;
    DELETE FROM frontend.app_user WHERE email = 'check064@example.invalid';
    IF EXISTS (SELECT 1 FROM frontend.starred_node) THEN
        RAISE EXCEPTION '064 check: a star outlived its account';
    END IF;
END
$$;

COMMIT;


-- ============================================================================
-- 4. Results (read-only)
-- ============================================================================

\echo ''
\echo '=== 4.1 Policies on frontend.starred_node ==='
SELECT policyname, cmd, roles FROM pg_policies WHERE schemaname = 'frontend' AND tablename = 'starred_node';


-- ============================================================================
-- 5. Undo (commented)
-- ============================================================================
--
-- DROP TABLE frontend.starred_node;
-- DROP FUNCTION frontend.assert_starred_tenant();
