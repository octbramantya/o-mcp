# WAGES Graph Network — Design

**Status:** **Live.** Migrations 008–013 and 016–019 are applied to valkyrie: 176 nodes, 231 edges (192 ELECTRICITY, 39 WATER), 888 measurement rows, 28 FUNCTIONAL categories, all for tenant 3. Phases 5 and 6 are **not** done — `prs.device_hierarchy`, `prs.device_node_mapping`, `public.assets` and `public.asset_connections` are all still present, so 014 and 015 remain the open work. Tenant 4 has 43 devices and no graph at all (§13).
**Date:** 2026-08-18, status updated 2026-08-20
**Replaces:** `public.assets`, `public.asset_connections`, `prs.device_hierarchy`, `prs.device_node_mapping`
**Database:** valkyrie (PostgreSQL 16.14 + TimescaleDB)

---

## 1. Why

The current structural model is a strict tree (`prs.device_hierarchy`, `parent_code` + `level`). It cannot express the plant as it actually is:

- **Multiple sources feeding one bus.** Grid (PLN) and the planned gas engine both feed Factory A&B; PV plants inject at specific downstream panels. A tree gives each node one parent, so today's schema fakes it with a synthetic `PURCHASED_ENERGY` root and a direction flip inside `get_sankey_energy_flow_v2` (`CASE WHEN hier_level = 1 THEN child→parent ELSE parent→child`). That flip is a tree being bent into a DAG by hand.
- **No place for the distribution layer.** The tree jumps from `SOURCE` straight to organisational `CATEGORY`, so the real switchboards have nowhere to live. 29 active tenant-3 devices are unmapped, and 12 of them are exactly that layer:

  ```
  LVAB    Incoming Factory A&B     LV630   LVMDB TF 630kVA
  LVA1    LVMDB A1                 LVTX    LVMDB Texture TF 1600kVA
  LVA2    LVMDB A2                 LVTX-02 LVMBD Texture TF 2000kVA
  LVA5    LVMDB A5                 LV-SP1  LVMDP Spinning 1
  LVB2    LVMDB B2                 LV-SP2  LVMDP Spinning 2
  PLTSC   PLTS A4                  PLTSD   PLTS Texture
  ```

- **No cross-utility handoff.** A compressor is the end of the electricity network and the start of the compressed-air network. The tree has one edge type, so it cannot say "electricity in, air out".
- **Meter/topology mismatch handled by arithmetic.** Device 98 (Compressor SCR 2200) is mapped `+1 → COMP_SCR2200` and `−1 → HVAC_A4`, because the HVAC_A4 meter physically covers both. That is a topology fact encoded as a hand-entered multiplier.

`public.assets` (141 rows) / `public.asset_connections` (12 rows) were an earlier attempt at the same problem — they even carry `source_utility`, `output_utility`, `flow_direction`, `utility_level` — but were never populated and nothing in the live query path reads them.

## 2. Decisions

| # | Decision | Chosen |
|---|---|---|
| 1 | Topology | **DAG.** Multiple in-edges per node, no cycles. Not mesh-with-switching — nothing in the plant reconfigures which source feeds which load. |
| 2 | Granularity | **Full physical SLD, including unmetered panels.** ~250+ nodes. Electricity only for now; the accurate SLD exists. |
| 3 | Cross-utility | **One node, typed edges.** A compressor is a single node with an `ELECTRICITY` in-edge and an `AIR` out-edge. |
| 4 | Measurement | **Node-attached for electricity now; edge-attached available from day one** for air branch meters later. |
| 5 | Source attribution | **Source totals only.** No downstream allocation of "which kWh came from PV". |
| 6 | Unmetered handling | **`UNACCOUNTED` residual node**, emitted at query time as a synthetic child, matching existing Sankey practice. |
| 7 | Reporting rollups | **Unchanged.** The ~30 hardcoded-device-list report functions stay as they are. Node tags are a future migration. |

### Why full SLD is worth 250 nodes

Unmetered panels are a **scaffold for future meters**. The node exists from day one; when a meter is installed you add one `graph.measurement` row with `effective_from = install date`. Sankey before that date derives the panel's value from downstream, after it uses the meter — same query, no restructuring.

It also dissolves the device-98 hack: with the real board modelled, `HVAC_A4_BOARD` has the compressor as one of its children and HVAC's true consumption is derived from topology instead of a `−1` multiplier nobody will remember the reason for.

## 3. Blast radius (verified against the live database)

| Retire | Breaks |
|---|---|
| `public.assets` + `public.asset_connections` | 18 `public.*` functions (`get_downstream_assets`, `get_upstream_sources`, `get_sankey_auto_flow`, …) — **all unused**, nothing in the live path calls them |
| `prs.device_hierarchy` + `prs.device_node_mapping` | exactly **3** functions: `prs.get_hierarchy_device_summary`, `prs.get_hierarchy_device_values`, `prs.get_sankey_energy_flow_v2` |

**The daily reporting is already safe.** 18 functions hardcode `device_id` lists (13 in `prs` incl. every `excel_reporter_*`, 5 in `iop`). Zero of them reference `device_hierarchy` or `device_node_mapping` — they read `daily_energy_cost_summary` / `telemetry_15min_agg` directly. No view anywhere depends on `assets`, `asset_connections`, `device_hierarchy`, or `device_node_mapping`.

Consequence: **the graph is built additively.** New schema alongside the old, `device_hierarchy` left running until the graph reproduces the Sankey, then port 3 functions and drop. No big-bang migration.

---

## 4. Schema

New schema `graph`, kept separate from `prs` (which is product-specific) because the graph is multi-tenant infrastructure.

### 4.1 Utility reference (WAGES)

`quantities.category` already carries these exact values — Electricity 3672, Water 1593, Air 244, Steam 164, Gas 133 — so this table joins straight onto the existing quantity dictionary.

```sql
CREATE SCHEMA IF NOT EXISTS graph;

COMMENT ON SCHEMA graph IS
  'WAGES (Water/Air/Gas/Electricity/Steam) network topology: nodes, typed edges, measurements.';

CREATE TABLE graph.utility (
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
  ('STEAM',       'Steam',          'kg',  'Steam',       '#b07bd4', 5);
```

### 4.2 Nodes

```sql
CREATE TABLE graph.node (
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

CREATE INDEX idx_node_tenant_active ON graph.node (tenant_id) WHERE is_active;
CREATE INDEX idx_node_tenant_class  ON graph.node (tenant_id, node_class);
CREATE INDEX idx_node_attrs         ON graph.node USING gin (attrs);
```

`node_class` semantics — the rule that keeps electricity and air symmetric is **a thing that holds inventory or has state is a node; a thing that only conveys is an edge**:

| class | Electricity | Compressed air |
|---|---|---|
| `SOURCE` | PLN incomer, gas engine, PV plant | — |
| `BUS` | LVMDP / LVMDB / switchboard | main header, ring main *(has pressure, multiple taps — structurally a busbar)* |
| `DISTRIBUTION` | sub-panel, MCC | branch manifold |
| `CONVERSION` | transformer, **compressor** | dryer |
| `STORAGE` | battery, capacitor bank | air receiver / tank |
| `LOAD` | motor, HVAC, machine | pneumatic consumer |

> **`DISTRIBUTION` was retired by migration 032 (2026-10-01).** Migration 026 moved the main/sub level into `node_type`: `MAIN_LV_BOARD` and `SUB_BOARD` are both `BUS` subtypes of `SWITCHBOARD`, and the readers that care about the level key on the type. No node, type or endpoint rule ever used the class. A level below a bus is a node type, never a class. The DDL above and the water class table further down show the design as it stood in 008.

`attrs` is free-form per class — `voltage_level`, `rated_capacity_kva`, `phases` for electricity; `operating_pressure_bar`, `volume_m3` for air. Kept in JSONB rather than columns because the useful attributes differ per utility and per class.

**`node_class` is descriptive, not structural.** The solver reads it nowhere; traversal, aggregation and residuals are driven entirely by topology (`in_degree` / `out_degree`) and measurements. Reclassifying a node — the engineers report that what you drew as a `LOAD` is really another board — is an `UPDATE` plus new child rows. The node keeps its `id`, `node_code` and measurements, and its parent's arithmetic is unchanged. The only visible effect is correct: `out_degree` becomes non-zero, so the node becomes eligible for an `UNACCOUNTED` residual. Note `node_class` has no temporal versioning, so a reclassification applies retroactively across all history; record *when* you learned it by setting `effective_from` on the new edges instead.

**`is_passthrough` is structural.** It asserts that a node consumes nothing itself — a pure conveyance point such as an air receiver, a bus tie, or a metering cubicle. It licenses solver rule (a) to push the node's whole value down its single out-edge. Set it only where it is physically true; on a board with any unmetered load of its own it will silently erase a real residual.

### 4.3 Edges (typed — this is what makes WAGES work)

```sql
CREATE TABLE graph.edge (
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
        ('FEEDER','CABLE','BUSTIE','PIPE','HEADER_BRANCH','DUCT','CONVERSION',
         'COMPENSATION')),                                 -- added by 024
    CONSTRAINT ck_edge_dates CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE INDEX idx_edge_from    ON graph.edge (from_node_id) WHERE is_active;
CREATE INDEX idx_edge_to      ON graph.edge (to_node_id)   WHERE is_active;
CREATE INDEX idx_edge_utility ON graph.edge (tenant_id, utility_code) WHERE is_active;
```

The composite FKs `(from_node_id, tenant_id) → node(id, tenant_id)` make cross-tenant edges structurally impossible without a trigger.

**"A separate graph per WAGES type" is a filter, not separate tables.** The electricity network is `WHERE utility_code = 'ELECTRICITY'`; the air network is `WHERE utility_code = 'AIR'`. A compressor has edges of both types, so it appears in both traversals automatically — no cross-graph link table, no duplicated nodes.

**`COMPENSATION` is the one edge class the solver skips** (migration 024). It joins a bus to a capacitor bank — a `STORAGE` node carrying its nameplate in `attrs` (`rated_kvar`, `step_kvar[]`, `control`, `target_pf`, `site_status`). A bank is unmetered by construction and carries no kWh, and no solver rule pushes a parent's residual down to an unmetered child, so as a `FEEDER` it would resolve to nothing while turning its bus into a parent: a board with no other children would show its whole consumption as `UNACCOUNTED`, and an unmetered board would lose rule (c) `OUT_EDGES` and its `SUM`/`RSS` rollup, both of which need every out-edge known. `graph.solve_flow` and `graph.get_node_quantity` therefore exclude `COMPENSATION` edges; topology readers (`descendants()`, `v_coverage`, `wages_sync export`) keep them. The bank's output is still visible where it always was — as its bus's negative reactive residual — and `pf_report.py` assesses each bank against it. The exclusion is keyed on the edge, not on `node_class = 'STORAGE'`, because class stays descriptive (§4.2) and an air receiver is a `STORAGE` node that flow must pass through.

### 4.4 Measurements

```sql
CREATE TABLE graph.measurement (
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

CREATE INDEX idx_meas_node   ON graph.measurement (node_id)   WHERE is_active;
CREATE INDEX idx_meas_edge   ON graph.measurement (edge_id)   WHERE is_active;
CREATE INDEX idx_meas_device ON graph.measurement (tenant_id, device_id) WHERE is_active;

CREATE UNIQUE INDEX uq_meas_node_dev_qty ON graph.measurement
    (node_id, device_id, quantity_id, effective_from) WHERE node_id IS NOT NULL;
CREATE UNIQUE INDEX uq_meas_edge_dev_qty ON graph.measurement
    (edge_id, device_id, quantity_id, effective_from) WHERE edge_id IS NOT NULL;
```

> **`quantity_id` is `NOT NULL`, deliberately.** It was originally nullable, meaning "every
> quantity this device reports". That is the same failure shape as the double-seeded mappings
> in §10.1: a value that matches more than one row and silently sums them. Schneider meters
> expose active energy on **two** registers, quantity 124 and quantity 130, and both land in
> `daily_energy_cost_summary` — 31 tenant-3 devices carry both, with identical values. A
> `NULL` match would double-count every one of them. See §12.
>
> Both unique indexes exist for the same reason: `NULL <> NULL` is exactly why
> `uq_device_node_mapping` failed to stop the 22 duplicate rows now sitting in
> `prs.device_node_mapping`. `quantity_id NOT NULL` is what makes these indexes bite.

- `node_id XOR edge_id` — exactly one, enforced by `num_nonnulls(...) = 1`. Costs one nullable column; lets electricity start node-only and air add edge meters later with no migration.
- `role`: `TOTAL` contributes to the target's total; `SUBMETER` is informational only; `CHECK` is a redundant meter kept for validation, never summed. `role` answers *which meter speaks for this node* — a trust question. It is orthogonal to *how a quantity composes across topology*, which lives in `graph.quantity_rule` (§4.7).
- `multiplier` is retained from `device_node_mapping` — several devices summing to one node is legitimate (`FINISHING_22` currently sums 6). The `−1` *topology* hacks should disappear during the redraw, but the mechanism stays for genuine arithmetic.
- `effective_from/to` is the mechanism that makes the unmetered-panel scaffold work.

