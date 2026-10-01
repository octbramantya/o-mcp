-- Migration: 031_create_vocabulary_alignment.sql
-- Description: Move standard-vocabulary references out of node_type.external_ref into
--              graph.vocabulary_alignment; repoint tx_equipment_code's source after the move.
-- Author: Claude
-- Date: 2026-10-01
-- Design: reference/brick-alignment-review.md;
--         reference/standards-landscape.md ("What this settles")
-- Requires: 030_type_loads.sql
--
-- WHY
-- ---
-- graph.node_type.external_ref is one VARCHAR per type. The Brick review measured
-- why that cannot hold what we know:
--
--   * NULL means two things. "Nobody checked" and "checked, Brick has no
--     equivalent" look the same. 11 of the 14 NULLs are the second kind, and that
--     finding is what stops the next person re-running the review.
--   * A reference without a version is not a fact. brick:Water_Tank was valid in
--     1.3.0 and is deprecated in 1.4.2.
--   * One type aligns to several schemes at different fidelities. WATER_TANK is
--     CLOSE in Brick and EXACT in SAREF4WATR; PRODUCTION_MACHINE is NONE in Brick
--     and CLOSE in SAREF4INMA.
--   * 3 of the 10 stored values are broken (Air_Compressor and Generator do not
--     exist; Water_Tank is deprecated) and 2 name the wrong concept.
--
-- So the column is replaced by a table, one row per (thing, scheme, version):
--
--     graph.vocabulary_alignment (kind, code, scheme, scheme_version, uri, match,
--                                 checked_on, note)
--
-- `note` is the one addition to the shape in the design docs: every CLOSE has a
-- reason (required), as do the NONEs where a plausible candidate was rejected.
-- Without it the next reader re-runs the review to find out why.
--
-- node_type.external_ref is DROPPED, not kept beside the table. Two places for
-- the same fact is the "one fact spelled three ways" problem 026 removed. No
-- script reads the column; tools/validate_brick.py hardcodes its own list.
--
-- graph.property.external_ref is NOT a vocabulary reference -- its only non-null
-- value, on tx_equipment_code, is the survey file the values came from. It stays.
-- Its path went stale when the design files moved from ../prs_diags to this
-- repository on 2026-10-01; 028 was left as applied, so the correction is here.
-- Like the 028 value, the new one is relative to the root of the repository that
-- holds the migrations -- now this one.
--
-- Every row below was looked up on 2026-10-01 in the distributed TTL, parsed with
-- rdflib, not written from recall:
--   Brick      1.4.2  https://brickschema.org/schema/1.4/Brick.ttl
--   SAREF4WATR 1.1.1  https://saref.etsi.org/saref4watr/v1.1.1/saref4watr.ttl
--   SAREF4INMA 1.1.2  https://saref.etsi.org/saref4inma/v1.1.2/saref4inma.ttl
--
-- Match levels:
--   EXACT  same concept, same granularity
--   CLOSE  usable, with a stated difference (usually: the standard files it under
--          HVAC, or at a different granularity)
--   NONE   the scheme was searched and holds no equivalent. A real finding, not a gap.
--
-- Every node_type gets a Brick row, NONE included, because Brick was checked for
-- all of them. SAREF4WATR and SAREF4INMA rows exist only where the scheme's scope
-- covers the type; MV_BUS has no SAREF4WATR row because nobody would look there.
--
-- Edge types get no rows. Brick would collapse all ten relations onto brick:feeds
-- (brick-alignment-review.md, "Brick cannot express our edge ontology"). The kind
-- is allowed so a future scheme that can express them (CIM) has somewhere to go.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 What node_type.external_ref holds today ==='
SELECT code, node_class, external_ref
FROM graph.node_type
ORDER BY external_ref IS NULL, node_class, code;
-- expect 24 rows: 10 with a brick: value, 14 NULL

