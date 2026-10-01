-- Migration: 028_create_edge_type.sql
-- Description: Type the edges. Adds graph.edge_type (the relation vocabulary),
--              graph.edge_type_endpoint (which node kinds a relation may connect),
--              graph.edge.edge_type, the view graph.v_edge_gaps, and moves the
--              solver's hardcoded COMPENSATION test into data.
-- Author: Claude
-- Date: 2026-09-28
-- Design: design/edge-type.md
-- Requires: 027_fix_pv_injection.sql
--
-- WHAT THIS IS
-- ------------
-- Step 1 (026) typed the nodes. The edges still use three labels between them --
-- FEEDER 168, PIPE 39, COMPENSATION 11 -- because edge_class names the CONVEYANCE
-- (a feeder, a pipe), not the RELATION. So a 20 kV -> 400 V transformer and a
-- cable between two boards carry the same label.
--
-- edge_class stays as it is. edge_type is added beside it, exactly as node_type
-- was added beside node_class, with a composite FK so the two cannot disagree.
--
-- THE SOLVER CHANGE
-- -----------------
-- graph.solve_flow and graph.get_node_quantity each contain the literal
--
--     AND e.edge_class <> 'COMPENSATION'   -- 024: see header
--
-- and 024 repeats the same test twice more. A capacitor bank is not a flow path,
-- and that fact is currently expressed by pasting a string comparison into every
-- query that walks the graph. Section 2.6 replaces it with a lookup of
-- edge_type.carries_flow. Behaviour must be IDENTICAL today: section 3.3 proves
-- it by diffing all five solver entry points before and after, inside the
-- transaction.
--
-- NO EDGE PROPERTIES
-- ------------------
-- 026 already put the transformer nameplate on the board node -- all 12 boards
-- carry rated_kva and tx_primary_v, and tx_impedance_pct is an allowed key there.
-- Repeating them on the edge would recreate the "one fact spelled three ways"
-- problem step 1 removed. No edge carries attrs today and no edge-scoped fact is
-- waiting, so there is no edge_type_property table and no edge attrs trigger.
-- Section 2.5 adds the one transformer fact recorded nowhere -- the equipment's
-- own name -- as a NODE property, beside the others.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 What the edges look like today ==='
SELECT utility_code, edge_class, count(*) AS n,
       count(*) FILTER (WHERE attrs <> '{}'::jsonb) AS with_attrs
FROM graph.edge WHERE tenant_id = 3 AND is_active
GROUP BY 1, 2 ORDER BY 1, 2;

\echo ''
\echo '=== 1.2 How they will classify ==='
SELECT
       CASE
               WHEN e.edge_class = 'COMPENSATION' THEN 'PF_COMPENSATION'
               WHEN e.utility_code = 'WATER' THEN CASE
                   WHEN f.node_type = 'WATER_TANK' AND t.node_type = 'WATER_TANK'
                        THEN 'WATER_TRANSFER'
                   WHEN t.node_type = 'WATER_TANK'
                        AND (f.node_class = 'LOAD' OR f.node_type = 'REACTION_TANK')
                        THEN 'WATER_RETURN'
                   WHEN f.node_type IN ('WATER_INTAKE','CLARIFIER','SOFTENER','RO_UNIT','REACTION_TANK')
                     OR t.node_type IN ('CLARIFIER','SOFTENER','RO_UNIT','REACTION_TANK')
                        THEN 'WATER_TREATMENT'
                   ELSE 'WATER_SUPPLY' END
               -- PV first: a PV_PLANT -> MAIN_LV_BOARD edge would otherwise match TRANSFORMER
               WHEN f.node_type = 'PV_PLANT'   THEN 'PV_INJECTION'
               WHEN f.node_type = 'GAS_ENGINE' THEN 'GENERATOR_INFEED'
               WHEN f.node_type = 'GRID_INCOMER' AND t.node_type = 'MV_BUS' THEN 'GRID_INFEED'
               -- INCOMING_PLN feeds 6 transformers directly, FACTORY_AB is an MV_BUS feeding 6
               WHEN f.node_type IN ('MV_BUS','GRID_INCOMER') AND t.node_type = 'MAIN_LV_BOARD'
                    THEN 'TRANSFORMER'
               ELSE 'SUPPLY_LV' END AS edge_type,
       e.edge_class, count(*) AS n
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active
GROUP BY 1, 2 ORDER BY 1;

