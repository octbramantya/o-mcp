-- Migration: 054_graph_sankey.sql
-- Description: graph.sankey_nodes, graph.sankey and graph.sankey_diagnostics: a sankey that
--              names no device and no node, solved on the graph in effect and rolled up the
--              category tree.
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-sankey.md §2-§6, §9.6, §9.7; design/graph-network-design.md §15
-- Requires: 053_node_type_category.sql
--
-- WHY
-- ---
-- The dashboard's prs.get_sankey_energy_flow names devices in IN (...) lists. It missed two PV
-- plants added later, read a PV meter as a compressor, and added nested meters together
-- (design §1). These functions name node classes, node types and categories only, and read
-- everything else from the graph in effect on p_as_of, so a node inserted into the graph is on
-- the diagram the day it is inserted. prs.get_sankey_energy_flow is not touched; it stays until
-- the new panel has run beside it for a month (design §8).
--
-- THE THREE FUNCTIONS
-- -------------------
-- graph.sankey_nodes   one row per (node, category): the node's own value and how its category
--                      was found. The other two read it, and a table panel can.
-- graph.sankey         the links: source -> Supply -> category tree -> node.
-- graph.sankey_diagnostics   what the diagram cannot show.
--
-- Each solves the window itself (graph.solve_flow), in one statement, so each is safe to call
-- alone from Grafana. They are VOLATILE (the solver creates temp tables) and SECURITY INVOKER;
-- they read only what the caller can read.
--
-- OWN VALUE (design §3, §9.7)
--   leaf (no out-edge)                              its solved value
--   out-edges, valued MEASURED or IN_EDGES          value - sum of its out-edges (the residual)
--   out-edges, valued OUT_EDGES or CHILDREN         0: its value is its children
--   SOURCE valued MEASURED or IN_EDGES              value - out-edges: what its meter reads that no
--                                                   feed accounts for (94: unmetered load or losses)
--   other SOURCE, STORAGE, SINK                     none
-- So the sum of own values equals the sum of what the sources supply, and no meter is counted
-- twice. A negative own value is a meter disagreement: it is never drawn, and is returned by
-- sankey_diagnostics as NEGATIVE_RESIDUAL.
--
-- CATEGORY (design §4), first that applies:
--   EXPLICIT   node_category rows in effect on the node (weighted splits kept)
--   TYPE       graph.node_type_category for the node's type (053)
--   CHILDREN   for a node with out-edges: the one category its unmetered children have, by
--              EXPLICIT or TYPE, when all of them have one and they agree. Its residual is
--              those children's load. (LVMDB_A5 -> COMPRESSOR via COMP_300HP and COMP_400HP.)
--   INHERITED  the nearest ancestor along the solver's edges with an EXPLICIT or TYPE category.
--              Unlike graph.resolve_category, a type default stops the walk too, so a pump under
--              an AHU is HVAC. Several ancestors at the same distance share the node evenly and
--              flag it ambiguous.
--   UNASSIGNED drawn under the root as "Unassigned", never folded into another category.
--
-- LINKS (design §5)
--   SUPPLY     each SOURCE -> the taxonomy's root (Supply), its solved value
--   CATEGORY   parent category -> category, the positive own values beneath it; and
--              root -> Unassigned
--   NODE       category -> node, the node's positive own value x its weight; with
--              p_node_detail = false only for nodes on a category that has child categories,
--              since nothing else carries their energy
-- Labels are category_name and node_name. A node whose name equals a category name (TRICOT is
-- "Tricot", like the category), "Unassigned" or another node's name is labelled
-- "name (CODE)". A source's own value is labelled "name (unaccounted)", so it is not a cycle back
-- to the source. Colours are category.display_color; a node takes its category's; Unassigned is
-- grey. No Export link in this version (design §9.6): negative edges and received energy are
-- diagnostics.
--
-- Arguments are dates, and p_end is inclusive (daily_energy_cost_summary is daily; the solver's
-- device_totals reads daily_bucket <= p_end). p_as_of defaults to p_end, so a past window is drawn
-- with the graph of that time. The utility is the quantity's (graph.quantity_rule).
--
-- Section 4 checks the balances on September 2026 and aborts if any fails.

