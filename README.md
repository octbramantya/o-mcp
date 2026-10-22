# o-mcp — ontology, topology, and the MCP server over them

The vocabulary and the plant model for tenant 3 of the **valkyrie** database, and the base
for an MCP server that exposes the plant rather than the schema.

Moved here from `../prs_diags/docs/` on **2026-10-01**. Every path reference in the moved
files was rewritten, in both directions; nothing points at a stale location.

## What is here

| path | what it is |
|---|---|
| `design/graph-sankey.md` | `graph.sankey`: a sankey that names no device or node, solved on the graph and rolled up the category tree; the September 2026 reconcile that led to 046–052 (§9) and the build (§10) |
| `design/graph-network-design.md` | the base topology: `graph.node` / `graph.edge`, the solver (`solve_flow`, `get_node_quantity`, `get_sankey_flow`), node and edge classes, the migration phasing |
| `design/type-property.md` | node ontology — `node_type`, `graph.property`, `type_property`, `v_property_gaps`. Applied as migrations 025 and 026 |
| `design/edge-type.md` | edge ontology — `edge_type`, `edge_type_endpoint`, `carries_flow`, `v_edge_gaps`. Applied as migrations 027–030 |
| `design/draft_load_types.csv` | the reviewed node-typing worksheet, source of truth for migration 030 |
| `design/node_type_descriptions.csv` | the reviewed rewrite of 15 one-line node type descriptions: current, proposed, the basis of each claim, and notes. Source of truth for migration 042 |
| `design/quantity_terms.csv` | the quantity vocabulary worksheet: code, unit, reading and description for each quantity the meters report. Source of truth for migration 037 |
| `design/graph-*.csv`, `graph-seed-v1.csv` | hand-authored topology seeds (electricity, water) |
| `design/trafo_tenant_3.csv`, `capbank_tenant_3.csv`, `draft_current_ratings*.csv` | site surveys that feed node properties |
| `reference/wtp-pid.xml` | the water P&ID (draw.io), source for the water graph |
| `reference/graph_sankey_{assigned,categories,orphan}.csv` | category assignment and the orphan review export |
| `reference/production_nodes.csv` | node → device → department mapping |
| `migrations/` | every migration that touches the `graph` schema: `008–013`, `016–021`, `023–058`, plus `028_pre_solver_bodies.sql` (an undo helper, never run forward) and `rollback_graph.sql` |
| `tools/dev_refresh.sh` | rebuilds the dev database from production: all structure, the data of `graph`, `public.devices`, `public.quantities`, and optionally one window of telemetry and `daily_energy_cost_summary` |
| `tools/migrate.sh` | applies migrations one at a time and records each in the target database's ledger, `graph.schema_migration`. See "Databases and migrations" |
| `tools/gen_030.py` | renders migration 030 from `design/draft_load_types.csv`. Regenerate; never hand-edit the `.sql` |
| `tools/gen_037.py` | renders migration 037 from `design/quantity_terms.csv`. Same rule |
| `tools/gen_042.py` | renders migration 042 from `design/node_type_descriptions.csv`. Same rule |
| `tools/validate_brick.py` | checks Brick class names against a downloaded Brick TTL |
| `tools/sld.py`, `tools/sld.sql` | draws a single-line diagram (SVG) of one node down to `--depth` levels at `--as-of`, from the effective window. Read-only; output goes to `logs/<label>/`. `--save-json` writes the data as an `o-mcp/subgraph` v1 document |
| `design/subgraph-v1.schema.json` | the definition of the `o-mcp/subgraph` v1 format (JSON Schema, a description on every field). The MCP topology tools' `outputSchema` |
| `design/subgraph-format.md` | the same format explained: guarantees, findings, and the versioning rule |
| `design/mcp-tools.md` | drafts for the MCP server: the `plant_section` and `plant_vocabulary` tools' descriptions and input schemas, how a model learns what a response means, and where each ontology description comes from |
| `design/mcp-tenancy.md` | one Hermes agent per tenant: the authorization layers that keep each agent to its tenant, a database role per tenant enforced by Postgres, and what that changes in migration 043 (proposed, decisions open) |
| `design/mcp-catalogue.md` | every tool the MCP server is expected to need, by layer (vocabulary, topology, instruments, values, analysis), and how their discovery is staggered: by release, not at run time |
| `design/frontend.md` | the custom frontend that replaces Grafana in the long run: dashboard time range and refresh, snapping tiles, one tenant per user plus an admin group, each user's own dashboards in a `frontend` schema, database pooling through one shared API, and the monorepo layout (decided 2026-10-22, the rest proposed) |
| `tools/check_subgraph.py` | checks v1 documents against the schema, strictly: `uv run --no-project --with jsonschema tools/check_subgraph.py doc.json` |
| `server/` | the MCP server, phases 1 and 2: `plant_vocabulary`, `plant_find`, `plant_section`, `node_meters`, `meter_readings`, `node_value`, one module each in `server/tools/` (each holds the tool's description and input schema). Run against dev: `O_MCP_TOKEN=… O_MCP_BIND=127.0.0.1:8765 O_MCP_TENANT=3 O_MCP_TZ=Asia/Jakarta uv run python -m server --env-file .env` (`--phase 1` for the topology tools only). Keys in `.env.example` |
| `design/{vocabulary,nodelist,meters,readings,values}-v1.schema.json` | the output formats of the other five tools, under the same rules as `o-mcp/subgraph` |
| `server/tests/` | `uv run pytest`; with `O_MCP_TEST_ENV=.env O_MCP_TEST_WINDOW=START:END` (and `O_MCP_TENANT`, `O_MCP_TZ`) also every tool against dev, each result checked strictly against its schema |
| `tools/deploy_server.sh`, `deploy/o-mcp.service` | deploys a pushed commit of the server to a tenant's agent instance over SSH-over-SSM (`tools/deploy_server.sh hermes-prs --confirm hermes-prs`): a release per commit under `/opt/o-mcp`, the systemd unit, a `/healthz` check and rollback. Never writes `/etc/o-mcp/env` |
| `tools/deploy_hermes.sh`, `deploy/hermes-gateway.service`, `deploy/hermes-managed.yaml`, `deploy/hermes-SOUL.md` | installs Hermes Agent's Telegram gateway on the same instance (`tools/deploy_hermes.sh hermes-prs --confirm hermes-prs`): a pinned Hermes release built without its installer, the settings the agent may not change (model, toolsets, allowlist) in Hermes's managed scope, the agent's standing instructions, and a sandboxed unit. Never writes the bot token or `/etc/hermes/.env` (the Telegram user IDs) |
| `tools/hermes_toolcheck.py` | run by `deploy_hermes.sh` on the host before the gateway starts: the tools the model gets on Telegram must be exactly the six plant tools and memory, through the gateway's own config loader |
| `tools/mcp_smoke.py` | calls a running server over HTTP as a client does, prints the size of `tools/list`, and checks every answer: `O_MCP_URL=… O_MCP_TOKEN=… uv run python tools/mcp_smoke.py --window START END` |

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

## Current state of the model (dev and production, 2026-10-19)

Tenant 3, after migration 057 on production and 058 on dev. Migrations 031–042 were rehearsed
on a fresh copy of production and replayed there on 2026-10-07 (below); production's ledger
starts with `baseline 030`. Backup taken first: `logs/prod/graph_backup_pre031.20261007-113054.dump`.
Migrations 046–056 were applied to production on 2026-10-19 (below).

- **188 nodes and 192 edges in effect** (190 and 227 rows; 223 edges have `is_active`).
  Every node carries a `node_type`; `graph.v_edge_gaps` is empty. 97 nodes are metered (103
  devices); the solver resolves the rest.
- **Ontology:** 7 node classes (`SOURCE / BUS / CONVERSION / TREATMENT / STORAGE / LOAD / SINK`),
  27 node types (2 abstract, `SWITCHBOARD` and `WATER_TREATMENT`, parents of 8 subtypes),
  3 edge classes, 11 edge types with 77 endpoint rules, and 27 properties on 90 type links
  (12 REQUIRED). Classes, types and properties are tables with a description each; endpoint
  rules, attrs and abstract types are checked by trigger.
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
  - 7 electrical nodes have more than one live feeder, each a transformer plus PV or the gas
    engine, as drawn. The 18 Texture loads fed from both Texture boards were settled by 049/050
    (`LVMDB_TEXTURE` out of service since 2026-05-11).
  - `WASTEWATER_TREATMENT`, `WATER_OUTFALL` and `RECYCLE_CUT` have no alignment row (added after 031).
- `tx_impedance_pct` is empty on all 12 boards and OPTIONAL, which is why harmonics uses a
  blanket strict 5% TDD instead of per-board IEEE 519 limits.

## Migrations 031–042 (on production since 2026-10-07)

`graph.property.external_ref` for `tx_equipment_code` held
`docs/database/design/trafo_tenant_3.csv`. Migration 031 (**applied on dev
2026-10-01, on production 2026-10-07**) moves Brick and SAREF references into
`graph.vocabulary_alignment` and corrects that path to `design/trafo_tenant_3.csv`, relative to
this repository.

Migration 032 (**applied on dev 2026-10-01, on production 2026-10-07**) retires the unused
`DISTRIBUTION` node class: a level below a bus is a node type (`SUB_BOARD`), never a class.
`design/subgraph-v1.schema.json` already lists the five classes.

Migration 033 (**applied on dev 2026-10-01, on production 2026-10-07**) gives classes a table each,
`graph.node_class` (5) and `graph.edge_class` (3: `FEEDER`, `PIPE`, `COMPENSATION`), with a
description per class, turns the four class checks into foreign keys, retires the five edge
classes nothing ever used, and checks endpoint rules by trigger.

Migration 034 (**applied on dev 2026-10-01, on production 2026-10-07**) adds the node class `TREATMENT`
and moves `WATER_TREATMENT` and its four subtypes, with their nodes, out of `CONVERSION`, which
now means only a change of utility (compressor, boiler).

Migrations 035 and 036 (**applied on dev 2026-10-01, on production 2026-10-07**) add the node class
`SINK` (where the utility leaves the graph unconsumed), narrow `LOAD`, and redraw the water exits:
the two IPALs become `WASTEWATER_TREATMENT` with an outfall each, `WTP1_OVR` an outfall,
`WTP1_REUSE` a `RECYCLE_CUT` re-entering at `WTP1_RAN`, and `WTP1_WJL_REC` the tank it is,
now feeding Tandon Bio. 035 also deletes the 11 dead `SUPPLY_LV` rules that let a `LOAD`
feed something.

Migration 037 (**applied on dev 2026-10-02, on production 2026-10-07**) adds `graph.quantity_term`,
the vocabulary for metered quantities: a readable code, a unit, `COUNTER` or `SAMPLE`, and a
description for the 96 quantities tenant 3's meters report plus air (5932). `public.quantities`
(ported from Schneider PME) is untouched. Every `quantity_rule` must now have a term, and
`derived_quantity` gains a unit and description. Units were checked against telemetry where
possible (`unit_basis`): the harmonic magnitudes and "THD RMS Current" are percent of the
fundamental, not amperes, and Schneider power factor is quadrant-encoded on -2..2.

Migration 038 (**applied on dev 2026-10-02, on production 2026-10-07**) dates the retirement of
`MC302_BARU` and `MC303_BARU` (retired 2026-09-28, so `effective_to = 2026-09-27`, the last
day in service), replacing the `'-infinity'` that had marked real equipment as never true, and
makes `v_property_gaps` filter the effective window.

Migration 039 (**applied on dev 2026-10-05, on production 2026-10-07**) makes `site_status` and
`site_status_as_of` OPTIONAL on every equipment type (all but `RECYCLE_CUT`; still REQUIRED on
capacitor banks) and records `LVMDB_TEXTURE`, `HEATER_8` and `AIR_DRYER` as `inactive` as of
2026-10-02: deliberately turned off on site, kept whole in the graph. The status is kept by
hand, so the MCP server pairs it with each device's last reading (`design/mcp-tools.md`, gap 5).

Migration 040 (**applied on dev 2026-10-05, on production 2026-10-07**) deletes `quantity_rule` 2097
(THD current phase A) and its 99 measurement rows. The solver rolled it up as the RSS of the
children's percentages, which ignores their currents, ran into sources, and used phase A only.
Harmonic current is assessed per device and per phase by `harmonics_report.py` and Grafana.

Migration 041 (**applied on dev 2026-10-05, on production 2026-10-07**) adds
`graph.node_type.is_abstract`, TRUE on `SWITCHBOARD` and `WATER_TREATMENT`. A trigger refuses an
abstract type on a node, and another refuses making a type abstract while nodes use it.

Migration 042 (**applied on dev 2026-10-06, on production 2026-10-07**) replaces the 15 node type
descriptions that restated the name, rendered by `tools/gen_042.py` from
`design/node_type_descriptions.csv`. Each says what the type covers, how its nodes sit in the
graph, and what may not be inferred: a `PRODUCTION_MACHINE` node may be one machine or a
panel, a `WATER_INTAKE` may be a well, the municipal supply, a river or rainwater. Both stay
provisional, not abstract, until their subtypes exist (`design/type-property.md`, "When a new
type is justified").

## Migrations 043–045 (on production since 2026-10-12)

Migration 043 (**applied on dev and production 2026-10-12**) rewrites `PF_TOTAL`'s
description, which named two of tenant 3's device codes in a vocabulary every tenant reads: Schneider
meters code power factor by quadrant on -2..2, generic power meters and PLCs report it on -1..1.
`design/quantity_terms.csv` now holds the current text, so `tools/gen_037.py` no longer overwrites
the applied 037 (it checks the CSV and writes only with `--out`). See `design/mcp-tenancy.md` §5.

Migration 044 (**applied on dev and production 2026-10-12**) creates `prs_hermes_agent`,
tenant 3's agent role, kept to tenant 3 by Postgres: row-level security on the five `graph` tables
that hold tenant rows (a permissive policy keeps every other role as it was), `security_invoker` on
the `graph` views, and `security_barrier` views of the shared `public` tables in `prs`, which the
role's `search_path` puts first. It drops `pfn_mcp_reader`. `LOGIN` and the password are set by hand.
See `design/mcp-tenancy.md` §4. On production `pfn_mcp_reader` still held a grant on schema `public` in
the `postgres` database, so 044 left it `NOLOGIN` with nothing in `valkyrie` (as it is written to).

Rehearsed on a fresh copy of production (2026-10-12, telemetry 2026-09-28 to 2026-10-13), then
applied there. Backup first: `logs/prod/graph_prs_backup_pre043.20261012-143422.dump`, and
`pfn_mcp_reader`'s grants in `logs/prod/pfn_mcp_reader_grants_pre044.20261012-143422.sql`.

Migration 045 (**applied on dev and production 2026-10-12**) rewrites `PROCESS_HEATER`'s
description without tenant 3's heaters. `tools/gen_030.py`, which holds the 030 text, no longer
overwrites 030.

## Migrations 046–052 (on production since 2026-10-19)

Migration 046 moves device 28 (LVMDB A5) from the node `LVMDB_A5` to its feeder edge
`FACTORY_AB → LVMDB_A5`, as a documentation correction (node rows `effective_to = '-infinity'`,
edge rows from `'-infinity'`). PLTS A5 joins after the meter, so 28 reads the net grid draw: the
solver now gives A5 = 28 + 27 (61,188 kWh in September, against 11,424 before). `THD_VOLTAGE_LN`
(1119) stays on the node. Migration 047 swaps the codes and names of `WTP_1` and `WTP_2`, so
device 92 is "WTP 1" and 91 "WTP 2", as `public.devices` has them. Both come from the Sankey
reconcile (`design/graph-reconcile.md`, local). The September
run that checked them, and the open corrections it found, are in `design/graph-sankey.md` §9.

Migration 048 adds a second active-energy row to `LVMDB_A4`: device 167 (PLTS A4) × ⅓. A
point-of-common-coupling mistake makes meter 26 read the board on two phases and the grid on
the third, so 26 = A4 load − ⅓ of PV (September per-phase data; `design/graph-sankey.md` §9.2).
Migration 049 ends `LVMDB_TEXTURE`'s 20 live edges on 2026-08-17. It was out of service by
2026-08-18, and with both Texture boards live the solver lost 115,972 kWh a month into it. The
18 Texture loads now have one live board parent.
Migration 050 moves that end back to 2026-05-11, the day of the board's meter (107)'s last
reading in production.

Migration 051 changes `graph.solve_flow`, so the gas engine's share of A1–A3 is solved from
FACTORY_AB's meter instead of split 50/50 (`design/graph-sankey.md` §9.5). It adds a rule for
passthrough nodes: the unknown out-edges share what the node's meter leaves after its known
out-edges, in proportion to the targets' values, capped at what the targets take. The even split
of several unknown in-edges now runs only as a last resort, and `FACTORY_AB` is flagged
passthrough. The migration solves September before and after and aborts if anything but the
engine and its six edges moves. On dev the engine is 234,879 kWh for September (279,858 before).

Migration 052 moves `COMP_WINDER`'s feed from `LVMDP_SPINNING_3` to `LVSDP_COMP_23`, beside
`COMP_INTERLACE`, as a documentation correction (the old edge `'-infinity'`). Only
`LVSDP_COMP_23`'s solved value changes.

All seven were applied on dev, then on production on 2026-10-19 without a fresh-copy rehearsal:
production's graph matched dev's starting point (row counts, solver md5, no edits since
2026-10-07). Each migration's checks ran again there, and 051 and 052 gave the same before/after
values as on dev. Backup taken first: `logs/prod/graph_backup_pre046.20261019-121543.dump`.

## Migrations 053–055 (on production since 2026-10-19)

Migration 053 adds `graph.node_type_category`, a category default per node type (tenant 3:
`AIR_COMPRESSOR` → Compressor, `BOILER` → Boiler, `AHU` → HVAC, `LIGHTING` → Lighting), renames
the `FUNCTIONAL` root from Purchased Energy to `SUPPLY` / Supply, gives every category a
`display_color`, and puts `WORKSHOP` under Production.

Migration 054 adds `graph.sankey`, `graph.sankey_diagnostics` and `graph.sankey_nodes`. They name
no device and no node: each node's own value comes from the solver (value minus what it passes
on), and its category from, in order, its `node_category` rows, its type's default, its unmetered
children, its nearest categorised ancestor, or Unassigned. A node inserted into the graph is on
the diagram the same day. The migration checks the balances on September 2026 and aborts if one
fails. `prs.get_sankey_energy_flow` is not touched. See `design/graph-sankey.md` §10 for the
September figures and the diagnostics (three negative residuals, seven silent meters).

Migration 055 moves `SIPPA` from `FINISHING_22` to `WWTP`, as the user's SLD has it, and retypes
`WWTP` from `PUMP` to `SUB_BOARD` (with `nominal_v` 400) so it can feed. It is a documentation
correction (the old edge `'-infinity'`). Meter 139 was already reading SIPPA's load, so
`FINISHING_22`'s −9,641 kWh negative residual disappears, and only the two boards' own values change.

All three were applied on dev, then on production on 2026-10-19. 054's self-test and 055's
before/after check passed there with the same September figures as on dev, and `grafReader` can
call the functions. Backup taken first: `logs/prod/graph_backup_pre053.20261019-150404.dump`
(taken with `pg_dump` 16; production runs PostgreSQL 16).

## Migration 056 (on production since 2026-10-19)

Migration 056 puts `FLR_124` (Work Panel Fl. 1, 2, 4) under Production, the client's two broad
classes being Production and Utilities. It is the only unmetered panel on `LVMDP_SPINNING_1`, so
the board's residual (60,764 kWh in September) moves from Unassigned to Production. Applied on
dev, then on production on 2026-10-19 with the same result. Backup first:
`logs/prod/graph_backup_pre056.20261019-152347.dump`.

## Migration 057 (on production since 2026-10-19)

Migration 057 adds `graph.sld_devices(tenant, device, depth, as_of)`, the devices of one SLD
section for a Grafana variable, in place of static `IN (...)` lists: the root device, every
device metering a node `depth` levels below it (on the node or its feeder edge), and the PV
plants and gas engine injecting into those nodes, at the depth of the board they feed
(`PLTS_TEXTURE` beside `LVMDB_TEXTURE_2`). The INCOMING_PLN list it replaces had missed
`LVMDB_TEXTURE_2` (163) and `LVMDB_TF630` (106). Granted to `grafReader` and `prs_hermes_agent`.
Applied on dev, then on production on 2026-10-19; its self-test passed there, and `grafReader`
can call it. Backup first: `logs/prod/graph_backup_pre057.20261019-155452.dump`.

## Migration 058 (on dev since 2026-10-22)

Migration 058 adds the 15 category rows of the G3 worklist (`design/graph-sankey.md` §10), as the
user decided them on 2026-10-19 and 2026-10-22: `LVMDB_A1`, `LVMDB_B2` and `LABKNIT` under
Fabric, `LVMDP_SPINNING_2` and `MC_SP_A/B/C` under Spinning, `LVMDB_TF630` and `OFFICE_2` under
Production, `LVMDB_TEXTURE_2` under Yarn, `MC_MOTOR_5/6` under MC Motor, `HEATER_5/6/11` under
Heater. Board rows are there only where the one-level CHILDREN rule can't reach the board from
its loads. In September 2026 Unassigned falls from 390,413 to 200,472 kWh, meter 94's
unaccounted remainder alone, and Production rises by the same amount; Utilities doesn't move.
The migration checks all three. Not yet on production.

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
`--telemetry` also copies `public.daily_energy_cost_summary` for the same days, with its shifts
and costs, since `graph.device_totals` reads electricity energy from it, not from telemetry.

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

- The MCP server: phases 1 and 2 are built (`design/mcp-tools.md`, "Built") and, since
  2026-10-12, deployed on tenant 3's agent instance `hermes-prs` as `prs_hermes_agent`, passing
  against production. Hermes Agent (v2026.9.24, Sonnet 5.5 on Bedrock) is installed there since
  2026-10-13 with only the plant tools and memory; the Telegram gateway starts once the bot token
  is in place. Hermes sends the model `inputSchema` only, never `outputSchema`. Watch cold-cache
  timings on long THD windows (one 7-day call took 13 s cold, 0.6 s warm, against a 20 s limit).
  Phase 3 waits on where the Python analyses run (`design/mcp-catalogue.md` §4).
- `STEAM` utility and steam distribution, once the site team finishes documenting it.
- Collect `tx_impedance_pct`, which needs `harmonics_report.py` to read it first.
