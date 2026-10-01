-- 028_pre_solver_bodies.sql
--
-- graph.solve_flow and graph.get_node_quantity EXACTLY as they stood on valkyrie
-- before 028, captured with pg_get_functiondef on 2026-09-28.
--
--     solve_flow        md5 2bb0f4e5bfa57108f9f72dac8c2c4f47
--     get_node_quantity md5 b99cb9998d09d0a0b5b45cb7705c4626
--
-- This file exists so section 4 of 028 is actually executable. Run it after the
-- rest of that undo block to put the solver back; the md5 above is the check
-- that it worked. Not part of the forward migration -- never run it on its own.
CREATE OR REPLACE FUNCTION graph.solve_flow(p_tenant_id integer, p_utility_code character varying, p_start timestamp without time zone, p_end timestamp without time zone, p_quantity_id integer, p_is_cost boolean DEFAULT false, p_shift_periods character varying[] DEFAULT ARRAY['SHIFT1'::text, 'SHIFT2'::text, 'SHIFT3'::text], p_as_of date DEFAULT CURRENT_DATE, p_max_iter integer DEFAULT 50)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_iter    INTEGER;
    v_changed INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM graph.quantity_rule qr
                    WHERE qr.quantity_id = p_quantity_id AND qr.conserved) THEN
        RAISE EXCEPTION
          'graph.solve_flow: quantity % is not declared conserved in graph.quantity_rule — flow balance does not apply (use graph.get_node_quantity)',
          p_quantity_id;
    END IF;

    DROP TABLE IF EXISTS _gn, _ge;

    CREATE TEMP TABLE _ge ON COMMIT DROP AS
    SELECT e.id, e.from_node_id, e.to_node_id,
           em.total AS meas, em.total AS value, FALSE AS amb
    FROM graph.edge e
    LEFT JOIN (
        SELECT ms.edge_id AS eid, SUM(dt.total * ms.multiplier) AS total
        FROM graph.measurement ms
        JOIN graph.device_totals(p_tenant_id, p_utility_code, p_start, p_end,
                                 p_quantity_id, p_is_cost, p_shift_periods) dt
          ON dt.device_id = ms.device_id AND dt.quantity_id = ms.quantity_id
        WHERE ms.edge_id IS NOT NULL AND ms.is_active AND ms.role = 'TOTAL'
          AND ms.utility_code = p_utility_code
          AND ms.effective_from <= p_as_of
          AND (ms.effective_to IS NULL OR ms.effective_to >= p_as_of)
        GROUP BY ms.edge_id
    ) em ON em.eid = e.id
    WHERE e.tenant_id = p_tenant_id AND e.is_active
      AND e.utility_code = p_utility_code
      AND e.edge_class <> 'COMPENSATION'   -- 024: see header
      AND e.effective_from <= p_as_of
      AND (e.effective_to IS NULL OR e.effective_to >= p_as_of);

    CREATE TEMP TABLE _gn ON COMMIT DROP AS
    SELECT n.id, n.node_code, n.node_name, n.node_class, n.is_passthrough,
           nm.total AS measured, nm.total AS value,
           (CASE WHEN nm.total IS NOT NULL THEN 'MEASURED' END)::VARCHAR(10) AS val_src,
           (SELECT COUNT(*) FROM _ge g WHERE g.to_node_id   = n.id) AS in_deg,
           (SELECT COUNT(*) FROM _ge g WHERE g.from_node_id = n.id) AS out_deg,
           TRUE AS has_data
    FROM graph.node n
    LEFT JOIN (
        SELECT ms.node_id AS nid, SUM(dt.total * ms.multiplier) AS total
        FROM graph.measurement ms
        JOIN graph.device_totals(p_tenant_id, p_utility_code, p_start, p_end,
                                 p_quantity_id, p_is_cost, p_shift_periods) dt
          ON dt.device_id = ms.device_id AND dt.quantity_id = ms.quantity_id
        WHERE ms.node_id IS NOT NULL AND ms.is_active AND ms.role = 'TOTAL'
          AND ms.utility_code = p_utility_code
          AND ms.effective_from <= p_as_of
          AND (ms.effective_to IS NULL OR ms.effective_to >= p_as_of)
        GROUP BY ms.node_id
    ) nm ON nm.nid = n.id
    WHERE n.tenant_id = p_tenant_id AND n.is_active
      AND n.effective_from <= p_as_of
      AND (n.effective_to IS NULL OR n.effective_to >= p_as_of)
      AND EXISTS (SELECT 1 FROM _ge g WHERE g.from_node_id = n.id OR g.to_node_id = n.id);

    FOR v_iter IN 1..p_max_iter LOOP
        v_changed := 0;

        -- (a) a node that cannot consume anything itself -- a graph head (in_deg = 0)
        --     or one declared is_passthrough -- with a single out-edge sends its whole
        --     value down that feeder. Skipped where rule (b) can resolve the target
        --     from the target's own meter, which would otherwise erase a real residual.
        WITH tgt AS (
            SELECT g.to_node_id AS nid,
                   COUNT(*) FILTER (WHERE g.value IS NULL) AS n_unknown
            FROM _ge g GROUP BY g.to_node_id
        ), upd AS (
            UPDATE _ge g SET value = n.value
            FROM _gn n, _gn c, tgt t
            WHERE g.from_node_id = n.id AND g.value IS NULL
              AND n.value IS NOT NULL AND n.out_deg = 1
              AND (n.in_deg = 0 OR n.is_passthrough)
              AND c.id = g.to_node_id AND t.nid = g.to_node_id
              AND (c.value IS NULL OR t.n_unknown > 1)
            RETURNING 1
        ) SELECT v_changed + COUNT(*) INTO v_changed FROM upd;

        -- (b) split a known node value across its still-unknown in-edges
        WITH t AS (
            SELECT g.to_node_id AS nid,
                   COALESCE(SUM(g.value), 0)               AS known_sum,
                   COUNT(*) FILTER (WHERE g.value IS NULL) AS n_unknown
            FROM _ge g GROUP BY g.to_node_id
        ), upd AS (
            UPDATE _ge g SET value = (n.value - t.known_sum) / t.n_unknown,
                             amb   = (t.n_unknown > 1)
            FROM t JOIN _gn n ON n.id = t.nid
            WHERE g.to_node_id = t.nid AND g.value IS NULL
              AND n.value IS NOT NULL AND t.n_unknown > 0
            RETURNING 1
        ) SELECT v_changed + COUNT(*) INTO v_changed FROM upd;

        -- (c) node value from fully-known in-edges, else fully-known out-edges.
        --     val_src records which, so §5.4 only claims a residual where the
        --     inflow was known independently of the out-edges.
        WITH ins AS (
            SELECT g.to_node_id AS nid, SUM(g.value) AS s,
                   COUNT(*) FILTER (WHERE g.value IS NULL) AS unk
            FROM _ge g GROUP BY g.to_node_id
        ), upd AS (
            UPDATE _gn n SET value = ins.s, val_src = 'IN_EDGES' FROM ins
            WHERE n.id = ins.nid AND n.value IS NULL AND ins.unk = 0
            RETURNING 1
        ) SELECT v_changed + COUNT(*) INTO v_changed FROM upd;

        WITH outs AS (
            SELECT g.from_node_id AS nid, SUM(g.value) AS s,
                   COUNT(*) FILTER (WHERE g.value IS NULL) AS unk
            FROM _ge g GROUP BY g.from_node_id
        ), upd AS (
            UPDATE _gn n SET value = outs.s, val_src = 'OUT_EDGES' FROM outs
            WHERE n.id = outs.nid AND n.value IS NULL AND outs.unk = 0
            RETURNING 1
        ) SELECT v_changed + COUNT(*) INTO v_changed FROM upd;

        IF v_changed = 0 THEN
            -- (d) last resort, only once a-c are exhausted
            WITH kids AS (
                SELECT g.from_node_id AS nid, SUM(c.value) AS s
                FROM _ge g JOIN _gn c ON c.id = g.to_node_id
                WHERE c.value IS NOT NULL GROUP BY g.from_node_id
            ), upd AS (
                UPDATE _gn n SET value = kids.s, val_src = 'CHILDREN' FROM kids
                WHERE n.id = kids.nid AND n.value IS NULL AND n.out_deg > 0
                RETURNING 1
            ) SELECT COUNT(*) INTO v_changed FROM upd;
            EXIT WHEN v_changed = 0;
        END IF;
    END LOOP;

    UPDATE _gn SET has_data = FALSE WHERE _gn.value IS NULL;
    UPDATE _gn SET value    = 0     WHERE _gn.value IS NULL;
    UPDATE _ge SET value    = 0     WHERE _ge.value IS NULL;