> **`effective_from` defaults to `'-infinity'`, deliberately — not `CURRENT_DATE`.**
> Topology is assumed to have always existed unless stated otherwise. If nodes and edges
> defaulted to `CURRENT_DATE`, the whole SLD seeded today would be invisible to every
> historical query — the Phase 3 validation against last month would return zero rows.
> Set `effective_from` explicitly only for a genuine change: a meter installed on a known
> date, a feeder commissioned, a board decommissioned (`effective_to`).

> **Which end of the pipe is the meter on — node or edge?** For electricity the answer is nearly
> always the node: a panel meter in a cubicle reads that board's total, and §2 fixed node-attached
> measurement as the default. **Water inverts it.** Every water meter in this plant is a flow meter
> tapped into a distribution pipe, and a pipe is an edge. The rule that decides it:
>
> | The device reads… | It measures | Attach to |
> |---|---|---|
> | flow or volume *through a pipe segment* | the segment | **`edge_id`** |
> | a board, vessel or header total | the thing itself | **`node_id`** |
> | tank level, pressure, temperature — inventory or state | the thing itself | **`node_id`** |
>
> This is not cosmetic. A flow meter modelled as a node forces an instrument into the topology as
> if it were equipment — `FLOW_METER_SOFTENER_1` is a node in the seed today — which then needs
> fabricated in- and out-edges to connect to anything. Modelled as an edge, the instrument vanishes
> from the topology and the P&ID's real vessels and headers are the only nodes. §10.2 rebuilds the
> six water rows on that basis.

### 4.5 Cycle prevention

Non-negotiable with ~250 hand-entered nodes.

```sql
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

CREATE TRIGGER trg_edge_acyclic
    BEFORE INSERT OR UPDATE OF from_node_id, to_node_id, is_active ON graph.edge
    FOR EACH ROW WHEN (NEW.is_active)
    EXECUTE FUNCTION graph.assert_acyclic();
```

`UNION` (not `UNION ALL`) guarantees termination. On `INSERT` the row is not yet visible in a `BEFORE` trigger; on `UPDATE` the stale version is excluded by id. Cheap at this graph size.

### 4.6 `updated_at` trigger

```sql
CREATE OR REPLACE FUNCTION graph.touch_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_node_touch BEFORE UPDATE ON graph.node
    FOR EACH ROW EXECUTE FUNCTION graph.touch_updated_at();
```


### 4.7 Quantity semantics — how a measurement composes

Energy is one quantity among many, and it is the *easy* one. Three tables say what the schema
otherwise cannot: which registers are redundant, how a quantity collapses over time and across
the topology, and which quantities are computed rather than measured.

```sql
-- (i) Redundant registers. Some meters expose the same physical quantity twice.
CREATE TABLE graph.quantity_alias (
    quantity_id           INTEGER PRIMARY KEY REFERENCES public.quantities (id),
    canonical_quantity_id INTEGER NOT NULL    REFERENCES public.quantities (id),
    note                  TEXT,
    CONSTRAINT ck_alias_not_self CHECK (quantity_id <> canonical_quantity_id)
);

INSERT INTO graph.quantity_alias VALUES
  (130, 124, 'Schneider Active Energy Delivered-Received; same physical energy as 124');

-- (ii) Composition rules.
CREATE TABLE graph.quantity_rule (
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
  (2097,'ELECTRICITY','P95',  'RSS',     FALSE),  -- THD Current A (% of fundamental; DB name "THD RMS Current A" is misleading)
  (5696,'WATER',      'DELTA','SUM',     TRUE);   -- Water Volume Supply (m3)

-- Air/gas/steam have no meters in the live database yet. When they arrive the rows
-- take the same shape -- and note that BOTH are needed for one flow meter:
--   (<id>,'AIR','DELTA','SUM',  TRUE)   -- cumulative Nm3 totaliser: MAX - MIN
--   (<id>,'AIR','AVG',  'NONE', FALSE)  -- instantaneous flow rate: never summed

-- (iii) Quantities that are computed at a node, never rolled up.
CREATE TABLE graph.derived_quantity (
    code          VARCHAR(40) PRIMARY KEY,
    utility_code  VARCHAR(20) NOT NULL REFERENCES graph.utility (code),
    display_name  VARCHAR(80) NOT NULL,
    formula       VARCHAR(20) NOT NULL,
    p_quantity_id INTEGER NOT NULL REFERENCES public.quantities (id),
    q_quantity_id INTEGER NOT NULL REFERENCES public.quantities (id),
    CONSTRAINT ck_derived_formula CHECK (formula IN ('PQ_RATIO'))
);

INSERT INTO graph.derived_quantity VALUES
  ('PF_TRUE','ELECTRICITY','Power Factor','PQ_RATIO', 124, 89);

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

CREATE TRIGGER trg_meas_canonical
    BEFORE INSERT OR UPDATE OF quantity_id ON graph.measurement
    FOR EACH ROW EXECUTE FUNCTION graph.assert_canonical_quantity();
```

**Two axes, not one.** `public.quantities.aggregation_method` already exists but is
*stage-ambiguous*: quantity 124 is `is_cumulative = TRUE` **and** `aggregation_method = 'SUM'`,
which look contradictory until you notice they describe different points in the pipeline. In
`telemetry_15min_agg` the values are raw lifetime totalisers (they run to 115,797,552 on a single
day); in `daily_energy_cost_summary` they are already differenced (max 25,896 kWh/day). `SUM` is
wrong at the first stage and right at the second. `raw_time_agg` states the first explicitly and
`network_agg` states what happens across an edge — neither is inferred. Seed them *from*
`aggregation_method`, then review every row (§12).

| `network_agg` | Behaviour | Quantities |
|---|---|---|
| `SUM` | **Extensive** — sums upward along edges; conservation applies | kWh, kVArh, m³, Nm³ |
| `RSS` | Sums upward as `sqrt(Σ x²)` — harmonic currents combine per order, with cancellation | THD current, per-order magnitudes |
| `INHERIT` | **Intensive** — propagates *downward*; a node with no meter of its own experiences its feeder's value | voltage, frequency, THD voltage |
| `NONE` | Never propagates; measured nodes only | power factor as read from the meter |

`conserved = TRUE` is what licenses the flow-balance solve and the `UNACCOUNTED` residual.
`graph.solve_flow` refuses to run without it — otherwise a caller could pass quantity 1072 and get
a beautifully balanced, entirely meaningless power factor complete with a residual.

**Why power factor is `NONE` and `PF_TRUE` exists instead.** A bus's PF is not the average of its
children's PF, nor a kWh-weighted average. It is `ΣP / sqrt((ΣP)² + (ΣQ)²)` — sum the extensive
components, then derive. A 5 kW machine at 0.55 barely moves an 800 kW bus; a 300 kW compressor
bank at 0.82 dominates it, and summing P and Q gets that weighting for free. Since 124 and 89 are
both `conserved`, PF resolves at **every** node in the graph, including unmetered ones whose P and
Q come up from the flow balance. §11.2 shows this producing a valid PF for a node with no meter.

> **Netting Delivered against Received is not yet modelled.** Physically, net reactive energy is
> `89 − 96` and net active energy is `124 − 131` on any node that exports. A `multiplier = -1`
> measurement row does **not** achieve this: `solve_flow` runs per `quantity_id`, so a row carrying
> quantity 96 participates only in the 96 solve and is invisible when solving 89. `quantity_alias`
> cannot express it either — that means *prefer one register or the other*, never *add them with a
> sign*. Netting would need a third relation (`canonical`, `component`, `sign`), and it is not built
> because it is not yet needed: `Active Energy Received` totals **zero** across all 80 tenant-3
> devices reporting it. Revisit when a node genuinely exports. See §13.

> **Apparent energy is not additive**, despite being an energy. `S_total = sqrt(P_total² + Q_total²)
> ≤ Σ S_i`, because loads at different phase angles do not add their kVAh linearly — two 100 kVAh
> loads, one purely resistive and one purely reactive, make 141 kVAh at the bus, not 200. So 62 and
> 481 are `network_agg = 'NONE'`: a bus's apparent energy is *derived* from summed P and Q, exactly
> like power factor. Only true extensive quantities get `SUM`.

---

## 5. Value resolution

### 5.1 Per-utility telemetry source

The pipelines differ by utility — electricity carries tariff and shift through `daily_energy_cost_summary`, water bypasses it entirely via `telemetry_intervals_water` (which handles counter overflow and resets). One function isolates that difference so the graph traversal stays utility-agnostic.

Routing is by **quantity**, not just utility. `daily_energy_cost_summary` and `telemetry_intervals_water` hold *conserved* quantities only; power quality for the same utility lives in raw `telemetry_15min_agg` and is collapsed per `raw_time_agg`. Without that split, asking for THD voltage on `ELECTRICITY` would search a table that only ever holds energy.

```sql
CREATE OR REPLACE FUNCTION graph.device_totals(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_quantity_id   INTEGER,
    p_is_cost       BOOLEAN   DEFAULT FALSE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3']
) RETURNS TABLE (device_id INTEGER, quantity_id INTEGER, total NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_src       INTEGER[];
    v_rule      VARCHAR;
    v_conserved BOOLEAN;
BEGIN
    IF p_quantity_id IS NULL THEN
        RAISE EXCEPTION 'graph.device_totals: p_quantity_id is required — a NULL match sums redundant registers (e.g. 130 alongside 124)';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.quantity_alias a WHERE a.quantity_id = p_quantity_id) THEN
        RAISE EXCEPTION 'graph.device_totals: quantity % is a register alias; pass its canonical id', p_quantity_id;
    END IF;

    SELECT array_agg(s.x) INTO v_src FROM (
        SELECT p_quantity_id AS x
        UNION
        SELECT a.quantity_id FROM graph.quantity_alias a
         WHERE a.canonical_quantity_id = p_quantity_id) s;

    -- Route by quantity, not just utility: daily_energy_cost_summary and
    -- telemetry_intervals_water hold *conserved* quantities only. Power quality
    -- for the same utility lives in raw telemetry.
    v_conserved := COALESCE((SELECT qr.conserved FROM graph.quantity_rule qr
                              WHERE qr.quantity_id = p_quantity_id), TRUE);

    IF p_utility_code = 'ELECTRICITY' AND v_conserved THEN
        RETURN QUERY
        WITH src AS (
            SELECT d.device_id AS did, d.quantity_id AS qsrc,
                   (d.quantity_id <> p_quantity_id) AS is_alias,
                   (CASE WHEN p_is_cost THEN d.total_cost ELSE d.total_consumption END) AS v
            FROM daily_energy_cost_summary d
            WHERE d.tenant_id = p_tenant_id
              AND d.daily_bucket >= p_start AND d.daily_bucket <= p_end
              AND d.shift_period = ANY (p_shift_periods)
              AND d.quantity_id = ANY (v_src)
        ), pref AS (          -- canonical register wins; alias only if canonical absent
            SELECT DISTINCT ON (s.did) s.did AS did, s.qsrc AS qsrc
            FROM src s ORDER BY s.did, s.is_alias
        )
        SELECT s.did, p_quantity_id, SUM(s.v)
        FROM src s JOIN pref p ON p.did = s.did AND p.qsrc = s.qsrc
        GROUP BY s.did;

    ELSIF p_utility_code = 'WATER' AND v_conserved THEN
        RETURN QUERY
        SELECT w.device_id, p_quantity_id, SUM(w.interval_m3)
        FROM telemetry_intervals_water w
        WHERE w.tenant_id = p_tenant_id
          AND w.bucket >= p_start AND w.bucket <= p_end
          AND w.is_valid_interval
          AND w.quantity_id = ANY (v_src)
        GROUP BY w.device_id;

    ELSE   -- raw telemetry, collapsed per graph.quantity_rule.raw_time_agg
        v_rule := COALESCE((SELECT qr.raw_time_agg FROM graph.quantity_rule qr
                             WHERE qr.quantity_id = p_quantity_id), 'SUM');
        RETURN QUERY
        WITH raw AS (
            SELECT t.device_id AS did, t.bucket AS b, t.aggregated_value AS v
            FROM telemetry_15min_agg t
            JOIN quantities q       ON q.id = t.quantity_id
            JOIN graph.utility u    ON u.quantity_category = q.category
            WHERE t.tenant_id = p_tenant_id
              AND u.code = p_utility_code
              AND t.bucket >= p_start AND t.bucket <= p_end
              AND t.quantity_id = ANY (v_src)
        )
        SELECT r.did, p_quantity_id,
               (CASE v_rule
                  WHEN 'DELTA' THEN MAX(r.v) - MIN(r.v)
                  WHEN 'AVG'   THEN AVG(r.v)
                  WHEN 'LAST'  THEN (array_agg(r.v ORDER BY r.b DESC))[1]
                  WHEN 'P95'   THEN (percentile_cont(0.95)
                                     WITHIN GROUP (ORDER BY r.v))::NUMERIC
                  ELSE              SUM(r.v)
                END)::NUMERIC
        FROM raw r GROUP BY r.did;
    END IF;
END;
$$;
```

**The DELTA branch is hardened against the two things live cumulative registers actually do** (added in `017_harden_delta_branch.sql`; the conserved paths never needed it because `telemetry_intervals_cumulative` and `telemetry_intervals_water` already guard them).

`MAX(v) − MIN(v)` is the obvious reading of "how much did this totaliser advance", and it is wrong twice over on this fleet:

| Failure | What it does to `MAX − MIN` | Seen live |
|---|---|---|
| **NaN bucket** | `NUMERIC` sorts `NaN` above every real value, so `MAX` returns `NaN`. The device totals `NaN`, and `solve_flow` carries it to every node above | device 103 `MC 3`, 2026-07-28 01:45, on quantities 131 and 481 |
| **Counter reset** | `MIN` lands after the reset while `MAX` sits before it, so the window reports a large slice of the *lifetime* counter as consumption | device 55 `MC 9` resets quantity 481 to zero 391 times in 30 days; device 27 `PLTS A` drops 1,756,259 → 1.0 |

Summing forward differences fixes both: a reset produces one negative difference, which is dropped, and a `NaN` row is excluded before the window function ever sees it. Two details are deliberate:

- **One hour of lookback before `p_start`.** Without it the first in-window bucket has no predecessor and its interval is silently lost — a systematic understatement that grows worse the shorter the window. The lookback is one cadence, not one day, because a predecessor far outside the window would attribute pre-window consumption to it.
- **The `999999` ceiling is borrowed, not invented.** `public.telemetry_intervals_cumulative` already rejects an interval above it as a register correction. Using the same number keeps the conserved and raw paths from disagreeing about what counts as a plausible fifteen minutes.

The `NaN` filter applies to the non-DELTA rules too. `AVG` and `percentile_cont` both return `NaN` from a single poisoned row, so power quality would have inherited the same failure.

### 5.2 This is a flow-balance solve, not a single pass

Two facts make naive traversal wrong, and both show up in the very first real slice of the SLD.

**Fact 1 — a child's value is not attributable to one parent.** `FACTORY_AB` is metered at 2,300, and its children sum to 900 + 800 + 450 + 400 = **2,550**. A naive `measured − Σ(children)` residual gives **−250**, which is nonsense. `LVMDB_A5` and `LVMDB_TEXTURE` each receive part of their value from PV, not from `FACTORY_AB`. The residual must be computed against **out-edge** values: 900 + 800 + **150** + **200** = 2,050, so the true residual is **+250**.

**Fact 2 — a metered node constrains its edges in both directions.** All meters here are node-attached, so no edge has a direct measurement. But `PLTS_A4` is a `SOURCE` metered at 300 with exactly one feeder — that feeder carries 300, full stop. Without that rule, `LVMDB_A5`'s two in-edges both look unknown and get split evenly at 225 each, which is wrong twice over.

So node values and edge values are mutually constraining, and the resolver is a **bounded fixed-point iteration** over four rules:

| | Rule | Applies when |
|---|---|---|
| **a** | out-edge = node value | node cannot consume anything itself — a graph head (`in_degree = 0`) or one flagged `is_passthrough` — has `out_degree = 1` and a known value. Skipped where rule (b) can resolve the target from the target's own meter |
| **b** | unknown in-edges share the remainder | node value known; `remainder = value − Σ(known in-edges)`, split across unknown in-edges (`is_ambiguous` if more than one) |
| **c** | node value = Σ edges | every in-edge known (and `in_degree > 0`), or every out-edge known (and `out_degree > 0`) |
| **d** | node value = Σ child values | last resort only, once **a–c** have stopped producing anything |

Rule **d** is deliberately quarantined until a–c converge. Applied eagerly it would give the unmetered `GAS_ENGINE` its child's full value (2,300) instead of its actual share (1,100).

Rule **a**'s two guards matter and were both found by testing. Keying on `in_degree = 0` rather than `node_class = 'SOURCE'` is what makes the compressed-air graph work: a compressor is `CONVERSION`, but in the `AIR` graph it is the root, and under the old rule its output never reached the receiver. The `is_passthrough` extension carries that one hop further through pure-conveyance nodes. The skip condition is the other half — without it, a metered head feeding one metered child would have its full value forced onto the edge, showing zero residual where the difference between the two meters is real unmetered load.

Tracing the worked example: **(a)** fixes the PLN, PLTS A4 and PLTS Texture feeders from their source meters → **(b)** gives `GAS_ENGINE → FACTORY_AB = 2,300 − 1,200 = 1,100` and `FACTORY_AB → LVMDB_A5 = 450 − 300 = 150` → **(c)** gives the unmetered `GAS_ENGINE` a value of 1,100 from its single known out-edge. Converged in one pass; rule **d** never fires.

### 5.3 The solver

Populates temp tables `_gn` (nodes) and `_ge` (edges), which the public functions then read. `VOLATILE`, not `STABLE` — it creates temp tables. It handles **conserved quantities only** and raises otherwise; non-flow quantities go through §11.

> Every temp-table column must be **explicitly qualified** (`_gn.value`, not `value`). The `RETURNS TABLE` output names of the calling functions are in scope as PL/pgSQL variables and will otherwise collide (`ERROR: column reference "value" is ambiguous`).

```sql
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
```

### 5.4 The two flow entry points

```sql
CREATE OR REPLACE FUNCTION graph.get_node_values(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_quantity_id   INTEGER,
    p_is_cost       BOOLEAN   DEFAULT FALSE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3'],
    p_as_of         DATE      DEFAULT CURRENT_DATE
) RETURNS TABLE (
    node_id BIGINT, node_code VARCHAR, node_name VARCHAR, node_class VARCHAR,
    measured NUMERIC, value NUMERIC, unaccounted NUMERIC,
    origin VARCHAR, has_data BOOLEAN)
LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    PERFORM graph.solve_flow(p_tenant_id, p_utility_code, p_start, p_end,
                             p_quantity_id, p_is_cost, p_shift_periods, p_as_of);
    RETURN QUERY
    SELECT n.id, n.node_code, n.node_name, n.node_class, n.measured, n.value,
           CASE WHEN n.val_src IN ('MEASURED','IN_EDGES')
                 AND o.out_sum IS NOT NULL AND n.value - o.out_sum > 0
                THEN n.value - o.out_sum END,
           n.val_src, n.has_data
    FROM _gn n
    LEFT JOIN (SELECT g.from_node_id AS nid, SUM(g.value) AS out_sum
               FROM _ge g GROUP BY g.from_node_id) o ON o.nid = n.id;
END;
$$;

CREATE OR REPLACE FUNCTION graph.get_sankey_flow(
    p_tenant_id     INTEGER,
    p_utility_code  VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_quantity_id   INTEGER,
    p_is_cost       BOOLEAN   DEFAULT FALSE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3'],
    p_as_of         DATE      DEFAULT CURRENT_DATE,
    p_unaccounted_threshold NUMERIC DEFAULT 0
) RETURNS TABLE (
    source TEXT, target TEXT, value NUMERIC,
    is_ambiguous BOOLEAN, is_unaccounted BOOLEAN)
LANGUAGE plpgsql VOLATILE AS $$
BEGIN
    PERFORM graph.solve_flow(p_tenant_id, p_utility_code, p_start, p_end,
                             p_quantity_id, p_is_cost, p_shift_periods, p_as_of);
    RETURN QUERY
    SELECT sn.node_name::TEXT, tn.node_name::TEXT, g.value, g.amb, FALSE
    FROM _ge g JOIN _gn sn ON sn.id = g.from_node_id JOIN _gn tn ON tn.id = g.to_node_id
    WHERE g.value > 0
    UNION ALL
    SELECT n.node_name::TEXT, (n.node_code || '__UNACCOUNTED')::TEXT,
           n.value - o.out_sum, FALSE, TRUE
    FROM _gn n
    JOIN (SELECT g.from_node_id AS nid, SUM(g.value) AS out_sum
          FROM _ge g GROUP BY g.from_node_id) o ON o.nid = n.id
    WHERE n.val_src IN ('MEASURED','IN_EDGES')
      AND n.value - o.out_sum > p_unaccounted_threshold;
END;
$$;
```

**A residual is only claimed where the inflow is independently known** — `origin IN ('MEASURED','IN_EDGES')`. A node whose value was itself derived from its out-edges has a residual of zero by construction, and one derived from rule (d) would have a fabricated one. Residuals are also emitted only for nodes with `out_degree > 0` (the `JOIN` guarantees it), so metered leaves don't each sprout a meaningless `UNACCOUNTED` equal to their whole consumption.

### 5.5 Three failure modes the UI must not conflate

| Situation | Signal | Meaning |
|---|---|---|
| residual | `is_unaccounted = TRUE` | the node's inflow is independently known and its out-edges don't add up — **real unmetered load** |
| dead branch | `has_data = FALSE` | node has no meter *and* no metered neighbour — contributes **0**, invisible in the Sankey |
| undetermined split | `is_ambiguous = TRUE` | more than one unknown in-edge; the split shown is an even guess |

`get_node_values` returns the provenance directly as `origin` — `MEASURED`, `IN_EDGES`,
`OUT_EDGES`, `CHILDREN`, or `NULL` for a dead branch — so the UI can distinguish a number that
was read from one that was inferred, and say which way.

The second is the specific hazard of a full SLD: a branch of unmetered panels feeding unmetered loads silently contributes nothing rather than showing a gap. A coverage view makes it visible:

```sql
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
```

> **`is_metered` was split in two because water broke it.** The original view asked only
> `EXISTS (… m.node_id = n.id)`. In a network metered entirely on its pipes — which is every
> water meter in this plant (§10.2) — that returns `FALSE` for all eleven nodes, including the
> six sitting directly on a meter. A coverage view that reports total blindness on a fully
> instrumented network is worse than no view. `is_node_metered OR is_edge_metered` is the
> question "do we have any instrument that speaks to this node"; the two columns separately
> answer "does it read the node, or the pipe".

---

## 6. Worked example — Factory A&B, real device IDs

```sql
-- Nodes
INSERT INTO graph.node (tenant_id, node_code, node_name, node_class, attrs) VALUES
 (3,'INCOMING_PLN','Incoming PLN 1','SOURCE','{"voltage_level":"20kV"}'),
 (3,'GAS_ENGINE',  'Gas Engine',    'SOURCE','{"fuel":"NATURAL_GAS"}'),
 (3,'PLTS_A4',     'PLTS A4',       'SOURCE','{"type":"PV"}'),
 (3,'PLTS_TEXTURE','PLTS Texture',  'SOURCE','{"type":"PV"}'),
 (3,'FACTORY_AB',  'Incoming Factory A&B','BUS','{"voltage_level":"400V"}'),
 (3,'LVMDB_A1',    'LVMDB A1',      'BUS','{}'),
 (3,'LVMDB_A2',    'LVMDB A2',      'BUS','{}'),
 (3,'LVMDB_A5',    'LVMDB A5',      'BUS','{}'),
 (3,'LVMDB_TEXTURE','LVMDB Texture TF 1600kVA','BUS','{"rated_kva":1600}'),
 (3,'COMP_KAESER', 'Compressor KAESER','CONVERSION','{}'),
 (3,'AIR_HEADER',  'Compressed Air Main Header','BUS','{"operating_pressure_bar":7}');

-- Electricity edges (note the two merges)
INSERT INTO graph.edge (tenant_id, from_node_id, to_node_id, utility_code, edge_class)
SELECT 3, f.id, t.id, 'ELECTRICITY', 'FEEDER'
FROM (VALUES
  ('INCOMING_PLN','FACTORY_AB'),
  ('GAS_ENGINE',  'FACTORY_AB'),      -- merge #1
  ('FACTORY_AB',  'LVMDB_A1'),
  ('FACTORY_AB',  'LVMDB_A2'),
  ('FACTORY_AB',  'LVMDB_A5'),
  ('PLTS_A4',     'LVMDB_A5'),        -- merge #2
  ('FACTORY_AB',  'LVMDB_TEXTURE'),
  ('PLTS_TEXTURE','LVMDB_TEXTURE'),   -- merge #3
  ('LVMDB_A1',    'COMP_KAESER')
) AS v(fc, tc)
JOIN graph.node f ON f.tenant_id = 3 AND f.node_code = v.fc
JOIN graph.node t ON t.tenant_id = 3 AND t.node_code = v.tc;

-- Cross-utility handoff: same node, AIR out-edge
INSERT INTO graph.edge (tenant_id, from_node_id, to_node_id, utility_code, edge_class)
SELECT 3, f.id, t.id, 'AIR', 'PIPE'
FROM graph.node f, graph.node t
WHERE f.tenant_id = 3 AND f.node_code = 'COMP_KAESER'
  AND t.tenant_id = 3 AND t.node_code = 'AIR_HEADER';

-- Measurements (electricity, node-attached).
-- One row per (node, device, quantity): 124 active energy AND 89 reactive energy,
-- so power factor (§11.2) resolves at every node from the same topology.
INSERT INTO graph.measurement (tenant_id, node_id, device_id, utility_code, quantity_id)
SELECT 3, n.id, v.dev, 'ELECTRICITY', q.qid
FROM (VALUES
  ('INCOMING_PLN',  94),   -- MAIN-PLN  Incoming PLN 1
  ('PLTS_A4',      167),   -- PLTSC     PLTS A4
  ('PLTS_TEXTURE', 168),   -- PLTSD     PLTS Texture
  ('FACTORY_AB',    84),   -- LVAB      Incoming Factory A&B   (currently unmapped)
  ('LVMDB_A1',      23),   -- LVA1                             (currently unmapped)
  ('LVMDB_A2',      24),   -- LVA2                             (currently unmapped)
  ('LVMDB_A5',      28),   -- LVA5                             (currently unmapped)
  ('LVMDB_TEXTURE',107),   -- LVTX                             (currently unmapped)
  ('COMP_KAESER',   71)    -- COMP-05   Compressor KAESER
) AS v(code, dev)
JOIN graph.node n ON n.tenant_id = 3 AND n.node_code = v.code
CROSS JOIN (VALUES (124), (89)) AS q(qid);
```

