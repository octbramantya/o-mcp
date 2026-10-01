# WAGES Graph — Node Types and Typed Properties

**Status:** **APPLIED to valkyrie 2026-09-28.** 025 then 026, both committed, all verification checks as predicted. Two migrations: `025_rename_plts_nodes.sql` then `026_create_node_type_property.sql`. Both were developed and tested on a local PostgreSQL 16 cluster restored from a live copy of the graph schema (188 nodes, 254 edges, 897 measurements), then applied to valkyrie (PostgreSQL 16.15) in one session with write credentials.
**Date:** 2026-09-21, revised and applied 2026-09-28
**Extends:** `graph-network-design.md` §4.2 (`node_class`, `attrs`)
**Database:** valkyrie (PostgreSQL 16.14 + TimescaleDB)

This is step 1 of making the graph's vocabulary explicit. It covers **what kind of equipment a node is** and **which facts about that equipment we record, in what datatype and unit**. It does not cover which connections are allowed (step 2, `connection_rule`) or how vendor registers map to physical quantities (step 3, `quantity_kind`).

---

## 1. Why

`graph.node.attrs` is free-form JSONB (§4.2). That was the right call while nobody read it. Now five scripts read it, across two repositories (`harmonics_report.py`, `layered_report.py`, `pf_report.py` and `graph_snapshot.py` in `../pq-analysis`, `wages_sync.py` here), and it is starting to fail in the usual ways. State of the live graph, tenant 3, 2026-09-21:

| | |
|---|---|
| nodes | 188 |
| nodes with any `attrs` | **21** — 11 of them are the capacitor banks from 024 |
| distinct keys in use | 13 |

**A wrong value went undetected until a report cross-checked it.** `FACTORY_AB` carries `voltage_level: '400V'`, but its meter reads **20,897 V L-L**, and `harmonics_report.py` raises `VOLTAGE_ATTR_MISMATCH` about it every week. The node sits between `INCOMING_PLN` and six boards that each have their own 20/0.4 kV transformer, so it is the 20 kV bus. Nothing rejected the value when it was written, because nothing knows what a voltage looks like.

**The same fact is spelled three ways.** `'400V'` and `'20kV'` are strings under `voltage_level`, and `rated_v: 400` is a number on the banks. Readers get the value back with a regex (`harmonics_report.parse_volts`).

**The kind of equipment is stored as an attribute.** Four `SOURCE` nodes carry `type: 'PV'`, which `harmonics_report.py` reads as `node_type` and `layered_report.py` prints. That is a classification, but nothing validates it as one.

**Nameplate data exists but is not in the graph.** `trafo_tenant_3.csv` lists 12 transformers. Only 3 ratings made it into the graph, as `rated_kva` on the boards they feed. The harmonics ratings backlog (`ratings_needed.csv`, 83 rows for 2026-09-07..13) includes **9 boards whose transformer rating is in that CSV**.

**Nameplates are attached to the wrong thing.** 6 devices carry `metadata.nameplate.rated_power`. Those devices are power meters, and a meter has no rated power; the compressor it measures does. `harmonics_report.py` falls back to that field because the graph has nowhere better to put it.

**Nobody can ask what is missing.** Whether a rating is needed is decided in report code, and a missing value shows up only as a fallback chain or a CSV of gaps from one report.

**`node_class` is too coarse to say what should be recorded.** The 29 `CONVERSION` nodes are 19 air compressors, 1 boiler and 9 water-treatment units. A compressor needs a kW rating and a softener does not, but the class cannot distinguish them.

## 2. Decisions