END;
$function$

;

CREATE OR REPLACE FUNCTION graph.get_node_quantity(p_tenant_id integer, p_utility_code character varying, p_quantity_id integer, p_start timestamp without time zone, p_end timestamp without time zone, p_as_of date DEFAULT CURRENT_DATE, p_shift_periods character varying[] DEFAULT ARRAY['SHIFT1'::text, 'SHIFT2'::text, 'SHIFT3'::text], p_max_iter integer DEFAULT 50)
 RETURNS TABLE(node_id bigint, node_code character varying, node_name character varying, val numeric, origin character varying)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_agg       VARCHAR;
    v_conserved BOOLEAN;
    v_iter      INTEGER;
    v_changed   INTEGER;
BEGIN
    SELECT qr.network_agg, qr.conserved INTO v_agg, v_conserved
    FROM graph.quantity_rule qr WHERE qr.quantity_id = p_quantity_id;

    IF v_agg IS NULL THEN
        RAISE EXCEPTION 'graph.get_node_quantity: quantity % has no row in graph.quantity_rule', p_quantity_id;
    END IF;

    IF v_conserved THEN     -- delegate: flow balance is strictly better than a rollup
        PERFORM graph.solve_flow(p_tenant_id, p_utility_code, p_start, p_end,
                                 p_quantity_id, FALSE, p_shift_periods, p_as_of);
        RETURN QUERY
        SELECT n.id, n.node_code, n.node_name, n.value,
               (CASE WHEN n.measured IS NOT NULL THEN 'MEASURED'
                     WHEN n.has_data              THEN 'ROLLUP'
                     ELSE 'NONE' END)::VARCHAR
        FROM _gn n;
        RETURN;
    END IF;

    DROP TABLE IF EXISTS _qe, _qn;

    CREATE TEMP TABLE _qe ON COMMIT DROP AS
    SELECT e.from_node_id, e.to_node_id FROM graph.edge e
    WHERE e.tenant_id = p_tenant_id AND e.is_active AND e.utility_code = p_utility_code
      AND e.edge_class <> 'COMPENSATION'   -- 024: see header
      AND e.effective_from <= p_as_of AND (e.effective_to IS NULL OR e.effective_to >= p_as_of);

    CREATE TEMP TABLE _qn ON COMMIT DROP AS
    SELECT n.id, n.node_code AS ncode, n.node_name AS nname,
           nm.total AS meas, nm.total AS val,
           (CASE WHEN nm.total IS NOT NULL THEN 'MEASURED' ELSE NULL END)::VARCHAR AS org
    FROM graph.node n
    LEFT JOIN (
        SELECT ms.node_id AS nid, AVG(dt.total * ms.multiplier) AS total
        FROM graph.measurement ms
        JOIN graph.device_totals(p_tenant_id, p_utility_code, p_start, p_end,
                                 p_quantity_id, FALSE, p_shift_periods) dt
          ON dt.device_id = ms.device_id AND dt.quantity_id = ms.quantity_id
        WHERE ms.node_id IS NOT NULL AND ms.is_active AND ms.role = 'TOTAL'
          AND ms.utility_code = p_utility_code
          AND ms.effective_from <= p_as_of
          AND (ms.effective_to IS NULL OR ms.effective_to >= p_as_of)
        GROUP BY ms.node_id
    ) nm ON nm.nid = n.id
    WHERE n.tenant_id = p_tenant_id AND n.is_active
      AND n.effective_from <= p_as_of AND (n.effective_to IS NULL OR n.effective_to >= p_as_of)
      AND EXISTS (SELECT 1 FROM _qe g WHERE g.from_node_id = n.id OR g.to_node_id = n.id);

    IF v_agg IN ('SUM','RSS') THEN
        FOR v_iter IN 1..p_max_iter LOOP
            WITH s AS (
                SELECT g.from_node_id AS nid,
                       SUM(c.val)                  AS sum_v,
                       sqrt(SUM(c.val * c.val))    AS rss_v,
                       COUNT(*) FILTER (WHERE c.val IS NULL) AS unk
                FROM _qe g JOIN _qn c ON c.id = g.to_node_id
                GROUP BY g.from_node_id
            ), upd AS (
                UPDATE _qn n
                   SET val = (CASE WHEN v_agg = 'RSS' THEN s.rss_v ELSE s.sum_v END),
                       org = 'ROLLUP'
                FROM s WHERE n.id = s.nid AND n.val IS NULL AND s.unk = 0
                RETURNING 1
            ) SELECT COUNT(*) INTO v_changed FROM upd;
            EXIT WHEN v_changed = 0;
        END LOOP;

    ELSIF v_agg = 'INHERIT' THEN
        FOR v_iter IN 1..p_max_iter LOOP
            -- strict: every feeder resolved
            WITH s AS (
                SELECT g.to_node_id AS nid, MAX(p.val) AS mx,
                       COUNT(*) FILTER (WHERE p.val IS NULL) AS unk
                FROM _qe g JOIN _qn p ON p.id = g.from_node_id
                GROUP BY g.to_node_id
            ), upd AS (
                UPDATE _qn n SET val = s.mx, org = 'INHERITED'
                FROM s WHERE n.id = s.nid AND n.val IS NULL AND s.unk = 0 AND s.mx IS NOT NULL
                RETURNING 1
            ) SELECT COUNT(*) INTO v_changed FROM upd;

            IF v_changed = 0 THEN
                -- relaxed: accept the worst known feeder
                WITH s AS (
                    SELECT g.to_node_id AS nid, MAX(p.val) AS mx
                    FROM _qe g JOIN _qn p ON p.id = g.from_node_id
                    GROUP BY g.to_node_id
                ), upd AS (
                    UPDATE _qn n SET val = s.mx, org = 'INHERITED'
                    FROM s WHERE n.id = s.nid AND n.val IS NULL AND s.mx IS NOT NULL
                    RETURNING 1
                ) SELECT COUNT(*) INTO v_changed FROM upd;
                EXIT WHEN v_changed = 0;
            END IF;
        END LOOP;
    END IF;   -- 'NONE': measured only, no propagation

    RETURN QUERY
    SELECT q.id, q.ncode, q.nname, q.val, COALESCE(q.org, 'NONE')::VARCHAR FROM _qn q;
END;
$function$

;
