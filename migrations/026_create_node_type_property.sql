-- Migration: 026_create_node_type_property.sql
-- Description: Node types and typed properties for graph.node.attrs -- step 1
--              of an explicit ontology over the WAGES graph
-- Author: Claude
-- Date: 2026-09-28
--
-- Design: design/type-property.md (read that first; this file is
-- its implementation and the section numbers below match it).
-- Depends on: 025_rename_plts_nodes.sql, whose PLTS_A5 / PLTS_B2 codes are used
-- verbatim here.
--
-- Why: graph.node.attrs is free-form JSONB. Five scripts now read it and it is
-- failing in the usual ways -- FACTORY_AB carried voltage_level '400V' while
-- its meter reads 20,890 V and harmonics_report.py flagged it every week; the
-- same fact is spelled '400V', '20kV' and 400; equipment kind is stored as an
-- attribute ("type": "PV"); nameplates sit on the meter device rather than on
-- the machine. Nothing rejected any of it, because nothing knew what a voltage
-- looks like.
--
-- What this adds:
--   graph.property       one global vocabulary: datatype, unit, range, kind
--   graph.node_type      equipment types under the existing node_class
--   graph.type_property  which properties each type has, and who reads them
--   graph.node.node_type nullable FK, composite with node_class
--   graph.v_type_property  properties of a type including inherited ones
--   graph.v_property_gaps  what is missing, unknown, stale, untyped or invalid
--   trigger on graph.node validates every value that is present
--
-- Enforcement is deliberately split (design 2 #4). A value that IS present is
-- validated hard by the trigger. A required value that is ABSENT is reported by
-- v_property_gaps, never rejected: missing information is normal here and is
-- exactly what the site-check list is built from.
--
-- The solver reads none of this (design 2 #8). node_type is descriptive, like
-- node_class. solve_flow, get_node_values, get_sankey_flow, get_node_quantity
-- and the 016 topology primitives are untouched, so any difference in their
-- output is a bug, not an expected effect.
--
-- Sources for the seeded data, all reviewed with the user 2026-09-28:
--   design/trafo_tenant_3.csv           12 transformer ratings
--   design/draft_current_ratings_mapped.csv  site breaker survey
--   PLN bill: tariff I-3, 7,585,000 VA contracted
--   devices.metadata.nameplate for 5 compressors that map 1:1 to a node
--
-- Also needed, outside SQL, shipping with this migration (design 5): the
-- voltage_level -> nominal_v rename breaks the old readers on purpose, so
-- harmonics_report.py, layered_report.py and graph_snapshot.py in
-- ../pq-analysis change in the same release, as do wages_sync.py and
-- graph_seed_export.py here.
--
-- ============================================================================
-- 1. Evidence -- read-only. Run this first and read it.
-- ============================================================================

SELECT 'Attrs in use today (expect 21 rows: 11 banks + 10 others)' AS check_name;
SELECT node_code, node_class, attrs FROM graph.node
WHERE tenant_id = 3 AND attrs <> '{}'::jsonb ORDER BY node_code;

SELECT 'Distinct attr keys in use (expect 13)' AS check_name;
SELECT k, count(*) FROM graph.node, LATERAL jsonb_object_keys(attrs) k
WHERE tenant_id = 3 GROUP BY k ORDER BY k;

SELECT 'Nodes by class (expect SOURCE 11, BUS 27, CONVERSION 29, STORAGE 21, LOAD 98 active / 100 total)' AS check_name;
SELECT node_class, count(*) FILTER (WHERE is_active) AS active, count(*) AS total
FROM graph.node WHERE tenant_id = 3 GROUP BY node_class ORDER BY node_class;

SELECT '025 must have run first (expect PLTS_A5 and PLTS_B2)' AS check_name;
SELECT node_code FROM graph.node
WHERE tenant_id = 3 AND node_code LIKE 'PLTS%' ORDER BY node_code;

-- ============================================================================
-- 2. Schema (design 3)
-- ============================================================================

BEGIN;

-- 2.1 The vocabulary. One row per attrs key, globally: a key has one datatype,
--     one unit and one meaning everywhere. Types select properties; they never
--     redefine them.
CREATE TABLE graph.property (
    attr_key         VARCHAR(40) PRIMARY KEY,
    datatype         VARCHAR(12) NOT NULL,
    unit             VARCHAR(12),              -- display only; the key name carries it too
    enum_values      TEXT[],
    min_value        NUMERIC,
    max_value        NUMERIC,
    kind             VARCHAR(12) NOT NULL,
    as_of_key        VARCHAR(40) REFERENCES graph.property (attr_key),
    stale_after_days INTEGER,
    description      TEXT        NOT NULL,
    external_ref     VARCHAR(120),

    CONSTRAINT ck_prop_key      CHECK (attr_key ~ '^[a-z][a-z0-9_]*$'),
    CONSTRAINT ck_prop_datatype CHECK (datatype IN
        ('number','integer','text','enum','boolean','date','number[]')),
    CONSTRAINT ck_prop_enum     CHECK ((datatype = 'enum') = (enum_values IS NOT NULL)),
    CONSTRAINT ck_prop_range    CHECK (datatype IN ('number','integer','number[]')
                                       OR (min_value IS NULL AND max_value IS NULL)),
    CONSTRAINT ck_prop_bounds   CHECK (min_value IS NULL OR max_value IS NULL
                                       OR min_value <= max_value),
    CONSTRAINT ck_prop_kind     CHECK (kind IN ('NAMEPLATE','DESIGN','SITE_STATUS','RECORD')),
    -- a SITE_STATUS property needs both; anything else must have neither, so a
    -- stray stale_after_days cannot sit on a key that never goes stale
    CONSTRAINT ck_prop_status   CHECK (
        (kind =  'SITE_STATUS' AND as_of_key IS NOT NULL AND stale_after_days IS NOT NULL)
     OR (kind <> 'SITE_STATUS' AND as_of_key IS NULL     AND stale_after_days IS NULL))
);

COMMENT ON TABLE graph.property IS
    'Vocabulary for graph.node.attrs: one row per key, global across tenants.';
COMMENT ON COLUMN graph.property.kind IS
    'Where a missing value has to come from: NAMEPLATE = read the plate on site; '
    'DESIGN = ask engineering; SITE_STATUS = a scheduled site check, goes stale; '
    'RECORD = bookkeeping about another property, never reported on its own.';

-- 2.2 Types, under the existing node_class. Single parent, so a subtype
--     inherits its parent's properties.
CREATE TABLE graph.node_type (
    code         VARCHAR(40) PRIMARY KEY,
    node_class   VARCHAR(20) NOT NULL,
    parent_code  VARCHAR(40),
    name         VARCHAR(80) NOT NULL,
    description  TEXT,
    external_ref VARCHAR(120),

    CONSTRAINT uq_node_type_class  UNIQUE (code, node_class),
    -- a subtype is always in its parent's class
    CONSTRAINT fk_node_type_parent FOREIGN KEY (parent_code, node_class)
        REFERENCES graph.node_type (code, node_class),
    CONSTRAINT ck_node_type_code   CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    CONSTRAINT ck_node_type_class  CHECK (node_class IN
        ('SOURCE','BUS','DISTRIBUTION','CONVERSION','STORAGE','LOAD')),
    CONSTRAINT ck_node_type_noself CHECK (parent_code IS NULL OR parent_code <> code)
);

-- The composite FK is the same device 4.3 uses for tenants: a node cannot be
-- typed AIR_COMPRESSOR while classed LOAD, and no trigger is needed. node_type
-- stays nullable, so the 100 untyped loads are legal (MATCH SIMPLE skips the
-- check on NULL) and simply report as UNTYPED.
ALTER TABLE graph.node ADD COLUMN node_type VARCHAR(40);
ALTER TABLE graph.node ADD CONSTRAINT fk_node_node_type
    FOREIGN KEY (node_type, node_class) REFERENCES graph.node_type (code, node_class);
CREATE INDEX idx_node_type ON graph.node (node_type) WHERE node_type IS NOT NULL;

COMMENT ON COLUMN graph.node.node_type IS
    'What the equipment is. Descriptive only -- the flow solver never reads it. '
    'Distinct from graph.category (15), which is what the business reports it under. '
    'Reclassification must set node_class and node_type together or the FK fails.';

-- 2.3 Which type has which property, and who reads it. A property may be
--     REQUIRED only if used_by names a reader (design 2 #7): that rule is what
--     keeps the gap list short enough to act on.
CREATE TABLE graph.type_property (
    node_type   VARCHAR(40) NOT NULL REFERENCES graph.node_type (code),
    attr_key    VARCHAR(40) NOT NULL REFERENCES graph.property (attr_key),
    requirement VARCHAR(10) NOT NULL DEFAULT 'OPTIONAL',
    used_by     TEXT,

    PRIMARY KEY (node_type, attr_key),
    CONSTRAINT ck_tp_requirement CHECK (requirement IN ('REQUIRED','OPTIONAL')),
    CONSTRAINT ck_tp_used_by     CHECK (requirement = 'OPTIONAL' OR used_by IS NOT NULL)
);

-- Properties a type has, including those inherited from its ancestors.
-- The nearest definition wins, so a subtype can tighten OPTIONAL to REQUIRED.
CREATE VIEW graph.v_type_property AS
WITH RECURSIVE lineage (node_type, ancestor, depth) AS (
    SELECT code, code, 0 FROM graph.node_type
    UNION
    SELECT l.node_type, t.parent_code, l.depth + 1
    FROM lineage l
    JOIN graph.node_type t ON t.code = l.ancestor
    WHERE t.parent_code IS NOT NULL
      AND l.depth < 10                      -- the type tree is authored; bound it anyway
)
SELECT DISTINCT ON (l.node_type, tp.attr_key)
       l.node_type, tp.attr_key, tp.requirement, tp.used_by,
       l.ancestor AS defined_on, l.depth
FROM lineage l
JOIN graph.type_property tp ON tp.node_type = l.ancestor
ORDER BY l.node_type, tp.attr_key, l.depth;

-- 2.4 One function decides whether a value is valid. The trigger, the gap view
--     and the wages_sync.py pre-flight all call it, so the three cannot drift
--     apart.
CREATE OR REPLACE FUNCTION graph.property_value_ok(p graph.property, v JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
    n NUMERIC;
BEGIN
    CASE p.datatype
    WHEN 'number', 'integer' THEN
        IF jsonb_typeof(v) <> 'number' THEN RETURN FALSE; END IF;
        n := (v #>> '{}')::numeric;
        IF p.datatype = 'integer' AND n <> trunc(n) THEN RETURN FALSE; END IF;
        RETURN (p.min_value IS NULL OR n >= p.min_value)
           AND (p.max_value IS NULL OR n <= p.max_value);
    WHEN 'number[]' THEN
        IF jsonb_typeof(v) <> 'array' OR jsonb_array_length(v) = 0 THEN RETURN FALSE; END IF;
        RETURN NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(v) e
            WHERE CASE WHEN jsonb_typeof(e) <> 'number' THEN TRUE   -- CASE, not OR: the cast
                       ELSE (p.min_value IS NOT NULL AND (e #>> '{}')::numeric < p.min_value)
                         OR (p.max_value IS NOT NULL AND (e #>> '{}')::numeric > p.max_value)
                  END);
    WHEN 'text'    THEN RETURN jsonb_typeof(v) = 'string';
    WHEN 'enum'    THEN RETURN jsonb_typeof(v) = 'string' AND (v #>> '{}') = ANY (p.enum_values);
    WHEN 'boolean' THEN RETURN jsonb_typeof(v) = 'boolean';
    WHEN 'date'    THEN RETURN jsonb_typeof(v) = 'string'
                           AND (v #>> '{}') ~ '^\d{4}-\d{2}-\d{2}$'
                           AND pg_input_is_valid(v #>> '{}', 'date');
    ELSE RETURN FALSE;
    END CASE;
END;
$fn$;

CREATE OR REPLACE FUNCTION graph.assert_node_attrs() RETURNS TRIGGER AS $fn$
DECLARE
    k TEXT;
    v JSONB;
    p graph.property%ROWTYPE;
BEGIN
    IF jsonb_typeof(NEW.attrs) <> 'object' THEN
        RAISE EXCEPTION 'graph.node %: attrs must be a JSON object', NEW.node_code;
    END IF;

    FOR k, v IN SELECT * FROM jsonb_each(NEW.attrs) LOOP
        SELECT * INTO p FROM graph.property WHERE attr_key = k;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'graph.node %: attrs key "%" is not defined in graph.property',
                NEW.node_code, k;
        END IF;

        IF NEW.node_type IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM graph.v_type_property t
               WHERE t.node_type = NEW.node_type AND t.attr_key = k) THEN
            RAISE EXCEPTION 'graph.node %: "%" is not a property of type %. Allowed: %',
                NEW.node_code, k, NEW.node_type,
                (SELECT string_agg(attr_key, ', ' ORDER BY attr_key)
                   FROM graph.v_type_property WHERE node_type = NEW.node_type);
        END IF;

        CONTINUE WHEN jsonb_typeof(v) = 'null';          -- asked, not yet answered (design 2 #5)

        IF NOT graph.property_value_ok(p, v) THEN
            RAISE EXCEPTION 'graph.node %: % = % is not a valid %',
                NEW.node_code, k, v,
                p.datatype
                || CASE WHEN p.enum_values IS NOT NULL
                        THEN ' (one of ' || array_to_string(p.enum_values, ', ') || ')' ELSE '' END
                || CASE WHEN p.min_value IS NOT NULL OR p.max_value IS NOT NULL
                        THEN rtrim(format(' in [%s, %s] %s',
                                          p.min_value, p.max_value, COALESCE(p.unit, '')))
                        ELSE '' END;
        END IF;
    END LOOP;
    RETURN NEW;
END;
$fn$ LANGUAGE plpgsql;

-- 2.5 The gap view. Missing values are reported here, not rejected.
CREATE VIEW graph.v_property_gaps AS
-- Required, and never recorded (MISSING) or asked but unanswered (UNKNOWN)
SELECT n.tenant_id, n.node_code, n.node_name, n.node_class, n.node_type,
       t.attr_key, p.kind,
       CASE WHEN n.attrs ? t.attr_key THEN 'UNKNOWN' ELSE 'MISSING' END AS status,
       t.used_by, NULL::TEXT AS detail
FROM graph.node n
JOIN graph.v_type_property t ON t.node_type = n.node_type AND t.requirement = 'REQUIRED'
JOIN graph.property p        ON p.attr_key  = t.attr_key
WHERE n.is_active
  AND jsonb_typeof(COALESCE(n.attrs -> t.attr_key, 'null'::jsonb)) = 'null'

UNION ALL
-- Site status older than its shelf life (or with no date at all)
SELECT n.tenant_id, n.node_code, n.node_name, n.node_class, n.node_type,
       t.attr_key, p.kind, 'STALE', t.used_by,
       'as of ' || COALESCE(n.attrs ->> p.as_of_key, 'never')
FROM graph.node n
JOIN graph.v_type_property t ON t.node_type = n.node_type
JOIN graph.property p        ON p.attr_key  = t.attr_key AND p.kind = 'SITE_STATUS'
WHERE n.is_active
  AND jsonb_typeof(COALESCE(n.attrs -> t.attr_key, 'null'::jsonb)) <> 'null'
  AND COALESCE((n.attrs ->> p.as_of_key)::date, '-infinity'::date)
      < CURRENT_DATE - p.stale_after_days

UNION ALL
-- No type yet: nothing can be said about what it should carry
SELECT n.tenant_id, n.node_code, n.node_name, n.node_class, n.node_type,
       NULL, NULL, 'UNTYPED', NULL, NULL
FROM graph.node n
WHERE n.is_active AND n.node_type IS NULL

UNION ALL
-- A stored value the current vocabulary no longer accepts. The trigger checks a
-- row when that row is written; if the vocabulary is narrowed later, existing
-- rows are not rechecked, and this is what catches that.
SELECT n.tenant_id, n.node_code, n.node_name, n.node_class, n.node_type,
       a.k, p.kind, 'INVALID', NULL, a.k || ' = ' || a.v::text
FROM graph.node n
CROSS JOIN LATERAL jsonb_each(n.attrs) a (k, v)
LEFT JOIN graph.property p ON p.attr_key = a.k
WHERE n.is_active
  AND (   p.attr_key IS NULL
       OR (jsonb_typeof(a.v) <> 'null' AND NOT graph.property_value_ok(p, a.v))
       OR (n.node_type IS NOT NULL AND NOT EXISTS (
               SELECT 1 FROM graph.v_type_property t
               WHERE t.node_type = n.node_type AND t.attr_key = a.k)));

-- 010 set default privileges for grafReader on this schema, which covers tables
-- and views created here; these are explicit so the file does not depend on it.
GRANT SELECT ON graph.property, graph.node_type, graph.type_property,
                graph.v_type_property, graph.v_property_gaps TO "grafReader";
GRANT EXECUTE ON FUNCTION graph.property_value_ok(graph.property, JSONB) TO "grafReader";

-- ============================================================================
-- 3. Seed the vocabulary (design 4.1)
--
-- Keys already in live use keep their names. The one exception is
-- voltage_level, which changes datatype and is renamed to nominal_v so that a
-- stale reader fails loudly instead of parsing a number out of a string.
-- "type" is not in the vocabulary at all: its only value, 'PV', becomes
-- node_type = 'PV_PLANT'.
--
-- site_status_as_of is inserted first: site_status references it as as_of_key.
-- ============================================================================

INSERT INTO graph.property
    (attr_key, datatype, unit, enum_values, min_value, max_value, kind,
     as_of_key, stale_after_days, description) VALUES
    ('site_status_as_of', 'date', NULL, NULL, NULL, NULL, 'RECORD', NULL, NULL,
     'Date the site last reported site_status. Bookkeeping for site_status; never reported as a gap on its own.'),
    ('nominal_v', 'number', 'V', NULL, 100, 150000, 'DESIGN', NULL, NULL,
     'Nominal line-to-line voltage of this node, in volts. Replaces the free-text voltage_level.'),
    ('rated_kva', 'number', 'kVA', NULL, 1, 100000, 'NAMEPLATE', NULL, NULL,
     'Apparent power rating. On a transformer-fed board this is the supplying transformer''s rating, and it is the loading denominator for that board.'),
    ('rated_a', 'number', 'A', NULL, 1, 10000, 'NAMEPLATE', NULL, NULL,
     'Continuous current rating. Not the breaker frame size -- see main_breaker_a.'),
    ('main_breaker_a', 'number', 'A', NULL, 1, 10000, 'NAMEPLATE', NULL, NULL,
     'Frame size of the breaker protecting this panel or way, in amps at this node''s own voltage. A trip threshold, not a capacity: on every transformer-fed board it is the next standard frame above the transformer''s full-load amps.'),
    ('tx_primary_v', 'number', 'V', NULL, 100, 150000, 'NAMEPLATE', NULL, NULL,
     'Primary voltage of the transformer supplying this board.'),
    ('tx_impedance_pct', 'number', '%', NULL, 1, 20, 'NAMEPLATE', NULL, NULL,
     'Short-circuit impedance of the supplying transformer. Gives Isc, which turns the IEEE 519 Isc/I_L yardstick into an actual limit.'),
    ('rated_kw', 'number', 'kW', NULL, 0.1, 50000, 'NAMEPLATE', NULL, NULL,
     'Rated electrical input power of a machine (compressor, engine, motor).'),
    ('rated_kwp', 'number', 'kWp', NULL, 0.1, 50000, 'NAMEPLATE', NULL, NULL,
     'PV array DC peak power.'),
    ('fuel', 'enum', NULL, ARRAY['NATURAL_GAS', 'DIESEL', 'LPG', 'COAL', 'BIOMASS'], NULL, NULL, 'NAMEPLATE', NULL, NULL,
     'Fuel burned by this unit.'),
    ('contract_kva', 'number', 'kVA', NULL, 1, 100000, 'DESIGN', NULL, NULL,
     'PLN contracted capacity (daya tersambung). A commercial limit, not a property of equipment, and the correct loading denominator at the point of common coupling.'),
    ('tariff_code', 'enum', NULL, ARRAY['I3', 'I4', 'B3'], NULL, NULL, 'DESIGN', NULL, NULL,
     'PLN tariff group, which decides which charges apply.'),
    ('drive', 'enum', NULL, ARRAY['FIXED', 'VSD'], NULL, NULL, 'NAMEPLATE', NULL, NULL,
     'Compressor drive type.'),
    ('rated_flow_nm3min', 'number', 'Nm3/min', NULL, 0.1, 1000, 'NAMEPLATE', NULL, NULL,
     'Rated free air delivery. With rated_kw this gives specific power once the air meters are in.'),
    ('rated_pressure_bar', 'number', 'bar(g)', NULL, 0.5, 50, 'NAMEPLATE', NULL, NULL,
     'Rated discharge pressure.'),
    ('rated_steam_kgh', 'number', 'kg/h', NULL, 10, 100000, 'NAMEPLATE', NULL, NULL,
     'Boiler rated steam output.'),
    ('volume_m3', 'number', 'm3', NULL, 0.1, 100000, 'NAMEPLATE', NULL, NULL,
     'Tank capacity. Needed for the storage term in the water balance.'),
    ('rated_kvar', 'number', 'kVAr', NULL, 1, 10000, 'NAMEPLATE', NULL, NULL,
     'Capacitor bank total rated reactive power.'),
    ('rated_v', 'number', 'V', NULL, 100, 50000, 'NAMEPLATE', NULL, NULL,
     'Capacitor rated voltage. Deliberately separate from nominal_v: a detuned bank is rated above system voltage.'),
    ('steps', 'integer', NULL, NULL, 1, 32, 'NAMEPLATE', NULL, NULL,
     'Number of switchable capacitor steps.'),
    ('step_kvar', 'number[]', 'kVAr', NULL, 1, 5000, 'NAMEPLATE', NULL, NULL,
     'kVAr of each step, in order. Sums to rated_kvar.'),
    ('control', 'enum', NULL, ARRAY['APFC', 'FIXED', 'MANUAL'], NULL, NULL, 'DESIGN', NULL, NULL,
     'How the bank is switched.'),
    ('target_pf', 'number', NULL, NULL, 0.8, 1.0, 'DESIGN', NULL, NULL,
     'Power factor the controller aims for.'),
    ('detuned_pct', 'number', '%', NULL, 0, 20, 'NAMEPLATE', NULL, NULL,
     'Detuning reactor rating as a percentage. NULL on all 11 banks: asked, not yet answered.'),
    ('site_status', 'enum', NULL, ARRAY['normal', 'inactive'], NULL, NULL, 'SITE_STATUS', 'site_status_as_of', 90,
     'What the site reports about this unit''s operating state.');

-- ============================================================================
-- 4. Seed the types (design 4.2)
--
-- SWITCHBOARD and WATER_TREATMENT are abstract: they exist to hold shared
-- properties and are never assigned to a node. Parents are inserted before
-- children because of fk_node_type_parent.
-- ============================================================================

INSERT INTO graph.node_type (code, node_class, parent_code, name, description, external_ref) VALUES
    ('GRID_INCOMER', 'SOURCE', NULL, 'Grid incomer',
     'Utility supply at the point of common coupling.', 'brick:Electrical_Meter'),
    ('PV_PLANT', 'SOURCE', NULL, 'PV plant',
     'Rooftop or ground-mount photovoltaic array.', 'brick:PV_Array'),
    ('GAS_ENGINE', 'SOURCE', NULL, 'Gas engine',
     'Reciprocating gas engine generator.', 'brick:Generator'),
    ('WATER_INTAKE', 'SOURCE', NULL, 'Water intake',
     'Raw water entering the site.', NULL),
    ('SWITCHBOARD', 'BUS', NULL, 'Switchboard',
     'Abstract: any board or bus. Not assigned to nodes directly.', 'brick:Switchgear'),
    ('MV_BUS', 'BUS', 'SWITCHBOARD', 'MV bus',
     'Medium-voltage bus upstream of the distribution transformers.', NULL),
    ('MAIN_LV_BOARD', 'BUS', 'SWITCHBOARD', 'Main LV board',
     'LV board fed by its own distribution transformer.', NULL),
    ('SUB_BOARD', 'BUS', 'SWITCHBOARD', 'Sub board',
     'LV board fed from another board, with no transformer in between.', NULL),
    ('AIR_COMPRESSOR', 'CONVERSION', NULL, 'Air compressor',
     'Electricity to compressed air.', 'brick:Air_Compressor'),
    ('BOILER', 'CONVERSION', NULL, 'Boiler',
     'Fuel to steam.', 'brick:Boiler'),
    ('WATER_TREATMENT', 'CONVERSION', NULL, 'Water treatment unit',
     'Abstract: any water treatment stage.', NULL),
    ('CLARIFIER', 'CONVERSION', 'WATER_TREATMENT', 'Clarifier',
     'Settling stage.', NULL),
    ('SOFTENER', 'CONVERSION', 'WATER_TREATMENT', 'Softener',
     'Ion-exchange hardness removal.', NULL),
    ('RO_UNIT', 'CONVERSION', 'WATER_TREATMENT', 'RO unit',
     'Reverse osmosis stage.', NULL),
    ('REACTION_TANK', 'CONVERSION', 'WATER_TREATMENT', 'Reaction tank',
     'Chemical dosing and reaction stage.', NULL),
    ('CAPACITOR_BANK', 'STORAGE', NULL, 'Capacitor bank',
     'Power factor correction bank.', NULL),
    ('WATER_TANK', 'STORAGE', NULL, 'Water tank',
     'Stored water.', 'brick:Water_Tank'),
    ('PRODUCTION_MACHINE', 'LOAD', NULL, 'Production machine',
     'Process machinery.', NULL),
    ('AHU', 'LOAD', NULL, 'Air handling unit',
     'Air handling unit.', 'brick:Air_Handling_Unit'),
    ('LIGHTING', 'LOAD', NULL, 'Lighting',
     'Lighting load.', 'brick:Lighting_System'),
    ('PUMP', 'LOAD', NULL, 'Pump',
     'Pump load.', 'brick:Pump'),
    ('GENERIC_LOAD', 'LOAD', NULL, 'Generic load',
     'A load not yet classified further.', NULL);

-- Every REQUIRED row names its reader (design 2 #7). Anything without a reader
-- today is OPTIONAL and gets promoted when a reader appears -- detuned_pct is
-- the standing example: pf_report.py warns about resonance in prose but does
-- not read the value, so it stays OPTIONAL.
INSERT INTO graph.type_property (node_type, attr_key, requirement, used_by) VALUES
    ('GRID_INCOMER', 'nominal_v', 'REQUIRED', 'harmonics_report.py voltage cross-check'),
    ('GRID_INCOMER', 'contract_kva', 'REQUIRED', 'harmonics_report.py loading denominator at the PCC'),
    ('GRID_INCOMER', 'main_breaker_a', 'OPTIONAL', NULL),
    ('GRID_INCOMER', 'tariff_code', 'OPTIONAL', NULL),
    ('PV_PLANT', 'rated_kwp', 'OPTIONAL', NULL),
    ('PV_PLANT', 'nominal_v', 'OPTIONAL', NULL),
    ('PV_PLANT', 'main_breaker_a', 'OPTIONAL', NULL),
    ('GAS_ENGINE', 'fuel', 'OPTIONAL', NULL),
    ('GAS_ENGINE', 'rated_kw', 'OPTIONAL', NULL),
    ('GAS_ENGINE', 'nominal_v', 'OPTIONAL', NULL),
    ('SWITCHBOARD', 'nominal_v', 'REQUIRED', 'harmonics_report.py voltage cross-check, layered_report.py'),
    ('SWITCHBOARD', 'rated_a', 'OPTIONAL', NULL),
    ('SWITCHBOARD', 'main_breaker_a', 'OPTIONAL', NULL),
    ('MAIN_LV_BOARD', 'rated_kva', 'REQUIRED', 'harmonics_report.py loading denominator'),
    ('MAIN_LV_BOARD', 'tx_primary_v', 'OPTIONAL', NULL),
    ('MAIN_LV_BOARD', 'tx_impedance_pct', 'OPTIONAL', NULL),
    ('SUB_BOARD', 'main_breaker_a', 'REQUIRED', 'harmonics_report.py loading denominator and small-load filter'),
    ('AIR_COMPRESSOR', 'rated_kw', 'REQUIRED', 'harmonics_report.py rating fallback'),
    ('AIR_COMPRESSOR', 'drive', 'OPTIONAL', NULL),
    ('AIR_COMPRESSOR', 'rated_flow_nm3min', 'OPTIONAL', NULL),
    ('AIR_COMPRESSOR', 'rated_pressure_bar', 'OPTIONAL', NULL),
    ('AIR_COMPRESSOR', 'nominal_v', 'OPTIONAL', NULL),
    ('AIR_COMPRESSOR', 'main_breaker_a', 'OPTIONAL', NULL),
    ('BOILER', 'fuel', 'OPTIONAL', NULL),
    ('BOILER', 'rated_steam_kgh', 'OPTIONAL', NULL),
    ('BOILER', 'main_breaker_a', 'OPTIONAL', NULL),
    ('WATER_TREATMENT', 'volume_m3', 'OPTIONAL', NULL),
    ('CAPACITOR_BANK', 'rated_kvar', 'REQUIRED', 'pf_report.py'),
    ('CAPACITOR_BANK', 'step_kvar', 'REQUIRED', 'pf_report.py'),
    ('CAPACITOR_BANK', 'control', 'REQUIRED', 'pf_report.py'),
    ('CAPACITOR_BANK', 'target_pf', 'REQUIRED', 'pf_report.py'),
    ('CAPACITOR_BANK', 'site_status', 'REQUIRED', 'pf_report.py'),
    ('CAPACITOR_BANK', 'site_status_as_of', 'REQUIRED', 'pf_report.py'),
    ('CAPACITOR_BANK', 'rated_v', 'OPTIONAL', NULL),
    ('CAPACITOR_BANK', 'steps', 'OPTIONAL', NULL),
    ('CAPACITOR_BANK', 'detuned_pct', 'OPTIONAL', NULL),
    ('WATER_TANK', 'volume_m3', 'OPTIONAL', NULL),
    ('PRODUCTION_MACHINE', 'rated_kw', 'OPTIONAL', NULL),
    ('PRODUCTION_MACHINE', 'nominal_v', 'OPTIONAL', NULL),
    ('PRODUCTION_MACHINE', 'main_breaker_a', 'OPTIONAL', NULL),
    ('AHU', 'rated_kw', 'OPTIONAL', NULL),
    ('AHU', 'nominal_v', 'OPTIONAL', NULL),
    ('AHU', 'main_breaker_a', 'OPTIONAL', NULL),
    ('LIGHTING', 'rated_kw', 'OPTIONAL', NULL),
    ('LIGHTING', 'nominal_v', 'OPTIONAL', NULL),
    ('LIGHTING', 'main_breaker_a', 'OPTIONAL', NULL),
    ('PUMP', 'rated_kw', 'OPTIONAL', NULL),
    ('PUMP', 'nominal_v', 'OPTIONAL', NULL),
    ('PUMP', 'main_breaker_a', 'OPTIONAL', NULL),
    ('GENERIC_LOAD', 'rated_kw', 'OPTIONAL', NULL),
    ('GENERIC_LOAD', 'nominal_v', 'OPTIONAL', NULL),
    ('GENERIC_LOAD', 'main_breaker_a', 'OPTIONAL', NULL);

-- ============================================================================
-- 5. Assign types to nodes (design 4.2)
--
-- By explicit node_code list, never by LIKE pattern: a pattern silently
-- includes the next node that happens to match. The 100 LOAD nodes stay
-- untyped -- typing them is an authoring pass with the engineers through the
-- review export, not something to guess in a migration. Two of them
-- (MC302_BARU, MC303_BARU) are retired: is_active FALSE, so v_property_gaps
-- leaves them out and UNTYPED reports 98, not 100.
-- ============================================================================

UPDATE graph.node SET node_type = 'GRID_INCOMER', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 1
    'INCOMING_PLN');

UPDATE graph.node SET node_type = 'PV_PLANT', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 4
    'PLTS_A4', 'PLTS_A5', 'PLTS_B2', 'PLTS_TEXTURE');

UPDATE graph.node SET node_type = 'GAS_ENGINE', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 1
    'GAS_ENGINE');

UPDATE graph.node SET node_type = 'WATER_INTAKE', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 5
    'WTP1_IN_1', 'WTP1_IN_2', 'WTP1_RAN', 'WTP2_IN_1', 'WTP2_IN_2');

UPDATE graph.node SET node_type = 'MV_BUS', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 1
    'FACTORY_AB');

UPDATE graph.node SET node_type = 'MAIN_LV_BOARD', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 12
    'LVMDB_A1', 'LVMDB_A2', 'LVMDB_A3', 'LVMDB_A4', 'LVMDB_A5', 'LVMDB_B2',
    'LVMDB_TEXTURE', 'LVMDB_TEXTURE_2', 'LVMDB_TF630', 'LVMDP_SPINNING_1',
    'LVMDP_SPINNING_2', 'LVMDP_SPINNING_3');

UPDATE graph.node SET node_type = 'SUB_BOARD', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 14
    'AJL2', 'COMP_INTERLACE', 'COMP_KAESER', 'COMP_WINDER', 'FINISHING_22',
    'LVSDP_COMP_23', 'LVSDP_PROD_ATY', 'LVSDP_SP2_1', 'LVSDP_SP2_2',
    'MC_RWD', 'TRICOT', 'TWIST_PANEL', 'WARPING', 'WJL1');

UPDATE graph.node SET node_type = 'AIR_COMPRESSOR', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 19
    'COMPRESSOR_CUCUK', 'COMP_100HP', 'COMP_AIKI', 'COMP_ELITE',
    'COMP_FS_INT_1', 'COMP_FS_INT_2', 'COMP_FS_INT_4', 'COMP_FS_WIND_1',
    'COMP_FS_WIND_2', 'COMP_FS_WIND_4', 'COMP_FUSHENG300HP',
    'COMP_NVX_INT_3', 'COMP_NVX_WND_3', 'COMP_SCR2200', 'COM_SCR_WIND_5',
    'KAESER_1', 'KAESER_2', 'KAESER_3', 'KAESER_4');

UPDATE graph.node SET node_type = 'BOILER', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 1
    'BOILER_MIURA');

UPDATE graph.node SET node_type = 'CAPACITOR_BANK', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 11
    'CB_A1', 'CB_A2', 'CB_A3', 'CB_A4', 'CB_A5', 'CB_B2', 'CB_MDP1',
    'CB_MDP2', 'CB_MDP3', 'CB_SPINNING_3', 'CB_TEXTURE_1600');

UPDATE graph.node SET node_type = 'WATER_TANK', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 10
    'WTP1_BIO', 'WTP1_RAW', 'WTP1_SOFT', 'WTP2_DEL', 'WTP2_EQL',
    'WTP2_HW_1', 'WTP2_HW_2', 'WTP2_RAW', 'WTP2_RO_TANK', 'WTP2_SOFT');

UPDATE graph.node SET node_type = 'CLARIFIER', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 2
    'WTP1_CLR', 'WTP2_CLR');