| # | Decision | Chosen |
|---|---|---|
| 1 | Granularity | **`node_type` under `node_class`.** A nullable FK on `graph.node`. The type must belong to the node's class, enforced by composite FK. A single-parent hierarchy lets child types inherit properties. |
| 2 | Vocabulary | **One global `graph.property` table.** A key has one datatype, one unit and one meaning everywhere: `rated_kw` is the same thing on a compressor and on a gas engine. Types *select* properties; they never redefine them. |
| 3 | Scope | **Global, not per tenant**, like `graph.utility`. What a transformer is does not vary by customer. |
| 4 | Enforcement | **Split.** A value that is present is validated hard by trigger (key known, allowed for the type, right datatype, range, enum). A required value that is absent is reported by a view, not rejected. Missing information is normal and is exactly what the site-check list is built from. |
| 5 | `null` vs absent | **Different on purpose.** Absent means never recorded. `null` means asked and not yet answered, like `detuned_pct` on the banks since 024. The gap view reports them separately: absent → `MISSING`, `null` → `UNKNOWN`. |
| 6 | Units | **Fixed per property and carried in the key name**, following the existing convention (`rated_kva`, `rated_kvar`, `volume_m3`). No unit conversion; the value is a bare number. |
| 7 | Required means consumed | **A property may be `REQUIRED` only if something reads it**, and `used_by` names that reader. The rule keeps the gap list short and actionable. Nothing becomes required just for completeness. |
| 8 | Solver | **Reads none of this.** `node_type` is descriptive, like `node_class` (§4.2). No change to `solve_flow`, `get_node_quantity` or the topology primitives. |
| 9 | Transformers | **Stay properties of the board they feed** (`rated_kva`, `tx_primary_v`, `tx_impedance_pct`). Making them nodes changes the solve and belongs with step 2 (§8). |
| 10 | Standard vocabulary | **`external_ref` column, filled where there is a clean match** (Brick class names, e.g. `brick:Air_Compressor`), so an export can be mapped later. Names are ours, not Brick's. |
| 11 | Breaker vs capacity | **Two keys, not one.** `main_breaker_a` (a trip threshold, from the site survey) stays separate from `rated_kva` / `rated_a` (a thermal capacity). Conflating them would understate loading on every transformer-fed board by 11-39 % (§4.3.8). |

### `node_type` is not the functional taxonomy

They look alike and answer different questions:

| | answers | example | keyed on |
|---|---|---|---|
| `node_type` | **what the equipment is** | `AIR_COMPRESSOR`, `MAIN_LV_BOARD` | the node, one type |
| `graph.category` (§15) | **what the business reports it under** | `COMPRESSOR`, `SPINNING`, `HVAC` | the node, weighted, inherited |

An air handling unit is always type `AHU`. The category it reports under can be HVAC or a production line, depending on who it serves. A board of type `MAIN_LV_BOARD` has no business category of its own. It passes one down to its loads. Neither table is derived from the other.

---

## 3. Schema

### 3.1 The vocabulary

```sql
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
    CONSTRAINT ck_prop_kind     CHECK (kind IN ('NAMEPLATE','DESIGN','SITE_STATUS','RECORD')),
    -- a SITE_STATUS property needs both; anything else must have neither, so a
    -- stray stale_after_days cannot sit on a key that never goes stale
    CONSTRAINT ck_prop_status   CHECK (
        (kind =  'SITE_STATUS' AND as_of_key IS NOT NULL AND stale_after_days IS NOT NULL)
     OR (kind <> 'SITE_STATUS' AND as_of_key IS NULL     AND stale_after_days IS NULL))
);
```

`kind` says where a missing value comes from, which is what turns a gap into the right task:

| kind | meaning | a gap becomes |
|---|---|---|
| `NAMEPLATE` | fixed by the equipment | read the plate on site, or the purchase records |
| `DESIGN` | a setting engineering chose | ask engineering |
| `SITE_STATUS` | observed on site; goes stale | a scheduled site check; again after `stale_after_days` |
| `RECORD` | bookkeeping about another property (`site_status_as_of`) | never reported on its own |

A `SITE_STATUS` property names its `as_of_key`. The 024 pair `site_status` / `site_status_as_of` is the first instance. The pattern becomes a declared rule instead of a convention in one migration.

### 3.2 Types

```sql
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
        ('SOURCE','BUS','DISTRIBUTION','CONVERSION','STORAGE','LOAD'))
);

ALTER TABLE graph.node ADD COLUMN node_type VARCHAR(40);
ALTER TABLE graph.node ADD CONSTRAINT fk_node_node_type
    FOREIGN KEY (node_type, node_class) REFERENCES graph.node_type (code, node_class);
CREATE INDEX idx_node_type ON graph.node (node_type) WHERE node_type IS NOT NULL;
```

The composite FK `(node_type, node_class)` is the same device §4.3 uses for tenants. A node cannot be typed `AIR_COMPRESSOR` while classed `LOAD`, and no trigger is needed. `node_type` stays nullable (`MATCH SIMPLE` skips the check on `NULL`), so the 100 untyped loads are legal and just show up as `UNTYPED`.

Reclassification (§4.2) still works as one `UPDATE`, but it now has to set both columns: `SET node_class = 'BUS', node_type = 'SUB_BOARD'`. Changing only the class fails the FK and names the problem. Like `node_class`, `node_type` has no history.

### 3.3 Which type has which property

```sql
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
```

### 3.4 Validation

One function decides whether a value is valid. The trigger, the audit view and the `wages_sync.py` pre-flight all call it, so the three cannot disagree.