\echo ''
\echo '=== 1.3 The two solver functions carry the predicate being replaced ==='
SELECT p.proname, md5(pg_get_functiondef(p.oid)) AS md5_now
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'graph' AND p.proname IN ('solve_flow','get_node_quantity')
ORDER BY 1;
-- must match the md5 asserted in 2.0, or this migration was written against a
-- different version of the solver and must not run.


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 2.0 Guard, and capture the solver output for the equivalence proof in 3.3
-- ---------------------------------------------------------------------------
DO $guard$
DECLARE
    m TEXT;
BEGIN
    SELECT md5(pg_get_functiondef(p.oid)) INTO m
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'graph' AND p.proname = 'get_node_quantity';
    IF m IS DISTINCT FROM 'b99cb9998d09d0a0b5b45cb7705c4626' THEN
        RAISE EXCEPTION 'ABORT: graph.get_node_quantity is not the version this migration '
                        'was written against (md5 %, expected b99cb9998d09d0a0b5b45cb7705c4626). Re-derive '
                        'the replacement body before running.', m;
    END IF;

    SELECT md5(pg_get_functiondef(p.oid)) INTO m
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'graph' AND p.proname = 'solve_flow';
    IF m IS DISTINCT FROM '2bb0f4e5bfa57108f9f72dac8c2c4f47' THEN
        RAISE EXCEPTION 'ABORT: graph.solve_flow is not the version this migration '
                        'was written against (md5 %, expected 2bb0f4e5bfa57108f9f72dac8c2c4f47). Re-derive '
                        'the replacement body before running.', m;
    END IF;

    IF (SELECT count(*) FROM graph.edge WHERE tenant_id = 3 AND is_active) <> 218 THEN
        RAISE EXCEPTION 'ABORT: expected 218 active edges (027 applied), found %',
            (SELECT count(*) FROM graph.edge WHERE tenant_id = 3 AND is_active);
    END IF;
END $guard$;

CREATE TEMP TABLE _before_nv_e ON COMMIT DROP AS SELECT * FROM graph.get_node_values(3,'ELECTRICITY','2026-09-07 00:00','2026-09-14 00:00',124);
CREATE TEMP TABLE _before_sk_e ON COMMIT DROP AS SELECT * FROM graph.get_sankey_flow(3,'ELECTRICITY','2026-09-07 00:00','2026-09-14 00:00',124);
CREATE TEMP TABLE _before_nq_e ON COMMIT DROP AS SELECT * FROM graph.get_node_quantity(3,'ELECTRICITY',124,'2026-09-07 00:00','2026-09-14 00:00');
CREATE TEMP TABLE _before_nv_w ON COMMIT DROP AS SELECT * FROM graph.get_node_values(3,'WATER','2026-09-07 00:00','2026-09-14 00:00',5696);
CREATE TEMP TABLE _before_sk_w ON COMMIT DROP AS SELECT * FROM graph.get_sankey_flow(3,'WATER','2026-09-07 00:00','2026-09-14 00:00',5696);

-- ---------------------------------------------------------------------------
-- 2.1 The relation vocabulary
-- ---------------------------------------------------------------------------
CREATE TABLE graph.edge_type (
    code         VARCHAR(40)  PRIMARY KEY,
    edge_class   VARCHAR(20)  NOT NULL,
    utility_code VARCHAR(20)  REFERENCES graph.utility (code),  -- NULL = any utility
    carries_flow BOOLEAN      NOT NULL,
    is_transform BOOLEAN      NOT NULL DEFAULT FALSE,
    description  TEXT         NOT NULL,

    CONSTRAINT ck_edge_type_code  CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    CONSTRAINT ck_edge_type_class CHECK (edge_class IN
        ('FEEDER','CABLE','BUSTIE','PIPE','HEADER_BRANCH','DUCT','CONVERSION','COMPENSATION')),
    -- target of the composite FK from graph.edge
    CONSTRAINT uq_edge_type_code_class UNIQUE (code, edge_class)
);

COMMENT ON TABLE graph.edge_type IS
  'What a relation MEANS. edge_class is the conveyance (feeder, pipe); edge_type is '
  'the relation (transformer, PF compensation, water return).';
COMMENT ON COLUMN graph.edge_type.carries_flow IS
  'FALSE if the commodity does not travel along this edge. The solver skips these; '
  'before 028 the same rule was the literal edge_class <> ''COMPENSATION''.';
COMMENT ON COLUMN graph.edge_type.is_transform IS
  'TRUE if the endpoints may legitimately differ in nominal_v or utility_code.';