UPDATE graph.node SET node_type = 'SOFTENER', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 5
    'WTP1_SOFT_1', 'WTP1_SOFT_2', 'WTP2_SOFT_3', 'WTP2_SOFT_4',
    'WTP2_SOFT_5');

UPDATE graph.node SET node_type = 'RO_UNIT', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 1
    'WTP2_RO_PROC');

UPDATE graph.node SET node_type = 'REACTION_TANK', updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 1
    'WTP2_REACT');

-- ============================================================================
-- 6. Data changes (design 4.3)
-- ============================================================================

-- 6.1 voltage_level -> nominal_v, as a number.
--     FACTORY_AB is CORRECTED, not just converted: it carried '400V' but its
--     meter reads 20,890 V L-L, and the six boards below it each have their own
--     20/0.4 kV transformer, so it is the 20 kV bus. harmonics_report.py has
--     raised VOLTAGE_ATTR_MISMATCH on it every week. Confirmed by the user
--     2026-09-28.
UPDATE graph.node
   SET attrs = (attrs - 'voltage_level') || jsonb_build_object('nominal_v', 20000),
       updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN ('INCOMING_PLN', 'FACTORY_AB');

-- 6.2 "type": "PV" is now carried by node_type = 'PV_PLANT' (set in section 5).
UPDATE graph.node
   SET attrs = attrs - 'type', updated_at = NOW()
 WHERE tenant_id = 3 AND attrs ? 'type';