Eight of those nine devices are unmapped in `device_hierarchy` today. That is the model earning its keep on the first slice.

The compressor's future air flow meter attaches to the **same node**, with `utility_code = 'AIR'` — which is what makes "query a node, see all its telemetry regardless of utility" work.

---

## 7. Grants

Matches the pattern in `007_grant_grafreader_permissions.sql`.

```sql
GRANT USAGE ON SCHEMA graph TO "grafReader";
GRANT SELECT ON ALL TABLES IN SCHEMA graph TO "grafReader";
ALTER DEFAULT PRIVILEGES IN SCHEMA graph GRANT SELECT ON TABLES TO "grafReader";
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graph TO "grafReader";
ALTER DEFAULT PRIVILEGES IN SCHEMA graph GRANT EXECUTE ON FUNCTIONS TO "grafReader";
```

Note: `graph.solve_flow` and `graph.get_node_quantity` create `TEMP` tables, so `grafReader` needs `TEMPORARY` on the database:
```sql
GRANT TEMPORARY ON DATABASE valkyrie TO "grafReader";
```
If that is unacceptable, rewrite the resolver using CTEs with a fixed iteration bound instead of temp tables.

---

## 8. Migration path

Additive throughout. Nothing existing is dropped until the graph demonstrably reproduces current output.

| Phase | File | Work | Risk |
|---|---|---|---|
| **0** | `008_create_graph_schema.sql`<br>`009_create_graph_functions.sql`<br>`010_grant_graph_permissions.sql` | Create `graph` schema, tables, triggers, `device_totals`, grants. Seed `graph.utility`, `graph.quantity_alias` (130→124), `graph.quantity_rule` and `graph.derived_quantity` | None — nothing reads it |
| **1–2** | `011_seed_tenant3_graph.sql` *(generated)* | Nodes, edges **and** measurements in one pass from the CSVs via `scripts/graph_seed_export.py` (§10.3) — full depth incl. unmetered panels | None |
| **3** | `012_verify_graph_migration.sql`<br>`013_fix_quantity_is_cumulative.sql` | **Validate `graph.get_sankey_flow()` against `get_sankey_energy_flow_v2`** for identical windows; correct `is_cumulative` on 131/481/5696 | None — 012 is read-only; 013's `UPDATE` is commented until reviewed |
| **4** | *(no SQL)* | Point the UI at the graph Sankey; keep `device_hierarchy` read-only as fallback | Low — revert by repointing |
| **4** | `019_port_functional_taxonomy.sql` | Port `prs.device_hierarchy` into the `FUNCTIONAL` taxonomy — 28 categories, 72 assignments (§15.6). **Must run before 014** | Medium — derives from the legacy tables, so it cannot be replayed once 014 drops them |
| **5** | `014_drop_legacy_hierarchy.sql` | Port `get_hierarchy_device_values` / `get_hierarchy_device_summary`; drop `prs.device_hierarchy`, `prs.device_node_mapping` | Low — 3 functions, verified |
| **6** | `015_drop_legacy_assets.sql` | Drop `public.assets`, `public.asset_connections`, and the unused `public.*` asset functions | Low for the 10 topology functions; the 8 application-facing ones are left commented |
| **0+** | `016_create_topology_primitives.sql` | `graph.descendants` / `graph.ancestors` / `graph.siblings` — reachability over `graph.edge`, shared by the dashboard and the analytics scripts (§14) | None — additive, `STABLE`, read-only |
| **0+** | `017_harden_delta_branch.sql` | `graph.device_totals` DELTA rule: sum forward differences instead of `MAX − MIN`, and exclude `NaN` buckets (§5.1) | None — `CREATE OR REPLACE`, signature unchanged, affects only the raw branch (quantities 62 and 481) |
| **0+** | `018_create_taxonomy_schema.sql` | `graph.taxonomy` / `graph.category` / `graph.node_category` + `graph.resolve_category` — the business rollup as a projection of the physical graph (§15) | None — additive; nothing reads it until the port seeds it |
| **7** | — | *(later)* Tenant 4 (43 devices, no hierarchy today); compressed air once the diagram exists; node tags to replace hardcoded report device lists; audit `quantities.aggregation_method` (§12.3) | — |
| — | `rollback_graph.sql` | Undo 008–011. Refuses once 014 has run, since that is no longer a revert | — |

Files live in `migrations/` (moved from `../prs_diags/docs/database/migrations/` on 2026-10-01), continuing the 001–007 series that stayed there. **016, 017 and 018 are numbered after the Phase 5/6 drops only because they were written later** — both are additive and apply any time after 009. 017 is a `CREATE OR REPLACE` of one function body; 009 carries the same definition, so a replay from scratch and an existing database running 009 + 017 converge byte for byte. **Phases 1 and 2 collapsed into one file** — the CSVs carry `device_ids`, so the measurements arrive with the topology and there is nothing left to port out of `device_node_mapping`; its 22 double-seeded pairs and the device-98 `−1` never reach the graph. 014 and 015 both refuse to run against an unpopulated graph, and 014 copies both legacy tables into `deprecated_tables.*_20260819` before dropping them.

### Phase 3 validation query

```sql
WITH old AS (
    SELECT source, target, SUM(value) v
    FROM prs.get_sankey_energy_flow_v2(3, '2026-07-01', '2026-07-31')
    GROUP BY 1, 2
),
new AS (
    SELECT source, target, SUM(value) v
    FROM graph.get_sankey_flow(3, 'ELECTRICITY', '2026-07-01', '2026-07-31')
    GROUP BY 1, 2
)
SELECT COALESCE(o.source, n.source) AS source,
       COALESCE(o.target, n.target) AS target,
       o.v AS old_value, n.v AS new_value,
       ROUND(100 * (n.v - o.v) / NULLIF(o.v, 0), 2) AS pct_diff
FROM old o FULL OUTER JOIN new n USING (source, target)
WHERE o.v IS DISTINCT FROM n.v
ORDER BY ABS(COALESCE(n.v, 0) - COALESCE(o.v, 0)) DESC;
```

Totals will **not** match exactly, and that is expected: the graph includes the 29 currently-unmapped devices. Grid-level totals should reconcile; leaf differences should be explainable device by device.

---

## 9. What was tested

Every statement in this document was extracted and executed end to end against a throwaway
PostgreSQL 14 cluster, with the `public` tables stubbed and the Factory A&B slice seeded using the
real device IDs. Bugs found and fixed this way:

| Bug | Symptom | Fix |
|---|---|---|
| the solver marked `STABLE` | temp-table creation rejected | `VOLATILE` |
| `FOR v_depth IN REVERSE (SELECT …)` | not valid PL/pgSQL | assign to a variable first |
| unqualified `value` / `measured` | `column reference "value" is ambiguous` — `RETURNS TABLE` names shadow columns | qualify every temp-table column |
| `effective_from DEFAULT CURRENT_DATE` on node/edge | whole SLD invisible to historical queries | `DEFAULT '-infinity'::date` |
| `percentile_cont(...)` inside a `CASE` | `returned type double precision does not match expected type numeric` | cast the whole `CASE` to `NUMERIC` |
| `device_totals` routed on utility alone | THD voltage on `ELECTRICITY` searched `daily_energy_cost_summary`, which only holds energy | route on `quantity_rule.conserved` as well |
| `v_coverage.is_metered` looked only at `m.node_id` | every node of an edge-metered network reported unmetered — all 11 water nodes, including the 6 sitting on a meter | split into `is_node_metered` / `is_edge_metered` |

**The full seed, end to end (§10.3):** `graph_seed_export.py` was run over both real CSVs and the
generated SQL replayed on a clean database with all 105 referenced devices stubbed.

| | |
|---|---|
| generated | 176 nodes, 231 edges (192 `ELECTRICITY`, 39 `WATER`), 882 node-attached and 6 edge-attached measurement rows |
| acyclic trigger | accepted all 231 edges |
| idempotent | second replay: 176 node upserts, **0** new edges, **0** new measurements |
| `BOILER_MIURA` | one node, three in-edges — `FEEDER` from `LVMDB_B2` and `PLTS_B`, `PIPE` from `WTP2_RO_PROC`; device 8 on the node, nothing on the pipe |
| water solve | `WTP2_CLR` 900 in / 840 out, **`UNACCOUNTED` 60** — the clarifier's sludge loss, from three metered outlet pipes against one metered inlet |
| electricity solve | 141 of 176 nodes valued (98 `MEASURED`, 3 `OUT_EDGES`, 2 `CHILDREN`), 147 flow edges, 9 residuals, 84 ambiguous |
| live check | `--verify-db` confirmed all 105 device ids exist, belong to tenant 3, and match their row's utility by `device_type` |

The 84 ambiguous electricity edges are not a defect: most loads in the seed are fed by a board
*and* a PLTS inverter in parallel, and that split genuinely cannot be derived from meters. They
are split evenly and flagged, which is §5.5's middle failure mode.

And three **design** errors:

1. The residual was originally computed as `measured − Σ(child node values)`, which returned
   **−250** for `FACTORY_AB`. That drove the rewrite of §5.2 into a flow-balance solve.
2. Rule (a) was keyed on `node_class = 'SOURCE'`, so a compressor — `CONVERSION`, but the root of
   the `AIR` graph — never propagated its output. Re-keyed on `in_degree = 0`, plus
   `is_passthrough` and the target-resolvable skip guard.
3. `get_sankey_flow` gated the `UNACCOUNTED` residual on `n.measured IS NOT NULL` — the node
   carrying a meter of its own. That silently assumed measurement is node-attached. Point every
   meter at a pipe instead, as water does, and **no residual is ever emitted**: the water slice
   below loses 1,500 m³ between what enters the process header and what leaves it, and the Sankey
   showed nothing. The condition was never about *having a meter*; it was about the node's inflow
   being known independently of its out-edges. `_gn.val_src` now records that, and the gate is
   `origin IN ('MEASURED','IN_EDGES')`. Electricity results are unchanged — those nodes are all
   `MEASURED`.

### Verified behaviour

**Flow (electricity) — unchanged by any of the above:**

- **Constraints** — cycle rejected, self-loop rejected, cross-tenant edge rejected by composite FK, `node_id`/`edge_id` both-set and neither-set rejected, `conserved` with `network_agg <> 'SUM'` rejected, duplicate `(node, device, quantity)` **and** duplicate `(edge, device, quantity)` rejected.
- **Merge resolution** — `Gas Engine → Factory A&B = 1,100` (2,300 − 1,200 PLN); `PLTS A4 → LVMDB A5 = 300`; `Factory A&B → LVMDB A5 = 150`. No spurious ambiguity flags.
- **Unmetered source solved** — `GAS_ENGINE` has no device row, yet resolves to 1,100.
- **Residual** — `FACTORY_AB__UNACCOUNTED = 250`, `LVMDB_A1__UNACCOUNTED = 400`, `LVMDB_A2__UNACCOUNTED = 800`. None on metered leaves or balancing sources.
- **Dead branch** — two unmetered panels below `LVMDB_A2` report `has_data = false` and value 0; the solver does *not* invent a 400/400 split.
- **Temporal scaffold** — a meter with `effective_from = 2026-08-15` is absent at `p_as_of = 2026-08-10` and active at `2026-08-20`, moving `LVMDB_A2`'s residual 800 → 700.
- **Utility isolation** — `AIR_HEADER` correctly excluded from the `ELECTRICITY` traversal.

**Redundant registers (§12.1):**

- `FACTORY_AB` carries device 84 on **both** 124 and 130 at 2,300 each and resolves to **2,300**, not 4,600.
- Device 30 reports **only** register 130 (100 kWh) and is returned correctly under canonical 124.
- `device_totals(…, NULL)` and `device_totals(…, 130)` both raise; inserting a measurement with `quantity_id = 130` raises.

**Cross-utility chain — the rule (a) fix:**

| | `COMP_KAESER` | `TANK_KAESER` | `AIR_HEADER` |
|---|---|---|---|
| `is_passthrough = TRUE` on the tank | 5,000 (measured) | 5,000 | **5,000** |
| `is_passthrough = FALSE` | 5,000 (measured) | 5,000, **unaccounted 5,000** | 0, `has_data = false` |

The compressor is metered only by a cumulative air totaliser on controller device 200
(1,000,000 → 1,005,000 raw), collapsed by `raw_time_agg = 'DELTA'`. Both rows are correct
behaviour: without the passthrough declaration the solver cannot know the receiver has no draw of
its own, and reporting 5,000 unaccounted is the honest answer.

**Flow (water) — every meter edge-attached, 11 nodes, 12 pipes, 6 real device IDs:**

Deep well → two clarifiers → softener header → three softeners → process header → dyeing and an
unmetered boiler-feed branch. Meters sit on the pipes (95, 96 on the clarifier feeds; 164, 165, 166
on the softener feeds; 97 on the dyeing draw). **No node carries a meter** — `measured` is `NULL`
everywhere — and the whole network still resolves:

| node | value | `origin` | unaccounted |
|---|---|---|---|
| `DEEP_WELL` | 2,400 | `OUT_EDGES` | — |
| `CLARIFIER_1` / `CLARIFIER_2` | 1,000 / 1,400 | `IN_EDGES` | 150 / 550 |
| `SOFT_HEADER` | 1,700 | `OUT_EDGES` | — |
| `SOFTENER_3/4/5` | 300 / 500 / 900 | `IN_EDGES` | — |
| `PROCESS_HEADER` | 1,700 | `IN_EDGES` | **1,500** |
| `DYEING` | 200 | `IN_EDGES` | — |
| `BOILER_FEED` | 0 | `NULL` | — *(`has_data = false`)* |

- **The unmetered boiler-feed branch is the point.** 1,700 m³ arrives at the process header and
  only 200 leaves through a meter. The missing 1,500 is now emitted as
  `PROCESS_HEADER__UNACCOUNTED`; before the design-error-3 fix it was absent from the Sankey
  entirely while the header still displayed 1,700 — a chart that visibly did not balance.
- **`is_passthrough` on the three softeners** is what carries the metered inlet flow through to the
  process header. Without it the softeners are terminal and the header never resolves.
- **The clarifier merge is honestly ambiguous.** Both outlet pipes are unmetered, so the solver
  splits the header's 1,700 evenly — 850/850, `is_ambiguous = TRUE` — rather than apportioning
  1,000:1,400 from the inlets. The 150/550 residuals inherit that guess. One meter on either
  clarifier outlet removes it.
- **Deep well resolves with no meter at all**, from the sum of its two outgoing pipe meters.

**Non-flow quantities:**

- `solve_flow` raises on quantity 1119 (`conserved = FALSE`).
- **THDv (`INHERIT`, `P95`)** — `FACTORY_AB` measured 4.2, `LVMDB_A1` measured 6.8. `COMP_KAESER` inherits **6.8** from A1, not 4.2 from the grandparent; `LVMDB_A2/A5/TEXTURE` and both unmetered panels inherit **4.2**; sources upstream of any THDv meter correctly return `NONE` rather than 0.
- **THDi (`RSS`)** — panels at 6.0 and 8.0 roll up to `LVMDB_A2 = 10.000` exactly.
- **True PF (`NONE`)** — only the measured node returns a value; nothing propagates.
- **Quantity isolation** — the two panels carry a THD current measurement and *no* energy measurement, and still report `has_data = false` in the energy solve.

**Derived power factor**, from summed P (124) and Q (89) at every node:

| node | kWh | kVArh | PF | hand-check |
|---|---|---|---|---|
| `FACTORY_AB` | 2,300 | 1,400 | 0.8542 | 2300/√(2300²+1400²) = 0.8542 |
| `GAS_ENGINE` *(no meter)* | 1,100 | 700 | 0.8437 | 1100/√(1100²+700²) = 0.8437 |
| `COMP_KAESER` | 500 | 300 | 0.8575 | 500/√(500²+300²) = 0.8575 |
| `PANEL_X` *(no data)* | — | — | `NULL` | not 0, not a fabricated 1.0 |

`GAS_ENGINE` is the point of the exercise: a node with no meter of its own gets a correct power
factor because both components were resolved by the flow balance.

Not tested: the `grafReader` grants, and the Phase 3 comparison against
`get_sankey_energy_flow_v2` (needs the real database).

## 10. Seed CSV format

Seed data is authored in **`graph-network-seed.csv`** (same directory) and converted to SQL by a
script. One row per **node**; edges are declared on the *receiving* node via `fed_by`, because that
is how you read an SLD — you trace what feeds a board, not what a board feeds.

| Column | Required | Meaning |
|---|---|---|
| `tenant_id` | yes | 3 = the plant with the SLD |
| `node_code` | yes | unique per tenant, `UPPER_SNAKE` |
| `node_name` | yes | display name shown in the Sankey |
| `node_class` | yes | `SOURCE` / `BUS` / `CONVERSION` / `STORAGE` / `LOAD` (`DISTRIBUTION` was retired by migration 032; a sub-panel is `BUS` with type `SUB_BOARD`) |
| `is_passthrough` | — | `TRUE` = this node consumes nothing of its own. Blank = `FALSE`. Structural, not descriptive — see §4.3 and rule 6 below |
| `fed_by` | — | `;`-separated upstream `node_code`s. **Blank for sources.** One entry per in-edge; `#device` attaches a meter to that in-edge |
| `in_utility` | yes | default utility for this row's `fed_by` edges *and* its `device_ids` |
| `edge_class` | — | defaults to `FEEDER` for `ELECTRICITY`, `PIPE` otherwise |
| `device_ids` | — | `;`-separated `devices.id`. Blank = unmetered (normal for a full SLD) |
| `attrs_json` | — | JSONB for the node (`voltage_level`, `rated_kva`, `operating_pressure_bar`, …) |
| `effective_from` / `effective_to` | — | blank = `'-infinity'` / open. Set only for a real commissioning or decommissioning date |
| `notes` | — | free text, **ignored by the importer** |

### Cell grammar

Both columns are `;`-separated lists. One entry reads:

```
    NODE_CODE [@UTILITY] [#device[:mult] [+device[:mult]]…]      -- fed_by
    device[:mult] [@UTILITY]                                     -- device_ids
```

```
fed_by      FACTORY_AB                     one upstream feed
            FACTORY_AB;PLTS_A4             two upstream feeds — a merge (this is the DAG)
            LVMDB_A1;AIR_HEADER@AIR        mixed utilities: @UTILITY overrides in_utility
            SOFT_HEADER#164                #DEVICE: a meter on THE PIPE, not on either node
            DEEP_WELL@WATER#95+96          all three suffixes; + joins two meters on one pipe
            PROCESS_HEADER#97:-1           a pipe meter read with a sign

device_ids  71                             one meter, reading THIS NODE'S own total
            5;138:-1;139:-1                :multiplier — this node = dev5 − dev138 − dev139
            71;900@AIR                     power meter + air flow meter on the same node
```

`#device` is the CSV's spelling of `graph.measurement.edge_id`, and it is the only way to author an
edge meter. It hangs off `fed_by` rather than getting its own column because an edge has no name of
its own — it is identified by the pair of nodes, and `fed_by` is where that pair is written down.
Electricity rows will rarely use it; every water row does (§10.2).

`@UTILITY` defaults to `in_utility`, so you only type it for a cross-WAGES row — a compressor's
`AIR` out-edge is declared on the *air header's* row as `fed_by = COMP_KAESER@AIR`, not on the
compressor's.

### What is pre-filled

105 rows are already populated with real `node_code`, `node_name`, `node_class`, and `device_ids`
pulled from the live database — 6 sources, 11 distribution boards, and 88 loads/conversions
covering all 105 devices. **`fed_by` is blank on every row**: that is the part only your SVG knows,
and it is the only column you have to type.

`notes` carries each node's old `device_hierarchy` path (`Purchased Energy / Utilities / HVAC /
HVAC A4`) to help you locate it on the diagram. Add rows for any panel on the SLD that has no
meter — leave `device_ids` blank; that is the scaffold described in §4.4.

### Flags to resolve while filling it in

- **20 rows marked `DE-DUPLICATED`** — see §10.1.
- **`LVMDP_SPINNING_3` vs `COMP_SP3`** — both carry device 74. Device 74 is `LV4 / LVMDP Spinning 3`,
  a spinning switchboard, but it is mapped today to a node named `Comp SP3` under `COMPRESSOR`.
  Almost certainly a seeding error. Keep one row, delete the other.
- **`COMP_SCR2200` / `HVAC_A4`** — both carry device 98 (`+1` and `-1`). This is the meter-coverage
  hack from §1. Once the real board is drawn, the subtraction should become topology and the `-1`
  should disappear.

### 10.1 A live bug this surfaced: double-seeded mappings

`prs.device_node_mapping` has **99 active rows but only 77 distinct `(node_code, device_id)` pairs**.
22 pairs are duplicated because migrations `002_seed_tenant3_hierarchy` and `006_seed_production_hierarchy`
both inserted them, and the unique constraint does not catch it:

```sql
CONSTRAINT uq_device_node_mapping UNIQUE (tenant_id, device_id, node_code, quantity_id)
-- every row has quantity_id IS NULL, and NULL <> NULL in a unique index
```

Seed timestamps confirm three separate runs on 2026-02-09: ids 1–26 at 08:46, **27–48 at 09:54**,
**49–99 at 10:19**.

**This is over-reporting the live Sankey today.** Device 30 (`AJL1`) metered 78,844 kWh in July 2026,
but `get_sankey_energy_flow_v2` emits two `AJL → AJL1` links of 134,068 and 153,160 — the duplicate
mapping inflates the node, and `SELECT DISTINCT` cannot collapse the rows because their values differ.
Affected nodes: `AJL1`, `AJL2`, `CELUP_1A/1B/2/3`, `FINISHING_1`, `FINISHING_22`, `LAB_DEVICE`,
`PACKING_DEVICE`, `PKN_DEVICE`, `RAINCOAT_DEVICE`, `SIZING`, `TRICOT1/2`, `WARPING`, `WJL1/2/3/4`.

The CSV is already de-duplicated, so **Phase 3 validation will show these nodes roughly halving.
That is the fix landing, not a regression** — worth writing down now so it isn't mistaken for a bug
in the new model. The old table can be corrected independently:

```sql
DELETE FROM prs.device_node_mapping a
USING prs.device_node_mapping b
WHERE a.id > b.id
  AND a.tenant_id = b.tenant_id AND a.device_id = b.device_id
  AND a.node_code = b.node_code
  AND a.quantity_id IS NOT DISTINCT FROM b.quantity_id;
```

### 10.2 Water P&IDs — one sheet, one CSV

The six water rows in the seed today are meters wearing the costume of equipment:
`FLOW_METER_SOFTENER_1` is not a thing in the plant, it is device 97; `TANK_SOFTENER_3` names a
tank but carries a flow meter that is not in the tank. That was the only option available when a
measurement could only attach to a node. It is no longer.

**The one rule that reorganises everything:** *a flow meter tapped into a pipe measures the pipe.*
Draw the P&ID's vessels and headers as nodes, the pipes between them as edges, and hang each meter
off the pipe it is tapped into with `#device`. Instruments stop being topology.

#### How to fill it in

1. **One CSV per P&ID sheet** — `graph-water-wtp.csv`, `graph-water-process.csv`. Same twelve
   columns, same grammar; the importer unions them. Keeping the file-to-drawing correspondence
   means a revised sheet is a re-typed file, not a hunt through a combined one.
2. **Every row is a vessel, a header, or a consumer.** If you cannot point at it on the P&ID as
   equipment, it is not a node. Tanks, clarifiers, softeners, filters, pumps' discharge headers,
   the ring main, each department's take-off — those are nodes.
3. **`fed_by` is the pipe.** `SOFT_HEADER` on the softener's row means "a pipe runs from the
   softener header to this softener".
4. **Append `#device` where the P&ID shows an FT/FQI tag on that pipe.** The tag's *position on the
   drawing* decides which edge it belongs to, and this is the one judgement call that matters:

   > A meter on the **inlet** of Softener 3 belongs to `fed_by = SOFT_HEADER#164` on the
   > `SOFTENER_3` row. A meter on its **outlet** belongs to `fed_by = SOFTENER_3#164` on the
   > `PROCESS_HEADER` row. Same device, same number, different edge — and the difference is
   > exactly the softener's own backwash loss. Put it on the wrong side and that loss lands on
   > the wrong vessel.

5. **`node_class` for water:**

   | class | Water |
   |---|---|
   | `SOURCE` | deep well, PDAM connection, recycled return from WWTP |
   | `BUS` | header, manifold, ring main — a pipe with multiple taps and no inventory |
   | `DISTRIBUTION` | department sub-manifold *(class retired by 032: a sub-manifold is a `BUS`)* |
   | `CONVERSION` | clarifier, softener, RO skid, filter — passes water through and loses some |
   | `STORAGE` | tank, reservoir, clearwell — **holds inventory** |
   | `LOAD` | dyeing, boiler feed, cooling-tower makeup, domestic |

6. **`is_passthrough` is the flag that makes a sparsely metered water network resolve** — and it
   is a property of the **vessel**, not of the meter. A flow meter is inherently pass-through;
   attaching it to an edge already says so. The flag answers a different question: *does this node
   consume anything of its own?* `TRUE` licenses solver rule (a) to push the node's whole value
   down its out-edge.

   Two things bound it, and both matter when deciding where to set it:

   - **Rule (a) requires `out_deg = 1`.** On a vessel that splits — a clarifier feeding three
     softeners, a header feeding four departments — the flag is inert no matter what it says. It
     only ever fires on a single-in / single-out chain.
   - **On a node with a real loss it silently erases that loss.** The residual is `value − Σ out`,
     and rule (a) forces `Σ out = value`. That is exactly the number an edge-attached inlet meter
     exists to produce.

   So: `TRUE` on buffers — raw-water tanks, soft-water tanks, hot-water tanks, equalization and
   delivery basins — where nothing leaves except through the outlet and only the level moves.
   `FALSE` on vessels whose loss is the thing you are trying to see: a clarifier (sludge
   blowdown), an RO skid (reject stream, often a quarter of throughput), a reaction tank
   (dosing and sludge). Softeners sit in between; backwash is real but small and intermittent, and
   setting them `TRUE` is what lets three metered softener feeds produce a soft-water-tank total
   where the alternative is no number at all. That is an engineering judgement about the plant,
   not something the data can settle.