-- which (from, to) node kinds a relation may connect. from_kind / to_kind hold a
-- node_type code, or a node_class for the coarse rules that must keep working
-- while 98 loads are untyped.
CREATE TABLE graph.edge_type_endpoint (
    edge_type VARCHAR(40) NOT NULL REFERENCES graph.edge_type (code) ON DELETE CASCADE,
    from_kind VARCHAR(40) NOT NULL,
    to_kind   VARCHAR(40) NOT NULL,
    PRIMARY KEY (edge_type, from_kind, to_kind)
);

ALTER TABLE graph.edge ADD COLUMN edge_type VARCHAR(40);
COMMENT ON COLUMN graph.edge.edge_type IS
  'The relation this edge expresses. NULL means not yet typed; v_edge_gaps lists those.';

-- ---------------------------------------------------------------------------
-- 2.2 Seed the relations
-- ---------------------------------------------------------------------------
INSERT INTO graph.edge_type (code, edge_class, utility_code, carries_flow,
                             is_transform, description) VALUES
  ('GRID_INFEED', 'FEEDER', 'ELECTRICITY', TRUE, FALSE,
   'Utility supply entering the site at medium voltage.'),
  ('TRANSFORMER', 'FEEDER', 'ELECTRICITY', TRUE, TRUE,
   'A step-down transformer. The endpoints differ in nominal_v; the transformer''s own nameplate (rated_kva, tx_primary_v, tx_impedance_pct) lives on the LV board node, where 026 put it.'),
  ('SUPPLY_LV', 'FEEDER', 'ELECTRICITY', TRUE, FALSE,
   'Ordinary low-voltage supply from a board to a downstream board or load, at the same voltage.'),
  ('PV_INJECTION', 'FEEDER', 'ELECTRICITY', TRUE, FALSE,
   'A PV array injecting into a board. The board meter is tapped after the PV tapping point and so already includes this energy; see migration 027. A PV plant must never be wired directly to a load.'),
  ('GENERATOR_INFEED', 'FEEDER', 'ELECTRICITY', TRUE, FALSE,
   'On-site generation (gas engine) feeding a board.'),
  ('PF_COMPENSATION', 'COMPENSATION', 'ELECTRICITY', FALSE, FALSE,
   'A capacitor bank on a board. It supplies reactive power in place, and is not a path the commodity flows along: carries_flow is FALSE, which is what the solver''s old edge_class <> ''COMPENSATION'' test meant.'),
  ('WATER_SUPPLY', 'PIPE', 'WATER', TRUE, FALSE,
   'Water delivered from a tank or header to the point that uses it.'),
  ('WATER_TREATMENT', 'PIPE', 'WATER', TRUE, FALSE,
   'A process step in the treatment train -- intake, clarifier, softener, RO, reaction tank. Volume in does not equal volume out.'),
  ('WATER_RETURN', 'PIPE', 'WATER', TRUE, FALSE,
   'A return or recovery leg back to a tank. Counting one of these as supply inflates measured intake.'),
  ('WATER_TRANSFER', 'PIPE', 'WATER', TRUE, FALSE,
   'Movement between two storage tanks; neither end consumes.');