-- 6.3 Transformers, from design/trafo_tenant_3.csv. Each of the
--     12 main boards gets its transformer's rating, the primary voltage and
--     nominal_v = 400. The 3 ratings already in the graph (1600, 2000, 630)
--     agree with the CSV. The CSV spells five before_node codes wrong
--     (LVMBD_A2..A5, LVMBD_TF630); they are mapped by hand below rather than
--     fuzzy-matched. Source confirmed by the user 2026-09-28.
UPDATE graph.node n SET attrs = n.attrs || jsonb_build_object(
           'rated_kva', v.kva, 'tx_primary_v', 20000, 'nominal_v', 400),
       updated_at = NOW()
  FROM (VALUES
    ('LVMDB_A1', 2000),
    ('LVMDB_A2', 2000),
    ('LVMDB_A3', 2000),
    ('LVMDB_A4', 2000),
    ('LVMDB_A5', 2000),
    ('LVMDB_B2', 2000),
    ('LVMDB_TEXTURE', 1600),
    ('LVMDB_TEXTURE_2', 2000),
    ('LVMDB_TF630', 630),
    ('LVMDP_SPINNING_1', 2000),
    ('LVMDP_SPINNING_2', 1600),
    ('LVMDP_SPINNING_3', 2000)
       ) AS v (node_code, kva)
 WHERE n.tenant_id = 3 AND n.node_code = v.node_code;