\echo ''
\echo '=== 1.2 graph.property.external_ref ==='
SELECT attr_key, external_ref FROM graph.property WHERE external_ref IS NOT NULL;
-- expect 1 row: tx_equipment_code | docs/database/design/trafo_tenant_3.csv


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 2.1 Refuse to run on a database that has drifted from what was reviewed
-- ----------------------------------------------------------------------------
DO $pre$
DECLARE
    drift TEXT;
BEGIN
    IF (SELECT count(*) FROM graph.node_type) <> 24 THEN
        RAISE EXCEPTION 'expected 24 node types, found %; the seed below covers exactly 24',
            (SELECT count(*) FROM graph.node_type);
    END IF;

    SELECT string_agg(coalesce(s.code, r.code), ', ') INTO drift
    FROM (SELECT code, external_ref FROM graph.node_type WHERE external_ref IS NOT NULL) s
    FULL JOIN (VALUES
        ('GRID_INCOMER',   'brick:Electrical_Meter'),
        ('PV_PLANT',       'brick:PV_Array'),
        ('GAS_ENGINE',     'brick:Generator'),
        ('SWITCHBOARD',    'brick:Switchgear'),
        ('AIR_COMPRESSOR', 'brick:Air_Compressor'),
        ('BOILER',         'brick:Boiler'),
        ('WATER_TANK',     'brick:Water_Tank'),
        ('AHU',            'brick:Air_Handling_Unit'),
        ('LIGHTING',       'brick:Lighting_System'),
        ('PUMP',           'brick:Pump')
    ) r (code, external_ref) ON r.code = s.code AND r.external_ref = s.external_ref
    WHERE s.code IS NULL OR r.code IS NULL;
    IF drift IS NOT NULL THEN
        RAISE EXCEPTION 'node_type.external_ref differs from the reviewed values at: %', drift;
    END IF;

    IF (SELECT external_ref FROM graph.property WHERE attr_key = 'tx_equipment_code')
       IS DISTINCT FROM 'docs/database/design/trafo_tenant_3.csv' THEN
        RAISE EXCEPTION 'tx_equipment_code.external_ref is not the value 028 applied';
    END IF;
END
$pre$;

-- ----------------------------------------------------------------------------
-- 2.2 The table
-- ----------------------------------------------------------------------------
CREATE TABLE graph.vocabulary_alignment (
    kind           VARCHAR(12)  NOT NULL,
    code           VARCHAR(40)  NOT NULL,
    scheme         VARCHAR(20)  NOT NULL,
    scheme_version VARCHAR(20)  NOT NULL,
    uri            VARCHAR(200),
    match          VARCHAR(5)   NOT NULL,
    checked_on     DATE         NOT NULL,
    note           TEXT,

    -- one verdict per thing per scheme release. A new release is a new row, so
    -- Water_Tank's 1.3 -> 1.4 history can be kept rather than overwritten.
    PRIMARY KEY (kind, code, scheme, scheme_version),

    CONSTRAINT ck_va_kind   CHECK (kind IN ('NODE_TYPE','EDGE_TYPE','PROPERTY')),
    CONSTRAINT ck_va_scheme CHECK (scheme ~ '^[A-Z][A-Z0-9_]*$'),
    CONSTRAINT ck_va_match  CHECK (match IN ('EXACT','CLOSE','NONE')),
    -- a full URI, not a CURIE: brick: is not a declared prefix anywhere
    CONSTRAINT ck_va_uri    CHECK (uri IS NULL OR uri ~ '^https?://'),
    -- NONE is exactly the case with nothing to point at
    CONSTRAINT ck_va_none   CHECK ((match = 'NONE') = (uri IS NULL)),
    -- an approximation without its reason is unreviewable; NONE explains itself
    CONSTRAINT ck_va_note   CHECK (match <> 'CLOSE' OR note IS NOT NULL)
);

COMMENT ON TABLE graph.vocabulary_alignment IS
    'How our vocabulary maps to external standards, one row per (thing, scheme, release). '
    'Our codes stay authoritative; this records alignment for export. match = NONE means '
    'the scheme was searched and has no equivalent -- distinct from having no row, which '
    'means nobody checked.';
