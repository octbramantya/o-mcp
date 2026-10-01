-- Migration: 033_create_class_tables.sql
-- Description: Give node classes and edge classes a table each, with a description per class.
--              The four class check constraints become foreign keys; the five never-used edge
--              classes are retired; endpoint rules must name a real node type or node class.
-- Author: Claude
-- Date: 2026-10-01
-- Design: design/mcp-tools.md (plant_vocabulary, "Gaps to close before building");
--         design/edge-type.md (decision 10)
-- Requires: 032_retire_distribution_class.sql
--
-- WHY
-- ---
-- Node types, edge types and properties each carry a description in the database.
-- Classes had only a check constraint: a list of allowed words with no meaning
-- attached, defined in design-doc prose. The plant_vocabulary MCP tool has to
-- tell a model what BUS or CONVERSION means, and the rule is that a description
-- is written once, in the database. So each class becomes a row with its
-- description, and the class columns point at those rows.
--
-- Nothing that reads a class changes. The columns keep their names, types and
-- values; only the guard moves from CHECK to FOREIGN KEY. The composite keys of
-- 026 and 028 (a node's class matches its type's) stay: they check agreement,
-- the new keys check existence, and an untyped node or edge has only the latter.
--
-- Two effects of the switch:
--   * adding a class is an INSERT that must carry a description;
--   * deleting a class is refused by the foreign keys while anything uses it,
--     which is the guard 032 had to write by hand.
--
-- Edge classes retired. 008 declared eight; only FEEDER, PIPE and COMPENSATION
-- have ever been used (edge-type.md section 1, and every edge row on 2026-10-01,
-- retired ones included). decision 10 left the other five unseeded:
--   CABLE, BUSTIE    no recorded purpose.
--   DUCT,            prepared for compressed air and steam. A header or ring main
--   HEADER_BRANCH    is a BUS node (graph-network-design.md node_class table) and
--                    what runs from it is a PIPE, for any piped utility. Re-added
--                    with an INSERT when the air and steam P&IDs arrive, if they
--                    show a conveyance PIPE cannot describe.
--   CONVERSION       conversion happens in a node, never along an edge. A
--                    compressor is a CONVERSION *node* with an ELECTRICITY in-edge
--                    and an AIR out-edge; each edge carries one utility. A
--                    transformer's voltage change is FEEDER with
--                    edge_type.is_transform.
-- The CONVERSION *node* class stays. Its description covers both kinds of node
-- it holds: utility conversion (compressor, boiler) and water treatment, where
-- water leaves changed and with some volume lost.
--
-- The flow solver (028's solve_flow) selects node_class but never branches on
-- it: it solves one utility at a time, on in/out degree, is_passthrough and the
-- meters. The descriptions below say what a class means, not how the solver
-- treats it.
--
-- Endpoint rules. edge_type_endpoint.from_kind / to_kind hold a node_type code
-- or a node_class code, and nothing checked either: a typo would be accepted and
-- the rule would silently never match. One column cannot carry two foreign keys,
-- so a trigger checks it, as 031 does for vocabulary_alignment.code. For the
-- answer to be unambiguous, no node_type code may equal a node_class code;
-- triggers on both tables keep it so, and stop a type or class from being
-- deleted or renamed while an endpoint rule names it.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 Node classes in use, all rows ==='
SELECT 'graph.node' AS tbl, node_class, count(*) FROM graph.node GROUP BY 2
UNION ALL
SELECT 'graph.node_type', node_class, count(*) FROM graph.node_type GROUP BY 2
ORDER BY 1, 2;
-- expect node: BUS 30, CONVERSION 32, LOAD 94, SOURCE 11, STORAGE 21
--        node_type: BUS 4, CONVERSION 7, LOAD 7, SOURCE 4, STORAGE 2

\echo ''
\echo '=== 1.2 Edge classes in use, all rows ==='
SELECT 'graph.edge' AS tbl, edge_class, count(*) FROM graph.edge GROUP BY 2
UNION ALL
SELECT 'graph.edge_type', edge_class, count(*) FROM graph.edge_type GROUP BY 2
ORDER BY 1, 2;
-- expect edge: COMPENSATION 11, FEEDER 172, PIPE 39
--        edge_type: COMPENSATION 1, FEEDER 5, PIPE 4

\echo ''
\echo '=== 1.3 Endpoint kinds that name a class rather than a type ==='
SELECT kind, count(*) AS rules
FROM (SELECT from_kind AS kind FROM graph.edge_type_endpoint
      UNION ALL SELECT to_kind FROM graph.edge_type_endpoint) k
WHERE kind NOT IN (SELECT code FROM graph.node_type)
GROUP BY 1 ORDER BY 1;
-- expect only LOAD (and possibly other class names); no misspelling


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run on anything the tables below would not cover
-- ----------------------------------------------------------------------------
DO $pre$
DECLARE
    bad TEXT;
BEGIN
    SELECT string_agg(DISTINCT c, ', ') INTO bad
    FROM (SELECT node_class AS c FROM graph.node
          UNION ALL SELECT node_class FROM graph.node_type) x
    WHERE c NOT IN ('SOURCE','BUS','CONVERSION','STORAGE','LOAD');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'node classes in use that 033 does not define: %', bad;
    END IF;

    SELECT string_agg(format('%s (%s rows)', edge_class, n), ', ') INTO bad
    FROM (SELECT edge_class, count(*) AS n
          FROM (SELECT edge_class FROM graph.edge
                UNION ALL SELECT edge_class FROM graph.edge_type) x
          WHERE edge_class NOT IN ('FEEDER','PIPE','COMPENSATION')
          GROUP BY 1) y;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'edge classes in use that 033 retires: %', bad;
    END IF;

    SELECT string_agg(DISTINCT format('%s %s -> %s', edge_type, from_kind, to_kind), ', ') INTO bad
    FROM graph.edge_type_endpoint e
    WHERE NOT EXISTS (SELECT 1 FROM graph.node_type t WHERE t.code = e.from_kind)
          AND e.from_kind NOT IN ('SOURCE','BUS','CONVERSION','STORAGE','LOAD')
       OR NOT EXISTS (SELECT 1 FROM graph.node_type t WHERE t.code = e.to_kind)
          AND e.to_kind NOT IN ('SOURCE','BUS','CONVERSION','STORAGE','LOAD');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'endpoint rules naming neither a node type nor a node class: %', bad;
    END IF;

    SELECT string_agg(code, ', ') INTO bad
    FROM graph.node_type WHERE code IN ('SOURCE','BUS','CONVERSION','STORAGE','LOAD');
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'node types named like a node class: %', bad;
    END IF;
END
$pre$;

-- ----------------------------------------------------------------------------
-- 2.2 The tables
-- ----------------------------------------------------------------------------
CREATE TABLE graph.node_class (
    code        VARCHAR(20) PRIMARY KEY,
    description TEXT        NOT NULL,
    CONSTRAINT ck_node_class_code CHECK (code ~ '^[A-Z][A-Z0-9_]*$')
);

CREATE TABLE graph.edge_class (
    code        VARCHAR(20) PRIMARY KEY,
    description TEXT        NOT NULL,
    CONSTRAINT ck_edge_class_code CHECK (code ~ '^[A-Z][A-Z0-9_]*$')
);

COMMENT ON TABLE graph.node_class IS
    'The broad role of a node. A finer distinction (main board versus sub-board) is a '
    'node_type, never a class: 032 retired DISTRIBUTION for that reason.';
COMMENT ON TABLE graph.edge_class IS
    'The conveyance an edge is (an electrical feeder, a pipe). What the relation means '
    '(transformer, PV injection, water return) is its edge_type.';

INSERT INTO graph.node_class (code, description) VALUES
    ('SOURCE',
     'Brings energy or water onto the site: the grid incomer, a PV plant, a generator, a '
     'water intake. Nothing feeds it on its own utility, though it may draw another (a '
     'water intake''s pumps take electricity).'),
    ('BUS',
     'A point where flow is pooled and shared out, holding no inventory: a switchboard, a '
     'water or air header. A main board and a sub-board are both BUS, told apart by '
     'node_type (MAIN_LV_BOARD, SUB_BOARD).'),
    ('CONVERSION',
     'A node whose output differs from its input. Either the utility changes (an air '
     'compressor takes electricity and delivers compressed air; a boiler delivers steam), '
     'so the node ends a path on one utility and starts one on another and may be metered '
     'on both; or the same utility leaves changed and with some volume lost (a clarifier, '
     'softener or RO unit). Inflow need not equal outflow.'),
    ('STORAGE',
     'Holds inventory, or compensates in place: a water tank, an air receiver, a capacitor '
     'bank.'),
    ('LOAD',
     'Consumes the utility: a machine, lighting, an air handling unit, a point where '
     'treated water is used. A path on that utility ends here.');

INSERT INTO graph.edge_class (code, description) VALUES
    ('FEEDER',
     'An electrical connection between two nodes: a low-voltage feeder, a transformer, a PV '
     'or generator infeed, the grid supply. Which of these it is, is its edge_type.'),
    ('PIPE',
     'A pipe carrying the utility from one node to the next. Water today; compressed air '
     'and steam pipes are PIPE too when those networks are drawn.'),
    ('COMPENSATION',
     'A capacitor bank''s connection to its board. It moves no energy '
     '(edge_type.carries_flow is false), so flow totals leave it out.');

-- ----------------------------------------------------------------------------
-- 2.3 The class columns point at the tables
-- ----------------------------------------------------------------------------
ALTER TABLE graph.node      DROP CONSTRAINT ck_node_class;
ALTER TABLE graph.node_type DROP CONSTRAINT ck_node_type_class;
ALTER TABLE graph.edge      DROP CONSTRAINT ck_edge_class;
ALTER TABLE graph.edge_type DROP CONSTRAINT ck_edge_type_class;

ALTER TABLE graph.node      ADD CONSTRAINT fk_node_class
    FOREIGN KEY (node_class) REFERENCES graph.node_class (code);
ALTER TABLE graph.node_type ADD CONSTRAINT fk_node_type_class
    FOREIGN KEY (node_class) REFERENCES graph.node_class (code);
ALTER TABLE graph.edge      ADD CONSTRAINT fk_edge_class
    FOREIGN KEY (edge_class) REFERENCES graph.edge_class (code);
ALTER TABLE graph.edge_type ADD CONSTRAINT fk_edge_type_class
    FOREIGN KEY (edge_class) REFERENCES graph.edge_class (code);

-- ----------------------------------------------------------------------------
-- 2.4 Endpoint kinds name a real node type or node class, never an ambiguous one
-- ----------------------------------------------------------------------------
COMMENT ON COLUMN graph.edge_type_endpoint.from_kind IS
    'A graph.node_type code, or a graph.node_class code for a coarse rule. Enforced by '
    'trigger, since one column cannot carry two foreign keys; no code is both.';
COMMENT ON COLUMN graph.edge_type_endpoint.to_kind IS
    'As from_kind.';

CREATE FUNCTION graph.assert_endpoint_kind() RETURNS TRIGGER AS $$
DECLARE
    k TEXT;
BEGIN
    FOREACH k IN ARRAY ARRAY[NEW.from_kind, NEW.to_kind] LOOP
        IF NOT EXISTS (SELECT 1 FROM graph.node_type  WHERE code = k)
           AND NOT EXISTS (SELECT 1 FROM graph.node_class WHERE code = k) THEN
            RAISE EXCEPTION 'edge_type_endpoint: % is neither a node type nor a node class', k;
        END IF;
    END LOOP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_edge_type_endpoint_kind
    BEFORE INSERT OR UPDATE OF from_kind, to_kind ON graph.edge_type_endpoint
    FOR EACH ROW EXECUTE FUNCTION graph.assert_endpoint_kind();

-- A node_type or node_class row: its code may not be taken by the other table,
-- and while an endpoint rule names it, it may not be deleted or renamed.
CREATE FUNCTION graph.assert_kind_code() RETURNS TRIGGER AS $$
DECLARE
    other TEXT := CASE TG_TABLE_NAME WHEN 'node_type' THEN 'node_class' ELSE 'node_type' END;
    taken BOOLEAN;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') AND (TG_OP = 'DELETE' OR NEW.code <> OLD.code)
       AND EXISTS (SELECT 1 FROM graph.edge_type_endpoint
                   WHERE OLD.code IN (from_kind, to_kind)) THEN
        RAISE EXCEPTION '%: % is named by an edge_type_endpoint rule', TG_TABLE_NAME, OLD.code;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM graph.%I WHERE code = $1)', other)
       INTO taken USING NEW.code;
    IF taken THEN
        RAISE EXCEPTION '%: % is already a % code', TG_TABLE_NAME, NEW.code, other;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_node_type_code
    BEFORE INSERT OR UPDATE OF code OR DELETE ON graph.node_type
    FOR EACH ROW EXECUTE FUNCTION graph.assert_kind_code();