```sql
CREATE OR REPLACE FUNCTION graph.property_value_ok(p graph.property, v JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
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
$$;

CREATE OR REPLACE FUNCTION graph.assert_node_attrs() RETURNS TRIGGER AS $$
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

        CONTINUE WHEN jsonb_typeof(v) = 'null';          -- asked, not yet answered (§2 #5)

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
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_node_attrs
    BEFORE INSERT OR UPDATE OF attrs, node_type, node_class ON graph.node
    FOR EACH ROW EXECUTE FUNCTION graph.assert_node_attrs();
```

An untyped node may carry any key from the vocabulary, as long as the value is valid. That still catches `kva_rated` vs `rated_kva` and `'400V'` vs `400`, while typing proceeds one batch at a time.

The trigger checks one row when that row is written. If the vocabulary changes later, for example an enum is narrowed or a `type_property` row is dropped, existing rows are not rechecked. The audit view below catches that as `INVALID`.

### 3.5 The gap view

```sql
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
-- A stored value the current vocabulary no longer accepts
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
```

Both views are plain `STABLE` SQL with no temp tables. Like the §14 primitives, they run under `grafReader` in a read-only transaction. Grants follow 010.

---

## 4. Seed

### 4.1 Property vocabulary

Seeded from the keys already in use (in **bold**), plus the ones a current reader needs or an open item in `graph-network-design.md` points at. Existing keys keep their names. The one exception is `voltage_level`, which changes datatype and is renamed so a stale reader fails loudly instead of parsing a number as `NaN`.

| attr_key | datatype | unit | kind | range / values | note |
|---|---|---|---|---|---|
| `nominal_v` | number | V | DESIGN | 100 – 150000 | replaces **`voltage_level`** (string) |
| **`rated_kva`** | number | kVA | NAMEPLATE | > 0 | on a transformer-fed board: the transformer's rating |
| `rated_a` | number | A | NAMEPLATE | > 0 | **continuous** current rating. Read by `harmonics_report.py`. Nothing sets it today and the site list does not supply it — see `main_breaker_a` |
| `main_breaker_a` | number | A | NAMEPLATE | > 0 | frame size of the breaker protecting this panel or way. A **trip threshold, not a capacity**: on every transformer-fed board it is the next standard frame *above* the transformer's full-load amps (§4.3.8). Source: `draft_current_ratings_mapped.csv` |
| `tx_primary_v` | number | V | NAMEPLATE | > 0 | supplying transformer's primary |
| `tx_impedance_pct` | number | % | NAMEPLATE | 1 – 20 | gives Isc, so IEEE 519 Isc/I_L stops being a yardstick |
| `rated_kw` | number | kW | NAMEPLATE | > 0 | compressor, engine, motor |
| `rated_kwp` | number | kWp | NAMEPLATE | > 0 | PV DC peak |
| **`fuel`** | enum | — | NAMEPLATE | `NATURAL_GAS`, `DIESEL`, `LPG`, `COAL`, `BIOMASS` | |
| `contract_kva` | number | kVA | DESIGN | > 0 | PLN contracted capacity (*daya tersambung*). A commercial limit, not a property of any equipment — hence `DESIGN`. Changes only when the connection agreement changes |
| `tariff_code` | enum | — | DESIGN | `I3`, `I4`, `B3` | PLN tariff group; sets which charges apply. `I3` for tenant 3 |
| `drive` | enum | — | NAMEPLATE | `FIXED`, `VSD` | compressor drive |
| `rated_flow_nm3min` | number | Nm³/min | NAMEPLATE | > 0 | with `rated_kw`, gives specific power once air meters arrive |
| `rated_pressure_bar` | number | bar(g) | NAMEPLATE | > 0 | |
| `rated_steam_kgh` | number | kg/h | NAMEPLATE | > 0 | boiler |
| `volume_m3` | number | m³ | NAMEPLATE | > 0 | tank capacity; needed for the ΔS storage term (§13) |
| **`rated_kvar`** | number | kVAr | NAMEPLATE | > 0 | |
| **`rated_v`** | number | V | NAMEPLATE | > 0 | capacitor rated voltage; deliberately separate from `nominal_v` (a detuned bank is rated above system voltage) |
| **`steps`** | integer | — | NAMEPLATE | 1 – 32 | |
| **`step_kvar`** | number[] | kVAr | NAMEPLATE | > 0 | |
| **`control`** | enum | — | DESIGN | `APFC`, `FIXED`, `MANUAL` | |
| **`target_pf`** | number | — | DESIGN | 0.80 – 1.00 | |
| **`detuned_pct`** | number | % | NAMEPLATE | 0 – 20 | `null` on all 11 banks since 024 |
| **`site_status`** | enum | — | SITE_STATUS | `normal`, `inactive` | `as_of_key = site_status_as_of`, `stale_after_days = 90` |
| **`site_status_as_of`** | date | — | RECORD | | |