\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
    IF to_regclass('graph.node_type_category') IS NULL THEN
        RAISE EXCEPTION '054: needs graph.node_type_category (053)';
    END IF;
    IF to_regprocedure('graph.sankey(integer,date,date,date,integer,boolean,character varying,boolean)') IS NOT NULL
       OR EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'graph'::regnamespace
                  AND proname IN ('sankey', 'sankey_nodes', 'sankey_diagnostics')) THEN
        RAISE EXCEPTION '054: a graph.sankey* function already exists';
    END IF;
END
$$;

-- ============================================================================
-- 1. graph.sankey_nodes
-- ============================================================================
CREATE FUNCTION graph.sankey_nodes(
    p_tenant_id   INTEGER,
    p_start       DATE,
    p_end         DATE,
    p_as_of       DATE    DEFAULT NULL,
    p_quantity_id INTEGER DEFAULT 124,
    p_is_cost     BOOLEAN DEFAULT FALSE,
    p_taxonomy    VARCHAR DEFAULT 'FUNCTIONAL')
RETURNS TABLE (node_id BIGINT, node_code TEXT, node_class TEXT, label TEXT,
               val_src TEXT, value NUMERIC, own NUMERIC,
               category_id BIGINT, category_how TEXT, weight NUMERIC,
               category_ambiguous BOOLEAN, flow_ambiguous BOOLEAN, has_data BOOLEAN)
LANGUAGE plpgsql VOLATILE
AS $fn$
#variable_conflict use_column
DECLARE
    v_as_of   DATE := COALESCE(p_as_of, p_end);
    v_utility VARCHAR;
