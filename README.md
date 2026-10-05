# o-mcp — ontology, topology, and the MCP server over them

The vocabulary and the plant model for tenant 3 of the **valkyrie** database, and the base
for an MCP server that exposes the plant rather than the schema.

Moved here from `../prs_diags/docs/` on **2026-10-01**. Every path reference in the moved
files was rewritten, in both directions; nothing points at a stale location.

## What is here

| path | what it is |
|---|---|
| `design/graph-network-design.md` | the base topology: `graph.node` / `graph.edge`, the solver (`solve_flow`, `get_node_quantity`, `get_sankey_flow`), node and edge classes, the migration phasing |
| `design/type-property.md` | node ontology — `node_type`, `graph.property`, `type_property`, `v_property_gaps`. Applied as migrations 025 and 026 |
| `design/edge-type.md` | edge ontology — `edge_type`, `edge_type_endpoint`, `carries_flow`, `v_edge_gaps`. Applied as migrations 027–030 |
| `design/draft_load_types.csv` | the reviewed node-typing worksheet, source of truth for migration 030 |
| `design/quantity_terms.csv` | the quantity vocabulary worksheet: code, unit, reading and description for each quantity the meters report. Source of truth for migration 037 |
| `design/graph-*.csv`, `graph-seed-v1.csv` | hand-authored topology seeds (electricity, water) |
| `design/trafo_tenant_3.csv`, `capbank_tenant_3.csv`, `draft_current_ratings*.csv` | site surveys that feed node properties |
| `reference/wtp-pid.xml` | the water P&ID (draw.io), source for the water graph |
| `reference/graph_sankey_{assigned,categories,orphan}.csv` | category assignment and the orphan review export |
| `reference/production_nodes.csv` | node → device → department mapping |
| `migrations/` | every migration that touches the `graph` schema: `008–013`, `016–021`, `023–040`, plus `028_pre_solver_bodies.sql` (an undo helper, never run forward) and `rollback_graph.sql` |
| `tools/dev_refresh.sh` | rebuilds the dev database from production: all structure, the data of `graph`, `public.devices`, `public.quantities`, and optionally one telemetry window |
| `tools/migrate.sh` | applies migrations one at a time and records each in the target database's ledger, `graph.schema_migration`. See "Databases and migrations" |
| `tools/gen_030.py` | renders migration 030 from `design/draft_load_types.csv`. Regenerate; never hand-edit the `.sql` |
| `tools/gen_037.py` | renders migration 037 from `design/quantity_terms.csv`. Same rule |
| `tools/validate_brick.py` | checks Brick class names against a downloaded Brick TTL |
| `tools/sld.py`, `tools/sld.sql` | draws a single-line diagram (SVG) of one node down to `--depth` levels at `--as-of`, from the effective window. Read-only; output goes to `logs/<label>/`. `--save-json` writes the data as an `o-mcp/subgraph` v1 document |
| `design/subgraph-v1.schema.json` | the definition of the `o-mcp/subgraph` v1 format (JSON Schema, a description on every field). The MCP topology tools' `outputSchema` |
| `design/subgraph-format.md` | the same format explained: guarantees, findings, and the versioning rule |
| `design/mcp-tools.md` | drafts for the MCP server: the `plant_section` and `plant_vocabulary` tools' descriptions and input schemas, how a model learns what a response means, and where each ontology description comes from |
| `tools/check_subgraph.py` | checks v1 documents against the schema, strictly: `uv run --no-project --with jsonschema tools/check_subgraph.py doc.json` |

## What stayed in `../prs_diags`

**Migrations `001–007`, `014`, `015`, `022`** and `rollback.sql` / `rollback_demand_daily.sql`:
the `prs` schema, the legacy drops and `public.demand_daily`. The graph migrations moved here
on 2026-10-01 (see `../prs_diags/docs/database/MOVED.md`). **The numbering is still one
sequence across both folders**: a new migration takes the next number after the highest in
*both* `migrations/` folders, so the two never both hold the same number.

Also left behind, because they are not ontology: the general valkyrie reference
(`docs/database/README.md`, `public-views.md`, `public-functions.md`, `schema/`), the
maintenance and cleanup notes, the Grafana/Sankey visualisation docs
(`docs/prs/sankey*.md`), and `scripts/` — `graph_seed_export.py` and `wages_sync.py` are
graph authoring tools but they import `scripts/db.py`, so they move only together with it.

## Current state of the model (dev, 2026-10-05)

Tenant 3 on dev, after migration 040. Production is at **030**: migrations 031–040 are applied
and verified on dev and wait to be replayed there (below), so production still has 24 node
types, 10 edge types, 85 endpoint rules and no class tables.