CREATE TRIGGER trg_node_class_code
    BEFORE INSERT OR UPDATE OF code OR DELETE ON graph.node_class
    FOR EACH ROW EXECUTE FUNCTION graph.assert_kind_code();

-- ----------------------------------------------------------------------------
-- 2.5 Grants -- the reports and the MCP server run as grafReader
-- ----------------------------------------------------------------------------
GRANT SELECT ON graph.node_class, graph.edge_class TO "grafReader";

COMMIT;


-- ============================================================================
-- 3. Verification (read-only: each refusal test runs in a block that is undone)
-- ============================================================================

\echo ''
\echo '=== 3.1 The class tables ==='
SELECT 'node_class' AS tbl, code, left(description, 60) AS description FROM graph.node_class
UNION ALL
SELECT 'edge_class', code, left(description, 60) FROM graph.edge_class
ORDER BY 1, 2;
-- expect 5 node classes, 3 edge classes

\echo ''
\echo '=== 3.2 The guards on the class columns ==='
SELECT conrelid::regclass, conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conname IN ('fk_node_class', 'fk_node_type_class', 'fk_edge_class', 'fk_edge_type_class',
                  'ck_node_class', 'ck_node_type_class', 'ck_edge_class', 'ck_edge_type_class')
ORDER BY 1, 2;
-- expect the four fk_ rows and no ck_ rows

