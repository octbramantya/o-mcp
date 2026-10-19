-- Migration: 057_sld_devices.sql
-- Description: graph.sld_devices: the devices of one SLD section, from a root device down
--              p_depth levels of the graph in effect, for Grafana device variables.
-- Author: Claude
-- Date: 2026-10-19
-- Design: tools/sld.sql (the same walk, as nodes and edges); design/edge-type.md
-- Requires: 054_graph_sankey.sql
--
-- WHY
-- ---
-- The SLD dashboards pick their devices with static lists, for example
--   SELECT id AS __value, device_name AS __text FROM devices
--   WHERE id IN (94, 84, 85, 90, 74, 168) AND tenant_id = $tenant_id
-- which go stale when the graph changes, as the sankey's IN (...) lists did (054). That list
-- already misses two boards the graph puts directly under INCOMING_PLN: LVMDB_TEXTURE_2 (163) and
-- LVMDB_TF630 (106). This function reads the section from the graph instead:
--
--   SELECT device_id AS __value, device_name AS __text
--   FROM graph.sld_devices($tenant_id, $sld_root, $sld_depth)
--   ORDER BY depth, device_name
--
-- THE WALK
-- --------
-- root      the node the root device meters: its node, or the target of its edge (a feeder
--           meter, like 28 on FACTORY_AB -> LVMDB_A5). Depth 0.
-- down      every live edge from a reached node, to p_depth levels (1 for a top-level SLD such
--           as INCOMING_PLN, 2 for a board and its sub-boards).
-- injecting a PV plant or the gas engine (edge type PV_INJECTION or GENERATOR_INFEED) feeding a
--           reached node, the root included. It is a second parent, so the walk down never
--           reaches it, but the SLD draws it beside the board it feeds: PLTS_TEXTURE beside
--           LVMDB_TEXTURE_2. It takes that board's depth. The grid feed (GRID_INFEED,
--           TRANSFORMER) is not injection, so the root's own supply is never included.
-- devices   every device metering a node of the section, on the node or on its feeder edge, at
--           the smallest depth it appears. Unmetered nodes (the gas engine, CB_A2, OFFICE) have
--           no row. A device that is not the tenant's has none either.
--
-- Nodes, edges and measurements are all filtered to the effective window at p_as_of (default
-- CURRENT_DATE); is_active alone over-reports. All utilities are walked: a root on the water
-- graph lists water meters.
--
-- `devices` is unqualified on purpose, as in graph.solve_flow: grafReader reads public.devices,
-- prs_hermes_agent reads prs.devices through its search_path (044). The function is STABLE and
-- SECURITY INVOKER, and reads only what the caller can read.
--
-- Section 2 checks five sections against the graph of 2026-10-19 and aborts if one differs.

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'graph'::regnamespace
               AND proname = 'sld_devices') THEN
        RAISE EXCEPTION '057: graph.sld_devices already exists';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM graph.edge_type WHERE code = 'PV_INJECTION')
       OR NOT EXISTS (SELECT 1 FROM graph.edge_type WHERE code = 'GENERATOR_INFEED') THEN
        RAISE EXCEPTION '057: needs edge types PV_INJECTION and GENERATOR_INFEED';
    END IF;
END
$$;

-- ============================================================================
-- 1. graph.sld_devices
-- ============================================================================
CREATE FUNCTION graph.sld_devices(
    p_tenant_id INTEGER,
    p_device_id INTEGER,
    p_depth     INTEGER DEFAULT 1,
    p_as_of     DATE    DEFAULT CURRENT_DATE)
