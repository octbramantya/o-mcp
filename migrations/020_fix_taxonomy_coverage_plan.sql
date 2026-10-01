-- Migration: 020_fix_taxonomy_coverage_plan.sql
-- Description: Rewrite graph.v_taxonomy_coverage to resolve once per taxonomy
--              instead of once per node
-- Author: Claude
-- Date: 2026-08-27
-- Phase: 0 -- additive. Replaces one view definition and refreshes planner
--            statistics. No table, column, function or result changes.
--
-- Requires 018 (the view and graph.resolve_category). Independent of 019, 014
-- and 015: apply it any time after 018.
--
-- ---------------------------------------------------------------------------
-- WHAT WAS WRONG
--
-- Measured on live valkyrie (tenant 3: 176 nodes, 231 edges, 28 categories,
-- 72 assignments), the view returned its 5 rows in 825 ms. Everything else in
-- the schema is sub-2 ms: graph.descendants 0.99 ms, graph.resolve_category
-- 1.6 ms, graph.v_category_tree 0.22 ms.
--
-- The 825 ms was almost entirely LLVM. From the plan's own JIT block:
--
--     Functions: 88
--     Generation 6.6 ms, Inlining 107.9 ms, Optimization 411.8 ms,
--     Emission 271.1 ms, Total 797.4 ms
--
-- Same query with SET jit = off: 57 ms. So ~93% of the cost was compiling
-- machine code to execute a query that touches 176 rows and returns 5.
--
-- Three faults compounded, and it is worth naming all three because only the
-- first is repaired by this file.
--
--   1. THE SHAPE. graph.resolve_category(tenant, taxonomy) takes no node
--      argument -- it resolves the WHOLE taxonomy on every call. 018 called it
--      from a LATERAL once per node and then threw away everything but the one
--      matching row:
--
--          CROSS JOIN graph.node n
--          LEFT JOIN LATERAL (
--              SELECT DISTINCT rc.node_id, rc.is_inherited, rc.is_ambiguous
--              FROM graph.resolve_category(n.tenant_id, t.code) rc
--              WHERE rc.node_id = n.id      -- filter applied AFTER the walk
--          ) r ON TRUE
--
--      The plan showed 99 nodes resolved per call, "Rows Removed by Filter: 98",
--      loops=176 -- 17,424 node-resolutions performed to keep 176. Buffers say
--      it plainly: the outer CROSS JOIN cost shared hit=5, the LATERAL cost
--      shared hit=40,723.
--
--   2. MISSING STATISTICS. graph.taxonomy and graph.category had never been
--      analysed -- last_analyze AND last_autoanalyze both NULL, because both
--      were seeded once and never touched again, so autovacuum's threshold was
--      never crossed. The planner used its default and estimated rows=155 for a
--      ONE-row table. That 155x error multiplied through the nested loop:
--      27,280 estimated loops against 176 actual, at a per-loop LATERAL cost of
--      238.50. Section 2 below fixes this.
--
--   3. JIT THRESHOLDS. The resulting estimate was 6,509,134, against server
--      settings jit_above_cost 100,000, jit_inline_above_cost 500,000 and
--      jit_optimize_above_cost 500,000 -- so it took the expensive tier, full
--      inlining plus optimization, which is where 684 of the 797 ms sat.
--
-- Fault 3 is NOT addressed by changing a server setting here, deliberately. The
-- rewrite drops the estimate to 39,076, below jit_above_cost, so JIT never
-- engages and the gain holds with jit left on. The inflated estimate was a true
-- signal about a genuinely wasteful query, not a planner quirk to silence.
--
-- MEASURED, live, before and after:
--
--     current view    825 ms   cost 6,509,134   JIT: 88 functions, 797 ms
--     this rewrite    2.5 ms   cost    39,076   JIT: none, under threshold
--
-- Both result sets were diffed row for row and are identical:
--
--     FUNCTIONAL|3|BUS        | 25 | 12 |  2 | 0 | 13
--     FUNCTIONAL|3|CONVERSION | 29 | 19 | 13 | 0 | 10
--     FUNCTIONAL|3|LOAD       |101 | 68 | 12 | 0 | 33
--     FUNCTIONAL|3|SOURCE     | 11 |  0 |  0 | 0 | 11
--     FUNCTIONAL|3|STORAGE    | 10 |  0 |  0 | 0 | 10
--
-- WHY THE FIX IS NOT "ADD A NODE ARGUMENT TO resolve_category"
--
-- That would make the per-node call cheap, but it is the wrong direction: the
-- inheritance walk is naturally set-at-a-time -- one pass down graph.edge
-- classifies every node at once -- and a per-node signature would invite the
-- same N+1 from every future caller. resolve_category keeps its signature and
-- its semantics; only the caller stops looping.
-- ---------------------------------------------------------------------------

BEGIN;

