-- Migration: 038_retire_mc_baru_panels.sql
-- Description: Date the retirement of MC302_BARU and MC303_BARU (last day in service
--              2026-09-27), and make v_property_gaps filter the effective window.
-- Author: Claude
-- Date: 2026-10-02
-- Design: design/edge-type.md (open question 5); README "Two rules worth not rediscovering"
-- Requires: 037_create_quantity_term.sql
--
-- WHY
-- ---
-- The site confirmed on 2026-10-02 that both panels were retired on 2026-09-28:
-- real equipment, taken out of use. The database records something else. On
-- 2026-09-29 both nodes were set is_active = FALSE by hand and their feeds from
-- TWIST_PANEL (edges 313, 315) set to effective_to = '-infinity', which by this
-- graph's convention means "never true": an SLD error. Past reports that
-- included the panels would then be retroactively wrong, and an as-of query for
-- any date before the 28th cannot see equipment that was there. Their 18
-- measurement rows were left in effect.
--
-- The fix is valid time. effective_to is the last day the row is true (the
-- window is effective_to >= as_of), so retired on the 28th means
-- effective_to = 2026-09-27 on the two nodes, their two feeds from TWIST_PANEL
-- and their 18 measurement rows. The nodes become is_active = TRUE again: the
-- window, not the flag, retires them, so an as-of query before the 28th sees
-- them and one after does not.
--
-- NOT changed: the feeds from LVMDB_TF630 (edges 119, 121). They are the
-- original SLD's path, superseded when TWIST_PANEL was inserted on 2026-09-21,
-- and stay '-infinity': the panels were fed through TWIST_PANEL, never directly.
-- Devices 158 (MC303-2) and 159 (MC302-3) in public.devices are not graph data
-- and are left as they are; their telemetry history stays reachable.
--
-- v_property_gaps (026) filters is_active only. Until now no node had a dated
-- effective_to, so the gap was invisible; these two are the first, and the
-- view would keep reporting them after retirement. It gets the same window
-- filter 029 gave v_edge_gaps, at CURRENT_DATE. Same columns, same branches.
-- Both panels are PRODUCTION_MACHINE with only OPTIONAL properties, so the
-- gap count does not move either way today.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 The two panels ==='
SELECT node_code, node_type, is_active, effective_from, effective_to
FROM graph.node WHERE tenant_id = 3 AND node_code IN ('MC302_BARU', 'MC303_BARU')
ORDER BY 1;
-- expect both is_active f, effective_to NULL

\echo ''
\echo '=== 1.2 Their feeds ==='
SELECT e.id, f.node_code AS parent, t.node_code AS child, e.is_active,
       e.effective_from, e.effective_to
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND t.node_code IN ('MC302_BARU', 'MC303_BARU')
ORDER BY 3, 2;
-- expect 4, all '-infinity': two from LVMDB_TF630, two from TWIST_PANEL

\echo ''
\echo '=== 1.3 Their measurement rows ==='
SELECT n.node_code, m.device_id, m.is_active, m.effective_to, count(*) AS quantities
FROM graph.measurement m JOIN graph.node n ON n.id = m.node_id
WHERE n.tenant_id = 3 AND n.node_code IN ('MC302_BARU', 'MC303_BARU')
GROUP BY 1, 2, 3, 4 ORDER BY 1;
-- expect MC302_BARU 159 and MC303_BARU 158, 9 rows each, in effect

