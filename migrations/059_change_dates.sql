-- Migration: 059_change_dates.sql
-- Description: graph.change_dates: the days inside a range on which the graph in effect changes,
--              where a value over the range is cut into pieces solved on their own graphs.
-- Author: Claude
-- Date: 2026-10-22
-- Design: design/frontend.md §3 ("Where C cuts"), §1 decision 20
-- Requires: 058_g3_categories.sql
--
-- WHY
-- ---
-- graph.solve_flow takes one p_as_of and solves a whole window against the graph in effect that
-- day (051). A window that spans a dated change in the plant is then solved on one graph for
-- days when another was true: September 2026 solved as of 09-30 drops MC302_BARU and
-- MC303_BARU's readings for 09-01 to 09-27, since both were retired on 09-28 (038).
-- Decided 2026-10-22: value widgets, and node_value, cut the range at its change dates, solve
-- each piece on its own graph and combine the pieces by the quantity's rule; topology widgets
-- draw the range's last day. This function is where both find the cuts, so the agent and the
-- frontend never disagree on a window.
--
-- WHAT COUNTS AS A CHANGE
-- -----------------------
-- A day d with p_start < d < p_end (half-open: a change on p_start doesn't cut, and p_end is
-- outside the range) on which a live row of the tenant's
--   graph.node, graph.edge, graph.measurement   (what solve_flow reads), or
--   graph.node_category                         (what graph.sankey reads)
-- starts (effective_from = d) or ends (effective_to = d - 1: effective_to is the last day in
-- service). Rows with is_active = FALSE are not read by the solver on any day, so they never
-- change it. Infinite dates are not changes: effective_to = '-infinity' is a documentation
-- correction, never true, so it applies to the whole range, and effective_from = '-infinity'
-- (or node_category's default 1900-01-01) is before every range anyway.
--
-- The function is STABLE and SECURITY INVOKER: it reads what the caller can read, so a tenant
-- role (044) sees its own tenant's changes only.
--
-- Section 2 checks the function against tenant 3's dated rows of 2026-10-22: edges ending
-- 2026-05-11 (049, 050), and nodes, edges and measurements ending 2026-09-27 (038).

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'graph'::regnamespace
               AND proname = 'change_dates') THEN
        RAISE EXCEPTION '059: graph.change_dates already exists';
    END IF;
END
$$;

-- ============================================================================
-- 1. The function
-- ============================================================================

CREATE FUNCTION graph.change_dates(p_tenant_id INTEGER, p_start DATE, p_end DATE)
RETURNS TABLE (change_date DATE)
LANGUAGE sql STABLE AS $$
    WITH bounds AS (
        SELECT effective_from AS f, effective_to AS t FROM graph.node
         WHERE tenant_id = p_tenant_id AND is_active
        UNION ALL
        SELECT effective_from, effective_to FROM graph.edge
         WHERE tenant_id = p_tenant_id AND is_active
        UNION ALL
        SELECT effective_from, effective_to FROM graph.measurement
         WHERE tenant_id = p_tenant_id AND is_active
        UNION ALL
        SELECT effective_from, effective_to FROM graph.node_category
         WHERE tenant_id = p_tenant_id AND is_active
    ), days AS (
        SELECT f AS d FROM bounds WHERE isfinite(f)
        UNION
        SELECT t + 1 FROM bounds WHERE t IS NOT NULL AND isfinite(t)
    )
    SELECT d FROM days WHERE d > p_start AND d < p_end ORDER BY d
$$;

COMMENT ON FUNCTION graph.change_dates(INTEGER, DATE, DATE) IS
    'Days d, p_start < d < p_end, on which the tenant''s graph in effect changes: a live node, edge, '
    'measurement or node_category row starts on d or ends on d - 1. Infinite dates are not changes. '
    'A range is solved in pieces cut at these days, each as of its own last day (059; design/frontend.md §3).';

GRANT EXECUTE ON FUNCTION graph.change_dates(INTEGER, DATE, DATE) TO "grafReader", prs_hermes_agent;

-- ============================================================================
-- 2. Self-test
-- ============================================================================

DO $$
DECLARE
    t RECORD;
    got DATE[];
BEGIN
    FOR t IN SELECT * FROM (VALUES
            ('2026-09-01'::date, '2026-10-01'::date, ARRAY['2026-09-28']::date[]),   -- 038's retirements
            ('2026-05-01', '2026-06-01', ARRAY['2026-05-12']::date[]),               -- 050's edge ends
            ('2026-01-01', '2026-12-31', ARRAY['2026-05-12', '2026-09-28']::date[]),
            ('2026-09-28', '2026-10-05', ARRAY[]::date[]),                          -- a change on the first day doesn't cut
            ('2026-09-20', '2026-09-28', ARRAY[]::date[]),                          -- nor one on the excluded end
            ('2026-10-01', '2026-10-22', ARRAY[]::date[])) AS v(s, e, expect)
    LOOP
        SELECT coalesce(array_agg(c.change_date ORDER BY c.change_date), '{}') INTO got
        FROM graph.change_dates(3, t.s, t.e) c;
        IF got IS DISTINCT FROM t.expect THEN
            RAISE EXCEPTION '059 self-test: % to % gave %, expected %', t.s, t.e, got, t.expect;
        END IF;
    END LOOP;

    IF EXISTS (SELECT 1 FROM graph.change_dates(-1, '2026-01-01', '2026-12-31')) THEN
        RAISE EXCEPTION '059 self-test: an unknown tenant returned changes';
    END IF;
END
$$;

COMMIT;


-- ============================================================================
-- 3. Results (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Tenant 3, 2026 ==='
SELECT * FROM graph.change_dates(3, '2026-01-01', '2027-01-01');


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- DROP FUNCTION graph.change_dates(integer, date, date);
