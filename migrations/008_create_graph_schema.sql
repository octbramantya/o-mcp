-- Migration: 008_create_graph_schema.sql
-- Description: Create the graph schema: nodes, typed edges, measurements, quantity rules
-- Author: Claude
-- Date: 2026-08-19
-- Phase: 0 -- additive, nothing reads it yet (see §8 of design/graph-network-design.md)
--
-- Every statement below is extracted from graph-network-design.md. Edit the
-- design document first, then regenerate -- not the other way round.
--
-- One adaptation for a migration file: IF NOT EXISTS / ON CONFLICT DO NOTHING /
-- DROP TRIGGER IF EXISTS are added so a re-run is a no-op, matching 001.
--
-- Additive throughout. Nothing existing is touched; prs.device_hierarchy and
-- prs.device_node_mapping keep serving the live Sankey until Phase 4.

BEGIN;

-- ============================================================================
-- Schema and the WAGES utility vocabulary (§4.1)
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS graph;

COMMENT ON SCHEMA graph IS
  'WAGES (Water/Air/Gas/Electricity/Steam) network topology: nodes, typed edges, measurements.';

CREATE TABLE IF NOT EXISTS graph.utility (
    code              VARCHAR(20)  PRIMARY KEY,
    name              VARCHAR(50)  NOT NULL,
    base_unit         VARCHAR(20)  NOT NULL,
    quantity_category VARCHAR(50),          -- joins public.quantities.category
    display_color     VARCHAR(20),
    display_order     INTEGER NOT NULL DEFAULT 0
);

INSERT INTO graph.utility (code, name, base_unit, quantity_category, display_color, display_order) VALUES
  ('ELECTRICITY', 'Electricity',    'kWh', 'Electricity', '#f2b705', 1),
  ('WATER',       'Water',          'm3',  'Water',       '#2a9df4', 2),
  ('AIR',         'Compressed Air', 'Nm3', 'Air',         '#7ac74f', 3),
  ('GAS',         'Natural Gas',    'Nm3', 'Gas',         '#e6704b', 4),
  ('STEAM',       'Steam',          'kg',  'Steam',       '#b07bd4', 5)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- Nodes (§4.2)