-- 6.4 Sub-board nominal_v = 400. DERIVED FROM TOPOLOGY, not read off a plate:
--     every sub-board is fed at 400 V with no transformer in between. If any of
--     them is not, harmonics_report.py's voltage cross-check against the meter
--     will say so.
UPDATE graph.node
   SET attrs = attrs || jsonb_build_object('nominal_v', 400), updated_at = NOW()
 WHERE tenant_id = 3 AND node_code IN (   -- 14
    'AJL2', 'COMP_INTERLACE', 'COMP_KAESER', 'COMP_WINDER', 'FINISHING_22',
    'LVSDP_COMP_23', 'LVSDP_PROD_ATY', 'LVSDP_SP2_1', 'LVSDP_SP2_2',
    'MC_RWD', 'TRICOT', 'TWIST_PANEL', 'WARPING', 'WJL1');

-- 6.5 main_breaker_a, from the site survey
--     (design/draft_current_ratings_mapped.csv, received
--     2026-09-28). 60 of the survey's 63 rows map to a node; each mapping was
--     confirmed against fed_by by ancestry, not by name.
--
--     These are breaker FRAME SIZES, not capacities. On every transformer-fed
--     board the frame is the next standard size above the transformer's
--     full-load amps -- 3200 A over 2887 A for a 2000 kVA unit, 1250 A over
--     909 A for the 630 kVA. That is why rated_kva, not this, is the loading
--     denominator on a MAIN_LV_BOARD, and why this is the denominator on a
--     SUB_BOARD, which has no transformer in between (design 4.2).
--
--     INCOMING_PLN and FACTORY_AB are 630 A AT 20 kV -- the standard MV cubicle
--     rating, about 21.8 MVA -- not an LV frame.
UPDATE graph.node n SET attrs = n.attrs || jsonb_build_object('main_breaker_a', v.a),
       updated_at = NOW()
  FROM (VALUES
    ('AHU_10_11', 100),
    ('AHU_12_13', 100),
    ('AHU_14', 63),
    ('AHU_2_3', 400),
    ('AHU_4_7', 400),
    ('AIR_DRYER', 250),
    ('AJL1', 800),
    ('AJL2', 800),
    ('BOILER_MIURA', 400),
    ('CELUP_1A', 800),
    ('CELUP_1B', 630),
    ('CELUP_2', 800),
    ('CELUP_3', 630),
    ('COMPRESSOR_CUCUK', 400),
    ('COMP_100HP', 400),
    ('COMP_300HP', 630),
    ('COMP_400HP', 800),
    ('COMP_SCR2200', 800),
    ('COOLING1', 400),
    ('COOLING2', 400),
    ('FACTORY_AB', 630),
    ('FINISHING_1', 1250),
    ('FINISHING_21', 800),
    ('FINISHING_22', 1000),
    ('GARUK', 630),
    ('INCOMING_PLN', 630),
    ('LAB_DEVICE', 400),
    ('LVMDB_A1', 3200),
    ('LVMDB_A2', 3200),
    ('LVMDB_A3', 3200),
    ('LVMDB_A4', 3200),
    ('LVMDB_A5', 3200),
    ('LVMDB_B2', 3200),
    ('LVMDB_TEXTURE_2', 3200),
    ('LVMDB_TF630', 1250),
    ('LVMDP_SPINNING_1', 3200),
    ('LVMDP_SPINNING_2', 3200),
    ('LVMDP_SPINNING_3', 3200),
    ('OFFICE', 125),
    ('PACKING_DEVICE', 400),
    ('PKN_DEVICE', 400),
    ('PLTS_A5', 800),
    ('PLTS_B2', 3200),
    ('PLTS_TEXTURE', 2000),
    ('RAINCOAT_DEVICE', 630),
    ('SIZING', 400),
    ('TRICOT', 800),
    ('TRICOT1', 400),
    ('TRICOT2', 400),
    ('WARPING', 400),
    ('WJL1', 800),
    ('WJL2', 800),
    ('WJL3', 800),
    ('WJL4', 630),
    ('WORKSHOP', 250),
    ('WTP_2', 630),
    ('WWTP', 630)
       ) AS v (node_code, a)
 WHERE n.tenant_id = 3 AND n.node_code = v.node_code;