-- ============================================================================
-- 1. The view
--
-- scopes    -- the (tenant, taxonomy) pairs that actually have nodes. Derived
--              from graph.node rather than listed, so a tenant with no graph
--              produces no rows, exactly as the 018 CROSS JOIN did. Today this
--              is a single pair, (3, FUNCTIONAL): one call, not 176.
-- resolved  -- one resolution per scope. The DISTINCT reproduces the DISTINCT
--              that sat inside the 018 LATERAL, so counting behaviour is
--              unchanged (see the note below).
--
-- NOTE ON A PRESERVED QUIRK. If a node ever resolves to two categories whose
-- (is_inherited, is_ambiguous) flags DIFFER, the DISTINCT keeps both rows and
-- the LEFT JOIN counts that node twice in `nodes`. 018 behaved identically --
-- an explicit split (several rows at hops = 0, same flags) collapses to one, so
-- it does not bite today, and live `ambiguous` is 0 across every class. This
-- file is a plan fix, not a semantics change: reporting a different total here
-- would be the more expensive surprise. Left as-is, recorded here on purpose.
-- ============================================================================

CREATE OR REPLACE VIEW graph.v_taxonomy_coverage AS
WITH scopes AS (
    SELECT DISTINCT n.tenant_id, t.code AS taxonomy_code
    FROM graph.node n
    CROSS JOIN graph.taxonomy t
    WHERE n.is_active AND t.is_active
), resolved AS (
    SELECT DISTINCT s.tenant_id, s.taxonomy_code,
           rc.node_id, rc.is_inherited, rc.is_ambiguous
    FROM scopes s
    CROSS JOIN LATERAL graph.resolve_category(s.tenant_id, s.taxonomy_code) rc
)
SELECT s.taxonomy_code,
       n.tenant_id,
       n.node_class,
       COUNT(*)                                        AS nodes,
       COUNT(*) FILTER (WHERE r.node_id IS NOT NULL)   AS classified,
       COUNT(*) FILTER (WHERE r.is_inherited)          AS by_inheritance,
       COUNT(*) FILTER (WHERE r.is_ambiguous)          AS ambiguous,
       COUNT(*) FILTER (WHERE r.node_id IS NULL)       AS unclassified
FROM scopes s
JOIN graph.node n ON n.tenant_id = s.tenant_id AND n.is_active
LEFT JOIN resolved r ON r.tenant_id     = s.tenant_id
                    AND r.taxonomy_code = s.taxonomy_code
                    AND r.node_id       = n.id
GROUP BY 1, 2, 3;

COMMENT ON VIEW graph.v_taxonomy_coverage IS
  'Per taxonomy and node class: how many nodes have a business home, how many got it by inheritance, how many are ambiguous, how many have none. Read this after any seed. Resolves once per (tenant, taxonomy) -- see 020 for why once-per-node cost 825 ms.';

COMMIT;

-- ============================================================================
-- 2. Statistics
--
-- Fault 2 above. Both tables are seed-once, so autovacuum will not analyse them
-- on its own -- last_analyze and last_autoanalyze are NULL on live today and
-- will stay NULL. A 1-row table estimated at 155 rows produces bad plans
-- anywhere it is joined, not only in this view, and that failure surfaces as
-- "the dashboard got slow" long after the seed.
--
-- Outside the transaction so a lock wait here cannot hold the view change.
-- Needs write privileges on the tables: grafReader cannot run this part.
-- ============================================================================

ANALYZE graph.taxonomy;
ANALYZE graph.category;
ANALYZE graph.node_category;

-- ============================================================================
-- Verification
-- ============================================================================
-- Expect Execution Time in single-digit ms and NO "JIT:" block in the output.
-- If a JIT block appears, section 2 did not run -- re-check the estimate.
--
-- EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM graph.v_taxonomy_coverage;
--
-- Result must be unchanged. Against tenant 3 as at 2026-08-27:
--
-- SELECT * FROM graph.v_taxonomy_coverage ORDER BY taxonomy_code, tenant_id, node_class;
--
--   taxonomy_code | tenant_id | node_class | nodes | classified | by_inheritance | ambiguous | unclassified
--   FUNCTIONAL    |         3 | BUS        |    25 |         12 |              2 |         0 |           13
--   FUNCTIONAL    |         3 | CONVERSION |    29 |         19 |             13 |         0 |           10
--   FUNCTIONAL    |         3 | LOAD       |   101 |         68 |             12 |         0 |           33
--   FUNCTIONAL    |         3 | SOURCE     |    11 |          0 |              0 |         0 |           11
--   FUNCTIONAL    |         3 | STORAGE    |    10 |          0 |              0 |         0 |           10
--
-- Statistics landed:
-- SELECT relname, n_live_tup, last_analyze FROM pg_stat_user_tables
--  WHERE schemaname = 'graph' AND relname IN ('taxonomy','category','node_category');