7. **Tie points between the two sheets get the same `node_code` in both.** The importer keys on
   `(tenant_id, node_code)`, so a node appearing in both files is one node. Declare the crossing
   pipe once — on the sheet that owns the *downstream* end, since `fed_by` is declared on the
   receiver. Note it in `notes` on both rows so the next person can see the seam.

#### What happens to the six existing rows

| today | becomes |
|---|---|
| `CLARIFIER_WTP_1` `STORAGE` dev 95 | node `CLARIFIER_1` `CONVERSION`, **no** `device_ids`; device 95 moves to `#95` on its feed pipe |
| `CLARIFIER_WTP_2` `STORAGE` dev 96 | same, device 96 |
| `FLOW_METER_SOFTENER_1` `STORAGE` dev 97 | **node deleted.** It was never equipment. Device 97 becomes `#97` on whichever pipe the P&ID shows it in |
| `TANK_SOFTENER_3/4/5` `STORAGE` dev 164/165/166 | tanks stay as `STORAGE` nodes if the P&ID shows real tanks; the meters move to `#164` / `#165` / `#166` on their inlet or outlet pipes per rule 4 |

None of these carry `fed_by` today, so nothing is lost by rewriting them — the water graph has no
topology to preserve.

> **A `STORAGE` node breaks flow balance, and water is where that finally bites.** The solver
> assumes what enters a node leaves it. A tank whose level differs at the start and end of the
> window genuinely violates that: `in − out = ΔS`, and the solver will report `ΔS` as
> `UNACCOUNTED` — indistinguishable from a leak. Over a monthly window on a buffer tank that
> cycles daily, `ΔS ≈ 0` and the approximation is fine. Over a day, or on a tank being filled for
> a shutdown, it is not. Electricity never had this problem because nothing stores kWh. If tank
> level is telemetered, the right long-term answer is a node-attached level measurement and a
> `ΔS` term in the balance; that is not built. See §13.

### 10.3 The exporter

> **Superseded by `scripts/wages_sync.py` — see §10.4.** What follows describes how the seed
> was originally produced, and stays because `011_seed_tenant3_graph.sql` is its output.


`scripts/graph_seed_export.py` reads the CSVs and emits idempotent SQL. It does not
connect to write anything — `grafReader` cannot — so the output is a file for a role with
INSERT rights, or for replay against a throwaway cluster.

```bash
./venv/bin/python scripts/graph_seed_export.py \
    graph-seed-v1.csv \
    graph-water-v1.csv -o graph_seed.sql
```

Every CSV named on the command line is read as **one graph**, in two passes, so row order
and file order do not matter and a `node_code` in two files is one node. Validation is
fatal rather than advisory — a dangling `fed_by`, a cycle (printed as a path), a device
attached to two targets, a `node_code` redeclared with a different `node_class` or
`is_passthrough`, a value outside a CHECK vocabulary, or unparseable `attrs_json` all
write nothing and exit non-zero. `--verify-db` adds read-only live checks: every
`device_id` exists, belongs to the row's tenant, and its `device_type` matches the
utility — a Flow Meter on an `ELECTRICITY` row is exactly the mistake the P&ID's ID
collision would have produced.

Two things in the generated SQL are worth knowing. **Edges resolve node ids by
`node_code` inside the statement**, so the file carries no surrogate keys and replays
anywhere. **Measurements expand across `graph.quantity_rule`** for the row's utility
rather than freezing a quantity list into the file, so adding a rule row and re-running
picks it up; a device that does not report a register simply returns nothing from
`device_totals`. Nothing is ever deleted — retiring a node or a feed is a deliberate
`UPDATE ... SET is_active = FALSE`.

### 10.4 The maintenance tool

`graph_seed_export.py` answered "how do we get the SLD in the first place". It does not answer
the question that arrives every time a meter is installed: *does adding this device break what
is already there?* It cannot — it takes numeric `devices.id` values, which do not exist until
after the device row has been written, and it knows nothing about `public.devices` at all. So
adding a device was two steps in two tools with a hand-copied id between them, and the graph
half was easy to simply forget. `scripts/sync_devices.py` had the mirror-image problem: it wrote
the device and stopped, leaving it invisible to `solve_flow`.

**`scripts/wages_sync.py` replaces both.** One CSV whose row unit is *a thing* — a node, a
device, or both — applied in one transaction:

```bash
./venv/bin/python scripts/wages_sync.py export --tenant 3 -o plant.csv   # live state out
./venv/bin/python scripts/wages_sync.py sync   --csv plant.csv --dry-run # what would change
./venv/bin/python scripts/wages_sync.py sync   --csv plant.csv           # apply
./venv/bin/python scripts/wages_sync.py doctor --tenant 3 --window 2026-07-01:2026-07-31
```

Three things it does that the exporter could not.

**A device reference may be a `device_code`.** That is what collapses the two steps into one:
a device created three rows earlier is nameable before its id exists.

**Checks run against the real post-state, inside the transaction, and roll it back.** The
structural set is the failure modes this document already names: a device on two targets over
overlapping dates (§10.1, the bug that made `AJL1` report 134,068 + 153,160 kWh against a real
78,844); a cycle, walked over live edges *plus* the new ones so a feeder closing a loop through
existing plant is caught; a node with no edges, which `solve_flow` filters out silently; a Flow
Meter on an `ELECTRICITY` row (§4.4); a measurement whose `tenant_id` disagrees with its node's,
which no FK enforces. `--check-balance START:END` adds the numeric half — solve the network
before and after and refuse if a node's residual crosses into negative, which is what a wrong
`fed_by` or a double-attach actually looks like from the data. It also warns when a new edge
defaults to `effective_from = '-infinity'` into a board that already had in-edges, because that
silently re-splits every historical query for that board.

**`doctor` makes §12 and `012_verify_graph_migration.sql` a command rather than a file someone
remembers to run.** It enforces the rule the graph is for — every active device must reach a
node — and reports the rest with severities and an exit code: orphan nodes, non-`SOURCE` roots,
double counting, quantities with no `quantity_rule` row, the §12.3 cumulative-flag drift, and
with `--window` the stopped meters of §12.5 alongside the solve-provenance histogram. Its
`--fix` is deliberately narrow: deactivate measurements on inactive devices, backfill the
`quantity_rule` quantities an attached device is missing. It never guesses where an orphan
device belongs; that is the question §13 records about device 53, not one a script should
answer.

`export` closes the loop: one row per (node, device) pair plus a row per unattached device, so
`export` → `sync --dry-run` reports zero changes. That round-trip is the format's regression
test, and `export --tenant 4` is the tenant-4 onboarding worksheet — 43 rows with the device
columns filled and `node_code`/`fed_by` blank.

## 11. Non-flow quantities

Energy is one measurement. The topology is the asset; quantities differ only in the operator they
carry across an edge. For energy the graph is a *convenience* — a tree plus hardcoded lists limps
along. For power quality the graph is the **only** structure that can answer the question at all,
because "which loads share this bus" is purely topological.

### 11.1 The resolver

`graph.get_node_quantity` dispatches on `graph.quantity_rule.network_agg` (§4.7). Conserved
quantities are delegated straight to the flow solver, which is strictly better than a rollup —
it uses in-edges, out-edges and residuals rather than just summing children.

```sql
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
```

### 11.2 Derived quantities

```sql
CREATE OR REPLACE FUNCTION graph.get_node_derived(
    p_tenant_id     INTEGER,
    p_code          VARCHAR,
    p_start         TIMESTAMP WITHOUT TIME ZONE,
    p_end           TIMESTAMP WITHOUT TIME ZONE,
    p_as_of         DATE      DEFAULT CURRENT_DATE,
    p_shift_periods VARCHAR[] DEFAULT ARRAY['SHIFT1','SHIFT2','SHIFT3']
) RETURNS TABLE (
    node_id BIGINT, node_code VARCHAR, node_name VARCHAR,
    p_val NUMERIC, q_val NUMERIC, val NUMERIC)
LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_util VARCHAR; v_p INTEGER; v_q INTEGER; v_formula VARCHAR;
BEGIN
    SELECT dq.utility_code, dq.p_quantity_id, dq.q_quantity_id, dq.formula
      INTO v_util, v_p, v_q, v_formula
    FROM graph.derived_quantity dq WHERE dq.code = p_code;

    IF v_util IS NULL THEN
        RAISE EXCEPTION 'graph.get_node_derived: no derived quantity %', p_code;
    END IF;

    PERFORM graph.solve_flow(p_tenant_id, v_util, p_start, p_end, v_p,
                             FALSE, p_shift_periods, p_as_of);
    DROP TABLE IF EXISTS _dq;
    CREATE TEMP TABLE _dq ON COMMIT DROP AS
    SELECT g.id, g.node_code AS ncode, g.node_name AS nname,
           (CASE WHEN g.has_data THEN g.value END) AS pv, NULL::NUMERIC AS qv
    FROM _gn g;

    PERFORM graph.solve_flow(p_tenant_id, v_util, p_start, p_end, v_q,
                             FALSE, p_shift_periods, p_as_of);
    UPDATE _dq d SET qv = (CASE WHEN g.has_data THEN g.value END) FROM _gn g WHERE g.id = d.id;

    RETURN QUERY
    SELECT d.id, d.ncode, d.nname, d.pv, d.qv,
           CASE WHEN d.pv IS NULL OR d.qv IS NULL THEN NULL
                WHEN d.pv = 0 AND d.qv = 0        THEN NULL
                ELSE round(d.pv / sqrt(d.pv*d.pv + d.qv*d.qv), 4) END
    FROM _dq d;
END;
$$;
```

### 11.3 What the two failure directions mean

Harmonics move in **both** directions, and conflating them is the classic mistake:

- **THD current sums upward, with cancellation.** Harmonic currents from loads combine at the bus
  per order, and different orders from different load types partially cancel. `RSS`
  (`sqrt(Σ x²)`) is the standard conservative treatment. Summing THD *percentages* — what any
  naive rollup does — is meaningless arithmetic. 48 tenant-3 devices report per-order current
  magnitudes (`H11 Current A Magnitude`, …), which is enough to do this properly rather than
  approximately.
- **THD voltage inherits downward.** THDv is not generated by the load; it is harmonic current
  acting on upstream source impedance, so everything on a bus shares essentially the same THDv.
  A downstream VFD's harmonic current flows *up* through the transformer, raising THDv at the
  upstream bus, which then propagates *back down* to every sibling that never caused it.

Answering "why is this motor running hot" is therefore: walk **up** to find whose harmonic current
is polluting the bus, then walk **down** to find everyone else eating it. There is no way to ask
that from a device list.

`INHERIT` resolves in two stages — strictly, while every feeder of a node is known, then relaxed to
the **worst** known feeder (`MAX`). The relaxation matters on merge nodes: `LVMDB_A5` is fed by both
`FACTORY_AB` and a PV plant that reports no THDv at all, and without it the whole branch would
stall. `MAX` is the engineering-conservative choice for a pollution metric and is worth revisiting
if a case appears where the feeders genuinely differ.

### 11.4 The query this is all for

Which loads are responsible for a bus's bad power factor — ranked by **kVAr contribution**, not by
their own PF:

```sql
WITH q AS (
    SELECT node_id, value AS kvarh
    FROM graph.get_node_values(3, 'ELECTRICITY', :start, :end, 89)
)
SELECT c.node_code, q.kvarh,
       round(100 * q.kvarh / SUM(q.kvarh) OVER (), 1) AS pct_of_siblings
FROM graph.edge e
JOIN graph.node p ON p.id = e.from_node_id AND p.node_code = 'FACTORY_AB'
JOIN graph.node c ON c.id = e.to_node_id
JOIN q            ON q.node_id = c.id
WHERE e.utility_code = 'ELECTRICITY'
ORDER BY q.kvarh DESC;
```

---

## 12. Data-quality findings in the live database

Five things surfaced while designing §4.7 and §10.2. None of them block the seed; all of them
change what the graph must do.

### 12.1 Quantity 130 duplicates quantity 124

Both are `Active Energy Delivered` registers on Schneider meters — 124 `Active Energy Delivered`,
130 `Active Energy Delivered-Received` — and both are written to `daily_energy_cost_summary`.
For tenant 3 on 2026-08-16:

| quantity | devices | daily kWh |
|---|---|---|
| 124 | 80 | 284,006 |
| 130 | 31 | 213,976 |

**31 devices report both, 49 report only 124, zero report only 130.** Over 2026-08-01…16, 30 of
the 31 agree exactly; the three that differ are rounding (Incoming PLN 1,130,840 vs 1,130,848 out
of 1.1 M). They are the same physical energy.

Live reporting is safe today only because `get_sankey_energy_flow_v2` pins `p_quantity_id DEFAULT
124`. The graph handles it structurally instead: `graph.quantity_alias` declares 130 → 124,
`device_totals` prefers the canonical register per device and falls back to the alias only where
the canonical is absent, and both `device_totals` and `graph.measurement` reject an alias id
outright. A device that reports *only* register 130 is still counted, reported under 124.