-- 6.6 The PLN contract, from the bill: tariff group I-3, 7,585,000 VA.
--     This, not the 630 A breaker, is the loading denominator at the PCC: it is
--     the limit with money attached. On the same measured demand (I_L 137 A
--     ~ 4,957 kVA) the contract reads 65.4 %, the installed transformers 25.0 %
--     and the breaker 21.7 %. The breaker and the installed capacity nearly
--     agree because the switchgear is sized to the plant, not to the contract.
--
--     The I-3 minimum bill (rekening minimum: 40 hours of jam nyala) is a rule
--     of the tariff, not a fact about this node, so it is not modelled here.
--     tariff_code points at it. It is far from binding anyway -- jam nyala ran
--     231-285 h in September 2026 against a 40 h floor.
UPDATE graph.node
   SET attrs = attrs || jsonb_build_object('contract_kva', 7585, 'tariff_code', 'I3'),
       updated_at = NOW()
 WHERE tenant_id = 3 AND node_code = 'INCOMING_PLN';

-- 6.7 Compressor rated_kw, from the 5 device nameplates that map 1:1 to a node.
--     Those nameplates sit on the power METERS in devices.metadata.nameplate,
--     which is the wrong place -- a meter has no rated power, the compressor it
--     measures does. harmonics_report.py falls back to that field only because
--     the graph had nowhere better to put it. The device rows are left in
--     place; they simply stop being the source.
--
--     Device 53 (Compressor Turbo 300HP, 224 kW) has no node and is reported in
--     section 7 rather than dropped silently.
--
--     Horsepower in a node NAME is not used as a nameplate: "Comp FS Interlace
--     150HP - 2" suggests 110 kW, but names are not plates -- the transformer
--     CSV's own typos make the point. The review export offers it as a proposal
--     column for engineers to confirm or overwrite.
UPDATE graph.node n SET attrs = n.attrs || jsonb_build_object('rated_kw', v.kw),
       updated_at = NOW()
  FROM (VALUES
    ('COMPRESSOR_CUCUK', 15),
    ('COMP_100HP', 75),
    ('COMP_AIKI', 110),
    ('COMP_FUSHENG300HP', 220),
    ('COMP_SCR2200', 250)
       ) AS v (node_code, kw)
 WHERE n.tenant_id = 3 AND n.node_code = v.node_code;