COMMENT ON COLUMN graph.vocabulary_alignment.code IS
    'graph.node_type.code, graph.edge_type.code or graph.property.attr_key, per kind. '
    'Enforced by trigger, since one column cannot carry three foreign keys.';

-- code must name a live row of the table its kind points at
CREATE OR REPLACE FUNCTION graph.assert_alignment_code() RETURNS TRIGGER AS $$
DECLARE
    found BOOLEAN;
BEGIN
    -- assigned first: plpgsql ends an IF condition at the first THEN, the CASE's own
    found := CASE NEW.kind
        WHEN 'NODE_TYPE' THEN EXISTS (SELECT 1 FROM graph.node_type WHERE code = NEW.code)
        WHEN 'EDGE_TYPE' THEN EXISTS (SELECT 1 FROM graph.edge_type WHERE code = NEW.code)
        WHEN 'PROPERTY'  THEN EXISTS (SELECT 1 FROM graph.property  WHERE attr_key = NEW.code)
    END;
    IF NOT found THEN
        RAISE EXCEPTION 'vocabulary_alignment: % % does not exist', NEW.kind, NEW.code;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_vocabulary_alignment_code
    BEFORE INSERT OR UPDATE OF kind, code ON graph.vocabulary_alignment
    FOR EACH ROW EXECUTE FUNCTION graph.assert_alignment_code();

-- ----------------------------------------------------------------------------
-- 2.3 Seed. Brick 1.4.2: all 24 node types.
-- ----------------------------------------------------------------------------
INSERT INTO graph.vocabulary_alignment
    (kind, code, scheme, scheme_version, uri, match, checked_on, note)
SELECT 'NODE_TYPE', v.code, 'BRICK', '1.4.2',
       CASE WHEN v.local IS NOT NULL
            THEN 'https://brickschema.org/schema/Brick#' || v.local END,
       v.match, DATE '2026-10-01', v.note
FROM (VALUES
    -- SOURCE
    ('GRID_INCOMER', NULL, 'NONE',
     'Was brick:Electrical_Meter, which is <: Meter: the instrument, not the point of common '
     'coupling. Service, Utility, Substation, Feeder, Entrance give no equipment class.'),
    ('PV_PLANT', 'PV_Generation_System', 'EXACT',
     'Was brick:PV_Array, which is <: Collection, a grouping rather than equipment.'),
    ('GAS_ENGINE', NULL, 'NONE',
     'Was brick:Generator, which does not exist. Energy_Generation_System has only '
     'PV_Generation_System under it.'),
    ('WATER_INTAKE', NULL, 'NONE', NULL),
    -- BUS
    ('SWITCHBOARD', 'Breaker_Panel', 'CLOSE',
     'Was brick:Switchgear, whose five subclasses are all switching devices. Breaker_Panel '
     '<: Electrical_Equipment is the enclosure and busbar.'),
    ('MV_BUS', NULL, 'NONE', 'Bus_Riser is a riser, not a bus.'),
    ('MAIN_LV_BOARD', 'Breaker_Panel', 'CLOSE',
     'Brick does not distinguish a transformer-fed board from a sub board.'),
    ('SUB_BOARD', 'Breaker_Panel', 'CLOSE',
     'Brick does not distinguish a transformer-fed board from a sub board.'),
    -- CONVERSION
    ('AIR_COMPRESSOR', 'Compressor', 'CLOSE',
     'Was brick:Air_Compressor, which does not exist. Compressor is <: HVAC_Equipment; ours '
     'make process compressed air.'),
    ('BOILER', 'Boiler', 'CLOSE',
     '<: HVAC_Equipment, Water_Heater; ours raise process steam.'),
    ('WATER_TREATMENT', NULL, 'NONE',
     'Brick has no water-treatment vocabulary: Treatment, Clarifier, Softener, Osmosis, '
     'Filtration, Dosing all return zero classes.'),
    ('CLARIFIER',     NULL, 'NONE', NULL),
    ('SOFTENER',      NULL, 'NONE', NULL),
    ('RO_UNIT',       NULL, 'NONE', NULL),
    ('REACTION_TANK', NULL, 'NONE', NULL),
    -- STORAGE
    ('CAPACITOR_BANK', NULL, 'NONE', 'No capacitor or power-factor equipment class.'),
    ('WATER_TANK', 'Water_Storage_Tank', 'CLOSE',
     'Was brick:Water_Tank, deprecated in 1.4 and <: Space (a room). Water_Storage_Tank '
     '<: Storage_Tank <: Tank.'),
    -- LOAD
    ('PRODUCTION_MACHINE', NULL, 'NONE', NULL),
    ('AHU', 'Air_Handling_Unit', 'EXACT', NULL),
    ('LIGHTING', 'Lighting_System', 'CLOSE',
     '<: System; our LIGHTING nodes are circuits.'),
    ('PUMP', 'Pump', 'CLOSE', '<: HVAC_Equipment; ours include the WTP/WWTP pumps.'),
    ('GENERIC_LOAD', NULL, 'NONE', 'Unclassified by design.'),
    ('PROCESS_HEATER', NULL, 'NONE',
     'Space_Heater is space heating; Water_Heater is not this.'),
    ('WATER_PROCESS', NULL, 'NONE', 'Water_Loop is an HVAC loop.')
) v (code, local, match, note);

