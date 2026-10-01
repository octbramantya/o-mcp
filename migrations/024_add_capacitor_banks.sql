-- Migration: 024_add_capacitor_banks.sql
-- Description: Tenant 3's eleven capacitor banks as STORAGE leaves on the
--              electricity graph, on a new COMPENSATION edge class that the
--              flow solver and the quantity rollup skip
-- Author: Claude
-- Date: 2026-09-21
--
-- Why: the banks are 4,360 kVAr of installed compensation and nothing in the
-- graph knew they existed. pf_report.py already reads a negative bus residual
-- (bus kVArh < sum of its children) as "a capacitor bank on the bus", but could
-- not say which bank, how big, or whether the site believes it is running.
-- Source: design/capbank_tenant_3.csv, as confirmed by the site
-- team on 2026-09-21 (all banks APFC; CB_MDP3 inactive; CB_A4/CB_A5 150 kVAr;
-- no bank on LVMDB_TEXTURE_2).
--
-- Modelling: design doc §4.2 (graph-network-design.md:131) already places a
-- capacitor bank in STORAGE. One node per bank, fed by the bus it hangs on.
-- attrs carries the nameplate and the site's reported status:
--   rated_kvar, rated_v, steps, step_kvar[], control, target_pf,
--   site_status ('normal' | 'inactive'), site_status_as_of, detuned_pct
-- detuned_pct is NULL: the site has not answered that question yet.
-- effective_from is '-infinity' because no install dates were supplied; the
-- banks predate every telemetry window we hold, so that loses nothing today.
--
-- Why a new edge class, and why the solver has to skip it.
-- A bank is unmetered by construction and carries no active energy, and the
-- solver has no rule that assigns a parent's residual down to an unmetered
-- child. So as a plain FEEDER a bank resolves to nothing and still changes
-- what is around it. Measured on a snapshot of the live graph, 2026-08-18..
-- 2026-09-21, with the banks loaded as FEEDER and the functions untouched:
--   * LVMDB_A3 has no child edges today. Given one, its whole consumption
--     became unaccounted: get_sankey_flow gained LVMDB_A3 -> LVMDB_A3__
--     UNACCOUNTED at 104,833 kWh, and get_node_values reported 104,833 kWh /
--     49,608 kVArh unaccounted on a board that was fully explained before.
--   * get_node_values and get_node_quantity each gained 11 rows per quantity:
--     banks at value 0 / has_data FALSE, and banks "inheriting" their bus's
--     1119 reading.
--   * Latent, not visible in this window: a bank is an out-edge that never
--     resolves. Rule (c) OUT_EDGES and get_node_quantity's SUM/RSS rollup both
--     need every out-edge known, so an unmetered board would lose both the day
--     its other children are all metered. LVSDP_SP2_1, LVSDP_SP2_2 and
--     LVMDB_TEXTURE already fall to rule (d) CHILDREN today for other reasons.
-- Excluding COMPENSATION edges from _ge (solve_flow) and _qe
-- (get_node_quantity) leaves every flow and rollup exactly as before (proven
-- row-for-row, section 3), while the banks stay in graph.node / graph.edge for
-- everything that reads topology: descendants(), v_coverage, wages_sync
-- export, and pf_report.py, which assesses each bank against its bus meter.
-- The reactive balance does not lose anything real by this: a bank's output
-- was already visible, and still is, as the negative residual of its bus.
--
-- Function bodies: solve_flow and get_node_quantity below are the 009 text,
-- confirmed identical to the live definitions (pg_get_functiondef, 2026-09-21),
-- with one predicate added to each, marked "-- 024". Nothing else changes.
--
-- Also needed, outside SQL: ../prs_diags/scripts/wages_sync.py EDGE_CLASSES gains
-- COMPENSATION (otherwise export -> sync of these rows is refused), and
-- pf_report.py filters COMPENSATION out of EDGES_SQL/NODES_SQL and reads the
-- banks separately. Both ship with this migration.
--
-- Not included, pending the site: the ~48 kVAr always-on capacitor measured
-- on MC302_1_8 (under LVMDB_TF630). It is not on the site's list.
--
-- Run as the graph owner. Re-running is a no-op.
-- Status: APPLIED to valkyrie on 2026-09-21. Tested first on a local PostgreSQL 16 restore of the live
-- graph schema, 2026-09-21 (section 3 results in the comments there).
-- Undo: section 4.

-- ============================================================================
-- 1. Evidence -- read-only.
--    Expect: 11 buses found, all BUS, none passthrough; 0 existing CB_ nodes.
-- ============================================================================

