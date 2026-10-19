-- Migration: 056_flr_124_production.sql
-- Description: FLR_124 ("Work Panel Fl. 1, 2, 4") under Production.
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-sankey.md §4 (CHILDREN rule), §7 (G3)
-- Requires: 055_sippa_under_wwtp.sql
--
-- WHY
-- ---
-- FLR_124 is the only unmetered panel on LVMDP_SPINNING_1 (the user's SLD; the site describes it as
-- "work panels for 1st, 2nd and 4th floor"). Nothing says whether it serves production or
-- utilities. The client asks for two broad classes, Production and Utilities, so the user
-- classifies it as Production (2026-10-19). An office or general-admin category waits until the
-- client asks for one, which would be done panel by panel from the SLD.
--
-- Effect: FLR_124 has no meter, so its own value stays 0. Through the CHILDREN rule of
-- graph.sankey, LVMDP_SPINNING_1's residual (meter 85 minus its six metered children: 60,764 kWh in
-- September 2026, about 85 kW day and night) takes FLR_124's category and moves from Unassigned to
-- Production. The residual may also hold cable losses and loads missing from the SLD; it is all
-- drawn as Production. Section 2 checks that nothing else moves.

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM graph.node_category nc JOIN graph.node n ON n.id = nc.node_id
               WHERE n.tenant_id = 3 AND n.node_code = 'FLR_124') THEN
        RAISE EXCEPTION '056: FLR_124 already has a node_category row';
    END IF;
END
$$;

CREATE TEMP TABLE _res (ver text, category text, value numeric) ON COMMIT DROP;
INSERT INTO _res
SELECT 'before', target, value FROM graph.sankey(3, '2026-09-01', '2026-09-30', p_node_detail => FALSE)
WHERE link_kind = 'CATEGORY';

INSERT INTO graph.node_category (tenant_id, node_id, category_id, weight, effective_from)
SELECT 3, n.id, c.id, 1.0, '1900-01-01'
FROM graph.node n, graph.category c
WHERE n.tenant_id = 3 AND n.node_code = 'FLR_124'
  AND c.tenant_id = 3 AND c.taxonomy_code = 'FUNCTIONAL' AND c.category_code = 'PRODUCTION';

INSERT INTO _res
SELECT 'after', target, value FROM graph.sankey(3, '2026-09-01', '2026-09-30', p_node_detail => FALSE)
WHERE link_kind = 'CATEGORY';

-- Post-condition: only Production and Unassigned move, by the same amount
DO $$
DECLARE
    n INT;
    d_prod NUMERIC;
    d_unas NUMERIC;
BEGIN
    SELECT count(*) INTO n
    FROM (SELECT category, value FROM _res WHERE ver = 'before') b
    FULL JOIN (SELECT category, value FROM _res WHERE ver = 'after') a ON a.category = b.category
    WHERE COALESCE(b.category, a.category) NOT IN ('Production', 'Unassigned')
      AND (a.category IS NULL OR b.category IS NULL OR abs(a.value - b.value) >= 0.5);
    IF n <> 0 THEN
        RAISE EXCEPTION '056: % categories other than Production and Unassigned moved', n;
    END IF;
    SELECT a.value - b.value INTO d_prod FROM _res a JOIN _res b ON b.category = a.category AND b.ver = 'before'
    WHERE a.ver = 'after' AND a.category = 'Production';
    SELECT COALESCE((SELECT value FROM _res WHERE ver = 'after' AND category = 'Unassigned'), 0)
         - COALESCE((SELECT value FROM _res WHERE ver = 'before' AND category = 'Unassigned'), 0) INTO d_unas;
    IF abs(d_prod + d_unas) >= 0.5 OR d_prod < 0.5 THEN
        RAISE EXCEPTION '056: Production moved by %, Unassigned by %', d_prod, d_unas;
    END IF;
END
$$;

\echo ''
\echo '=== What moved (September 2026, kWh) ==='
SELECT b.category, round(b.value) AS before, round(a.value) AS after
FROM _res b JOIN _res a ON a.ver = 'after' AND a.category = b.category
WHERE b.ver = 'before' AND abs(a.value - b.value) >= 0.5 ORDER BY 1;
-- on dev: Production 1,242,897 -> 1,303,661; Unassigned 451,177 -> 390,413

COMMIT;


-- ============================================================================
-- Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== LVMDP_SPINNING_1 and FLR_124 ==='
SELECT node_code, round(own) AS own, category_how
FROM graph.sankey_nodes(3, '2026-09-01', '2026-09-30')
WHERE node_code IN ('LVMDP_SPINNING_1', 'FLR_124') ORDER BY 1;
-- expect LVMDP_SPINNING_1 60,764 CHILDREN; FLR_124 0 EXPLICIT

-- Undo (commented):
-- DELETE FROM graph.node_category nc USING graph.node n
--  WHERE n.id = nc.node_id AND n.tenant_id = 3 AND n.node_code = 'FLR_124';