`type` is **not** in the vocabulary. Its only value (`PV`) becomes `node_type = 'PV_PLANT'`.

### 4.2 Types and what each requires

Every `REQUIRED` row names its reader (§2 #7). Anything without a reader today is `OPTIONAL` and is promoted when a reader appears.

| type | class | parent | nodes | REQUIRED (used_by) | OPTIONAL |
|---|---|---|---|---|---|
| `GRID_INCOMER` | SOURCE | | `INCOMING_PLN` | `nominal_v` (harmonics voltage check), `contract_kva` (harmonics loading denominator at the PCC) | `main_breaker_a`, `tariff_code` |
| `PV_PLANT` | SOURCE | | `PLTS_A5`, `PLTS_B2` (both renamed, §4.5), `PLTS_A4`, `PLTS_TEXTURE` | | `rated_kwp`, `nominal_v`, `main_breaker_a` |
| `GAS_ENGINE` | SOURCE | | `GAS_ENGINE` | | `fuel`, `rated_kw`, `nominal_v` |
| `WATER_INTAKE` | SOURCE | | `WTP1_IN_1/2`, `WTP2_IN_1/2`, `WTP1_RAN` | | |
| `SWITCHBOARD` | BUS | | *(abstract)* | `nominal_v` (harmonics voltage check, layered report) | `rated_a`, `main_breaker_a` |
| `MV_BUS` | BUS | `SWITCHBOARD` | `FACTORY_AB` | *(inherits)* | |
| `MAIN_LV_BOARD` | BUS | `SWITCHBOARD` | the 12 transformer-fed boards (§4.3) | `rated_kva` (harmonics loading denominator) | `main_breaker_a`, `tx_primary_v`, `tx_impedance_pct` |
| `SUB_BOARD` | BUS | `SWITCHBOARD` | the other 14 boards | `main_breaker_a` (harmonics loading denominator, small-load filter) | `rated_a` |
| `AIR_COMPRESSOR` | CONVERSION | | 19 nodes | `rated_kw` (harmonics rating fallback) | `drive`, `rated_flow_nm3min`, `rated_pressure_bar`, `nominal_v`, `main_breaker_a` |
| `BOILER` | CONVERSION | | `BOILER_MIURA` | | `fuel`, `rated_steam_kgh`, `main_breaker_a` |
| `WATER_TREATMENT` | CONVERSION | | *(abstract)* | | `volume_m3` |
| `CLARIFIER` | CONVERSION | `WATER_TREATMENT` | `WTP1_CLR`, `WTP2_CLR` | | |
| `SOFTENER` | CONVERSION | `WATER_TREATMENT` | `WTP1_SOFT_1/2`, `WTP2_SOFT_3/4/5` | | |
| `RO_UNIT` | CONVERSION | `WATER_TREATMENT` | `WTP2_RO_PROC` | | |
| `REACTION_TANK` | CONVERSION | `WATER_TREATMENT` | `WTP2_REACT` | | |
| `CAPACITOR_BANK` | STORAGE | | 11 banks (024) | `rated_kvar`, `step_kvar`, `control`, `target_pf`, `site_status`, `site_status_as_of` (all `pf_report.py`) | `rated_v`, `steps`, `detuned_pct` |
| `WATER_TANK` | STORAGE | | 10 tanks | | `volume_m3` |
| `PRODUCTION_MACHINE`, `AHU`, `LIGHTING`, `PUMP`, `GENERIC_LOAD` | LOAD | | *(none yet)* | | `rated_kw`, `nominal_v`, `main_breaker_a` |

Class totals check against live: BUS 1 + 12 + 14 = 27, CONVERSION 19 + 1 + 9 = 29, STORAGE 11 + 10 = 21, SOURCE 11. That is all 88 non-`LOAD` nodes. The 100 `LOAD` nodes stay untyped (§4.4); 98 of them are active, and `MC302_BARU` / `MC303_BARU` are retired, so the gap view counts 98.

**`main_breaker_a` is never the loading denominator on a `MAIN_LV_BOARD`.** The site list gives the incomer frame size, which is by design above what the transformer can deliver (§4.3.8). Using it would show `LVMDB_TF630` at 73 % just as its transformer reaches 100 %, and `LOAD_ABOVE_RATING` would stop firing on exactly the boards it exists to catch. On a `SUB_BOARD` there is no transformer in between, so the feeder breaker *is* the limit and `main_breaker_a` is the right denominator. Hence the resolution order in §5, which puts `rated_kva` first and `main_breaker_a` late.

Both values are worth keeping where both exist. "% of transformer" is a thermal, sustained limit; "% of breaker" is a trip threshold. They are different alarms and the report can show both.

`detuned_pct` stays `OPTIONAL` even though `pf_report.py` warns about resonance in prose. The warning does not read the value. The property is promoted when the report does.

### 4.3 Data changes in the migration

Everything is by explicit `node_code` list, not by `LIKE` pattern, for the same reason 019 lifts from the live tables rather than hand-copying: a pattern silently includes the next node that happens to match.

1. **`voltage_level` → `nominal_v`.** `INCOMING_PLN` becomes `20000`. **`FACTORY_AB` becomes `20000`, corrected from `'400V'`**. The meter reads 20,897 V, and the six boards below it each have their own 20/0.4 kV transformer.
2. **`type: 'PV'` → `node_type = 'PV_PLANT'`**, and the key is removed from all four nodes.
3. **Transformers from `trafo_tenant_3.csv`.** Each of the 12 boards gets `rated_kva`, `tx_primary_v = 20000` and `nominal_v = 400`. The 3 existing `rated_kva` values (1600, 2000, 630) agree with the CSV. The CSV spells five `before_node` codes wrong (`LVMBD_A2`…`A5`, `LVMBD_TF630`). The migration maps them by hand and says so; it does not fuzzy-match.
4. **`SUB_BOARD` `nominal_v = 400`.** This is derived from topology: every sub-board is fed at 400 V with no transformer in between. The migration comment records that it is derived, not read off a plate. `harmonics_report.py`'s voltage cross-check will flag any exceptions.
5. **Compressor `rated_kw` from the 5 device nameplates that map to a node:** `COMP_100HP` 75, `COMP_FUSHENG300HP` 220, `COMP_SCR2200` 250, `COMP_AIKI` 110, `COMPRESSOR_CUCUK` 15. Each of those nodes has exactly one measuring device, checked in the migration. Device 53 (`Compressor Turbo 300HP`, 224 kW) has no node and is reported, not dropped silently (the same case as §15.6). `devices.metadata.nameplate` is left in place; it stops being the source.
6. **Horsepower in node names is not used.** "Comp FS Interlace 150HP - 2" suggests 110 kW, but names are not nameplates, as the CSV typos above show. The review export (§5) offers it as a proposal column.
7. **`main_breaker_a` from `draft_current_ratings_mapped.csv`.** 60 of the site list's 63 rows map to nodes: 11 main boards, 5 sub-boards and ~30 loads and compressors. The list is flat, so a row's position under a board does not always mean a direct feed; each mapping was confirmed against `fed_by` by ancestry, not by name. Two "Spare" ways and `AHU 8, 9` have no node (§4.6).

   Three values arrived after the first list (2026-09-28) and are **at 20 kV, not 400 V**, which the migration comment records so nobody later reads them as LV frames: `INCOMING_PLN` 630 A, `FACTORY_AB` 630 A — the standard MV cubicle rating, about 21.8 MVA at 20 kV — and `PLTS_TEXTURE` 2000 A.
8. **The breaker list is not a capacity.** Every transformer-fed board's frame is the next standard size above the transformer's full-load amps, which is what fixes the resolution order in §5:

   | board | kVA | FLA @ 400 V | frame | ratio |
   |---|---|---|---|---|
   | `LVMDB_A1`…`A5`, `B2`, `TEXTURE_2`, `SPINNING_1`/`3` | 2000 | 2887 A | 3200 A | 1.11 |
   | `LVMDP_SPINNING_2` | 1600 | 2309 A | 3200 A | 1.39 |
   | `LVMDB_TF630` | 630 | 909 A | 1250 A | 1.37 |

9. **`INCOMING_PLN` gets `contract_kva = 7585` and `tariff_code = 'I3'`**, from the PLN bill (7,585,000 VA, tariff group I-3), received 2026-09-28. This, not the breaker, is the denominator at the PCC (§5), because it is the limit with money attached. The three candidates differ by a factor of three on the same measured demand:

   | denominator | value | I_L = 137 A ≈ 4,957 kVA reads as |
   |---|---|---|
   | **`contract_kva`** | 7,585 kVA (219 A at 20 kV) | **65.4 %** |
   | installed transformers | 19,830 kVA | 25.0 % |
   | `main_breaker_a` | 630 A ≈ 21,800 kVA | 21.7 % |

   The breaker and the installed transformer capacity nearly agree, because the switchgear is sized to the plant, not to the contract. Only the first number tells anyone whether the next load addition needs a contract upgrade.
10. **Three rows are knowingly blank.** `LVMDB_TEXTURE` (a 1600 kVA main board), `PLTS_A4` and `SIPPA` have no rating on the site list, and all three stay absent rather than guessed. None raises a gap row: `main_breaker_a` is `OPTIONAL` on `MAIN_LV_BOARD` (which `rated_kva` already covers) and on `PV_PLANT`, and `SIPPA` is an untyped load.
11. **`WTP_2` stays fed by `LVMDB_TF630`.** The site list groups it under LVMDB B2; the graph is right and the list's grouping is not. Confirmed 2026-09-28. No topology change.
12. **The trigger is created last**, after the data is clean. The verify section then requires `v_property_gaps` to hold **zero `INVALID` rows** before it commits.

### 4.4 What `v_property_gaps` should report after seeding

Derived from the seed plan above. The verify section asserts these counts.

| status | what | rows |
|---|---|---|
| `UNTYPED` | active loads with no type | 98 |
| `MISSING` | `SUB_BOARD.main_breaker_a` | 9 |
| `MISSING` | `AIR_COMPRESSOR.rated_kw` | 14 |
| `STALE` | `CAPACITOR_BANK.site_status` | 0 today; all 11 on 2026-12-20 |
| `INVALID` | | 0 |

That is the ratings backlog as a query rather than a report by-product: **23 nameplate reads**, all of them site-check items with a named reason. `ratings_needed.csv` drops the 9 transformer-fed boards. Loads stay in it until they are typed.

The 9 remaining sub-boards are exactly the ones the site list does not reach, all in the Spinning and Texture area: `LVSDP_SP2_1`, `LVSDP_SP2_2`, `LVSDP_COMP_23`, `LVSDP_PROD_ATY`, `COMP_INTERLACE`, `COMP_KAESER`, `COMP_WINDER`, `MC_RWD`, `TWIST_PANEL`. That is one coherent site visit rather than 14 scattered ones.

Seeding ~30 loads with `main_breaker_a` also changes what the harmonics report can suppress. `SMALL_OF_RATING` (harmonic amps below 5 % of the rating) only applies where a rating is known; until now almost nothing had one, so `HARM_KVA_MIN = 10 kVA` did the work alone. With this coverage that threshold is worth re-deciding, separately from this migration.

### 4.5 Rename `PLTS_A` → `PLTS_A5` and `PLTS_B` → `PLTS_B2`

Site names each array after the board it feeds. The graph calls them `PLTS_A` and `PLTS_B`, which read like a matched pair and match nothing on site. Both are renamed, `node_code` and `node_name` together: node `id = 121` becomes `PLTS_A5` / `PLTS A5`, and `PLTS_B` becomes `PLTS_B2` / `PLTS B2`. `PLTS_A4` and `PLTS_TEXTURE` already agree with site and are left alone.

This is safe inside `graph`, because `graph.edge` references `node_id`, not `node_code` (008 §4.3), as do `graph.measurement` and the taxonomy tables. Nothing needs re-pointing; it is one `UPDATE`.

It is **not** contained to `graph`. The legacy `prs.device_hierarchy` carries both `node_code`s (002 lines 33-34), `prs.device_node_mapping` maps device 27 to `PLTS_A` and device 11 to `PLTS_B` (002 lines 116-117), and `prs.device_hierarchy.parent_code` is a plain string reference. The rename must cover all three or deliberately cover none, so **it ships as its own migration, applied before 025**, rather than being folded into the ontology work. Mixing an identity rename into 025 would make either one impossible to roll back alone.

Stale copies to refresh afterwards: `graph_nodes.csv` / `graph_edges.csv` / `graph_network.md` (re-run `graph_snapshot.py`), `reference/graph_sankey_orphan.csv`, `graph-network-seed.csv`, `graph-seed-v1.csv`. Past report outputs under `../pq-analysis/reports/` keep the old code and are left as they are — they are records of what was run.

### 4.6 Deferred: `AHU 8, 9`

The site list has a 100 A way "AHU 8, 9" under LVMDB A2, between `AJL1` and `AJL2`, with no node in the graph. `AHU_10_11` is fed by `AJL2`, so by symmetry this one is likely fed by `AJL1` — likely is not good enough to create a node from. Held pending confirmation (2026-09-28). Until then its rating has nowhere to go, and the node stays absent rather than being invented under a guessed parent.

---

## 5. Changes outside SQL

The readers live in **two repositories** since 2026-09-28: the reports are in `../pq-analysis/scripts`, the sync and export stay in `prs_diags/scripts`. The rename of `voltage_level` therefore breaks across a repo boundary, and both sides ship with the migration (§7).

| file | change |
|---|---|
| `../pq-analysis/scripts/harmonics_report.py` | `NODE_ATTRS_SQL` (line 183) reads `(attrs->>'nominal_v')::numeric`, `attrs->>'main_breaker_a'` and `n.node_type` instead of `attrs->>'voltage_level'` / `attrs->>'type'`; `parse_volts` is no longer needed for attrs (line 442). The PV test at line 415 compares against `'PV_PLANT'`, not `'PV'`. **The rating resolution order in `rate()` becomes `rated_kva` → `contract_kva` (`GRID_INCOMER` only) → `rated_a` → `rated_kw` → `main_breaker_a` → device nameplate kW.** It is ordered by how tightly each candidate actually binds, not by how specific it looks, because every percentage downstream is read as headroom: a transformer-fed board is measured against its transformer, the incomer against its contract, a machine against its own motor, and a sub-board — which has no transformer in between — against its breaker. `rating_basis` gains `NODE_CONTRACT_KVA`, `NODE_RATED_KW` and `NODE_BREAKER_A`. Node `rated_kw` outranks `devices.metadata.nameplate`, which becomes the fallback for machines not yet in the graph. `ratings_needed.csv` can be cross-checked against `v_property_gaps` where `used_by` names this report. |
| `../pq-analysis/scripts/layered_report.py` | line 170 reads `nominal_v` as a number instead of mapping `voltage_level` through `hr.parse_volts`; line 199's `node_type` needs no change, since it already reads whatever `NODE_ATTRS_SQL` returns. |
| `../pq-analysis/scripts/graph_snapshot.py` | `INLINE_ATTRS` becomes `nominal_v, rated_kva, rated_a, main_breaker_a, fuel`; `NODES_SQL` selects `node_type`, and a node prints as `[BUS/SUB_BOARD]`. Re-run after the migration: the snapshot is the file everything else reads the topology from. |
| `../pq-analysis/scripts/pf_report.py` | none; bank keys are unchanged. |
| `scripts/wages_sync.py` | CSV gains a `node_type` column (carried through `_node`, `_merge_node`, both write statements and the live snapshot, so a rename on a reference row keeps the type). New `check_ontology()` runs beside `check_preflight` and calls the same `graph.property_value_ok`, reporting `E-ATTR-KEY`, `E-ATTR-VALUE` and `E-NODE-TYPE` with the file and line. On a database without 026 it is a no-op, so the script still works either way. `wages_template.csv` regenerated. |
| `scripts/graph_seed_export.py` | `node_type` in the CSV contract, parsed and validated like `node_code`, emitted in the INSERT and its `DO UPDATE SET`, and reconciled in `_merge_node`. |
| new: review export | like `reference/graph_sankey_orphan.csv` (§13): the 98 active untyped loads and 23 missing ratings, with `device_id`, `slave_address`, `ip_address`, a `proposed_node_type` pick-list column and a `proposed_rated_kw_from_name` column engineers confirm or overwrite. |

---

## 6. Test plan (local cluster) — run 2026-09-28

**Result: all checks pass.** What follows is what was run and what came back.

1. **Solver untouched — proven by definition, not by sampling.** 024 needed a row-for-row diff because it changed two function bodies. 026 changes none, so the stronger check is available and was used: `pg_get_functiondef` for all 17 `graph` functions, live versus post-migration, is **byte-identical** — the diff contains 0 removed lines and adds only `property_value_ok` and `assert_node_attrs`. Two further properties make the result exhaustive rather than indicative: no `graph` function writes `graph.node`, so the new trigger cannot fire during a solve; and none does `SELECT *` on `graph.node`, so the new column cannot widen a result. That covers every window, not just one.
2. **Existing data validates.** All 11 banks from 024 pass the trigger unchanged; `detuned_pct: null` is accepted.
3. **Rejections are readable.** Each of these must fail with a message naming the node, key and rule:
   - `nominal_v: '400V'` (string) on a switchboard
   - `rated_kva` on an `AIR_COMPRESSOR`, which lists the allowed keys
   - `kva_rated` anywhere (not in the vocabulary)
   - `site_status: 'ok'` (not in the enum)
   - `step_kvar: [50, "50"]`
   - `node_class = 'LOAD'` on a node typed `AIR_COMPRESSOR` (FK)
   - `main_breaker_a: 3200` on a node typed `CAPACITOR_BANK` (not a property of that type)
4. **Vocabulary drift is caught.** Narrow an enum after seeding; `v_property_gaps` shows `INVALID` for the affected rows and the trigger is not what reports it.
5. **Counts.** §4.4 exactly: `UNTYPED` 98, `MISSING` 23 (9 sub-board breakers + 14 compressor ratings), `STALE` 0, `INVALID` 0. 88 nodes typed, in the per-type counts §4.2 predicts.
6. **Constraint coverage.** 14 of 14 rejection cases fail and 3 of 3 permitted writes succeed (`null` as "asked, unanswered", a valid value on a typed node, a vocabulary key on an untyped node). Testing this way found a real hole in a first draft of `ck_prop_status`: it allowed a stray `stale_after_days` on a non-`SITE_STATUS` key, and is now written as two explicit branches (§3.1).
7. **Reports.** `harmonics_report.py` and `layered_report.py` produce the same output for 2026-09-07..13, except that `FACTORY_AB`'s `VOLTAGE_ATTR_MISMATCH` disappears and 9 boards leave `ratings_needed.csv`.
8. **Reader changes tested against the migrated cluster.** `NODE_ATTRS_SQL` runs and returns the seven typed columns; `rate()` resolves all 12 `MAIN_LV_BOARD` to `NODE_RATED_KVA` (`LVMDB_TF630` to its transformer's 909 A, not its 1250 A frame), `INCOMING_PLN` to `NODE_CONTRACT_KVA` (219 A, not 630 A), the seeded compressors to `NODE_RATED_KW` and the 5 known sub-boards to `NODE_BREAKER_A`. `graph_snapshot.py` regenerates all three files. `wages_sync.py` round-trips a `node_type` insert and update, and its pre-flight raises exactly 6 errors on 6 bad rows and none on 2 good ones.

   Two defects were found this way and fixed: `rate()` ignored the node's own `rated_kw` and fell through to the breaker, so a 75 kW compressor was measured against a 400 A way; and the pre-flight rejected `detuned_pct: null`, because `jsonb_to_recordset` hands back SQL `NULL` for a JSON null and the `jsonb_typeof(...) = 'null'` guard never fired — it disagreed with the trigger, which is the one thing that check exists to prevent.
9. **Rating basis is right per type.** After the resolution-order change, `rating_basis` reads `kva` on all 12 transformer-fed boards and `breaker` on the 5 sub-boards that now have one. A `MAIN_LV_BOARD` resolving to `breaker` is the specific regression this ordering exists to prevent, so it fails the test.

---

## 7. Sequencing

The rename (§4.5) is **025**, applied first; the ontology is **026**, whose explicit `node_code` lists are written against the renamed codes and which asserts in its evidence section that 025 has run. 026 is not re-runnable — it creates tables — so it is applied once, in a transaction that rolls back whole if any check fails. Neither depends on 014/015 and neither blocks them. It needs write credentials for one session, applied by the admin like 022 and 024. The report changes in §5 ship in the same change, because the rename of `voltage_level` breaks the old readers on purpose.

---

## 8. Not in this step

- **Cross-property rules.** `sum(step_kvar) = rated_kvar` and `steps = len(step_kvar)` are checked in 024's verify section and in `pf_report.py`, not by the schema. A small `graph.property_rule` table is the obvious home, but two rules don't justify it yet.
- **Transformers as nodes.** A `TRANSFORMER` node of class `CONVERSION` between `INCOMING_PLN` and each board is physically right (§4.2 already lists it). It inserts an unmetered node into every electricity path, though, and that changes what the solver resolves. It belongs with step 2, where connection rules decide what may feed what.
- **Property history.** `attrs` is not temporal. A replaced transformer overwrites `rated_kva` for all past queries, which is the same limitation `node_class` has (§13). This is acceptable while nothing computes history from nameplates. If loading-% trends ever do, ratings need `effective_from`, most likely as rows in a `graph.node_property` table instead of JSONB.
- **Typing the 98 active loads.** An authoring pass with the engineers, through the review export, like the taxonomy CSVs. It is not something to guess in a migration.
- **Inherited properties along edges.** `nominal_v` is intensive and could resolve down the topology like `INHERIT` quantities do (§4.7), removing step 4.3.4. Not done: it would make a stored-looking value computed, and a wrong one would propagate silently. An explicit value plus the meter cross-check is safer while the boards are being confirmed.
- **Tariff rules.** The I-3 minimum bill (*rekening minimum*: if kWh ÷ contracted kVA falls below 40 hours in a month, PLN bills 40 hours) is a rule of the tariff, not a fact about `INCOMING_PLN`. It is the same constant for every I-3 customer, so it belongs wherever the tariff is modelled, not duplicated onto each incomer as a property. `tariff_code` points at it. For tenant 3 it is far from binding — jam nyala ran 231-285 h in September 2026 against a 40 h floor — so nothing reads it today either.
- **Tenant 4.** Nothing to type until it has an SLD.