-- ---------------------------------------------------------------------------
-- 2.3 Which node kinds each relation may connect
-- ---------------------------------------------------------------------------
INSERT INTO graph.edge_type_endpoint (edge_type, from_kind, to_kind) VALUES
  ('GRID_INFEED', 'GRID_INCOMER', 'MV_BUS'),
  ('TRANSFORMER', 'MV_BUS', 'MAIN_LV_BOARD'),
  ('TRANSFORMER', 'GRID_INCOMER', 'MAIN_LV_BOARD'),
  ('GENERATOR_INFEED', 'GAS_ENGINE', 'MAIN_LV_BOARD'),
  ('PV_INJECTION', 'PV_PLANT', 'MAIN_LV_BOARD'),
  ('PV_INJECTION', 'PV_PLANT', 'SUB_BOARD'),
  ('PF_COMPENSATION', 'MAIN_LV_BOARD', 'CAPACITOR_BANK'),
  ('PF_COMPENSATION', 'SUB_BOARD', 'CAPACITOR_BANK'),
  ('SUPPLY_LV', 'MAIN_LV_BOARD', 'SUB_BOARD'),
  ('SUPPLY_LV', 'MAIN_LV_BOARD', 'LOAD'),
  ('SUPPLY_LV', 'MAIN_LV_BOARD', 'AIR_COMPRESSOR'),
  ('SUPPLY_LV', 'MAIN_LV_BOARD', 'BOILER'),
  ('SUPPLY_LV', 'MAIN_LV_BOARD', 'WATER_INTAKE'),
  ('SUPPLY_LV', 'MAIN_LV_BOARD', 'SOFTENER'),
  ('SUPPLY_LV', 'MAIN_LV_BOARD', 'CLARIFIER'),
  ('SUPPLY_LV', 'MAIN_LV_BOARD', 'RO_UNIT'),
  ('SUPPLY_LV', 'MAIN_LV_BOARD', 'REACTION_TANK'),
  ('SUPPLY_LV', 'MAIN_LV_BOARD', 'WATER_TANK'),
  ('SUPPLY_LV', 'SUB_BOARD', 'SUB_BOARD'),
  ('SUPPLY_LV', 'SUB_BOARD', 'LOAD'),
  ('SUPPLY_LV', 'SUB_BOARD', 'AIR_COMPRESSOR'),
  ('SUPPLY_LV', 'SUB_BOARD', 'BOILER'),
  ('SUPPLY_LV', 'SUB_BOARD', 'WATER_INTAKE'),
  ('SUPPLY_LV', 'SUB_BOARD', 'SOFTENER'),
  ('SUPPLY_LV', 'SUB_BOARD', 'CLARIFIER'),
  ('SUPPLY_LV', 'SUB_BOARD', 'RO_UNIT'),
  ('SUPPLY_LV', 'SUB_BOARD', 'REACTION_TANK'),
  ('SUPPLY_LV', 'SUB_BOARD', 'WATER_TANK'),
  ('SUPPLY_LV', 'LOAD', 'SUB_BOARD'),
  ('SUPPLY_LV', 'LOAD', 'LOAD'),
  ('SUPPLY_LV', 'LOAD', 'AIR_COMPRESSOR'),
  ('SUPPLY_LV', 'LOAD', 'BOILER'),
  ('SUPPLY_LV', 'LOAD', 'CAPACITOR_BANK'),
  ('SUPPLY_LV', 'LOAD', 'WATER_INTAKE'),
  ('SUPPLY_LV', 'LOAD', 'SOFTENER'),
  ('SUPPLY_LV', 'LOAD', 'CLARIFIER'),
  ('SUPPLY_LV', 'LOAD', 'RO_UNIT'),
  ('SUPPLY_LV', 'LOAD', 'REACTION_TANK'),
  ('SUPPLY_LV', 'LOAD', 'WATER_TANK'),
  ('WATER_TREATMENT', 'WATER_INTAKE', 'CLARIFIER'),
  ('WATER_TREATMENT', 'WATER_INTAKE', 'SOFTENER'),
  ('WATER_TREATMENT', 'WATER_INTAKE', 'RO_UNIT'),
  ('WATER_TREATMENT', 'WATER_INTAKE', 'REACTION_TANK'),
  ('WATER_TREATMENT', 'WATER_INTAKE', 'WATER_TANK'),
  ('WATER_TREATMENT', 'WATER_INTAKE', 'BOILER'),
  ('WATER_TREATMENT', 'WATER_INTAKE', 'LOAD'),
  ('WATER_TREATMENT', 'CLARIFIER', 'CLARIFIER'),
  ('WATER_TREATMENT', 'CLARIFIER', 'SOFTENER'),
  ('WATER_TREATMENT', 'CLARIFIER', 'RO_UNIT'),
  ('WATER_TREATMENT', 'CLARIFIER', 'REACTION_TANK'),
  ('WATER_TREATMENT', 'CLARIFIER', 'WATER_TANK'),
  ('WATER_TREATMENT', 'CLARIFIER', 'BOILER'),
  ('WATER_TREATMENT', 'CLARIFIER', 'LOAD'),
  ('WATER_TREATMENT', 'SOFTENER', 'CLARIFIER'),
  ('WATER_TREATMENT', 'SOFTENER', 'SOFTENER'),
  ('WATER_TREATMENT', 'SOFTENER', 'RO_UNIT'),
  ('WATER_TREATMENT', 'SOFTENER', 'REACTION_TANK'),
  ('WATER_TREATMENT', 'SOFTENER', 'WATER_TANK'),
  ('WATER_TREATMENT', 'SOFTENER', 'BOILER'),
  ('WATER_TREATMENT', 'SOFTENER', 'LOAD'),
  ('WATER_TREATMENT', 'RO_UNIT', 'CLARIFIER'),
  ('WATER_TREATMENT', 'RO_UNIT', 'SOFTENER'),
  ('WATER_TREATMENT', 'RO_UNIT', 'RO_UNIT'),
  ('WATER_TREATMENT', 'RO_UNIT', 'REACTION_TANK'),
  ('WATER_TREATMENT', 'RO_UNIT', 'WATER_TANK'),
  ('WATER_TREATMENT', 'RO_UNIT', 'BOILER'),
  ('WATER_TREATMENT', 'RO_UNIT', 'LOAD'),
  ('WATER_TREATMENT', 'REACTION_TANK', 'CLARIFIER'),
  ('WATER_TREATMENT', 'REACTION_TANK', 'SOFTENER'),
  ('WATER_TREATMENT', 'REACTION_TANK', 'RO_UNIT'),
  ('WATER_TREATMENT', 'REACTION_TANK', 'REACTION_TANK'),
  ('WATER_TREATMENT', 'REACTION_TANK', 'WATER_TANK'),
  ('WATER_TREATMENT', 'REACTION_TANK', 'BOILER'),
  ('WATER_TREATMENT', 'REACTION_TANK', 'LOAD'),
  ('WATER_TREATMENT', 'WATER_TANK', 'CLARIFIER'),
  ('WATER_TREATMENT', 'WATER_TANK', 'SOFTENER'),
  ('WATER_TREATMENT', 'WATER_TANK', 'RO_UNIT'),
  ('WATER_TREATMENT', 'WATER_TANK', 'REACTION_TANK'),
  ('WATER_SUPPLY', 'WATER_TANK', 'LOAD'),
  ('WATER_SUPPLY', 'WATER_TANK', 'BOILER'),
  ('WATER_SUPPLY', 'WATER_TANK', 'AIR_COMPRESSOR'),
  ('WATER_SUPPLY', 'LOAD', 'LOAD'),
  ('WATER_RETURN', 'LOAD', 'WATER_TANK'),
  ('WATER_RETURN', 'REACTION_TANK', 'WATER_TANK'),
  ('WATER_TRANSFER', 'WATER_TANK', 'WATER_TANK');

