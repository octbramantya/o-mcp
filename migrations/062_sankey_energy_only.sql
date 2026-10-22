-- Migration: 062_sankey_energy_only.sql
-- Description: graph.sankey, graph.sankey_nodes and graph.sankey_diagnostics lose p_is_cost: the
--              sankey draws energy flow only.
-- Author: Claude
-- Date: 2026-10-22
-- Design: design/graph-sankey.md §6, §10 ("Cost mode doesn't balance")
-- Requires: 061_frontend_schema.sql
--
-- WHY
-- ---
-- With p_is_cost the functions solved total_cost through the graph as if it were energy. Each
-- meter's cost is its own kWh at its own tariff, so residuals carry tariff differences, and a
-- PV-fed meter is priced at the grid tariff while PV costs nothing at Supply. On 2026-10-20 to 21
-- (dev, production's summary) Supply came to 140 M IDR and the categories to 174.6 M IDR. A cost
-- flow needs an average price per kWh across grid, PV and gas engine first. Decided 2026-10-22:
-- the sankey is for energy flow only, cost is out of scope.
--
-- WHAT CHANGES
-- ------------
-- The parameter goes from all three signatures; sankey_nodes asks graph.solve_flow for energy
-- (p_is_cost => FALSE), and sankey_diagnostics no longer needs its NOT p_is_cost guard on
-- REVERSE_ENERGY. The bodies are otherwise those in effect before this migration (054, unchanged
-- since). graph.solve_flow and graph.device_totals keep p_is_cost: other callers read them.
--
-- A changed signature is a new function, so each is dropped and created. Their EXECUTE grants
-- (054: grafReader, prs_hermes_agent; 061: prs_frontend; PUBLIC by default) and comments are read
-- before the drop and put back as they were, whatever they are by then. Section 2 checks that the
-- energy output for 2026-10-20 to 21 is the same before and after, row for row.
--
-- Callers passing arguments by position keep working up to p_quantity_id; p_taxonomy moves from
-- the 7th to the 6th position and p_node_detail from the 8th to the 7th. The Grafana panel
-- (grafana/graph-sankey/) passes p_node_detail by name.

\set ON_ERROR_STOP on

BEGIN;

-- ============================================================================
-- 1. Capture: grants, comments, and the energy output before
-- ============================================================================

DO $$
BEGIN
    IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'graph' AND p.proname IN ('sankey', 'sankey_nodes', 'sankey_diagnostics')
          AND 'p_is_cost' = ANY (p.proargnames)) <> 3
       OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'graph' AND p.proname IN ('sankey', 'sankey_nodes', 'sankey_diagnostics')) <> 3 THEN
        RAISE EXCEPTION '062: expected exactly the three sankey functions of 054, each with p_is_cost';
    END IF;
END
$$;

CREATE TEMP TABLE _acl ON COMMIT DROP AS
SELECT p.proname::text AS fn, a.grantee, a.privilege_type
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace, aclexplode(p.proacl) a
WHERE n.nspname = 'graph' AND p.proname IN ('sankey', 'sankey_nodes', 'sankey_diagnostics')
  AND a.grantee <> p.proowner;

CREATE TEMP TABLE _cmt ON COMMIT DROP AS
SELECT p.proname::text AS fn, obj_description(p.oid, 'pg_proc') AS cmt
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'graph' AND p.proname IN ('sankey', 'sankey_nodes', 'sankey_diagnostics');

CREATE TEMP TABLE _out (ver text, what text, r text) ON COMMIT DROP;

CREATE FUNCTION pg_temp.capture(p_ver text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
    -- by name, so the same call reaches the old and the new signature
    INSERT INTO _out SELECT p_ver, 'sankey', concat_ws('|', s.source, s.target, round(s.value, 6), s.color, s.link_kind, s.is_ambiguous)
    FROM graph.sankey(p_tenant_id => 3, p_start => '2026-10-20', p_end => '2026-10-21') s;
    INSERT INTO _out SELECT p_ver, 'sankey_cat', concat_ws('|', s.source, s.target, round(s.value, 6), s.color, s.link_kind, s.is_ambiguous)
    FROM graph.sankey(p_tenant_id => 3, p_start => '2026-10-20', p_end => '2026-10-21', p_node_detail => FALSE) s;
    INSERT INTO _out SELECT p_ver, 'nodes', concat_ws('|', s.node_id, s.val_src, round(s.value, 6), round(s.own, 6), s.category_id, s.category_how, s.weight, s.category_ambiguous, s.flow_ambiguous, s.has_data)
    FROM graph.sankey_nodes(p_tenant_id => 3, p_start => '2026-10-20', p_end => '2026-10-21') s;
    INSERT INTO _out SELECT p_ver, 'diag', concat_ws('|', s.node_code, s.kind, round(s.value, 6), s.detail)
    FROM graph.sankey_diagnostics(p_tenant_id => 3, p_start => '2026-10-20', p_end => '2026-10-21') s;
END $f$;

SELECT pg_temp.capture('before');

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM _out WHERE ver = 'before' AND what = 'sankey') THEN
        RAISE EXCEPTION '062: graph.sankey returns nothing for 2026-10-20 to 21; the before/after check needs that telemetry';
    END IF;
END
$$;

-- ============================================================================
-- 2. Drop and create, without p_is_cost
-- ============================================================================

DROP FUNCTION graph.sankey(integer, date, date, date, integer, boolean, varchar, boolean);
DROP FUNCTION graph.sankey_diagnostics(integer, date, date, date, integer, boolean, varchar);
DROP FUNCTION graph.sankey_nodes(integer, date, date, date, integer, boolean, varchar);