SELECT 'Target buses' AS check_name;
SELECT n.node_code, n.node_class, n.is_passthrough,
       (SELECT count(*) FROM graph.edge e
         WHERE e.from_node_id = n.id AND e.is_active AND e.utility_code = 'ELECTRICITY') AS out_deg,
       EXISTS (SELECT 1 FROM graph.measurement m
                WHERE m.node_id = n.id AND m.is_active AND m.role = 'TOTAL') AS metered
FROM graph.node n
WHERE n.tenant_id = 3
  AND n.node_code IN ('LVMDP_SPINNING_1','LVSDP_SP2_1','LVSDP_SP2_2','LVMDP_SPINNING_3',
                      'LVMDB_TEXTURE','LVMDB_A1','LVMDB_A2','LVMDB_A3','LVMDB_A4',
                      'LVMDB_A5','LVMDB_B2')
ORDER BY 1;

SELECT 'Existing CB_ nodes (expect 0)' AS check_name;
SELECT count(*) FROM graph.node WHERE tenant_id = 3 AND node_code LIKE 'CB\_%';

-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- 2a. The edge class.
ALTER TABLE graph.edge DROP CONSTRAINT IF EXISTS ck_edge_class;
ALTER TABLE graph.edge ADD CONSTRAINT ck_edge_class CHECK (edge_class IN
    ('FEEDER','CABLE','BUSTIE','PIPE','HEADER_BRANCH','DUCT','CONVERSION','COMPENSATION'));

COMMENT ON CONSTRAINT ck_edge_class ON graph.edge IS
  'COMPENSATION (024): bus -> capacitor bank. Topology only: graph.solve_flow and '
  'graph.get_node_quantity skip it, since the bank is unmetered and carries no kWh.';

-- 2b. The solver and the rollup skip it.
CREATE OR REPLACE FUNCTION graph.solve_flow(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_quantity_id   INTEGER,
    p_is_cost       BOOLEAN   DEFAULT FALSE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3'],
    p_as_of         DATE      DEFAULT CURRENT_DATE,
    p_max_iter      INTEGER   DEFAULT 50
) RETURNS VOID
LANGUAGE plpgsql VOLATILE AS $$
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
$$;

CREATE OR REPLACE FUNCTION graph.get_node_quantity(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_quantity_id   INTEGER,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_as_of         DATE      DEFAULT CURRENT_DATE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3'],
    p_max_iter      INTEGER   DEFAULT 50
) RETURNS TABLE (
    node_id BIGINT, node_code VARCHAR, node_name VARCHAR,
    val NUMERIC, origin VARCHAR)
LANGUAGE plpgsql VOLATILE AS $$
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
$$;

-- 2c. The banks. step_kvar sums to rated_kvar on every row (checked in section 3).
INSERT INTO graph.node (tenant_id, node_code, node_name, node_class, attrs)
SELECT 3, b.code, b.name, 'STORAGE',
       jsonb_build_object(
           'rated_kvar',        b.rated_kvar,
           'rated_v',           400,
           'steps',             jsonb_array_length(b.step_kvar),
           'step_kvar',         b.step_kvar,
           'control',           'APFC',
           'target_pf',         0.98,
           'site_status',       b.status,
           'site_status_as_of', '2026-09-21',
           'detuned_pct',       NULL)
FROM (VALUES
    ('CB_MDP3',         'Capacitor Bank MDP3',         700, 'inactive', '[50,50,50,50,50,50,50,50,50,50,50,50,50,50]'::jsonb),
    ('CB_MDP1',         'Capacitor Bank MDP1',         640, 'normal',   '[40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40]'::jsonb),
    ('CB_MDP2',         'Capacitor Bank MDP2',         640, 'normal',   '[40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40]'::jsonb),
    ('CB_SPINNING_3',   'Capacitor Bank Spinning 3',   480, 'normal',   '[40,40,40,40,40,40,40,40,40,40,40,40]'::jsonb),
    ('CB_TEXTURE_1600', 'Capacitor Bank Texture 1600', 400, 'normal',   '[50,50,50,50,50,50,50,50]'::jsonb),
    ('CB_A1',           'Capacitor Bank A1',           300, 'normal',   '[50,50,50,50,50,50]'::jsonb),
    ('CB_A2',           'Capacitor Bank A2',           300, 'normal',   '[50,50,50,50,50,50]'::jsonb),
    ('CB_A3',           'Capacitor Bank A3',           300, 'normal',   '[50,50,50,50,50,50]'::jsonb),
    ('CB_A4',           'Capacitor Bank A4',           150, 'normal',   '[25,25,50,50]'::jsonb),
    ('CB_A5',           'Capacitor Bank A5',           150, 'normal',   '[25,25,50,50]'::jsonb),
    ('CB_B2',           'Capacitor Bank B2',           300, 'normal',   '[50,50,50,50,50,50]'::jsonb)
) AS b (code, name, rated_kvar, status, step_kvar)
ON CONFLICT (tenant_id, node_code) DO NOTHING;

