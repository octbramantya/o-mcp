-- Migration: 050_lvmdb_texture_last_reading.sql
-- Description: Move the end of LVMDB_TEXTURE's 20 edges from 2026-08-17 back to 2026-05-11,
--              the day of its meter's last reading.
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-sankey.md §9.3 (G9)
-- Requires: 049_lvmdb_texture_out_of_service.sql
--
-- WHY
-- ---
-- 049 ended the edges on 2026-08-17, the latest last day the evidence then allowed: a document of
-- 2026-08-18 about LVMDB_TEXTURE_2's new meter. On 2026-10-19 the user checked production's
-- telemetry_15min_agg: the latest bucket for device 107, LVMDB_TEXTURE's meter, is on 2026-05-11.
-- The August document only records that a new meter was installed. So the board was switched off
-- long before August, and its last day in service is taken as the meter's last day, 2026-05-11.
-- That assumes the meter stopped because the board did, which is what the user concluded.
--
-- Valid time, as in 049: the board operated until then. Same 20 edges, same rows; only
-- effective_to moves. Between 2026-05-12 and 2026-08-17, solver results that 049 left with two
-- Texture parents now have one.

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE _g9b ON COMMIT DROP AS
SELECT e.id
FROM graph.edge e JOIN graph.node b ON b.node_code = 'LVMDB_TEXTURE' AND b.tenant_id = 3
WHERE (e.from_node_id = b.id OR e.to_node_id = b.id)
  AND e.is_active AND e.effective_to = DATE '2026-08-17';

DO $$
BEGIN
    IF (SELECT count(*) FROM _g9b) <> 20 THEN
        RAISE EXCEPTION '050: expected the 20 edges 049 ended on 2026-08-17, found %',
            (SELECT count(*) FROM _g9b);
    END IF;
    IF EXISTS (SELECT 1 FROM graph.edge e JOIN _g9b g ON g.id = e.id
               WHERE e.effective_from > DATE '2026-05-11') THEN
        RAISE EXCEPTION '050: an edge starts after 2026-05-11';
    END IF;
END
$$;

UPDATE graph.edge e SET effective_to = DATE '2026-05-11'
FROM _g9b g WHERE e.id = g.id;

COMMIT;


-- ============================================================================
-- Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== Live LVMDB_TEXTURE edges on its last day and the day after ==='
SELECT d.as_of, count(e.id) AS edges
FROM (VALUES (DATE '2026-05-11'), (DATE '2026-05-12')) AS d(as_of)
CROSS JOIN graph.node b
LEFT JOIN graph.edge e ON (e.from_node_id = b.id OR e.to_node_id = b.id)
      AND e.is_active AND e.effective_from <= d.as_of
      AND (e.effective_to IS NULL OR e.effective_to >= d.as_of)
WHERE b.tenant_id = 3 AND b.node_code = 'LVMDB_TEXTURE'
GROUP BY 1 ORDER BY 1;
-- expect 20, then 0

-- Undo (commented):
-- UPDATE graph.edge e SET effective_to = DATE '2026-08-17' FROM graph.node b
--  WHERE b.tenant_id = 3 AND b.node_code = 'LVMDB_TEXTURE'
--    AND (e.from_node_id = b.id OR e.to_node_id = b.id)
--    AND e.is_active AND e.effective_to = DATE '2026-05-11';