BEGIN
    IF p_start IS NULL OR p_end IS NULL OR p_end < p_start THEN
        RAISE EXCEPTION 'graph.sankey: need p_start <= p_end (both dates, p_end inclusive)';
    END IF;
    SELECT qr.utility_code INTO v_utility FROM graph.quantity_rule qr
    WHERE qr.quantity_id = p_quantity_id AND qr.conserved;
    IF v_utility IS NULL THEN
        RAISE EXCEPTION 'graph.sankey: quantity % is not a conserved quantity in graph.quantity_rule',
            p_quantity_id;
    END IF;

    PERFORM graph.solve_flow(p_tenant_id => p_tenant_id, p_utility_code => v_utility,
                             p_start => p_start::timestamp, p_end => p_end::timestamp,
                             p_quantity_id => p_quantity_id, p_is_cost => p_is_cost,
                             p_as_of => v_as_of);

    RETURN QUERY
    WITH RECURSIVE
    cat AS (
        SELECT c.id, c.category_name FROM graph.category c
        WHERE c.tenant_id = p_tenant_id AND c.taxonomy_code = p_taxonomy AND c.is_active
    ),
    nd AS (
        SELECT n.id, n.node_code::text AS code, n.node_name::text AS name, n.node_class::text AS cls,
               gn.node_type, n.val_src::text AS src, n.value AS val, n.out_deg, n.has_data AS hd,
               n.measured,
               COALESCE((SELECT sum(g.value) FROM _ge g WHERE g.from_node_id = n.id), 0) AS out_sum
        FROM _gn n JOIN graph.node gn ON gn.id = n.id
        WHERE n.node_class NOT IN ('STORAGE', 'SINK')
    ),
    ownv AS (
        SELECT nd.*,
               CASE WHEN nd.cls = 'SOURCE' THEN
                        CASE WHEN nd.src IN ('MEASURED', 'IN_EDGES') THEN nd.val - nd.out_sum ELSE 0 END
                    WHEN nd.out_deg = 0 THEN COALESCE(nd.val, 0)
                    WHEN nd.src IN ('MEASURED', 'IN_EDGES') THEN nd.val - nd.out_sum
                    ELSE 0 END AS own_v
        FROM nd
    ),
    -- EXPLICIT and TYPE: the categories a node states itself
    direct AS (
        SELECT nc.node_id AS nid, nc.category_id AS cid, nc.weight AS w, 'EXPLICIT'::text AS how
        FROM graph.node_category nc JOIN cat ON cat.id = nc.category_id
        WHERE nc.tenant_id = p_tenant_id AND nc.is_active
          AND nc.effective_from <= v_as_of
          AND (nc.effective_to IS NULL OR nc.effective_to >= v_as_of)
          AND nc.node_id IN (SELECT o.id FROM ownv o)
      UNION ALL
        SELECT o.id, t.category_id, 1.0, 'TYPE'
        FROM ownv o
        JOIN graph.node_type_category t ON t.tenant_id = p_tenant_id AND t.taxonomy_code = p_taxonomy
                                       AND t.node_type = o.node_type
        JOIN cat ON cat.id = t.category_id
        WHERE NOT EXISTS (SELECT 1 FROM graph.node_category nc JOIN cat c2 ON c2.id = nc.category_id
                          WHERE nc.node_id = o.id AND nc.tenant_id = p_tenant_id AND nc.is_active
                            AND nc.effective_from <= v_as_of
                            AND (nc.effective_to IS NULL OR nc.effective_to >= v_as_of))
    ),
    -- CHILDREN: unmetered children that all state the same category
    kids AS (
        SELECT g.from_node_id AS nid, min(d.cid) AS cid
        FROM _ge g JOIN _gn c ON c.id = g.to_node_id
        LEFT JOIN direct d ON d.nid = c.id
        WHERE g.meas IS NULL AND c.measured IS NULL AND c.node_class NOT IN ('SOURCE', 'STORAGE', 'SINK')
        GROUP BY g.from_node_id
        HAVING count(DISTINCT d.cid) = 1 AND count(*) = count(d.cid)
    ),
    -- INHERITED: walk down the solver's edges from every node that states a category
    walk AS (
        SELECT d.nid, d.nid AS origin, d.cid, d.w, 0 AS hops FROM direct d
      UNION ALL
        SELECT g.to_node_id, w.origin, w.cid, w.w, w.hops + 1
        FROM walk w JOIN _ge g ON g.from_node_id = w.nid
        WHERE w.hops < 50 AND NOT EXISTS (SELECT 1 FROM direct d WHERE d.nid = g.to_node_id)
    ),
    near AS (
        SELECT DISTINCT w.nid, w.origin, w.cid, w.w, w.hops,
               min(w.hops) OVER (PARTITION BY w.nid) AS min_hops
        FROM walk w WHERE w.hops > 0
    ),
    nearest AS (SELECT DISTINCT nid, origin, cid, w FROM near WHERE hops = min_hops),
    inh AS (
        SELECT n.nid, n.cid, sum(n.w) / k.n_origin AS w, k.n_cat > 1 AS amb
        FROM nearest n
        JOIN (SELECT nid, count(DISTINCT origin) AS n_origin, count(DISTINCT cid) AS n_cat
              FROM nearest GROUP BY nid) k ON k.nid = n.nid
        GROUP BY n.nid, n.cid, k.n_origin, k.n_cat
    ),
    assign AS (
        SELECT o.id, d.cid, d.w, d.how, FALSE AS amb FROM ownv o JOIN direct d ON d.nid = o.id
      UNION ALL
        SELECT o.id, k.cid, 1.0, 'CHILDREN', FALSE FROM ownv o JOIN kids k ON k.nid = o.id
        WHERE o.out_deg > 0 AND NOT EXISTS (SELECT 1 FROM direct d WHERE d.nid = o.id)
      UNION ALL
        SELECT o.id, i.cid, i.w, 'INHERITED', i.amb FROM ownv o JOIN inh i ON i.nid = o.id
        WHERE NOT EXISTS (SELECT 1 FROM direct d WHERE d.nid = o.id)
          AND NOT (o.out_deg > 0 AND EXISTS (SELECT 1 FROM kids k WHERE k.nid = o.id))
      UNION ALL
        SELECT o.id, NULL::bigint, 1.0, 'UNASSIGNED', FALSE FROM ownv o
        WHERE NOT EXISTS (SELECT 1 FROM direct d WHERE d.nid = o.id)
          AND NOT (o.out_deg > 0 AND EXISTS (SELECT 1 FROM kids k WHERE k.nid = o.id))
          AND NOT EXISTS (SELECT 1 FROM inh i WHERE i.nid = o.id)
    ),
    -- the node's own value is uncertain when an edge it is computed from is a guess
    flow_amb AS (
        SELECT o.id,
               EXISTS (SELECT 1 FROM _ge g WHERE g.from_node_id = o.id AND g.amb)
               OR (o.src IS DISTINCT FROM 'MEASURED'
                   AND EXISTS (SELECT 1 FROM _ge g WHERE g.to_node_id = o.id AND g.amb)) AS amb
        FROM ownv o
    )
    SELECT o.id, o.code, o.cls,
           CASE WHEN o.cls = 'SOURCE' THEN o.name || ' (unaccounted)'
                WHEN lower(o.name) = 'unassigned'
                  OR EXISTS (SELECT 1 FROM cat WHERE lower(cat.category_name) = lower(o.name))
                  OR EXISTS (SELECT 1 FROM ownv o2 WHERE o2.id <> o.id AND lower(o2.name) = lower(o.name))
                THEN o.name || ' (' || o.code || ')'
                ELSE o.name END,
           o.src, o.val, o.own_v,
           a.cid, a.how, a.w,
           a.amb, f.amb, o.hd
    FROM ownv o JOIN assign a ON a.id = o.id JOIN flow_amb f ON f.id = o.id
    ORDER BY o.code, a.cid;