-- ============================================================================
CREATE TABLE IF NOT EXISTS graph.node (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      INTEGER      NOT NULL,
    node_code      VARCHAR(60)  NOT NULL,
    node_name      VARCHAR(120) NOT NULL,
    node_class     VARCHAR(20)  NOT NULL,
    attrs          JSONB        NOT NULL DEFAULT '{}'::jsonb,
    is_passthrough BOOLEAN      NOT NULL DEFAULT FALSE,
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    effective_from DATE         NOT NULL DEFAULT '-infinity'::date,
    effective_to   DATE,
    created_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMP    NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_node_tenant_code UNIQUE (tenant_id, node_code),
    -- composite key so edges can enforce same-tenant endpoints via FK
    CONSTRAINT uq_node_id_tenant   UNIQUE (id, tenant_id),
    CONSTRAINT ck_node_class CHECK (node_class IN
        ('SOURCE','BUS','DISTRIBUTION','CONVERSION','STORAGE','LOAD')),
    CONSTRAINT ck_node_dates CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX IF NOT EXISTS idx_node_tenant_active ON graph.node (tenant_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_node_tenant_class  ON graph.node (tenant_id, node_class);
CREATE INDEX IF NOT EXISTS idx_node_attrs         ON graph.node USING gin (attrs);

-- ============================================================================
-- Edges -- typed, which is what makes WAGES work (§4.3)
-- ============================================================================
CREATE TABLE IF NOT EXISTS graph.edge (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      INTEGER     NOT NULL,
    from_node_id   BIGINT      NOT NULL,
    to_node_id     BIGINT      NOT NULL,
    utility_code   VARCHAR(20) NOT NULL REFERENCES graph.utility(code),
    edge_class     VARCHAR(20) NOT NULL DEFAULT 'FEEDER',
    attrs          JSONB       NOT NULL DEFAULT '{}'::jsonb,
    is_active      BOOLEAN     NOT NULL DEFAULT TRUE,
    effective_from DATE        NOT NULL DEFAULT '-infinity'::date,
    effective_to   DATE,
    created_at     TIMESTAMP   NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_edge_from FOREIGN KEY (from_node_id, tenant_id)
        REFERENCES graph.node (id, tenant_id) ON DELETE CASCADE,
    CONSTRAINT fk_edge_to   FOREIGN KEY (to_node_id, tenant_id)
        REFERENCES graph.node (id, tenant_id) ON DELETE CASCADE,
    CONSTRAINT uq_edge UNIQUE (from_node_id, to_node_id, utility_code, effective_from),
    CONSTRAINT ck_edge_no_self CHECK (from_node_id <> to_node_id),
    CONSTRAINT ck_edge_class CHECK (edge_class IN
        ('FEEDER','CABLE','BUSTIE','PIPE','HEADER_BRANCH','DUCT','CONVERSION')),
    CONSTRAINT ck_edge_dates CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX IF NOT EXISTS idx_edge_from    ON graph.edge (from_node_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_edge_to      ON graph.edge (to_node_id)   WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_edge_utility ON graph.edge (tenant_id, utility_code) WHERE is_active;

-- ============================================================================
-- Measurements -- node_id XOR edge_id (§4.4)
--
-- A power meter on a switchboard reads that board: node_id.
-- A flow meter tapped into a pipe reads the pipe: edge_id.
-- ============================================================================
CREATE TABLE IF NOT EXISTS graph.measurement (
    id             BIGSERIAL PRIMARY KEY,
    tenant_id      INTEGER     NOT NULL,
    node_id        BIGINT      REFERENCES graph.node (id) ON DELETE CASCADE,
    edge_id        BIGINT      REFERENCES graph.edge (id) ON DELETE CASCADE,
    device_id      INTEGER     NOT NULL REFERENCES public.devices (id),
    quantity_id    INTEGER     NOT NULL REFERENCES public.quantities (id),
    utility_code   VARCHAR(20) NOT NULL REFERENCES graph.utility(code),
    multiplier     NUMERIC     NOT NULL DEFAULT 1,
    role           VARCHAR(20) NOT NULL DEFAULT 'TOTAL',
    is_active      BOOLEAN     NOT NULL DEFAULT TRUE,
    effective_from DATE        NOT NULL DEFAULT '-infinity'::date,
    effective_to   DATE,
    created_at     TIMESTAMP   NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_meas_target CHECK (num_nonnulls(node_id, edge_id) = 1),
    CONSTRAINT ck_meas_role   CHECK (role IN ('TOTAL','SUBMETER','CHECK')),
    CONSTRAINT ck_meas_dates  CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX IF NOT EXISTS idx_meas_node   ON graph.measurement (node_id)   WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_meas_edge   ON graph.measurement (edge_id)   WHERE is_active;
CREATE INDEX IF NOT EXISTS idx_meas_device ON graph.measurement (tenant_id, device_id) WHERE is_active;

CREATE UNIQUE INDEX IF NOT EXISTS uq_meas_node_dev_qty ON graph.measurement
    (node_id, device_id, quantity_id, effective_from) WHERE node_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_meas_edge_dev_qty ON graph.measurement
    (edge_id, device_id, quantity_id, effective_from) WHERE edge_id IS NOT NULL;

-- ============================================================================
-- Cycle prevention (§4.5) and updated_at
-- ============================================================================
CREATE OR REPLACE FUNCTION graph.assert_acyclic() RETURNS TRIGGER AS $$
DECLARE
    v_cycle BOOLEAN;
BEGIN
    WITH RECURSIVE reach(node_id) AS (
        SELECT NEW.to_node_id
        UNION
        SELECT e.to_node_id
        FROM graph.edge e
        JOIN reach r ON e.from_node_id = r.node_id
        WHERE e.is_active
          AND e.id <> COALESCE(NEW.id, -1)   -- ignore the row being written
    )
    SELECT EXISTS (SELECT 1 FROM reach WHERE node_id = NEW.from_node_id) INTO v_cycle;

    IF v_cycle THEN
        RAISE EXCEPTION
          'graph.edge %->% would create a cycle (utility %)',
          NEW.from_node_id, NEW.to_node_id, NEW.utility_code;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_edge_acyclic ON graph.edge;
CREATE TRIGGER trg_edge_acyclic
    BEFORE INSERT OR UPDATE OF from_node_id, to_node_id, is_active ON graph.edge
    FOR EACH ROW WHEN (NEW.is_active)
    EXECUTE FUNCTION graph.assert_acyclic();

CREATE OR REPLACE FUNCTION graph.touch_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_node_touch ON graph.node;
CREATE TRIGGER trg_node_touch BEFORE UPDATE ON graph.node
    FOR EACH ROW EXECUTE FUNCTION graph.touch_updated_at();

-- ============================================================================
-- Quantity handling (§4.7): register aliases, composition rules, derived
-- ============================================================================
-- (i) Redundant registers. Some meters expose the same physical quantity twice.
CREATE TABLE IF NOT EXISTS graph.quantity_alias (
    quantity_id           INTEGER PRIMARY KEY REFERENCES public.quantities (id),
    canonical_quantity_id INTEGER NOT NULL    REFERENCES public.quantities (id),
    note                  TEXT,
    CONSTRAINT ck_alias_not_self CHECK (quantity_id <> canonical_quantity_id)
);

INSERT INTO graph.quantity_alias VALUES
  (130, 124, 'Schneider Active Energy Delivered-Received; same physical energy as 124')
ON CONFLICT DO NOTHING;

-- (ii) Composition rules.
CREATE TABLE IF NOT EXISTS graph.quantity_rule (
    quantity_id  INTEGER PRIMARY KEY REFERENCES public.quantities (id),
    utility_code VARCHAR(20) NOT NULL REFERENCES graph.utility (code),
    raw_time_agg VARCHAR(20) NOT NULL,   -- collapse the TIME axis
    network_agg  VARCHAR(20) NOT NULL,   -- collapse the TOPOLOGY axis
    conserved    BOOLEAN     NOT NULL DEFAULT FALSE,
    CONSTRAINT ck_raw_time_agg  CHECK (raw_time_agg IN ('DELTA','SUM','AVG','LAST','P95')),
    CONSTRAINT ck_network_agg   CHECK (network_agg  IN ('SUM','RSS','INHERIT','NONE')),
    CONSTRAINT ck_conserved_sum CHECK (NOT conserved OR network_agg = 'SUM')
);

INSERT INTO graph.quantity_rule VALUES
  ( 124,'ELECTRICITY','DELTA','SUM',     TRUE),   -- Active Energy Delivered
  ( 131,'ELECTRICITY','DELTA','SUM',     TRUE),   -- Active Energy Received    (net P = 124 - 131)
  (  89,'ELECTRICITY','DELTA','SUM',     TRUE),   -- Reactive Energy Delivered
  (  96,'ELECTRICITY','DELTA','SUM',     TRUE),   -- Reactive Energy Received  (net Q =  89 -  96)
  ( 481,'ELECTRICITY','DELTA','NONE',    FALSE),  -- Apparent Energy Delivered  -- NOT additive
  (  62,'ELECTRICITY','DELTA','NONE',    FALSE),  -- Apparent Energy Del+Rec    -- NOT additive
  (1072,'ELECTRICITY','AVG',  'NONE',    FALSE),  -- True Power Factor Total
  (1119,'ELECTRICITY','P95',  'INHERIT', FALSE),  -- THD Voltage L-N
  (2097,'ELECTRICITY','P95',  'RSS',     FALSE),  -- THD RMS Current A
  (5696,'WATER',      'DELTA','SUM',     TRUE)    -- Water Volume Supply (m3)
ON CONFLICT DO NOTHING;

-- Air/gas/steam have no meters in the live database yet. When they arrive the rows
-- take the same shape -- and note that BOTH are needed for one flow meter:
--   (<id>,'AIR','DELTA','SUM',  TRUE)   -- cumulative Nm3 totaliser: MAX - MIN
--   (<id>,'AIR','AVG',  'NONE', FALSE)  -- instantaneous flow rate: never summed

-- (iii) Quantities that are computed at a node, never rolled up.
CREATE TABLE IF NOT EXISTS graph.derived_quantity (
    code          VARCHAR(40) PRIMARY KEY,
    utility_code  VARCHAR(20) NOT NULL REFERENCES graph.utility (code),
    display_name  VARCHAR(80) NOT NULL,
    formula       VARCHAR(20) NOT NULL,
    p_quantity_id INTEGER NOT NULL REFERENCES public.quantities (id),
    q_quantity_id INTEGER NOT NULL REFERENCES public.quantities (id),
    CONSTRAINT ck_derived_formula CHECK (formula IN ('PQ_RATIO'))
);

INSERT INTO graph.derived_quantity VALUES
  ('PF_TRUE','ELECTRICITY','Power Factor','PQ_RATIO', 124, 89)
ON CONFLICT DO NOTHING;

-- A measurement must name a canonical register, never an alias.
CREATE OR REPLACE FUNCTION graph.assert_canonical_quantity() RETURNS TRIGGER AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM graph.quantity_alias a WHERE a.quantity_id = NEW.quantity_id) THEN
        RAISE EXCEPTION
          'graph.measurement.quantity_id % is a redundant register alias; use its canonical id %',
          NEW.quantity_id,
          (SELECT a.canonical_quantity_id FROM graph.quantity_alias a
            WHERE a.quantity_id = NEW.quantity_id);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_meas_canonical ON graph.measurement;
CREATE TRIGGER trg_meas_canonical
    BEFORE INSERT OR UPDATE OF quantity_id ON graph.measurement
    FOR EACH ROW EXECUTE FUNCTION graph.assert_canonical_quantity();

-- ============================================================================
-- Coverage view (§5.5) -- DROP first: a CREATE OR REPLACE cannot rename a
-- view column, and is_metered was split into is_node_metered/is_edge_metered.
-- ============================================================================
DROP VIEW IF EXISTS graph.v_coverage;
CREATE OR REPLACE VIEW graph.v_coverage AS
SELECT n.tenant_id, n.id, n.node_code, n.node_name, n.node_class,
       EXISTS (SELECT 1 FROM graph.measurement m
                WHERE m.node_id = n.id AND m.is_active) AS is_node_metered,
       EXISTS (SELECT 1 FROM graph.measurement m
                JOIN graph.edge e ON e.id = m.edge_id AND e.is_active
                WHERE m.is_active
                  AND (e.from_node_id = n.id OR e.to_node_id = n.id)) AS is_edge_metered,
       (SELECT COUNT(*) FROM graph.edge e WHERE e.from_node_id = n.id AND e.is_active) AS out_degree,
       (SELECT COUNT(*) FROM graph.edge e WHERE e.to_node_id   = n.id AND e.is_active) AS in_degree
FROM graph.node n
WHERE n.is_active;

COMMIT;

-- ============================================================================
-- Verification
-- ============================================================================
-- SELECT COUNT(*) FROM graph.utility;        -- expect 5
-- SELECT COUNT(*) FROM graph.quantity_rule;  -- expect 10
-- SELECT COUNT(*) FROM graph.quantity_alias; -- expect 1  (130 -> 124)