-- ----------------------------------------------------------------------------
-- 2.4 Seed. SAREF4WATR 1.1.1: the water types.
-- ----------------------------------------------------------------------------
INSERT INTO graph.vocabulary_alignment
    (kind, code, scheme, scheme_version, uri, match, checked_on, note)
SELECT 'NODE_TYPE', v.code, 'SAREF4WATR', '1.1.1',
       CASE WHEN v.local IS NOT NULL
            THEN 'https://saref.etsi.org/saref4watr/' || v.local END,
       v.match, DATE '2026-10-01', v.note
FROM (VALUES
    ('WATER_INTAKE', 'Intake', 'EXACT', NULL),
    ('WATER_TANK',   'Tank',   'EXACT', NULL),
    ('PUMP',         'Pump',   'EXACT', NULL),
    ('WATER_TREATMENT', 'TreatmentPlant', 'CLOSE',
     'Plant level only; ours is a stage in a five-stage train.'),
    ('CLARIFIER',     NULL, 'NONE', 'No unit operations below TreatmentPlant.'),
    ('SOFTENER',      NULL, 'NONE', 'No unit operations below TreatmentPlant.'),
    ('RO_UNIT',       NULL, 'NONE', 'No unit operations below TreatmentPlant.'),
    ('REACTION_TANK', NULL, 'NONE', 'No unit operations below TreatmentPlant.'),
    ('WATER_PROCESS', NULL, 'NONE',
     'SinkAsset covers only natural sinks: River, Sea, Ocean, Estuary.')
) v (code, local, match, note);

-- ----------------------------------------------------------------------------
-- 2.5 Seed. SAREF4INMA 1.1.2: production equipment.
-- ----------------------------------------------------------------------------
INSERT INTO graph.vocabulary_alignment
    (kind, code, scheme, scheme_version, uri, match, checked_on, note)
VALUES
    ('NODE_TYPE', 'PRODUCTION_MACHINE', 'SAREF4INMA', '1.1.2',
     'https://saref.etsi.org/saref4inma/ProductionEquipment', 'CLOSE', DATE '2026-10-01',
     'As specific as SAREF4INMA gets: it has no equipment taxonomy below this.');

-- ----------------------------------------------------------------------------
-- 2.6 Retire the column the table replaces
-- ----------------------------------------------------------------------------
ALTER TABLE graph.node_type DROP COLUMN external_ref;

-- ----------------------------------------------------------------------------
-- 2.7 The survey file moved with the design docs. Relative to the root of the
--     repository holding the migrations, as the 028 value was.
-- ----------------------------------------------------------------------------
UPDATE graph.property
   SET external_ref = 'design/trafo_tenant_3.csv'
 WHERE attr_key = 'tx_equipment_code';