-- ---------------------------------------------------------------------------
-- 2.4 Classify every active edge, then lock the pair with a composite FK
-- ---------------------------------------------------------------------------
UPDATE graph.edge e SET edge_type =
    CASE
            WHEN e.edge_class = 'COMPENSATION' THEN 'PF_COMPENSATION'
            WHEN e.utility_code = 'WATER' THEN CASE
                WHEN f.node_type = 'WATER_TANK' AND t.node_type = 'WATER_TANK'
                     THEN 'WATER_TRANSFER'
                WHEN t.node_type = 'WATER_TANK'
                     AND (f.node_class = 'LOAD' OR f.node_type = 'REACTION_TANK')
                     THEN 'WATER_RETURN'
                WHEN f.node_type IN ('WATER_INTAKE','CLARIFIER','SOFTENER','RO_UNIT','REACTION_TANK')
                  OR t.node_type IN ('CLARIFIER','SOFTENER','RO_UNIT','REACTION_TANK')
                     THEN 'WATER_TREATMENT'
                ELSE 'WATER_SUPPLY' END
            -- PV first: a PV_PLANT -> MAIN_LV_BOARD edge would otherwise match TRANSFORMER
            WHEN f.node_type = 'PV_PLANT'   THEN 'PV_INJECTION'
            WHEN f.node_type = 'GAS_ENGINE' THEN 'GENERATOR_INFEED'
            WHEN f.node_type = 'GRID_INCOMER' AND t.node_type = 'MV_BUS' THEN 'GRID_INFEED'
            -- INCOMING_PLN feeds 6 transformers directly, FACTORY_AB is an MV_BUS feeding 6
            WHEN f.node_type IN ('MV_BUS','GRID_INCOMER') AND t.node_type = 'MAIN_LV_BOARD'
                 THEN 'TRANSFORMER'
            ELSE 'SUPPLY_LV' END
FROM graph.node f, graph.node t
WHERE f.id = e.from_node_id AND t.id = e.to_node_id
  AND e.tenant_id = 3 AND e.is_active;

-- added after the UPDATE so the seed does not have to satisfy it mid-flight.
-- MATCH SIMPLE: the check is skipped while edge_type is NULL, which is what lets
-- an untyped edge exist at all.
ALTER TABLE graph.edge ADD CONSTRAINT fk_edge_edge_type
    FOREIGN KEY (edge_type, edge_class) REFERENCES graph.edge_type (code, edge_class);

CREATE INDEX idx_edge_type ON graph.edge (edge_type) WHERE is_active;

-- ---------------------------------------------------------------------------
-- 2.5 The one transformer fact recorded nowhere: the equipment's own name.
--     A NODE property, beside rated_kva and tx_primary_v which 026 put there.
--     Source: design/trafo_tenant_3.csv
-- ---------------------------------------------------------------------------
INSERT INTO graph.property (attr_key, datatype, kind, description, external_ref) VALUES
  ('tx_equipment_code', 'text', 'RECORD',
   'Name of the transformer feeding this board, as the site names it (TF_A1, '
   'TF_SPINNING_1). The transformer is modelled as the TRANSFORMER edge into this '
   'board; this records which physical unit that edge is.',
   'docs/database/design/trafo_tenant_3.csv');  -- as applied; see README.md