END
$fn$;

COMMENT ON FUNCTION graph.sankey_nodes(integer, date, date, date, integer, boolean, varchar) IS
    'One row per (node, category) in effect on p_as_of (default p_end): the node''s own value '
    '(what it consumes net of what it passes on; for a source, what its meter reads beyond its '
    'feeds) and its category with how it was found (EXPLICIT, TYPE, CHILDREN, INHERITED, '
    'UNASSIGNED; category_id NULL when unassigned). own x weight sums to the supply. p_end is '
    'inclusive. design/graph-sankey.md §3-§4.';

-- ============================================================================
-- 2. graph.sankey
-- ============================================================================
CREATE FUNCTION graph.sankey(
    p_tenant_id   INTEGER,
    p_start       DATE,
    p_end         DATE,
    p_as_of       DATE    DEFAULT NULL,
    p_quantity_id INTEGER DEFAULT 124,
    p_is_cost     BOOLEAN DEFAULT FALSE,
    p_taxonomy    VARCHAR DEFAULT 'FUNCTIONAL',
    p_node_detail BOOLEAN DEFAULT TRUE)
RETURNS TABLE (source TEXT, target TEXT, value NUMERIC, color TEXT,
               link_kind TEXT, is_ambiguous BOOLEAN)
LANGUAGE plpgsql VOLATILE
AS $fn$
#variable_conflict use_column
DECLARE
    c_unassigned CONSTANT TEXT := 'Unassigned';
    c_grey       CONSTANT TEXT := '#9E9E9E';
    c_eps        CONSTANT NUMERIC := 0.0005;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS _sk_nodes (
        node_id BIGINT, node_code TEXT, node_class TEXT, label TEXT, val_src TEXT, value NUMERIC,
        own NUMERIC, category_id BIGINT, category_how TEXT, weight NUMERIC,
        category_ambiguous BOOLEAN, flow_ambiguous BOOLEAN, has_data BOOLEAN) ON COMMIT DROP;
    TRUNCATE _sk_nodes;
    INSERT INTO _sk_nodes
    SELECT * FROM graph.sankey_nodes(p_tenant_id, p_start, p_end, p_as_of, p_quantity_id,
                                     p_is_cost, p_taxonomy);

    RETURN QUERY
    WITH
    cat AS (
        SELECT t.id, t.category_name::text AS name, t.parent_id, t.path, t.sort_key,
               t.display_color::text AS color,
               EXISTS (SELECT 1 FROM graph.category k WHERE k.parent_id = t.id AND k.is_active) AS has_kids
        FROM graph.v_category_tree t
        WHERE t.tenant_id = p_tenant_id AND t.taxonomy_code = p_taxonomy AND t.is_active
    ),
    root AS (SELECT * FROM cat WHERE parent_id IS NULL),
    nv AS (
        SELECT s.*, s.own * s.weight AS v, s.category_ambiguous OR s.flow_ambiguous AS amb
        FROM _sk_nodes s WHERE s.own * s.weight > c_eps
    ),
    links AS (
        -- SUPPLY: each source's solved value into the root
        SELECT 1 AS ord, NULL::int[] AS sk, gn.node_name::text AS src, r.name AS tgt,
               gn.value AS val, r.color AS col, 'SUPPLY'::text AS kind,
               EXISTS (SELECT 1 FROM _ge g WHERE g.from_node_id = gn.id AND g.amb) AS amb
        FROM _gn gn CROSS JOIN root r
        WHERE gn.node_class = 'SOURCE' AND gn.value > c_eps
      UNION ALL
        -- CATEGORY: parent -> category, everything positive beneath it
        SELECT 2, c.sort_key, p.name, c.name, sum(nv.v), c.color, 'CATEGORY', bool_or(nv.amb)
        FROM cat c JOIN cat p ON p.id = c.parent_id
        JOIN cat d ON d.path = c.path OR d.path LIKE c.path || '/%'
        JOIN nv ON nv.category_id = d.id
        GROUP BY c.sort_key, p.name, c.name, c.color
      UNION ALL
        SELECT 2, ARRAY[2147483647], r.name, c_unassigned, sum(nv.v), c_grey, 'CATEGORY',
               bool_or(nv.amb)
        FROM nv CROSS JOIN root r WHERE nv.category_id IS NULL
        GROUP BY r.name
      UNION ALL
        -- NODE: category -> node
        SELECT 3, COALESCE(c.sort_key, ARRAY[2147483647]), COALESCE(c.name, c_unassigned), nv.label,
               nv.v, COALESCE(c.color, c_grey), 'NODE', nv.amb
        FROM nv LEFT JOIN cat c ON c.id = nv.category_id
        WHERE p_node_detail OR c.has_kids
    )
    SELECT l.src, l.tgt, l.val, l.col, l.kind, l.amb
    FROM links l
    ORDER BY l.ord, l.sk NULLS FIRST, l.val DESC, l.tgt;