\echo ''
\echo '=== 3.3 v_edge_gaps is still empty ==='
SELECT count(*) AS edge_gaps FROM graph.v_edge_gaps;
-- expect 0

\echo ''
\echo '=== 3.4 Each guard refuses what it should ==='
DO $chk$
DECLARE
    probes TEXT[] := ARRAY[
        $$INSERT INTO graph.edge_type_endpoint VALUES ('SUPPLY_LV', 'MAIN_LV_BOARD', 'LAOD')$$,
        $$INSERT INTO graph.node_class VALUES ('SUB_BOARD', 'clash')$$,
        $$DELETE FROM graph.node_class WHERE code = 'LOAD'$$,
        $$DELETE FROM graph.node_class WHERE code = 'BUS'$$,
        $$UPDATE graph.edge SET edge_class = 'CABLE' WHERE id = (SELECT min(id) FROM graph.edge)$$
    ];
    p TEXT;
BEGIN
    FOREACH p IN ARRAY probes LOOP
        BEGIN
            EXECUTE p;
            RAISE EXCEPTION 'not refused: %', p;
        EXCEPTION
            WHEN raise_exception OR foreign_key_violation THEN
                IF SQLERRM LIKE 'not refused:%' THEN RAISE; END IF;
                RAISE NOTICE 'refused, as it should be: %  (%)', p, SQLERRM;
        END;
    END LOOP;