- **188 nodes and 212 edges in effect** (190 and 225 rows; 221 edges have `is_active`).
  Every node carries a `node_type`; `graph.v_edge_gaps` is empty. 97 nodes are metered (103
  devices); the solver resolves the rest.
- **Ontology:** 7 node classes (`SOURCE / BUS / CONVERSION / TREATMENT / STORAGE / LOAD / SINK`),
  27 node types (3 with subtypes), 3 edge classes, 11 edge types with 77 endpoint rules, and
  27 properties on 90 type links (12 REQUIRED). Classes, types and properties are tables with a
  description each; endpoint rules and attrs are checked by trigger.
- **Vocabularies:** 34 Brick/SAREF alignment rows (`graph.vocabulary_alignment`), 97 quantity
  terms (`graph.quantity_term`), 10 solver rules (`graph.quantity_rule`), 1 alias and 1 derived
  quantity (`PF_TRUE`).
- `graph.v_property_gaps` holds **31 MISSING** rows — the site-check list (`rated_kw` 17,
  `main_breaker_a` 11, `nominal_v` 3). Each names a reader in `used_by`; a property is REQUIRED
  only if a real reader needs it.
- `site_status`: 4 nodes `inactive` (`LVMDB_TEXTURE`, `HEATER_8`, `AIR_DRYER`, `CB_MDP3`),
  10 `normal`, all capacitor banks.
- Known-wrong on purpose: `AIR_DRYER` is typed `AIR_COMPRESSOR`. See `design/edge-type.md` §9.
- Open:
  - 25 nodes have more than one live feeder. 7 are a transformer plus PV or a generator, as
    drawn; the 18 Texture boards fed by two `SUPPLY_LV` edges are the open parentage question.
  - 16 node types have one-line descriptions that restate the name.
  - `WASTEWATER_TREATMENT`, `WATER_OUTFALL` and `RECYCLE_CUT` have no alignment row (added after 031).
- `tx_impedance_pct` is empty on all 12 boards and OPTIONAL, which is why harmonics uses a
  blanket strict 5% TDD instead of per-board IEEE 519 limits.

## Pending on production: migrations 031–040

`graph.property.external_ref` for `tx_equipment_code` still holds
`docs/database/design/trafo_tenant_3.csv` on production. Migration 031 (**applied on dev
2026-10-01, not yet on production**) moves Brick and SAREF references into
`graph.vocabulary_alignment` and corrects that path to `design/trafo_tenant_3.csv`, relative to
this repository.

Migration 032 (**applied on dev 2026-10-01, not yet on production**) retires the unused
`DISTRIBUTION` node class: a level below a bus is a node type (`SUB_BOARD`), never a class.
`design/subgraph-v1.schema.json` already lists the five classes.

Migration 033 (**applied on dev 2026-10-01, not yet on production**) gives classes a table each,
`graph.node_class` (5) and `graph.edge_class` (3: `FEEDER`, `PIPE`, `COMPENSATION`), with a
description per class, turns the four class checks into foreign keys, retires the five edge
classes nothing ever used, and checks endpoint rules by trigger.

Migration 034 (**applied on dev 2026-10-01, not yet on production**) adds the node class `TREATMENT`
and moves `WATER_TREATMENT` and its four subtypes, with their nodes, out of `CONVERSION`, which
now means only a change of utility (compressor, boiler).

Migrations 035 and 036 (**applied on dev 2026-10-01, not yet on production**) add the node class
`SINK` (where the utility leaves the graph unconsumed), narrow `LOAD`, and redraw the water exits:
the two IPALs become `WASTEWATER_TREATMENT` with an outfall each, `WTP1_OVR` an outfall,
`WTP1_REUSE` a `RECYCLE_CUT` re-entering at `WTP1_RAN`, and `WTP1_WJL_REC` the tank it is,
now feeding Tandon Bio. 035 also deletes the 11 dead `SUPPLY_LV` rules that let a `LOAD`
feed something.

Migration 037 (**applied on dev 2026-10-02, not yet on production**) adds `graph.quantity_term`,
the vocabulary for metered quantities: a readable code, a unit, `COUNTER` or `SAMPLE`, and a
description for the 96 quantities tenant 3's meters report plus air (5932). `public.quantities`
(ported from Schneider PME) is untouched. Every `quantity_rule` must now have a term, and
`derived_quantity` gains a unit and description. Units were checked against telemetry where
possible (`unit_basis`): the harmonic magnitudes and "THD RMS Current" are percent of the
fundamental, not amperes, and Schneider power factor is quadrant-encoded on -2..2.

Migration 038 (**applied on dev 2026-10-02, not yet on production**) dates the retirement of
`MC302_BARU` and `MC303_BARU` (retired 2026-09-28, so `effective_to = 2026-09-27`, the last
day in service), replacing the `'-infinity'` that had marked real equipment as never true, and
makes `v_property_gaps` filter the effective window.