RETURNS TABLE (device_id INTEGER, device_name TEXT, depth INTEGER, node_code TEXT)
LANGUAGE plpgsql STABLE
AS $fn$
#variable_conflict use_column
BEGIN
    IF p_tenant_id IS NULL OR p_device_id IS NULL OR p_as_of IS NULL THEN
        RAISE EXCEPTION 'graph.sld_devices: tenant, device and as_of are required';
    END IF;
    IF p_depth IS NULL OR p_depth < 0 THEN
        RAISE EXCEPTION 'graph.sld_devices: depth must be 0 or more, got %', p_depth;
    END IF;

    RETURN QUERY
    WITH RECURSIVE
    live_n AS (
      SELECT n.* FROM graph.node n
      WHERE n.tenant_id = p_tenant_id AND n.is_active AND n.effective_from <= p_as_of
        AND (n.effective_to IS NULL OR n.effective_to >= p_as_of)
    ), live_e AS (
      SELECT e.* FROM graph.edge e
      JOIN live_n f ON f.id = e.from_node_id
      JOIN live_n t ON t.id = e.to_node_id
      WHERE e.tenant_id = p_tenant_id AND e.is_active AND e.effective_from <= p_as_of
        AND (e.effective_to IS NULL OR e.effective_to >= p_as_of)
    ), live_m AS (
      SELECT m.* FROM graph.measurement m
      WHERE m.tenant_id = p_tenant_id AND m.is_active AND m.effective_from <= p_as_of
        AND (m.effective_to IS NULL OR m.effective_to >= p_as_of)
    ), walk(node_id, depth) AS (
      SELECT DISTINCT coalesce(m.node_id, e.to_node_id), 0
      FROM live_m m LEFT JOIN live_e e ON e.id = m.edge_id
      WHERE m.device_id = p_device_id
        AND coalesce(m.node_id, e.to_node_id) IS NOT NULL   -- an edge meter on an edge not in effect
      UNION
      SELECT e.to_node_id, w.depth + 1
      FROM walk w JOIN live_e e ON e.from_node_id = w.node_id
      WHERE w.depth < p_depth
    ), reached AS (
      SELECT w.node_id, min(w.depth) AS depth FROM walk w GROUP BY w.node_id
    ), injecting AS (
      SELECT e.from_node_id AS node_id, min(r.depth) AS depth
      FROM live_e e
      JOIN reached r ON r.node_id = e.to_node_id
      WHERE e.edge_type IN ('PV_INJECTION', 'GENERATOR_INFEED')
        AND e.from_node_id NOT IN (SELECT r2.node_id FROM reached r2)
      GROUP BY e.from_node_id
    ), section AS (
      SELECT * FROM reached UNION ALL SELECT * FROM injecting
    ), metered AS (   -- each device at its smallest depth, with the node it meters there
      SELECT DISTINCT ON (m.device_id) m.device_id, s.depth, n.node_code
      FROM section s
      JOIN live_n n ON n.id = s.node_id
      JOIN live_m m ON m.node_id = s.node_id
                    OR m.edge_id IN (SELECT e.id FROM live_e e WHERE e.to_node_id = s.node_id)
      ORDER BY m.device_id, s.depth, n.node_code
    )
    SELECT d.id, d.device_name::text, x.depth, x.node_code::text
    FROM metered x
    JOIN devices d ON d.id = x.device_id AND d.tenant_id = p_tenant_id;
END
$fn$;

COMMENT ON FUNCTION graph.sld_devices(integer, integer, integer, date) IS
    'The devices of one SLD section: the root device, every device metering a node p_depth levels '
    'below the node it meters (on the node or its feeder edge), and PV plants and generators '
    'injecting into those nodes, at the depth of the node they feed. Graph in effect at p_as_of. '
    'depth orders the rows; node_code is the node each device meters at that depth. Migration 057.';

GRANT EXECUTE ON FUNCTION graph.sld_devices(integer, integer, integer, date)
      TO "grafReader", prs_hermes_agent;


-- ============================================================================
-- 2. Self-test (tenant 3, graph of 2026-10-19); aborts the migration if a section differs
-- ============================================================================
DO $$
DECLARE
    got INTEGER[];
    t RECORD;
BEGIN
    FOR t IN
        SELECT * FROM (VALUES
            (94,  1, ARRAY[74, 84, 85, 90, 94, 106, 163, 168]),               -- INCOMING_PLN, PLTS_TEXTURE beside LVMDB_TEXTURE_2
            (163, 1, ARRAY[37, 38, 40, 43, 44, 45, 46, 50, 51, 52, 54, 55, 56, 99, 103, 160, 163, 168]),
                                                                              -- PV into the root itself
            (24,  1, ARRAY[20, 21, 24, 29, 30, 34, 137]),                     -- LVMDB_A2; the gas engine is unmetered
            (24,  2, ARRAY[20, 21, 24, 29, 30, 34, 35, 36, 137]),
            (84,  1, ARRAY[11, 12, 23, 24, 25, 26, 27, 28, 84, 167])          -- FACTORY_AB; 28 is an edge meter
        ) v(root, depth, expect)
    LOOP
        SELECT coalesce(array_agg(s.device_id ORDER BY s.device_id), '{}') INTO got
        FROM graph.sld_devices(3, t.root, t.depth, '2026-10-19') s;
        IF got IS DISTINCT FROM t.expect THEN
            RAISE EXCEPTION '057 self-test: root % depth % gave %, expected %', t.root, t.depth, got, t.expect;
        END IF;
    END LOOP;

    IF EXISTS (SELECT 1 FROM graph.sld_devices(3, 94, 1, '2026-10-19') WHERE device_id = 94 AND depth <> 0) THEN
        RAISE EXCEPTION '057 self-test: the root device is not at depth 0';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.sld_devices(3, 94, 1, '2026-10-19') WHERE device_id = 168 AND depth <> 1) THEN
        RAISE EXCEPTION '057 self-test: PLTS Texture is not at the depth of LVMDB_TEXTURE_2';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.sld_devices(3, -1, 2, '2026-10-19')) THEN
        RAISE EXCEPTION '057 self-test: an unknown device returned rows';
    END IF;
END
$$;

COMMIT;


-- ============================================================================
-- 3. Results (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 INCOMING_PLN (94), depth 1 ==='
SELECT * FROM graph.sld_devices(3, 94, 1) ORDER BY depth, device_name;

\echo ''
\echo '=== 3.2 LVMDB_A2 (24), depth 2 ==='
SELECT * FROM graph.sld_devices(3, 24, 2) ORDER BY depth, device_name;


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- DROP FUNCTION graph.sld_devices(integer, integer, integer, date);