-- 2d. Bus -> bank, one COMPENSATION edge each.
INSERT INTO graph.edge (tenant_id, from_node_id, to_node_id, utility_code, edge_class)
SELECT 3, bus.id, cb.id, 'ELECTRICITY', 'COMPENSATION'
FROM (VALUES
    ('LVMDP_SPINNING_1', 'CB_MDP3'),
    ('LVSDP_SP2_1',      'CB_MDP1'),
    ('LVSDP_SP2_2',      'CB_MDP2'),
    ('LVMDP_SPINNING_3', 'CB_SPINNING_3'),
    ('LVMDB_TEXTURE',    'CB_TEXTURE_1600'),
    ('LVMDB_A1',         'CB_A1'),
    ('LVMDB_A2',         'CB_A2'),
    ('LVMDB_A3',         'CB_A3'),
    ('LVMDB_A4',         'CB_A4'),
    ('LVMDB_A5',         'CB_A5'),
    ('LVMDB_B2',         'CB_B2')
) AS m (bus_code, cb_code)
JOIN graph.node bus ON bus.tenant_id = 3 AND bus.node_code = m.bus_code
JOIN graph.node cb  ON cb.tenant_id  = 3 AND cb.node_code  = m.cb_code
ON CONFLICT ON CONSTRAINT uq_edge DO NOTHING;

-- A bus code that failed to match would silently drop its edge above. (Cycles
-- are already refused per row by the graph.assert_acyclic trigger.)
DO $$
BEGIN
    IF (SELECT count(*) FROM graph.edge WHERE tenant_id = 3 AND edge_class = 'COMPENSATION') <> 11 THEN
        RAISE EXCEPTION '024: expected 11 COMPENSATION edges for tenant 3';
    END IF;
END $$;

COMMIT;

-- ============================================================================
-- 3. Verification
--
-- Local test, 2026-09-21: live graph schema restored into PostgreSQL 16,
-- graph.device_totals replaced by a snapshot of the live totals for
-- 2026-08-18..2026-09-21, outputs captured before and after this file:
--   get_node_values 124 and 89    284 rows before, 284 after, 0 differ
--   get_sankey_flow 124           159 links before, 159 after, 0 differ
--   get_node_quantity 2097, 1119  284 rows before, 284 after, 0 differ
-- Run twice: the second run changes nothing. The control -- same banks as
-- FEEDER, functions untouched -- differed on 47 rows (header).
-- ============================================================================

SELECT 'Banks on the graph (expect 11 rows, kvar_ok everywhere)' AS check_name;
SELECT bus.node_code AS bus, cb.node_code AS bank, e.edge_class,
       (cb.attrs ->> 'rated_kvar')::int AS rated_kvar,
       cb.attrs ->> 'site_status' AS site_status,
       (SELECT sum(s::int) FROM jsonb_array_elements_text(cb.attrs -> 'step_kvar') s)
           = (cb.attrs ->> 'rated_kvar')::int AS kvar_ok
FROM graph.edge e
JOIN graph.node bus ON bus.id = e.from_node_id
JOIN graph.node cb  ON cb.id  = e.to_node_id
WHERE e.tenant_id = 3 AND e.edge_class = 'COMPENSATION'
ORDER BY 1;

SELECT 'Banks the solver sees (expect 0)' AS check_name;
BEGIN;
SELECT count(*) FROM graph.get_node_values(3, 'ELECTRICITY',
    (CURRENT_DATE - 7)::timestamp, CURRENT_DATE::timestamp, 124)
WHERE node_code LIKE 'CB\_%';
COMMIT;

-- ============================================================================
-- 4. Undo (tested locally). After the COMMIT below, restore the two function
--    bodies by running ONLY the CREATE OR REPLACE statements for
--    graph.solve_flow and graph.get_node_quantity from 009. Do not re-run all
--    of 009: it also defines graph.device_totals, which 017 superseded.
-- ============================================================================

-- BEGIN;
-- DELETE FROM graph.edge WHERE tenant_id = 3 AND edge_class = 'COMPENSATION';
-- DELETE FROM graph.node WHERE tenant_id = 3 AND node_code IN
--     ('CB_MDP3','CB_MDP1','CB_MDP2','CB_SPINNING_3','CB_TEXTURE_1600',
--      'CB_A1','CB_A2','CB_A3','CB_A4','CB_A5','CB_B2');
-- ALTER TABLE graph.edge DROP CONSTRAINT ck_edge_class;
-- ALTER TABLE graph.edge ADD CONSTRAINT ck_edge_class CHECK (edge_class IN
--     ('FEEDER','CABLE','BUSTIE','PIPE','HEADER_BRANCH','DUCT','CONVERSION'));
-- COMMIT;