-- ----------------------------------------------------------------------------
-- 2.8 Grants -- the reports and the MCP server run as grafReader
-- ----------------------------------------------------------------------------
GRANT SELECT ON graph.vocabulary_alignment TO "grafReader";

-- ----------------------------------------------------------------------------
-- 2.9 Post-conditions
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
    got TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM graph.node_type t
               WHERE NOT EXISTS (SELECT 1 FROM graph.vocabulary_alignment a
                                 WHERE a.kind = 'NODE_TYPE' AND a.code = t.code
                                   AND a.scheme = 'BRICK')) THEN
        RAISE EXCEPTION 'a node_type has no Brick verdict';
    END IF;

    SELECT string_agg(scheme || ':' || match || '=' || n, ' ' ORDER BY scheme, match) INTO got
    FROM (SELECT scheme, match, count(*) n FROM graph.vocabulary_alignment
          GROUP BY 1, 2) c;
    IF got <> 'BRICK:CLOSE=8 BRICK:EXACT=2 BRICK:NONE=14 '
              'SAREF4INMA:CLOSE=1 '
              'SAREF4WATR:CLOSE=1 SAREF4WATR:EXACT=3 SAREF4WATR:NONE=5' THEN
        RAISE EXCEPTION 'unexpected alignment counts: %', got;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'graph' AND table_name = 'node_type'
                 AND column_name = 'external_ref') THEN
        RAISE EXCEPTION 'node_type.external_ref still exists';
    END IF;

    IF (SELECT external_ref FROM graph.property WHERE attr_key = 'tx_equipment_code')
       IS DISTINCT FROM 'design/trafo_tenant_3.csv' THEN
        RAISE EXCEPTION 'tx_equipment_code.external_ref not updated';
    END IF;
END
$post$;

COMMIT;


-- ============================================================================
-- 3. After (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 Alignment by type ==='
SELECT code, scheme, match, uri
FROM graph.vocabulary_alignment
ORDER BY code, scheme;
-- expect 34 rows: 24 BRICK, 9 SAREF4WATR, 1 SAREF4INMA

\echo ''
\echo '=== 3.2 Types aligned EXACT or CLOSE to nothing anywhere ==='
SELECT t.code
FROM graph.node_type t
WHERE NOT EXISTS (SELECT 1 FROM graph.vocabulary_alignment a
                  WHERE a.kind = 'NODE_TYPE' AND a.code = t.code AND a.match <> 'NONE')
ORDER BY 1;
-- expect 11: CAPACITOR_BANK CLARIFIER GAS_ENGINE GENERIC_LOAD GRID_INCOMER MV_BUS
--            PROCESS_HEATER REACTION_TANK RO_UNIT SOFTENER WATER_PROCESS


-- ============================================================================
-- 4. Undo (commented) -- restores 030's state, including the broken values
-- ============================================================================
--
-- BEGIN;
-- ALTER TABLE graph.node_type ADD COLUMN external_ref VARCHAR(120);
-- UPDATE graph.node_type t SET external_ref = v.ref
-- FROM (VALUES
--     ('GRID_INCOMER',   'brick:Electrical_Meter'),
--     ('PV_PLANT',       'brick:PV_Array'),
--     ('GAS_ENGINE',     'brick:Generator'),
--     ('SWITCHBOARD',    'brick:Switchgear'),
--     ('AIR_COMPRESSOR', 'brick:Air_Compressor'),
--     ('BOILER',         'brick:Boiler'),
--     ('WATER_TANK',     'brick:Water_Tank'),
--     ('AHU',            'brick:Air_Handling_Unit'),
--     ('LIGHTING',       'brick:Lighting_System'),
--     ('PUMP',           'brick:Pump')
-- ) v (code, ref) WHERE t.code = v.code;
-- UPDATE graph.property SET external_ref = 'docs/database/design/trafo_tenant_3.csv'
--  WHERE attr_key = 'tx_equipment_code';
-- DROP TABLE graph.vocabulary_alignment;
-- DROP FUNCTION graph.assert_alignment_code();
-- COMMIT;