-- ============================================================================
-- 7. The trigger goes on LAST, after the data is clean (design 4.3.12)
-- ============================================================================

CREATE TRIGGER trg_node_attrs
    BEFORE INSERT OR UPDATE OF attrs, node_type, node_class ON graph.node
    FOR EACH ROW EXECUTE FUNCTION graph.assert_node_attrs();

-- An untyped node may still carry any key from the vocabulary, as long as the
-- value is valid. That already catches kva_rated vs rated_kva and '400V' vs
-- 400, while typing proceeds one batch at a time.

-- Nothing may be invalid before this commits.
DO $$
DECLARE
    bad BIGINT;
    r   RECORD;
BEGIN
    SELECT count(*) INTO bad FROM graph.v_property_gaps WHERE status = 'INVALID';
    IF bad > 0 THEN
        FOR r IN SELECT node_code, detail FROM graph.v_property_gaps
                 WHERE status = 'INVALID' LOOP
            RAISE WARNING 'INVALID: % %', r.node_code, r.detail;
        END LOOP;
        RAISE EXCEPTION '% invalid attrs value(s) -- see warnings above', bad;
    END IF;
END $$;

COMMIT;

-- ============================================================================
-- 8. Verification (design 4.4)
-- ============================================================================

SELECT 'Typed nodes by type (expect 88 typed, 98 active LOAD untyped)' AS check_name;
SELECT COALESCE(node_type, '(untyped)') AS node_type, node_class, count(*)
FROM graph.node WHERE tenant_id = 3 AND is_active
GROUP BY 1, 2 ORDER BY 2, 1;