END
$chk$;
-- expect five "refused" notices: the misspelt kind, the clashing code, LOAD
-- (named by endpoint rules), BUS (used by nodes), and the retired CABLE class


-- ============================================================================
-- 4. Undo (commented) -- restores the check constraints of 024 and 032
-- ============================================================================
--
-- BEGIN;
-- REVOKE SELECT ON graph.node_class, graph.edge_class FROM "grafReader";
-- DROP TRIGGER trg_node_type_code ON graph.node_type;
-- DROP TRIGGER trg_node_class_code ON graph.node_class;
-- DROP TRIGGER trg_edge_type_endpoint_kind ON graph.edge_type_endpoint;
-- DROP FUNCTION graph.assert_kind_code();
-- DROP FUNCTION graph.assert_endpoint_kind();
-- ALTER TABLE graph.node      DROP CONSTRAINT fk_node_class;
-- ALTER TABLE graph.node_type DROP CONSTRAINT fk_node_type_class;
-- ALTER TABLE graph.edge      DROP CONSTRAINT fk_edge_class;
-- ALTER TABLE graph.edge_type DROP CONSTRAINT fk_edge_type_class;
-- ALTER TABLE graph.node ADD CONSTRAINT ck_node_class CHECK (node_class IN
--     ('SOURCE','BUS','CONVERSION','STORAGE','LOAD'));
-- ALTER TABLE graph.node_type ADD CONSTRAINT ck_node_type_class CHECK (node_class IN
--     ('SOURCE','BUS','CONVERSION','STORAGE','LOAD'));
-- ALTER TABLE graph.edge ADD CONSTRAINT ck_edge_class CHECK (edge_class IN
--     ('FEEDER','CABLE','BUSTIE','PIPE','HEADER_BRANCH','DUCT','CONVERSION','COMPENSATION'));
-- ALTER TABLE graph.edge_type ADD CONSTRAINT ck_edge_type_class CHECK (edge_class IN
--     ('FEEDER','CABLE','BUSTIE','PIPE','HEADER_BRANCH','DUCT','CONVERSION','COMPENSATION'));
-- COMMENT ON COLUMN graph.edge_type_endpoint.from_kind IS NULL;
-- COMMENT ON COLUMN graph.edge_type_endpoint.to_kind IS NULL;
-- DROP TABLE graph.edge_class;
-- DROP TABLE graph.node_class;
-- COMMIT;
