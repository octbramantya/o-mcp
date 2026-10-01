-- Migration: 012_verify_graph_migration.sql
-- Description: Read-only checks that the graph reproduces the legacy Sankey
-- Author: Claude
-- Date: 2026-08-19
-- Phase: 3 (see §8 of design/graph-network-design.md)
--
-- Nothing here writes. Run it after 011 and read the output; Phase 4 (repointing
-- the UI at graph.get_sankey_flow) is a config change with no SQL of its own, and
-- must not happen until section 2 below reconciles.

-- ============================================================================
-- 1. Structure landed
-- ============================================================================

SELECT 'Node counts by class' AS check_name;
SELECT node_class, COUNT(*) AS nodes
FROM graph.node WHERE tenant_id = 3 AND is_active
GROUP BY 1 ORDER BY 1;

SELECT 'Edge counts by utility' AS check_name;
SELECT utility_code, edge_class, COUNT(*) AS edges
FROM graph.edge WHERE tenant_id = 3 AND is_active
GROUP BY 1, 2 ORDER BY 1, 2;

SELECT 'Measurements by attachment' AS check_name;
SELECT utility_code,
       COUNT(*) FILTER (WHERE node_id IS NOT NULL) AS on_nodes,
       COUNT(*) FILTER (WHERE edge_id IS NOT NULL) AS on_edges,
       COUNT(DISTINCT device_id)                   AS devices
FROM graph.measurement WHERE tenant_id = 3 AND is_active
GROUP BY 1 ORDER BY 1;

-- Roots. Anything unexpected here means a fed_by was missed.
SELECT 'Nodes with no in-edge (should be sources only)' AS check_name;
SELECT n.node_code, n.node_class
FROM graph.node n
WHERE n.tenant_id = 3 AND n.is_active
  AND NOT EXISTS (SELECT 1 FROM graph.edge e WHERE e.to_node_id = n.id AND e.is_active)
ORDER BY n.node_class, n.node_code;

-- ============================================================================
-- 2. THE GATE: graph Sankey vs the legacy one, same window
--
-- Totals will NOT match exactly, and that is expected -- the graph includes the
-- 29 devices that prs.device_node_mapping never mapped. Grid-level totals should
-- reconcile; every leaf difference should be explainable device by device.
-- ============================================================================

SELECT 'Sankey: graph vs get_sankey_energy_flow_v2' AS check_name;
WITH old AS (
    SELECT source, target, SUM(value) v
    FROM prs.get_sankey_energy_flow_v2(3, '2026-07-01', '2026-07-31')
    GROUP BY 1, 2
),
new AS (
    SELECT source, target, SUM(value) v
    FROM graph.get_sankey_flow(3, 'ELECTRICITY', '2026-07-01', '2026-07-31', 124)
    GROUP BY 1, 2
)
SELECT COALESCE(o.source, n.source) AS source,
       COALESCE(o.target, n.target) AS target,
       o.v AS old_value, n.v AS new_value,
       ROUND(100 * (n.v - o.v) / NULLIF(o.v, 0), 2) AS pct_diff
FROM old o FULL OUTER JOIN new n USING (source, target)
WHERE o.v IS DISTINCT FROM n.v
ORDER BY ABS(COALESCE(n.v, 0) - COALESCE(o.v, 0)) DESC;

-- ============================================================================
-- 3. Coverage -- which nodes have no instrument at all
--
-- Expected to be a long list: the seed is the FULL physical SLD including
-- unmetered panels, which the legacy hierarchy never held. A node here is not a
-- defect; a *metered* node missing from here is.
-- ============================================================================

SELECT 'Unmetered nodes' AS check_name;
SELECT node_code, node_name, node_class, in_degree, out_degree
FROM graph.v_coverage
WHERE tenant_id = 3 AND NOT is_node_metered AND NOT is_edge_metered
ORDER BY node_class, node_code;

SELECT 'Coverage summary' AS check_name;
SELECT COUNT(*)                                          AS nodes,
       COUNT(*) FILTER (WHERE is_node_metered)           AS node_metered,
       COUNT(*) FILTER (WHERE is_edge_metered)           AS edge_metered,
       COUNT(*) FILTER (WHERE NOT is_node_metered
                          AND NOT is_edge_metered)       AS unmetered
FROM graph.v_coverage WHERE tenant_id = 3;

-- ============================================================================
-- 4. Every device that reports energy, but is attached to nothing
--
-- This is the list the graph is supposed to shrink to zero. 29 devices were
-- unmapped under prs.device_node_mapping.
-- ============================================================================

SELECT 'Devices reporting energy but not in the graph' AS check_name;
SELECT DISTINCT d.id, d.device_code, d.device_name, d.device_type
FROM public.devices d
JOIN public.daily_energy_cost_summary s ON s.device_id = d.id AND s.tenant_id = 3
WHERE d.tenant_id = 3
  AND NOT EXISTS (SELECT 1 FROM graph.measurement m
                   WHERE m.device_id = d.id AND m.tenant_id = 3 AND m.is_active)
ORDER BY d.id;

-- ============================================================================
-- 5. Solver health on the real seed
--
-- origin tells you HOW each value was obtained. A large NULL bucket is normal
-- where the SLD is deeper than the metering; a large CHILDREN bucket is not --
-- rule (d) is the last resort and should be rare.
-- ============================================================================

SELECT 'Electricity solve by provenance' AS check_name;
SELECT COALESCE(origin, '(unresolved)') AS origin,
       COUNT(*) AS nodes,
       COUNT(*) FILTER (WHERE unaccounted IS NOT NULL) AS with_residual
FROM graph.get_node_values(3, 'ELECTRICITY', '2026-07-01', '2026-07-31', 124)
GROUP BY 1 ORDER BY 1;

SELECT 'Water solve by provenance' AS check_name;
SELECT COALESCE(origin, '(unresolved)') AS origin,
       COUNT(*) AS nodes,
       COUNT(*) FILTER (WHERE unaccounted IS NOT NULL) AS with_residual
FROM graph.get_node_values(3, 'WATER', '2026-07-01', '2026-07-31', 5696)
GROUP BY 1 ORDER BY 1;

-- ============================================================================
-- 6. Stopped meters (§12.5, §13)
--
-- v_coverage reports whether an instrument is ATTACHED, not whether it is
-- REPORTING. A dead meter reads as zero, and its branch then shows a residual
-- that looks exactly like a leak. Check this before showing anyone a residual.
-- ============================================================================

SELECT 'Attached devices with no data in the window' AS check_name;
SELECT m.device_id, d.device_code, d.device_name, m.utility_code,
       COALESCE(n.node_code, 'edge ' || m.edge_id::TEXT) AS attached_to
FROM graph.measurement m
JOIN public.devices d ON d.id = m.device_id
LEFT JOIN graph.node n ON n.id = m.node_id
WHERE m.tenant_id = 3 AND m.is_active
  AND NOT EXISTS (
      SELECT 1 FROM graph.device_totals(3, m.utility_code,
                                        '2026-07-01', '2026-07-31', m.quantity_id) t
      WHERE t.device_id = m.device_id AND t.total <> 0)
ORDER BY m.utility_code, m.device_id;