SELECT 'Gap summary (expect UNTYPED 98, MISSING 23, STALE 0, INVALID 0)' AS check_name;
SELECT status, count(*) FROM graph.v_property_gaps
WHERE tenant_id = 3 GROUP BY status ORDER BY status;

SELECT 'The site-check list: 9 sub-board breakers + 14 compressor ratings' AS check_name;
SELECT node_code, node_name, node_type, attr_key, kind, used_by
FROM graph.v_property_gaps
WHERE tenant_id = 3 AND status = 'MISSING' ORDER BY node_type, node_code;

SELECT 'Capacitor banks still valid after 024 (expect 11, detuned_pct null)' AS check_name;
SELECT count(*) FILTER (WHERE node_type = 'CAPACITOR_BANK') AS banks,
       count(*) FILTER (WHERE jsonb_typeof(attrs -> 'detuned_pct') = 'null') AS unanswered
FROM graph.node WHERE tenant_id = 3 AND node_code LIKE 'CB\_%';

SELECT 'FACTORY_AB is now 20 kV (expect 20000)' AS check_name;
SELECT node_code, node_type, attrs FROM graph.node
WHERE tenant_id = 3 AND node_code IN ('FACTORY_AB', 'INCOMING_PLN') ORDER BY node_code;

SELECT 'Transformer-fed boards (expect 12 rows, rated_kva and nominal_v 400)' AS check_name;
SELECT node_code, (attrs->>'rated_kva')::int AS rated_kva,
       (attrs->>'nominal_v')::int AS nominal_v,
       (attrs->>'main_breaker_a')::int AS breaker_a,
       round((attrs->>'rated_kva')::numeric * 1000
             / (sqrt(3) * (attrs->>'nominal_v')::numeric)) AS tx_fla_a