CREATE FUNCTION graph.sankey_nodes(p_tenant_id integer, p_start date, p_end date, p_as_of date DEFAULT NULL::date, p_quantity_id integer DEFAULT 124, p_taxonomy character varying DEFAULT 'FUNCTIONAL'::character varying)
 RETURNS TABLE(node_id bigint, node_code text, node_class text, label text, val_src text, value numeric, own numeric, category_id bigint, category_how text, weight numeric, category_ambiguous boolean, flow_ambiguous boolean, has_data boolean)
 LANGUAGE plpgsql
AS $function$
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
                             p_quantity_id => p_quantity_id, p_is_cost => FALSE,
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
$function$;

CREATE FUNCTION graph.sankey(p_tenant_id integer, p_start date, p_end date, p_as_of date DEFAULT NULL::date, p_quantity_id integer DEFAULT 124, p_taxonomy character varying DEFAULT 'FUNCTIONAL'::character varying, p_node_detail boolean DEFAULT true)
 RETURNS TABLE(source text, target text, value numeric, color text, link_kind text, is_ambiguous boolean)
 LANGUAGE plpgsql
AS $function$
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
                                     p_taxonomy);

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
$function$;

CREATE FUNCTION graph.sankey_diagnostics(p_tenant_id integer, p_start date, p_end date, p_as_of date DEFAULT NULL::date, p_quantity_id integer DEFAULT 124, p_taxonomy character varying DEFAULT 'FUNCTIONAL'::character varying)
 RETURNS TABLE(node_code text, kind text, value numeric, detail text)
 LANGUAGE plpgsql
AS $function$
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
                                     p_taxonomy);

    SELECT qr.utility_code INTO v_utility FROM graph.quantity_rule qr WHERE qr.quantity_id = p_quantity_id;
    -- the received-energy counterpart of a *_DELIVERED quantity, by vocabulary code
    SELECT r.quantity_id INTO v_recv
    FROM graph.quantity_term d JOIN graph.quantity_term r
      ON r.code = regexp_replace(d.code, '_DELIVERED$', '_RECEIVED')
    WHERE d.quantity_id = p_quantity_id AND d.code LIKE '%\_DELIVERED'
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
$function$;

-- grants as they were: PUBLIC's default EXECUTE comes off first, then each captured grantee
DO $$
DECLARE
    f record;
    g record;
BEGIN
    FOR f IN SELECT p.oid::regprocedure AS sig, p.proname::text AS fn
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'graph' AND p.proname IN ('sankey', 'sankey_nodes', 'sankey_diagnostics') LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
        FOR g IN SELECT * FROM _acl WHERE fn = f.fn LOOP
            EXECUTE format('GRANT %s ON FUNCTION %s TO %s', g.privilege_type, f.sig,
                           CASE WHEN g.grantee = 0 THEN 'PUBLIC' ELSE g.grantee::regrole::text END);   -- regrole quotes
        END LOOP;
        EXECUTE format('COMMENT ON FUNCTION %s IS %L', f.sig,
                       (SELECT cmt FROM _cmt WHERE fn = f.fn) || ' Energy only: no cost mode (062).');
    END LOOP;
END
$$;

-- ============================================================================
-- 3. Post-conditions
-- ============================================================================

SELECT pg_temp.capture('after');

DO $$
DECLARE
    n INT;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = 'graph' AND p.proname IN ('sankey', 'sankey_nodes', 'sankey_diagnostics')
                 AND 'p_is_cost' = ANY (p.proargnames)) THEN
        RAISE EXCEPTION '062: a sankey function still takes p_is_cost';
    END IF;
    SELECT count(*) INTO n FROM (
        (SELECT what, r FROM _out WHERE ver = 'before' EXCEPT ALL SELECT what, r FROM _out WHERE ver = 'after')
        UNION ALL
        (SELECT what, r FROM _out WHERE ver = 'after' EXCEPT ALL SELECT what, r FROM _out WHERE ver = 'before')) x;
    IF n <> 0 THEN
        RAISE EXCEPTION '062: % rows of energy output differ before and after', n;
    END IF;
    SELECT count(*) INTO n FROM (
        (SELECT fn, grantee, privilege_type FROM _acl
         EXCEPT
         SELECT p.proname::text, a.grantee, a.privilege_type
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace, aclexplode(p.proacl) a
         WHERE n.nspname = 'graph' AND p.proname IN ('sankey', 'sankey_nodes', 'sankey_diagnostics')
           AND a.grantee <> p.proowner)
        UNION ALL
        (SELECT p.proname::text, a.grantee, a.privilege_type
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace, aclexplode(p.proacl) a
         WHERE n.nspname = 'graph' AND p.proname IN ('sankey', 'sankey_nodes', 'sankey_diagnostics')
           AND a.grantee <> p.proowner
         EXCEPT
         SELECT fn, grantee, privilege_type FROM _acl)) x;
    IF n <> 0 THEN
        RAISE EXCEPTION '062: % grants differ from before', n;
    END IF;
END
$$;

\echo ''
\echo '=== Rows compared (2026-10-20 to 21), and grants carried over ==='
SELECT what, count(*) FILTER (WHERE ver = 'before') AS before, count(*) FILTER (WHERE ver = 'after') AS after
FROM _out GROUP BY what ORDER BY what;
SELECT fn, string_agg(CASE WHEN grantee = 0 THEN 'PUBLIC' ELSE grantee::regrole::text END, ', ' ORDER BY 1) AS execute_granted_to
FROM _acl GROUP BY fn ORDER BY fn;

COMMIT;

-- Undo: replay 054's three CREATE FUNCTION statements (they take p_is_cost) after dropping these,
-- and its grants and comments; then 061's grants to prs_frontend.