### 12.2 One meter emitting an INT64 sentinel

Device **168 (`PLTSD`, PLTS Texture)** reports `92233720368547760` on quantity 130 for all 96
buckets of 2026-08-16. That is 2⁶³/100 — a Modbus null sentinel ingested as a reading. It does not
reach `daily_energy_cost_summary`, so nothing downstream is wrong today, but PLTS Texture has no
usable 130 data and anything reading `telemetry_15min_agg` directly gets 9.2 × 10¹⁶ kWh. It is one
of the unmapped PV devices in the seed CSV.

### 12.3 `aggregation_method` and `is_cumulative` are not the source of truth

Neither column drives behaviour, and one of them is wrong.

| Column | Read by |
|---|---|
| `quantities.aggregation_method` | **one** function — `get_shared_quantities_for_user`, which passes it through to the UI in a `SELECT` list. Nothing branches on it. |
| `quantities.is_cumulative` | **nothing.** |

The cumulative set is instead hardcoded, twice, and the two copies disagree:

```sql
-- public.get_telemetry_aggregation_for_user
cumulative_quantity_ids INTEGER[] := ARRAY[62, 89, 96, 124, 130];

-- public.refresh_daily_energy_costs   (the ETL behind daily_energy_cost_summary)
WHERE tic.quantity_id = ANY (ARRAY[62, 89, 96, 124, 130, 131, 481])
```

Five ids against seven. A cumulative register decreases rarely and for a reason, where a per-interval
register decreases about half the time — so the decrease *rate* settles it. Over 2026-08-16, tenant 3:

| quantity | consecutive pairs | % non-decreasing |
|---|---|---|
| 62, 89, 96, 124, 130, 131, 481 | 3,037 – 8,472 each | **99.4 – 99.8** |

All seven are cumulative; the ~0.5% of dips are meter resets and comms gaps. **The ETL is right and
`is_cumulative` is wrong on 131 and 481.**

That is the argument for `graph.quantity_rule` being *authored* rather than derived at runtime.
Seed it from these columns once, review every row by hand, and let the table be authoritative
afterwards. Deriving from a column that nothing reads and that is wrong on two rows would inherit
the error silently.

Three actions:

**1. Correct the column** so it stops contradicting the ETL. Safe — nothing reads it.

```sql
UPDATE quantities SET is_cumulative = TRUE WHERE id IN (131, 481);
```

**2. Leave `aggregation_method` values alone.** Its one consumer displays it; changing it changes UI
text for no behavioural gain. It is ambiguous by construction, which is exactly why §4.7 splits the
two axes instead of trying to fix it in place.

**3. Run a drift check** so `quantity_rule` does not quietly become a fourth disagreeing copy.

```sql
SELECT COALESCE(qr.quantity_id, q.id) AS quantity_id, q.quantity_code,
       qr.raw_time_agg, q.is_cumulative,
       (q.id = ANY (ARRAY[62,89,96,124,130,131,481])) AS etl_treats_as_cumulative,
       CASE
         WHEN qr.raw_time_agg = 'DELTA' AND NOT q.is_cumulative
              THEN 'rule says DELTA, column says not cumulative'
         WHEN qr.raw_time_agg <> 'DELTA' AND q.is_cumulative
              THEN 'column says cumulative, rule does not difference it'
         WHEN qr.quantity_id IS NULL AND q.is_cumulative
              THEN 'cumulative quantity with no quantity_rule row'
       END AS drift
FROM quantities q
FULL JOIN graph.quantity_rule qr ON qr.quantity_id = q.id
WHERE (q.is_cumulative OR qr.quantity_id IS NOT NULL)
  -- aliases are folded into their canonical id before any rule applies,
  -- so they correctly have no quantity_rule row of their own
  AND NOT EXISTS (SELECT 1 FROM graph.quantity_alias a WHERE a.quantity_id = q.id)
ORDER BY 1;
```

### 12.4 Water volume is a totaliser flagged as not cumulative

There is exactly **one** water quantity in use: **5696**, `Water Volume Supply (m^3)`, reported by
all six flow meters. It carries `aggregation_method = 'SUM'` and `is_cumulative = FALSE`. Both are
wrong in the same way as 131 and 481 (§12.3) — the raw register is a totaliser:

| device | 15-min samples (2 d) | non-decreasing | range |
|---|---|---|---|
| 95 | 123 | 100 % | 2,592,567 → 2,594,217 |
| 96 | 123 | 100 % | 6,030,621 → 6,032,415 |
| 165 | 123 | 100 % | 2,376,060 → 2,376,305 |
| 166 | 123 | 100 % | 2,972,060 → 2,973,458 |

Nothing is broken *today*, because `telemetry_intervals_water` already differences the register and
`device_totals` reads `interval_m3` from it. The hazard is the generic branch: any water quantity
that is not `conserved` — a flow *rate*, a pressure — falls through to raw `telemetry_15min_agg`,
where a missing `quantity_rule` row defaults `raw_time_agg` to `SUM`. Summing 2,811 samples of a
6-million-m³ totaliser produces a number with no meaning and no obvious sign of being wrong.

`graph.quantity_rule` therefore carries `(5696,'WATER','DELTA','SUM',TRUE)` (§4.7). `DELTA` is
unused on the water path, and is stated anyway so the §12.3 drift check has something correct to
compare against. The column itself should be fixed:

```sql
UPDATE quantities SET is_cumulative = TRUE WHERE id = 5696;
```

### 12.5 Two of the six water meters are dead

Before any water topology is drawn, the instruments were checked over 2026-07-19 → 2026-08-18:

| device | code | name | 30-day total | status |
|---|---|---|---|---|
| 95 | `FLO-02` | Clarifier WTP 1 | 27,789 m³ | healthy |
| 96 | `FLO-03` | Clarifier WTP 2 | 39,568 m³ | healthy |
| 165 | `FLO-05` | Tank Softener-4 | 16,825 m³ | healthy |
| 166 | `FLO-06` | Tank Softener-5 | 31,285 m³ | healthy |
| **164** | `FLO-04` | Tank Softener-3 | 1,809 m³ | **stopped 2026-08-04** — nothing since |
| **97** | `FLO-01` | Flow Meter Softener 1 | **5 m³** | **dead** — last movement 2026-07-27 |

Device 97 is the worse of the two: its raw register sits at a constant **−42,459**. A cumulative
volume totaliser cannot be negative, so this is not a stalled meter reading a real value — it is a
register being misread, most likely a signed/unsigned or word-order fault, the same family as the
INT64 sentinel in §12.2.

This matters for the graph in a specific way. Two dead meters out of six means a third of the water
network's edges will carry zero, and the solver will faithfully turn that into large `UNACCOUNTED`
residuals on whichever vessels sit downstream. **That residual will look exactly like a leak.**
`v_coverage` reports whether an instrument is *attached*, not whether it is *alive*; nothing in the
model distinguishes a genuinely unmetered branch from a metered branch whose meter stopped three
weeks ago. Fix or flag both meters before the water residuals are shown to anyone. See §13.

### 12.6 Scope note

Only **5** quantities carry `is_cumulative = TRUE` today and all five are Electricity. Any air, gas
or steam flow *totaliser* is therefore unflagged, and the generic branch of `device_totals` reads
raw `telemetry_15min_agg` — so `raw_time_agg` for those utilities has to be authored by hand until
meters exist and the flags are set. `graph.quantity_rule` only ever needs rows for quantities the
graph actually traverses, not for all 6,746 rows in `quantities`.

The hardcoded arrays above are the same pattern as the hardcoded report device lists (decision 7):
a fact copied into function bodies instead of read from a table. Consolidating them is the right
long-term fix and is deliberately out of scope for this session.

---

## 13. Open items

- **Gas engine has no device row.** Nothing in `devices` matches `gas|engine|genset` for either tenant. The node can be created now, but the model is unvalidated against data until the meter exists.
- **Compressed air has no diagram.** Schema is utility-agnostic from day one; populate `AIR` when the topology is known. Header and receiver are nodes; branch pipes are edges with `measurement.edge_id`.
- **Tenant 4** (43 power meters, zero hierarchy nodes) has no SLD yet.
- **Node code reuse.** `UNIQUE (tenant_id, node_code)` prevents retiring a node and reusing its code later. Acceptable now; if it becomes a problem the constraint moves to a partial index on `is_active`.
- **Ambiguous merges.** More than one unknown in-edge on a node cannot be split from data. Currently split evenly and flagged; revisit if it occurs often in the real SLD.
- **`p_as_of` is a single date, not per-bucket.** Measurement effectivity is evaluated once for the whole query window. A meter installed mid-window is therefore either fully in or fully out. Acceptable for monthly Sankey; if per-day accuracy across an install date matters, the solve has to run per bucket.
- **Zero-valued edges are hidden.** `get_sankey_flow` filters `value > 0`, so edges into a dead branch do not render at all. If the UI should show unmetered stubs explicitly, drop the filter and let `has_data` drive the styling.
- **Rule (a) stops at one hop past a passthrough node.** A mid-chain node with no `is_passthrough` flag and no meter cannot be resolved, because nothing rules out load of its own. Declaring conveyance nodes is a modelling decision, not something the data can supply.
- **`node_class` has no history.** A reclassification (§4.2) applies retroactively across all queries. Only edges and measurements are temporal. Acceptable because the solver ignores `node_class` entirely; it would matter if that ever stopped being true.
- **`INHERIT` takes `MAX` across feeders.** On a node fed by two buses with genuinely different THDv, the worst is reported. Conservative for a pollution metric, but it is a choice, not a measurement.
- **`RSS` assumes no phase information.** Per-order magnitudes are available on 48 devices but not phase angles, so cancellation between orders is approximated rather than computed. Standard practice, and conservative in the right direction.
- **Delivered/Received netting is unbuilt.** See §4.7. Needs a `(canonical, component, sign)` relation and a change to `device_totals` to combine components before the solve. Blocked on nothing except a node that actually exports — `Active Energy Received` is currently zero everywhere on tenant 3.
- **Air/gas/steam totalisers are unflagged.** `is_cumulative` is set on 5 Electricity quantities only (§12.3). Until that audit is done, `raw_time_agg` for those utilities must be authored by hand rather than seeded.
- **Storage nodes are outside the flow balance.** A tank's `in − out = ΔS`, and the solver reports `ΔS` as `UNACCOUNTED`, indistinguishable from a leak (§10.2). Fine over a monthly window on a daily-cycling buffer tank; wrong over a day, or on a tank being filled. Needs a node-attached level measurement and a `ΔS` term. Water is the first utility where this can occur.
- **A stopped meter is invisible to `v_coverage`.** It reports whether an instrument is attached, not whether it is reporting. Two of six water meters are currently dead (§12.5), and their branches will produce residuals that read as leaks. A staleness column — last non-zero bucket per device — belongs next to `is_edge_metered` before water residuals are put in front of anyone. Dead meters stay attached by policy: the graph records what is *physically installed*, and whether a device reports is a telemetry-configuration flip, not a topology change. That makes the staleness column the only thing standing between a switched-off meter and a residual that reads as a leak.
- **Meter-side placement is unverifiable from the database.** Whether a flow meter sits on a vessel's inlet or outlet pipe (§10.2, rule 4) changes which node owns the loss between them, and only the P&ID says which. Wrong placement produces a plausible, silently misattributed residual.
- **`DROP TABLE IF EXISTS` emits a `NOTICE` on every call.** Harmless, but noisy in logs; `SET client_min_messages = warning` inside the functions if it matters.
- **The functional taxonomy is authored, not inherited — and the authoring is not finished.** 019 ported what `prs.device_hierarchy` knew, which leaves 42 electricity nodes with no category and 27 carrying a category they acquired by inheritance rather than by decision. Inheritance is a resolution mechanism, not an authoring one: a tag on a mixed distribution board propagates a wrong category to everything below it (§15.7). Both sets are exported for review to `reference/graph_sankey_orphan.csv` and `reference/graph_sankey_assigned.csv`, carrying `device_id`, `slave_address` and `ip_address` (from `devices.metadata->'data_concentrator'`) so a node can be identified on the plant floor rather than only in the database. `reference/graph_sankey_categories.csv` is the pick-list for both: the 28 valid `category_code` values with their path, depth, whether they are a leaf, and how many nodes each already holds. The columns engineers fill in — `proposed_category_code` and `corrected_category_code` — take a **`category_code`**, not a path: `graph.node_category` resolves through `category_code`, which is unique per tenant and taxonomy, while the path is derived from `parent_id` and is display only. A filled-in code turns straight into an `INSERT`; a path or a description has to be interpreted first. Every row is to be confirmed with the engineers and then written as an **explicit** assignment. Known-suspect today: `AHU_LINE3`, `LIGHT_INT_1` and `LIGHT_INT_2` inheriting COMPRESSOR from `LVMDP_SPINNING_3` / `COMP_INTERLACE`; the four AHUs inheriting AJL / WJL / WSBC where `AHU_LINE1` and `AHU_LINE2` were authored as HVAC; and `OFFICE`, `OFFICE_2` and `FLR_124`, for which no category exists at all.
- **`graph.resolve_category` scopes inheritance by utility but not the explicit seed set.** `p_utility_code` filters the walk down `graph.edge`, so inherited categories stay inside one network — but a node with an explicit assignment is returned for *every* utility, because `graph.node_category` has no utility column and a node is a node. Asking for `WATER` therefore returns 72 electricity loads. Harmless for a report that filters, wrong for `get_sankey_functional`, which would pull another network's nodes into the diagram. The fix is to require the node to participate in the requested utility's graph; until then, callers must join to `graph.edge` themselves, which is what the CSV export does.
- **No WATER taxonomy exists.** 019 ported ELECTRICITY only, so all 35 water nodes appear in the orphan export by construction. Not a defect — nothing has been authored for water yet — but it means the orphan file must be filtered by utility before it is read as a list of electricity problems.
- **`WWTP` is modelled twice, deliberately.** The electricity node `WWTP` (device 139) and the water chain `WTP2_EQL → WTP2_REACT → WTP2_DEL → WTP2_IPAL` are the same building. Kept as separate nodes until it is confirmed whether the power meter covers the pumps and auxiliaries of the basins the P&ID draws; if it does, `WWTP` merges onto `WTP2_EQL` the same way `BOILER_MIURA` already merges across ELECTRICITY and WATER.