\echo ''
\echo '=== 1.4 Gap counts before ==='
SELECT status, count(*) FROM graph.v_property_gaps GROUP BY 1 ORDER BY 1;
-- expect MISSING 31


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run unless the rows are exactly as described above
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n FROM graph.node
    WHERE tenant_id = 3 AND node_code IN ('MC302_BARU', 'MC303_BARU')
      AND NOT is_active AND effective_to IS NULL;
    IF n <> 2 THEN
        RAISE EXCEPTION 'expected both panels inactive with no effective_to, found % matching', n;
    END IF;

    SELECT count(*) INTO n
    FROM graph.edge e
    JOIN graph.node f ON f.id = e.from_node_id
    JOIN graph.node t ON t.id = e.to_node_id
    WHERE e.tenant_id = 3 AND t.node_code IN ('MC302_BARU', 'MC303_BARU')
      AND f.node_code = 'TWIST_PANEL' AND e.is_active AND e.effective_to = '-infinity';
    IF n <> 2 THEN
        RAISE EXCEPTION 'expected two TWIST_PANEL feeds at -infinity, found %', n;
    END IF;

    SELECT count(*) INTO n
    FROM graph.edge e JOIN graph.node t ON t.id = e.to_node_id
    WHERE e.tenant_id = 3 AND t.node_code IN ('MC302_BARU', 'MC303_BARU')
      AND (e.effective_to IS DISTINCT FROM '-infinity');
    IF n <> 0 THEN
        RAISE EXCEPTION 'a feed into the panels is not at -infinity (% rows); 038 assumes none is', n;
    END IF;

    SELECT count(*) INTO n
    FROM graph.measurement m JOIN graph.node t ON t.id = m.node_id
    WHERE t.tenant_id = 3 AND t.node_code IN ('MC302_BARU', 'MC303_BARU')
      AND m.is_active AND m.effective_to IS NULL;
    IF n <> 18 THEN
        RAISE EXCEPTION 'expected 18 measurement rows in effect on the panels, found %', n;
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 2.2 Retire by the window: last day in service 2026-09-27
-- ----------------------------------------------------------------------------
UPDATE graph.node
   SET is_active = TRUE, effective_to = DATE '2026-09-27'
 WHERE tenant_id = 3 AND node_code IN ('MC302_BARU', 'MC303_BARU');

UPDATE graph.edge e
   SET effective_to = DATE '2026-09-27'
  FROM graph.node f, graph.node t
 WHERE f.id = e.from_node_id AND t.id = e.to_node_id
   AND e.tenant_id = 3 AND f.node_code = 'TWIST_PANEL'
   AND t.node_code IN ('MC302_BARU', 'MC303_BARU');

UPDATE graph.measurement m
   SET effective_to = DATE '2026-09-27'
  FROM graph.node t
 WHERE t.id = m.node_id
   AND t.tenant_id = 3 AND t.node_code IN ('MC302_BARU', 'MC303_BARU');

-- ----------------------------------------------------------------------------
-- 2.3 v_property_gaps filters the effective window (026's body otherwise unchanged)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW graph.v_property_gaps AS
-- Required, and never recorded (MISSING) or asked but unanswered (UNKNOWN)
SELECT n.tenant_id, n.node_code, n.node_name, n.node_class, n.node_type,
       t.attr_key, p.kind,
       CASE WHEN n.attrs ? t.attr_key THEN 'UNKNOWN' ELSE 'MISSING' END AS status,
       t.used_by, NULL::TEXT AS detail
FROM graph.node n
JOIN graph.v_type_property t ON t.node_type = n.node_type AND t.requirement = 'REQUIRED'
JOIN graph.property p        ON p.attr_key  = t.attr_key
WHERE n.is_active AND n.effective_from <= CURRENT_DATE
  AND (n.effective_to IS NULL OR n.effective_to >= CURRENT_DATE)
  AND jsonb_typeof(COALESCE(n.attrs -> t.attr_key, 'null'::jsonb)) = 'null'

UNION ALL
-- Site status older than its shelf life (or with no date at all)
SELECT n.tenant_id, n.node_code, n.node_name, n.node_class, n.node_type,
       t.attr_key, p.kind, 'STALE', t.used_by,
       'as of ' || COALESCE(n.attrs ->> p.as_of_key, 'never')
FROM graph.node n
JOIN graph.v_type_property t ON t.node_type = n.node_type
JOIN graph.property p        ON p.attr_key  = t.attr_key AND p.kind = 'SITE_STATUS'
WHERE n.is_active AND n.effective_from <= CURRENT_DATE
  AND (n.effective_to IS NULL OR n.effective_to >= CURRENT_DATE)
  AND jsonb_typeof(COALESCE(n.attrs -> t.attr_key, 'null'::jsonb)) <> 'null'
  AND COALESCE((n.attrs ->> p.as_of_key)::date, '-infinity'::date)
      < CURRENT_DATE - p.stale_after_days

UNION ALL
-- No type yet: nothing can be said about what it should carry
SELECT n.tenant_id, n.node_code, n.node_name, n.node_class, n.node_type,
       NULL, NULL, 'UNTYPED', NULL, NULL
FROM graph.node n
WHERE n.is_active AND n.effective_from <= CURRENT_DATE
  AND (n.effective_to IS NULL OR n.effective_to >= CURRENT_DATE)
  AND n.node_type IS NULL

UNION ALL
-- A stored value the current vocabulary no longer accepts. The trigger checks a
-- row when that row is written; if the vocabulary is narrowed later, existing
-- rows are not rechecked, and this is what catches that.
SELECT n.tenant_id, n.node_code, n.node_name, n.node_class, n.node_type,
       a.k, p.kind, 'INVALID', NULL, a.k || ' = ' || a.v::text
FROM graph.node n
CROSS JOIN LATERAL jsonb_each(n.attrs) a (k, v)
LEFT JOIN graph.property p ON p.attr_key = a.k
WHERE n.is_active AND n.effective_from <= CURRENT_DATE
  AND (n.effective_to IS NULL OR n.effective_to >= CURRENT_DATE)
  AND (   p.attr_key IS NULL
       OR (jsonb_typeof(a.v) <> 'null' AND NOT graph.property_value_ok(p, a.v))
       OR (n.node_type IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM graph.v_type_property t
               WHERE t.node_type = n.node_type AND t.attr_key = a.k)));

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 TWIST_PANEL children on the last day in service and on the first day out ==='
SELECT d.as_of, string_agg(t.node_code, ', ' ORDER BY t.node_code) AS children
FROM (VALUES (DATE '2026-09-27'), (DATE '2026-09-28')) AS d(as_of)
JOIN graph.edge e ON e.is_active AND e.effective_from <= d.as_of
                 AND (e.effective_to IS NULL OR e.effective_to >= d.as_of)