INSERT INTO graph.type_property (node_type, attr_key, requirement, used_by)
VALUES ('MAIN_LV_BOARD', 'tx_equipment_code', 'OPTIONAL', NULL);

UPDATE graph.node n SET attrs = n.attrs || jsonb_build_object('tx_equipment_code', v.tx),
                        updated_at = NOW()
FROM (VALUES
  ('LVMDP_SPINNING_1', 'TF_SPINNING_1'),
  ('LVMDB_TEXTURE', 'TF_TEXTURE_1600'),
  ('LVMDB_TEXTURE_2', 'TF_TEXTURE_2000'),
  ('LVMDB_TF630', 'TF_TWISTING'),
  ('LVMDP_SPINNING_2', 'TF_SPINNING_2'),
  ('LVMDP_SPINNING_3', 'TF_SPINNING_3'),
  ('LVMDB_A1', 'TF_A1'),
  ('LVMDB_A2', 'TF_A2'),
  ('LVMDB_A3', 'TF_A3'),
  ('LVMDB_A4', 'TF_A4'),
  ('LVMDB_A5', 'TF_A5'),
  ('LVMDB_B2', 'TF_B2')
) AS v (board, tx)
WHERE n.tenant_id = 3 AND n.node_code = v.board;

-- ---------------------------------------------------------------------------
-- 2.6 The solver rule becomes data.
--
--     Both bodies below are graph.solve_flow and graph.get_node_quantity exactly
--     as they exist on valkyrie today (md5 asserted in 2.0), with ONE predicate
--     replaced. Nothing else is touched. Section 3.3 proves the output is
--     unchanged before this transaction commits.
-- ---------------------------------------------------------------------------
-- ---- graph.solve_flow -------------------------------------------------------
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
      -- 028: was e.edge_class <> 'COMPENSATION'. The rule is now data on
      -- graph.edge_type. COALESCE keeps an untyped edge carrying flow, which
      -- is what the old predicate did for everything except COMPENSATION.
      AND COALESCE((SELECT et.carries_flow FROM graph.edge_type et
                     WHERE et.code = e.edge_type), TRUE)
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
$function$;

-- ---- graph.get_node_quantity -------------------------------------------------------
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
      -- 028: was e.edge_class <> 'COMPENSATION'. The rule is now data on
      -- graph.edge_type. COALESCE keeps an untyped edge carrying flow, which
      -- is what the old predicate did for everything except COMPENSATION.
      AND COALESCE((SELECT et.carries_flow FROM graph.edge_type et
                     WHERE et.code = e.edge_type), TRUE)
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
$function$;

-- ---------------------------------------------------------------------------
-- 2.7 The gap view -- the edge counterpart of v_property_gaps
-- ---------------------------------------------------------------------------
CREATE VIEW graph.v_edge_gaps AS
WITH e AS (
    SELECT ed.id, ed.tenant_id, ed.edge_type, ed.utility_code, ed.edge_class,
           f.node_code AS from_code, t.node_code AS to_code,
           f.node_type  AS from_type, t.node_type  AS to_type,
           f.node_class AS from_class, t.node_class AS to_class
    FROM graph.edge ed
    JOIN graph.node f ON f.id = ed.from_node_id
    JOIN graph.node t ON t.id = ed.to_node_id
    WHERE ed.is_active
)
SELECT e.tenant_id, e.id AS edge_id, e.from_code, e.to_code, e.utility_code,
       e.edge_type,
       CASE
         WHEN e.edge_type IS NULL THEN 'UNTYPED'
         -- a rule can only be judged when both ends are typed. With 98 loads
         -- still untyped, reporting is the honest answer, not rejection.
         WHEN e.from_type IS NULL OR e.to_type IS NULL THEN 'ENDPOINT_UNTYPED'
         WHEN EXISTS (SELECT 1 FROM graph.edge_type_endpoint x
                       WHERE x.edge_type = e.edge_type
                         AND x.from_kind IN (e.from_type, e.from_class)
                         AND x.to_kind   IN (e.to_type,   e.to_class))
              THEN NULL
         ELSE 'ILLEGAL_ENDPOINT'
       END AS status,
       e.from_type, e.to_type