END
$fn$;

COMMENT ON FUNCTION graph.sankey(integer, date, date, date, integer, boolean, varchar, boolean) IS
    'Sankey links for one window (p_end inclusive; p_as_of defaults to p_end): each SOURCE -> the '
    'taxonomy root (Supply), down the category tree, then to each node''s own value (NODE links; '
    'p_node_detail = false keeps only nodes on a category with child categories). Unassigned nodes '
    'go under the root as "Unassigned". Names no device and no node: a node inserted into the graph '
    'appears automatically. Negative own values are not drawn; see graph.sankey_diagnostics. '
    'design/graph-sankey.md.';

-- ============================================================================
-- 3. graph.sankey_diagnostics
-- ============================================================================
CREATE FUNCTION graph.sankey_diagnostics(
    p_tenant_id   INTEGER,
    p_start       DATE,
    p_end         DATE,
    p_as_of       DATE    DEFAULT NULL,
    p_quantity_id INTEGER DEFAULT 124,
    p_is_cost     BOOLEAN DEFAULT FALSE,
    p_taxonomy    VARCHAR DEFAULT 'FUNCTIONAL')
RETURNS TABLE (node_code TEXT, kind TEXT, value NUMERIC, detail TEXT)
LANGUAGE plpgsql VOLATILE
AS $fn$
#variable_conflict use_column
DECLARE
    c_eps     CONSTANT NUMERIC := 0.0005;
    v_as_of   DATE := COALESCE(p_as_of, p_end);
    v_utility VARCHAR;
    v_recv    INTEGER;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS _sk_diag (
        node_id BIGINT, node_code TEXT, node_class TEXT, label TEXT, val_src TEXT, value NUMERIC,
        own NUMERIC, category_id BIGINT, category_how TEXT, weight NUMERIC,
        category_ambiguous BOOLEAN, flow_ambiguous BOOLEAN, has_data BOOLEAN) ON COMMIT DROP;
    TRUNCATE _sk_diag;
    INSERT INTO _sk_diag
    SELECT * FROM graph.sankey_nodes(p_tenant_id, p_start, p_end, p_as_of, p_quantity_id,
                                     p_is_cost, p_taxonomy);

    SELECT qr.utility_code INTO v_utility FROM graph.quantity_rule qr WHERE qr.quantity_id = p_quantity_id;
    -- the received-energy counterpart of a *_DELIVERED quantity, by vocabulary code
    SELECT r.quantity_id INTO v_recv
    FROM graph.quantity_term d JOIN graph.quantity_term r
      ON r.code = regexp_replace(d.code, '_DELIVERED$', '_RECEIVED')
    WHERE d.quantity_id = p_quantity_id AND d.code LIKE '%\_DELIVERED' AND NOT p_is_cost
      AND EXISTS (SELECT 1 FROM graph.quantity_rule qr WHERE qr.quantity_id = r.quantity_id);

    RETURN QUERY
    WITH diag AS (
        SELECT s.node_code AS code, 'NEGATIVE_RESIDUAL'::text AS k, s.own AS val,
               CASE WHEN s.node_class = 'SOURCE'
                    THEN 'its feeds carry more than its meter reads; not drawn'
                    ELSE 'what it passes on exceeds its value (' || s.val_src || '); meter or topology question; not drawn'
               END AS det
        FROM (SELECT DISTINCT node_code, node_class, val_src, own FROM _sk_diag) s
        WHERE s.own < -c_eps
      UNION ALL
        SELECT f.node_code || ' -> ' || t.node_code, 'NEGATIVE_FLOW', g.value,
               'the solver returns reverse flow on this edge; not drawn (no Export link)'
        FROM _ge g JOIN _gn f ON f.id = g.from_node_id JOIN _gn t ON t.id = g.to_node_id
        WHERE g.value < -c_eps
      UNION ALL
        SELECT f.node_code || ' -> ' || t.node_code, 'AMBIGUOUS_FLOW', g.value,
               'split by rule, not measured'
        FROM _ge g JOIN _gn f ON f.id = g.from_node_id JOIN _gn t ON t.id = g.to_node_id
        WHERE g.amb
      UNION ALL
        SELECT s.node_code, 'AMBIGUOUS_CATEGORY', sum(s.own * s.weight),
               'inherits from several ancestors at the same distance: ' ||
               string_agg(c.category_code, ', ' ORDER BY c.category_code)
        FROM _sk_diag s JOIN graph.category c ON c.id = s.category_id
        WHERE s.category_ambiguous
        GROUP BY s.node_code
      UNION ALL
        SELECT s.node_code, 'UNASSIGNED', s.own,
               'no category row, type default or categorised ancestor'
        FROM _sk_diag s WHERE s.category_id IS NULL AND s.own > c_eps
      UNION ALL
        -- a meter in effect that returned nothing for the window
        SELECT gn.node_code, 'NO_DATA', NULL::numeric,
               'node meter: device ' || string_agg(DISTINCT m.device_id::text, ', ')
        FROM _gn gn JOIN graph.measurement m ON m.node_id = gn.id
        WHERE gn.measured IS NULL AND m.is_active AND m.role = 'TOTAL'
          AND m.quantity_id = p_quantity_id AND m.utility_code = v_utility
          AND m.effective_from <= v_as_of AND (m.effective_to IS NULL OR m.effective_to >= v_as_of)
        GROUP BY gn.node_code
      UNION ALL
        SELECT f.node_code || ' -> ' || t.node_code, 'NO_DATA', NULL,
               'feeder meter: device ' || string_agg(DISTINCT m.device_id::text, ', ')
        FROM _ge g JOIN _gn f ON f.id = g.from_node_id JOIN _gn t ON t.id = g.to_node_id
        JOIN graph.measurement m ON m.edge_id = g.id
        WHERE g.meas IS NULL AND m.is_active AND m.role = 'TOTAL'
          AND m.quantity_id = p_quantity_id AND m.utility_code = v_utility
          AND m.effective_from <= v_as_of AND (m.effective_to IS NULL OR m.effective_to >= v_as_of)
        GROUP BY f.node_code, t.node_code
      UNION ALL
        -- energy registered against the meter's direction (design §9.6), per device, when it is
        -- at least 0.1% of what the device delivered (PV inverters' night draw stays out)
        SELECT string_agg(DISTINCT COALESCE(n.node_code, f.node_code || ' -> ' || t.node_code), ', '),
               'REVERSE_ENERGY', r.total,
               'device ' || m.device_id || ' registered energy received; ' ||
               round(100 * r.total / NULLIF(dv.total, 0), 2) || '% of delivered'
        FROM graph.measurement m
        JOIN graph.device_totals(p_tenant_id, v_utility, p_start::timestamp, p_end::timestamp,
                                 v_recv, FALSE, ARRAY['SHIFT1','SHIFT2','SHIFT3']) r
          ON r.device_id = m.device_id
        LEFT JOIN graph.device_totals(p_tenant_id, v_utility, p_start::timestamp, p_end::timestamp,
                                      p_quantity_id, FALSE, ARRAY['SHIFT1','SHIFT2','SHIFT3']) dv
          ON dv.device_id = m.device_id
        LEFT JOIN _gn n ON n.id = m.node_id
        LEFT JOIN _ge g ON g.id = m.edge_id
        LEFT JOIN _gn f ON f.id = g.from_node_id
        LEFT JOIN _gn t ON t.id = g.to_node_id
        WHERE v_recv IS NOT NULL AND r.total > 0.001 * COALESCE(dv.total, 0) AND r.total > c_eps
          AND m.is_active AND m.role = 'TOTAL' AND m.quantity_id = p_quantity_id
          AND m.effective_from <= v_as_of AND (m.effective_to IS NULL OR m.effective_to >= v_as_of)
          AND (n.id IS NOT NULL OR g.id IS NOT NULL)
        GROUP BY m.device_id, r.total, dv.total
    )
    SELECT d.code, d.k, d.val, d.det FROM diag d
    ORDER BY array_position(ARRAY['NEGATIVE_RESIDUAL','NEGATIVE_FLOW','NO_DATA','REVERSE_ENERGY',
                                  'UNASSIGNED','AMBIGUOUS_CATEGORY','AMBIGUOUS_FLOW'], d.k),
             abs(d.val) DESC NULLS LAST, d.code;
END
$fn$;

COMMENT ON FUNCTION graph.sankey_diagnostics(integer, date, date, date, integer, boolean, varchar) IS
    'What graph.sankey cannot draw, for the same window: NEGATIVE_RESIDUAL (a node''s children or '
    'feeds read more than it), NEGATIVE_FLOW (reverse flow on an edge), NO_DATA (a meter in effect '
    'with no reading), REVERSE_ENERGY (received energy on a meter, for *_DELIVERED quantities), '
    'UNASSIGNED (own value with no category), AMBIGUOUS_CATEGORY, AMBIGUOUS_FLOW. '
    'design/graph-sankey.md §6.';

GRANT EXECUTE ON FUNCTION graph.sankey_nodes(integer, date, date, date, integer, boolean, varchar),
                          graph.sankey(integer, date, date, date, integer, boolean, varchar, boolean),
                          graph.sankey_diagnostics(integer, date, date, date, integer, boolean, varchar)
      TO "grafReader", prs_hermes_agent;


-- ============================================================================
-- 4. Self-test on September 2026 (tenant 3); aborts the migration if a balance fails
-- ============================================================================
CREATE TEMP TABLE _t_links ON COMMIT DROP AS
SELECT * FROM graph.sankey(3, '2026-09-01', '2026-09-30');
CREATE TEMP TABLE _t_nodes ON COMMIT DROP AS
SELECT * FROM graph.sankey_nodes(3, '2026-09-01', '2026-09-30');
CREATE TEMP TABLE _t_diag ON COMMIT DROP AS
SELECT * FROM graph.sankey_diagnostics(3, '2026-09-01', '2026-09-30');
CREATE TEMP TABLE _t_brief ON COMMIT DROP AS
SELECT * FROM graph.sankey(3, '2026-09-01', '2026-09-30', p_node_detail => FALSE);

DO $$
DECLARE
    v_supply NUMERIC := (SELECT sum(value) FROM _t_links WHERE link_kind = 'SUPPLY');
    v_root   TEXT    := (SELECT DISTINCT target FROM _t_links WHERE link_kind = 'SUPPLY');
    v_pos    NUMERIC := (SELECT sum(own * weight) FROM _t_nodes WHERE own * weight > 0.0005);
    v_all    NUMERIC := (SELECT sum(own * weight) FROM _t_nodes);
    v_neg    NUMERIC := (SELECT COALESCE(sum(value), 0) FROM _t_diag WHERE kind = 'NEGATIVE_RESIDUAL');
    n        INT;
BEGIN
    IF COALESCE(v_supply, 0) <= 0 THEN
        RAISE EXCEPTION '054 self-test: no supply in September 2026; is there telemetry?';
    END IF;
    -- 1. every node's weights sum to 1
    SELECT count(*) INTO n FROM (SELECT node_id FROM _t_nodes GROUP BY node_id
                                 HAVING abs(sum(weight) - 1) > 1e-9) x;
    IF n <> 0 THEN RAISE EXCEPTION '054 self-test: % nodes whose weights do not sum to 1', n; END IF;
    -- 2. what the sources supply = the sum of own values, negatives included
    IF abs(v_supply - v_all) > 0.001 * v_supply THEN
        RAISE EXCEPTION '054 self-test: supply % <> sum of own values %', v_supply, v_all;
    END IF;
    -- 3. the root hands down exactly the positive own values, and so do the NODE links
    IF abs((SELECT sum(value) FROM _t_links WHERE source = v_root AND link_kind = 'CATEGORY') +
           COALESCE((SELECT sum(value) FROM _t_links WHERE source = v_root AND link_kind = 'NODE'), 0)
           - v_pos) > 0.01 THEN
        RAISE EXCEPTION '054 self-test: the root''s out-links do not sum to the positive own values';
    END IF;
    IF abs((SELECT sum(value) FROM _t_links WHERE link_kind = 'NODE') - v_pos) > 0.01 THEN
        RAISE EXCEPTION '054 self-test: NODE links do not sum to the positive own values';
    END IF;
    -- 4. every category below the root passes on what it receives
    SELECT count(*) INTO n
    FROM (SELECT target, sum(value) AS v_in FROM _t_links WHERE link_kind = 'CATEGORY' GROUP BY target) i
    JOIN (SELECT source, sum(value) AS v_out FROM _t_links WHERE link_kind IN ('CATEGORY','NODE') GROUP BY source) o
      ON o.source = i.target
    WHERE abs(i.v_in - o.v_out) > 0.01;
    IF n <> 0 THEN RAISE EXCEPTION '054 self-test: % categories do not balance', n; END IF;
    -- the same holds without node detail, apart from the leaf categories
    SELECT count(*) INTO n
    FROM (SELECT target, sum(value) AS v_in FROM _t_brief WHERE link_kind = 'CATEGORY' GROUP BY target) i
    JOIN (SELECT source, sum(value) AS v_out FROM _t_brief WHERE link_kind IN ('CATEGORY','NODE') GROUP BY source) o
      ON o.source = i.target
    WHERE abs(i.v_in - o.v_out) > 0.01;
    IF n <> 0 THEN RAISE EXCEPTION '054 self-test: % categories do not balance without node detail', n; END IF;
    -- 5. the diagram minus the negative residuals is the supply
    IF abs(v_pos + v_neg - v_supply) > 0.001 * v_supply THEN
        RAISE EXCEPTION '054 self-test: positive % + negative % <> supply %', v_pos, v_neg, v_supply;
    END IF;
    -- 6. no self-link, no non-positive link, no label both a source and a node or category
    IF EXISTS (SELECT 1 FROM _t_links WHERE source = target OR value <= 0 OR color IS NULL) THEN
        RAISE EXCEPTION '054 self-test: a self-link, a non-positive link or a link with no colour';
    END IF;
    IF EXISTS (SELECT 1 FROM _t_links s JOIN _t_links t ON t.target = s.source
               WHERE s.link_kind = 'SUPPLY') THEN
        RAISE EXCEPTION '054 self-test: a source label is also a link target (a cycle)';
    END IF;
    SELECT count(*) INTO n FROM (SELECT target FROM _t_links WHERE link_kind = 'NODE'
                                 GROUP BY target HAVING count(DISTINCT source) <> count(*)) x;
    IF n <> 0 THEN RAISE EXCEPTION '054 self-test: % node labels repeated under one category', n; END IF;
END
$$;

COMMIT;


-- ============================================================================
-- 5. Results (read-only), September 2026
-- ============================================================================

\echo ''
\echo '=== 5.1 SUPPLY and CATEGORY links ==='
SELECT link_kind, source, target, round(value) AS value, color, is_ambiguous
FROM graph.sankey(3, '2026-09-01', '2026-09-30') WHERE link_kind <> 'NODE';

\echo ''
\echo '=== 5.2 How each node got its category ==='
SELECT category_how, count(DISTINCT node_id) AS nodes, round(sum(own * weight)) AS value
FROM graph.sankey_nodes(3, '2026-09-01', '2026-09-30') GROUP BY 1 ORDER BY 1;

\echo ''
\echo '=== 5.3 Diagnostics, by kind ==='
SELECT kind, count(*) AS rows, round(sum(value)) AS value
FROM graph.sankey_diagnostics(3, '2026-09-01', '2026-09-30') GROUP BY kind ORDER BY 1;

\echo ''
\echo '=== 5.4 Diagnostics other than AMBIGUOUS_FLOW ==='
SELECT node_code, kind, round(value) AS value, detail
FROM graph.sankey_diagnostics(3, '2026-09-01', '2026-09-30') WHERE kind <> 'AMBIGUOUS_FLOW';


-- ============================================================================
-- 6. Undo (commented)
-- ============================================================================
--
-- DROP FUNCTION graph.sankey_diagnostics(integer, date, date, date, integer, boolean, varchar);
-- DROP FUNCTION graph.sankey(integer, date, date, date, integer, boolean, varchar, boolean);
-- DROP FUNCTION graph.sankey_nodes(integer, date, date, date, integer, boolean, varchar);