JOIN graph.node f ON f.id = e.from_node_id AND f.node_code = 'TWIST_PANEL' AND f.tenant_id = 3
JOIN graph.node t ON t.id = e.to_node_id
GROUP BY 1 ORDER BY 1;
-- expect 2026-09-27: MC302_1_8, MC302_BARU, MC303_BARU
--        2026-09-28: MC302_1_8

\echo ''
\echo '=== 3.2 Measurement rows in effect on the panels, by date ==='
SELECT d.as_of, count(m.id) AS rows_in_effect
FROM (VALUES (DATE '2026-09-27'), (DATE '2026-09-28')) AS d(as_of)
LEFT JOIN graph.measurement m ON m.is_active AND m.effective_from <= d.as_of
      AND (m.effective_to IS NULL OR m.effective_to >= d.as_of)
      AND m.node_id IN (SELECT id FROM graph.node
                        WHERE tenant_id = 3 AND node_code IN ('MC302_BARU', 'MC303_BARU'))
GROUP BY 1 ORDER BY 1;
-- expect 18, then 0

\echo ''
\echo '=== 3.3 Gap views ==='
SELECT status, count(*) FROM graph.v_property_gaps GROUP BY 1 ORDER BY 1;
SELECT count(*) AS edge_gaps FROM graph.v_edge_gaps;
SELECT count(*) AS panels_in_gaps FROM graph.v_property_gaps
WHERE node_code IN ('MC302_BARU', 'MC303_BARU');
-- expect MISSING 31, 0 edge gaps, 0 panel rows


-- ============================================================================
-- 4. Undo (commented) -- restores the 2026-09-29 state and 026's view
-- ============================================================================
--
-- BEGIN;
-- UPDATE graph.measurement m SET effective_to = NULL FROM graph.node t
--  WHERE t.id = m.node_id AND t.tenant_id = 3 AND t.node_code IN ('MC302_BARU', 'MC303_BARU');
-- UPDATE graph.edge e SET effective_to = '-infinity' FROM graph.node f, graph.node t
--  WHERE f.id = e.from_node_id AND t.id = e.to_node_id AND e.tenant_id = 3
--    AND f.node_code = 'TWIST_PANEL' AND t.node_code IN ('MC302_BARU', 'MC303_BARU');
-- UPDATE graph.node SET is_active = FALSE, effective_to = NULL
--  WHERE tenant_id = 3 AND node_code IN ('MC302_BARU', 'MC303_BARU');
-- -- then re-run section 2.5 of 026_create_node_type_property.sql (CREATE OR REPLACE VIEW)
-- COMMIT;