FROM e
WHERE CASE
        WHEN e.edge_type IS NULL THEN TRUE
        WHEN e.from_type IS NULL OR e.to_type IS NULL THEN TRUE
        WHEN EXISTS (SELECT 1 FROM graph.edge_type_endpoint x
                      WHERE x.edge_type = e.edge_type
                        AND x.from_kind IN (e.from_type, e.from_class)
                        AND x.to_kind   IN (e.to_type,   e.to_class))
             THEN FALSE
        ELSE TRUE
      END;

COMMENT ON VIEW graph.v_edge_gaps IS
  'Active edges that are untyped, cannot be checked because an endpoint node is '
  'untyped, or connect a pair their relation does not permit. The edge half of '
  'the site-check list; see graph.v_property_gaps for the node half.';

-- ---------------------------------------------------------------------------
-- 2.8 Grants -- the reports run as grafReader
-- ---------------------------------------------------------------------------
GRANT SELECT ON graph.edge_type, graph.edge_type_endpoint, graph.v_edge_gaps
   TO "grafReader";

-- ---------------------------------------------------------------------------
-- 2.9 Post-conditions
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
    r       RECORD;
    n       INTEGER;
    untyped INTEGER;
BEGIN
    FOR r IN SELECT * FROM (VALUES
        ('PF_COMPENSATION', 11),
        ('GENERATOR_INFEED', 3),
        ('GRID_INFEED', 1),
        ('PV_INJECTION', 4),
        ('SUPPLY_LV', 148),
        ('TRANSFORMER', 12),
        ('WATER_RETURN', 6),
        ('WATER_SUPPLY', 11),
        ('WATER_TRANSFER', 2),
        ('WATER_TREATMENT', 20)
    ) AS v (code, expected) LOOP
        SELECT count(*) INTO n FROM graph.edge
         WHERE tenant_id = 3 AND is_active AND edge_type = r.code;
        IF n <> r.expected THEN
            RAISE EXCEPTION 'edge_type % : expected % edges, got %', r.code, r.expected, n;
        END IF;
    END LOOP;

    SELECT count(*) INTO untyped FROM graph.edge
     WHERE tenant_id = 3 AND is_active AND edge_type IS NULL;
    IF untyped <> 0 THEN
        RAISE EXCEPTION '% active edges left untyped', untyped;
    END IF;

    SELECT count(*) INTO n FROM graph.v_edge_gaps WHERE status = 'ILLEGAL_ENDPOINT';
    IF n <> 0 THEN
        RAISE EXCEPTION '% edge(s) connect a pair their relation does not permit; '
                        'see graph.v_edge_gaps', n;
    END IF;

    SELECT count(*) INTO n FROM graph.node
     WHERE tenant_id = 3 AND attrs ? 'tx_equipment_code';
    IF n <> 12 THEN
        RAISE EXCEPTION 'expected 12 boards to carry tx_equipment_code, found %', n;
    END IF;

    RAISE NOTICE 'OK: 218 edges typed across 10 relations, 0 illegal endpoints, '
                 '12 transformers named';
END $post$;


-- ============================================================================
-- 3. Verification -- run BEFORE committing
-- ============================================================================

\echo ''
\echo '=== 3.1 The relation vocabulary ==='
SELECT et.code, et.edge_class, et.utility_code, et.carries_flow, et.is_transform,
       count(e.id) AS edges
FROM graph.edge_type et
LEFT JOIN graph.edge e ON e.edge_type = et.code AND e.tenant_id = 3 AND e.is_active
GROUP BY 1,2,3,4,5 ORDER BY 3, 1;

\echo ''
\echo '=== 3.2 The twelve transformers, now visible as such ==='
SELECT f.node_code AS from_code, t.node_code AS to_code,
       t.attrs ->> 'tx_equipment_code' AS transformer,
       (t.attrs ->> 'rated_kva')::numeric  AS kva,
       (f.attrs ->> 'nominal_v')::numeric  AS primary_v,
       (t.attrs ->> 'nominal_v')::numeric  AS secondary_v,
       t.attrs ->> 'tx_impedance_pct'      AS z_pct
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active AND e.edge_type = 'TRANSFORMER'
ORDER BY 3;
-- z_pct is NULL for all 12: the slot exists (026), the values do not. See design §6.