Migration 039 (**applied on dev 2026-10-05, not yet on production**) makes `site_status` and
`site_status_as_of` OPTIONAL on every equipment type (all but `RECYCLE_CUT`; still REQUIRED on
capacitor banks) and records `LVMDB_TEXTURE`, `HEATER_8` and `AIR_DRYER` as `inactive` as of
2026-10-02: deliberately turned off on site, kept whole in the graph. The status is kept by
hand, so the MCP server pairs it with each device's last reading (`design/mcp-tools.md`, gap 5).

Migration 040 (**applied on dev 2026-10-05, not yet on production**) deletes `quantity_rule` 2097
(THD current phase A) and its 99 measurement rows. The solver rolled it up as the RSS of the
children's percentages, which ignores their currents, ran into sources, and used phase A only.
Harmonic current is assessed per device and per phase by `harmonics_report.py` and Grafana.

## Two rules worth not rediscovering

**Filter the effective window, not just `is_active`.** `graph.node` and `graph.edge` have two
independent retirement mechanisms. `is_active` alone over-reports (on dev, 2026-10-05: 221 edge
rows are active, 212 are in effect) and it has already produced two wrong findings and one wrong
view.

```sql
is_active AND effective_from <= CURRENT_DATE
          AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)
```

**Valid time versus documentation correction.** `effective_to = <date>` means the plant
changed on that date and past reports stay valid. `effective_to = '-infinity'` means never
true — recorded from an SLD that was simply wrong — so past reports built on it are
retroactively wrong. `DELETE` only when the wrong belief has no evidential value. The site
engineers do not insert panels; they realise the SLD we hold is incorrect and request a
redraw, which is `'-infinity'`, not a date.

## Databases and migrations

Develop against a **development database**, not valkyrie. Its connection goes in `.env`
(gitignored; copy `.env.example`), and superuser access there is fine. The migrations check
the data before changing anything (for example 031 refuses to run unless there are exactly 24
node types), so dev must match production where the migrations look. Rebuild it before
testing each migration:

```bash
tools/dev_refresh.sh -s .env.prod-ro --confirm dev                              # structure + graph data
tools/dev_refresh.sh -s .env.prod-ro --telemetry 2026-09-07 2026-09-14 --confirm dev   # + a telemetry week, for solver changes
```

`.env.prod-ro` holds read-only production credentials (`grafReader`) for that session, and the
tunnel must be up. The script drops and recreates the dev database. It copies the full
structure, plus the data of `graph`, `public.devices` and `public.quantities` (graph's foreign
keys point at those two), and creates the roles as `NOLOGIN` without passwords. Telemetry is
copied only when asked for: without it, solver before/after checks compare empty to empty.

Dev doesn't need TimescaleDB. Hypertables and continuous aggregates become plain tables with
the same columns, so views over them keep working. Objects that can't exist without
TimescaleDB are reported and skipped. The run fails unless every `graph` object and every
copied row count matches production.

```bash
tools/migrate.sh status                      # what this database has run; read-only
tools/migrate.sh apply 031 --confirm dev     # run one migration and record it
```

**Promotion to production means replaying the same files, never copying the dev database.**
Each database keeps its own ledger, so `status` against production lists exactly what is
pending there:

1. Write the migration in `migrations/`, apply it to dev, and check the output.
2. Create `.env.prod` for that session only, with `DB_LABEL=prod` and write credentials, and open the tunnel:
   `ssh -f -N -o ExitOnForwardFailure=yes -L 15432:localhost:5432 ec2-ssm`
3. `tools/migrate.sh -e .env.prod status`, then `tools/migrate.sh -e .env.prod apply NNN --confirm prod`.
4. Delete `.env.prod` and revert the write credentials.

The same checks that ran on dev run again on production. If production differs from what
dev was restored from, the migration aborts inside its transaction and changes nothing.
After a migration is applied anywhere, don't edit it: `status` flags any file whose hash no
longer matches its ledger row.

**First use of each database:** `init` creates the ledger. Then `baseline 030` records the
migrations that ran before the ledger existed, without running them again.

Each run's output goes to `logs/<label>/` (gitignored).

## Next

- Build the MCP server. The ontology enters at three distinct times: tool-registration
  (vocabulary becomes JSON Schema enums), invocation (server-side resolution and endpoint
  validation, never the model's responsibility), and discovery (a browsable resource, as a
  fallback and not a prerequisite). Make `as_of` a required argument on every topology tool,
  defaulting to `CURRENT_DATE`, with the window filter inside the server.
- The 18 Texture nodes with two live board parents — the last genuine parentage ambiguity in
  the electricity graph.
- `STEAM` utility and steam distribution, once the site team finishes documenting it.
- Collect `tx_impedance_pct`, which needs `harmonics_report.py` to read it first.