FROM graph.node WHERE tenant_id = 3 AND node_type = 'MAIN_LV_BOARD' ORDER BY node_code;

SELECT 'No node still carries voltage_level or type (expect 0)' AS check_name;
SELECT count(*) FROM graph.node
WHERE tenant_id = 3 AND (attrs ? 'voltage_level' OR attrs ? 'type');

SELECT 'Device nameplates with no node (expect device 53)' AS check_name;
SELECT d.id, d.device_name, (d.metadata->'nameplate'->>'rated_power')::float8 AS nameplate_kw
FROM devices d
WHERE d.tenant_id = 3 AND d.metadata->'nameplate'->>'rated_power' IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM graph.measurement m
                  JOIN graph.node n ON n.id = m.node_id
                  WHERE m.device_id = d.id AND n.attrs ? 'rated_kw')
ORDER BY d.id;

-- Rejections must be readable. Each of these must fail, naming the node, the
-- key and the rule (design 6.3). Run them one at a time, outside a transaction
-- you care about.
-- UPDATE graph.node SET attrs = attrs || '{"nominal_v": "400V"}'::jsonb
--  WHERE tenant_id = 3 AND node_code = 'WJL1';                  -- wrong datatype
-- UPDATE graph.node SET attrs = attrs || '{"rated_kva": 100}'::jsonb
--  WHERE tenant_id = 3 AND node_code = 'COMP_100HP';            -- not a property of the type
-- UPDATE graph.node SET attrs = attrs || '{"kva_rated": 100}'::jsonb
--  WHERE tenant_id = 3 AND node_code = 'WJL1';                  -- not in the vocabulary
-- UPDATE graph.node SET attrs = attrs || '{"site_status": "ok"}'::jsonb
--  WHERE tenant_id = 3 AND node_code = 'CB_A1';                 -- not in the enum
-- UPDATE graph.node SET attrs = attrs || '{"step_kvar": [50, "50"]}'::jsonb
--  WHERE tenant_id = 3 AND node_code = 'CB_A1';                 -- mixed array
-- UPDATE graph.node SET attrs = attrs || '{"main_breaker_a": 3200}'::jsonb
--  WHERE tenant_id = 3 AND node_code = 'CB_A1';                 -- not a property of the type
-- UPDATE graph.node SET node_class = 'LOAD'
--  WHERE tenant_id = 3 AND node_code = 'COMP_100HP';            -- composite FK
--
-- The solver must be untouched: capture get_node_values, get_sankey_flow,
-- get_node_quantity and get_node_values before and after this file over
-- 2026-08-18..2026-09-28 and diff row for row, as 024 did. Nothing here is read
-- by the solver, so any difference is a bug.

-- ============================================================================
-- 9. Undo
-- ============================================================================

-- BEGIN;
-- DROP TRIGGER trg_node_attrs ON graph.node;
-- DROP VIEW graph.v_property_gaps;
-- DROP FUNCTION graph.assert_node_attrs();
-- ALTER TABLE graph.node DROP CONSTRAINT fk_node_node_type;
-- DROP INDEX graph.idx_node_type;
-- ALTER TABLE graph.node DROP COLUMN node_type;
-- DROP VIEW graph.v_type_property;
-- DROP TABLE graph.type_property;
-- DROP TABLE graph.node_type;
-- DROP FUNCTION graph.property_value_ok(graph.property, JSONB);
-- DROP TABLE graph.property;
-- -- attrs are NOT restored by the above. To put them back as they were:
-- UPDATE graph.node SET attrs = '{"voltage_level": "20kV"}'::jsonb
--  WHERE tenant_id = 3 AND node_code = 'INCOMING_PLN';
-- UPDATE graph.node SET attrs = '{"voltage_level": "400V"}'::jsonb
--  WHERE tenant_id = 3 AND node_code = 'FACTORY_AB';
-- UPDATE graph.node SET attrs = '{"type": "PV"}'::jsonb
--  WHERE tenant_id = 3 AND node_code IN ('PLTS_A5','PLTS_A4','PLTS_B2','PLTS_TEXTURE');
-- UPDATE graph.node SET attrs = jsonb_build_object('rated_kva', 1600)
--  WHERE tenant_id = 3 AND node_code = 'LVMDB_TEXTURE';
-- UPDATE graph.node SET attrs = jsonb_build_object('rated_kva', 2000)
--  WHERE tenant_id = 3 AND node_code = 'LVMDB_TEXTURE_2';
-- UPDATE graph.node SET attrs = jsonb_build_object('rated_kva', 630)
--  WHERE tenant_id = 3 AND node_code = 'LVMDB_TF630';
-- UPDATE graph.node SET attrs = '{}'::jsonb
--  WHERE tenant_id = 3 AND attrs <> '{}'::jsonb AND node_code NOT LIKE 'CB\_%'
--    AND node_code NOT IN ('INCOMING_PLN','FACTORY_AB','PLTS_A5','PLTS_A4','PLTS_B2',
--                          'PLTS_TEXTURE','LVMDB_TEXTURE','LVMDB_TEXTURE_2','LVMDB_TF630');
-- UPDATE graph.node SET attrs = attrs - 'nominal_v' - 'main_breaker_a'
--  WHERE tenant_id = 3 AND node_code LIKE 'CB\_%';
-- COMMIT;