---

## 14. Topology primitives, and where analysis lives

`016_create_topology_primitives.sql` adds three reachability functions over `graph.edge`:

| Function | Question it answers |
|---|---|
| `graph.descendants(tenant, node_code, [utility], [as_of], [max_depth])` | everything fed from here — *what goes dark if this breaker opens* |
| `graph.ancestors(tenant, node_code, [utility], [as_of], [max_depth])` | the path back towards source — *what could have caused this* |
| `graph.siblings(tenant, node_code, [utility], [as_of])` | nodes sharing a direct feeder — *did the whole bus dip, or just this branch* |

Shared semantics:

- **`p_utility_code` is optional and `NULL` means every utility**, which lets a walk cross a tie point — out of `ELECTRICITY` and into `WATER` at `BOILER_MIURA`. That is the payoff of modelling tie points at all, but it is rarely what a single-network question wants, so pass a code to stay inside one network. `graph.siblings` forces both hops onto the *same* utility regardless, so a tie point never makes an electrical load the sibling of a water vessel.
- **`p_as_of` honours `effective_from` / `effective_to`** on both nodes and edges, so a walk reflects the topology on that date rather than today's.
- **Self is never returned**; `descendants` and `ancestors` both start at depth 1.
- **A DAG reaches the same node by more than one route.** One row per node is returned, at the shallowest depth, and `path` is that one representative route — not an exhaustive path enumeration.
- All three are `STABLE` and use no temp tables, so unlike `graph.solve_flow` they run under a read-only role in a read-only transaction, and the planner inlines them.

### Why these are in SQL when the analytics are not

The boundary is: **the graph schema owns topology, analytics scripts own statistics.**

Flow resolution belongs in the database because it meets three tests at once — a dashboard queries it interactively over user-chosen windows, it reduces millions of telemetry rows to a few hundred values, and it is expressible as set operations plus one bounded loop. `solve_flow` in plpgsql was the right call.

Power-quality analysis inverts all three. Its consumer is a scheduled report, not a live dashboard; its output is small; and its logic is temporal and stateful — coincidence across buckets, hysteresis on thresholds, ranking harmonic injectors by absolute distortion current, recognising the signature of a protection trip. That is what plpgsql is worst at and pandas is best at. The operational asymmetry decides it: only the read-only `grafReader` role exists, so every database function is a migration developed against a throwaway local cluster, while a script in `scripts/` runs today. Power-quality thresholds and report shapes are still undecided (§11), and undecided things should not be frozen into plpgsql.

What must **not** happen is Python reimplementing adjacency. Two implementations of "downstream of" eventually disagree, and the Sankey and the weekly report start telling different stories about the same plant. Hence these three functions: traversal is defined once, in the schema that owns it, and the scripts call it.

| Analysis | Home | Why |
|---|---|---|
| Energy / water flow, Sankey | database | interactive, large reduction |
| `descendants` / `ancestors` / `siblings` | database | shared primitive, must not fork |
| Power factor, reactive attribution | database | settled physics; `PQ_RATIO` over conserved P and Q (§11) |
| Sustained undervoltage survey | Python | scheduled; needs per-bucket state and per-node nominal voltage |
| Harmonic source ranking | Python | needs per-order amps, and RSS over the right basis |
| Trip / subtree-blackout detection | Python | stateful scan of 60 s raw, then a graph lookup |
| Current unbalance survey | Python | scheduled, small output |

Things graduate. Prototype in Python; promote to a database function once the shape has stopped moving and a dashboard needs it interactively.

### The event that *is* observable

Sag and swell logging is a meter-tier capability: the PM5110s that make up most of this fleet cannot do it, and the telemetry path could not carry it anyway — 60-second polling of a 100 ms register, then averaged into 15-minute buckets (§11). What *is* observable is the protection response. A breaker trip appears as an entire subtree's power going to zero within one bucket while its siblings keep running, which 60-second raw data resolves comfortably.

`graph.descendants` is what turns that from a list into a diagnosis: seventeen meters reading zero at 14:32 is data; *everything below `AJL2` went dark simultaneously* names the breaker. A planned shutdown staggers across the subtree; a trip does not. Unmetered loads that trip stay invisible directly, but show as a step change in their parent's residual, which the flow solver already computes.


## 15. The functional view: taxonomy over the physical graph

`graph.edge` is the wrong shape for the question a C-level reader is actually asking. They do not want to know which meter feeds which meter; they want to know how the plant is spending energy. Those are different questions and neither answer is derivable from the other.

The legacy `prs.device_hierarchy` answers the business question, and 27 of its 102 nodes are pure abstraction:

```
PURCHASED_ENERGY
├── UTILITIES     → BOILER, COMPRESSOR, HVAC, LIGHTING, WTP
└── PRODUCTION
    ├── FABRIC    → WJL, PKN, AJL, TRICOT, WSBC, BEAM, RAPID,
    │                PRESS, RAINCOAT, PACKING, LAB, PKR, GARUK
    └── YARN      → SPINNING, MC_MOTOR, REWINDING, HEATER, TWISTING
```

There is no busbar called `PRODUCTION`. That is the case for keeping the functional view — and it is a real case.

### 15.1 It is a labelling, not a topology

What it is *not* is a second graph. Checked against live: `prs.device_node_mapping` holds 99 rows over 74 leaves and 76 devices, and exactly **one** device (98) appears in two leaves. It is a partition. The functional view carries no adjacency of its own — it is a path string per device, and the 27 abstraction nodes are just the distinct prefixes of those strings.

So the design is one topology with two projections:

| | answers | mechanism |
|---|---|---|
| `graph.edge` | what is physically connected | `solve_flow` runs here |
| `graph.category` | how the business reports | the Sankey groups here |

### 15.2 Why not simply keep the legacy Sankey

Because it does not merely group differently — it **computes** differently. It sums device meters up its tree, which means it structurally cannot see unmetered load, cannot resolve a node fed by two sources, and cannot produce a residual at all. The visible symptom is coverage:

| | devices |
|---|---|
| legacy Sankey | 76 |
| graph, electricity | 98 |
| in both | 75 |
| **graph only** | **23** |

Run both and they will report different totals for the same plant in the same month, and the first question back will be which number is real. The functional Sankey therefore solves **once** on the physical graph — where unmetered load, dual-source nodes and the residual are handled — and then rolls the *solved* node values up the category tree instead of the edge tree. Same total, same unaccounted line, different grouping. The two views cannot disagree.

### 15.3 Shape

| object | what it holds |
|---|---|
| `graph.taxonomy` | the taxonomies. `FUNCTIONAL` today; `COST_CENTRE` or an ISO 50001 boundary is a row, not a table |
| `graph.category` | the tree within a taxonomy. `parent_id` only — no `level`, no stored path |
| `graph.node_category` | assignment of a **node** (not a device) to a category, with `weight` and effective dating |
| `graph.v_category_tree` | path and depth, recomputed per query |
| `graph.resolve_category` | which category each node reports under, explicit or inherited |
| `graph.v_taxonomy_coverage` | what has no business home yet |

Four decisions are worth the words:

**Assignment attaches to nodes, not devices.** The legacy mapping was device-keyed, which is exactly why it could never place an unmetered node — there is no device to hang the label on, but the solver still gives that node a value, and the value has to land somewhere in the rollup.

**No stored path.** `public.assets` carried one maintained by `update_asset_path()`, a trigger 015 drops; path drift is a known failure of that pattern. The tree is tens of rows.

**Inheritance is resolved at read time, not stored.** A tag on `AJL2` covers the twelve loads beneath it — one row instead of twelve — by walking `graph.edge` to the nearest tagged ancestor. Explicit assignment always wins over inheritance, so an HVAC unit sitting on a production bus can be corrected with one row.

**`weight` exists from the start.** A strict partition holds today, but breaks the first time shared HVAC has to be split across Fabric and Yarn for energy intensity. Device 98 is already that case in miniature. The column is free now and a migration later.

### 15.4 Split versus ambiguous

These look alike and mean opposite things, so `resolve_category` distinguishes them:

- a node **explicitly** assigned to several categories returns several rows at `hops = 0` with weights summing to 1. That is a deliberate allocation, and `is_ambiguous` is false.
- a node **inheriting** from two differently-tagged ancestors at the same distance returns `is_ambiguous = TRUE`. It is reported, never silently resolved — the same posture as `is_ambiguous` in the flow solver (§5.3).

A deferred constraint trigger enforces the weight total, so a re-cut can delete the old split and insert the new one inside one transaction without the intermediate state tripping it.

### 15.5 Sequencing

014 stays held, and its gate gains a condition: not just "the UI is repointed" but "the functional overlay exists and reconciles". The legacy Sankey keeps serving the business view until the taxonomy-based one produces the same departmental numbers — then it is retired because it is redundant, not because a phase said so.

The port is the next file. The 27 abstraction nodes and 74 leaf assignments lift straight out of `prs.device_hierarchy`; the ~23 graph-only devices arrive with no business home and need one assigned, which `graph.v_taxonomy_coverage` is there to surface.

### 15.6 What the port actually produced

`019_port_functional_taxonomy.sql` derives the taxonomy from the live legacy tables rather than hardcoding it — they *are* the specification, and a hand-copy is one transcription error away from a wrong departmental total. The cost is that it cannot be replayed after 014 drops those tables, which is why it must run first and why section 0 refuses rather than half-running.

Run against a full local replica of the live data (176 nodes, 231 edges, 888 measurements):

| | |
|---|---|
| categories | **28** — 1 root, 2 category, 7 department/group, 18 process |
| assignments | **72** |
| ambiguous | **0** |
| classified by inheritance | **27** nodes that carry no assignment of their own |

Three things are deliberately excluded, and each is named in the file:

- **The three legacy `SOURCE` nodes.** `GRID`, `PLTS_A` and `PLTS_B` map one-to-one onto graph `SOURCE` nodes (`INCOMING_PLN`, `PLTS_A`, `PLTS_B`). They are the supply side, which the physical graph already models; re-creating them as categories would put the same three nodes on both sides of the diagram.
- **`HVAC_A4` → device 98.** Device 98 "Compressor SCR 2200" is seeded under both `COMP_SCR2200` (COMPRESSOR) and `HVAC_A4` (HVAC) — the double-seeding already noted in §8. Its real home is COMPRESSOR, and `HVAC_A4` keeps its other device, 26 "LVMDB A4", so the leaf is not lost. Without the exclusion the node would take two categories at weight 1.0 and trip the weight guard.
- **`COMP_TURBO300HP` → device 53.** An active Power Meter in the legacy hierarchy with zero rows in `graph.measurement`, so there is no node to attach a category to. Not excluded by a rule — the join simply finds nothing — but reported, because the silence is otherwise indistinguishable from success.

Three guards were exercised and all produce readable messages rather than arithmetic ones: re-running refuses; a graph node claimed by two categories refuses by name (`LVMDB_A4 <- HVAC + SPINNING`); and a tree level deeper than the staged inserts reach is caught by count (`expected 29 abstraction nodes, inserted 28. Missing: SPINNING_LINE_2`).

### 15.7 What the port exposed

Inheritance does not merely save typing — it made a legacy mis-grouping visible for the first time.

`LVMDP_SPINNING_3` is a distribution board (device 74) that the legacy hierarchy filed under COMPRESSOR through a leaf named `COMP_SP3`. Physically it feeds nineteen nodes: mostly compressors, which is presumably why it was filed that way, but also `AHU_LINE3`, `LIGHT_INT_1`, `LIGHT_INT_2` and the sub-board `LVSDP_PROD_ATY`. In the legacy Sankey none of those four appeared at all — they are among the 23 devices the graph reaches and the old hierarchy did not — so the board's category was never contradicted by anything visible.

On the graph they do appear, and they inherit COMPRESSOR from the board. Air handling and lighting reported as compressed air is exactly the kind of error a departmental energy report must not contain, and it needs four explicit override rows.

Section 5 of 019 therefore prints every inherited assignment beside the tagged node it came from. That listing is the review step: a tag on a board propagates to everything the board feeds, and wherever the board serves mixed loads the inherited category is wrong. Explicit assignment always beats inheritance, so each correction is one row.