\echo ''
\echo '=== 3.3 SOLVER EQUIVALENCE -- the load-bearing check ==='
\echo '    Every row must read 0. carries_flow must reproduce the old predicate exactly.'
SELECT * FROM (
  SELECT 'nv_e' AS solver,
         (SELECT count(*) FROM (SELECT * FROM _before_nv_e
                                EXCEPT ALL SELECT * FROM graph.get_node_values(3,'ELECTRICITY','2026-09-07 00:00','2026-09-14 00:00',124)) a) AS lost,
         (SELECT count(*) FROM (SELECT * FROM graph.get_node_values(3,'ELECTRICITY','2026-09-07 00:00','2026-09-14 00:00',124)
                                EXCEPT ALL SELECT * FROM _before_nv_e) b) AS gained
  UNION ALL
  SELECT 'sk_e' AS solver,
         (SELECT count(*) FROM (SELECT * FROM _before_sk_e
                                EXCEPT ALL SELECT * FROM graph.get_sankey_flow(3,'ELECTRICITY','2026-09-07 00:00','2026-09-14 00:00',124)) a) AS lost,
         (SELECT count(*) FROM (SELECT * FROM graph.get_sankey_flow(3,'ELECTRICITY','2026-09-07 00:00','2026-09-14 00:00',124)
                                EXCEPT ALL SELECT * FROM _before_sk_e) b) AS gained
  UNION ALL
  SELECT 'nq_e' AS solver,
         (SELECT count(*) FROM (SELECT * FROM _before_nq_e
                                EXCEPT ALL SELECT * FROM graph.get_node_quantity(3,'ELECTRICITY',124,'2026-09-07 00:00','2026-09-14 00:00')) a) AS lost,
         (SELECT count(*) FROM (SELECT * FROM graph.get_node_quantity(3,'ELECTRICITY',124,'2026-09-07 00:00','2026-09-14 00:00')
                                EXCEPT ALL SELECT * FROM _before_nq_e) b) AS gained
  UNION ALL
  SELECT 'nv_w' AS solver,
         (SELECT count(*) FROM (SELECT * FROM _before_nv_w
                                EXCEPT ALL SELECT * FROM graph.get_node_values(3,'WATER','2026-09-07 00:00','2026-09-14 00:00',5696)) a) AS lost,
         (SELECT count(*) FROM (SELECT * FROM graph.get_node_values(3,'WATER','2026-09-07 00:00','2026-09-14 00:00',5696)
                                EXCEPT ALL SELECT * FROM _before_nv_w) b) AS gained
  UNION ALL
  SELECT 'sk_w' AS solver,
         (SELECT count(*) FROM (SELECT * FROM _before_sk_w
                                EXCEPT ALL SELECT * FROM graph.get_sankey_flow(3,'WATER','2026-09-07 00:00','2026-09-14 00:00',5696)) a) AS lost,
         (SELECT count(*) FROM (SELECT * FROM graph.get_sankey_flow(3,'WATER','2026-09-07 00:00','2026-09-14 00:00',5696)
                                EXCEPT ALL SELECT * FROM _before_sk_w) b) AS gained
) d ORDER BY solver;

\echo ''
\echo '=== 3.4 The edge gap list ==='
SELECT status, count(*) FROM graph.v_edge_gaps WHERE tenant_id = 3
GROUP BY 1 ORDER BY 1;
-- expect ENDPOINT_UNTYPED only -- edges into the 98 untyped LOAD nodes.
-- UNTYPED must be 0 and ILLEGAL_ENDPOINT must be absent (2.9 raises otherwise).

\echo ''
\echo '=== 3.5 Node gaps are unchanged by this migration ==='
SELECT status, count(*) FROM graph.v_property_gaps GROUP BY 1 ORDER BY 1;
-- expect MISSING 23, UNTYPED 98 -- same as before 028

COMMIT;


-- ============================================================================
-- 4. Undo (commented)
--
--     The solver functions must be restored from their pre-028 definitions.
--     Those are in 028_pre_solver_bodies.sql, captured from live before this
--     migration was written; run that file after the block below. The md5 values
--     asserted in section 2.0 are the check that the restore worked.
-- ============================================================================
--
-- BEGIN;
-- DROP VIEW  IF EXISTS graph.v_edge_gaps;
-- ALTER TABLE graph.edge DROP CONSTRAINT IF EXISTS fk_edge_edge_type;
-- DROP INDEX IF EXISTS graph.idx_edge_type;
-- ALTER TABLE graph.edge DROP COLUMN IF EXISTS edge_type;
-- DROP TABLE IF EXISTS graph.edge_type_endpoint;
-- DROP TABLE IF EXISTS graph.edge_type;
-- UPDATE graph.node SET attrs = attrs - 'tx_equipment_code' WHERE tenant_id = 3;
-- DELETE FROM graph.type_property WHERE attr_key = 'tx_equipment_code';
-- DELETE FROM graph.property      WHERE attr_key = 'tx_equipment_code';
-- COMMIT;
--
-- \i migrations/028_pre_solver_bodies.sql
