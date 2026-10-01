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
| `design/graph-*.csv`, `graph-seed-v1.csv` | hand-authored topology seeds (electricity, water) |
| `design/trafo_tenant_3.csv`, `capbank_tenant_3.csv`, `draft_current_ratings*.csv` | site surveys that feed node properties |
| `reference/wtp-pid.xml` | the water P&ID (draw.io), source for the water graph |
| `reference/graph_sankey_{assigned,categories,orphan}.csv` | category assignment and the orphan review export |
| `reference/production_nodes.csv` | node → device → department mapping |
| `migrations/` | every migration that touches the `graph` schema: `008–013`, `016–021`, `023–032`, plus `028_pre_solver_bodies.sql` (an undo helper, never run forward) and `rollback_graph.sql` |
| `tools/dev_refresh.sh` | rebuilds the dev database from production: all structure, the data of `graph`, `public.devices`, `public.quantities`, and optionally one telemetry window |
| `tools/migrate.sh` | applies migrations one at a time and records each in the target database's ledger, `graph.schema_migration`. See "Databases and migrations" |
| `tools/gen_030.py` | renders migration 030 from `design/draft_load_types.csv`. Regenerate; never hand-edit the `.sql` |
| `tools/validate_brick.py` | checks Brick class names against a downloaded Brick TTL |
| `tools/sld.py`, `tools/sld.sql` | draws a single-line diagram (SVG) of one node down to `--depth` levels at `--as-of`, from the effective window. Read-only; output goes to `logs/<label>/`. `--save-json` writes the data as an `o-mcp/subgraph` v1 document |
| `design/subgraph-v1.schema.json` | the definition of the `o-mcp/subgraph` v1 format (JSON Schema, a description on every field). The MCP topology tools' `outputSchema` |
| `design/subgraph-format.md` | the same format explained: guarantees, findings, and the versioning rule |
| `design/mcp-tools.md` | drafts for the MCP server: the `plant_section` tool's description and input schema, and how a model learns what the response means |
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

## Current state of the model (2026-10-01)

Tenant 3, applied and verified on valkyrie:

- **188 nodes, 222 edges.** Every node carries a `node_type`; `graph.v_edge_gaps` is empty.
- **24 node types** across `SOURCE / BUS / CONVERSION / STORAGE / LOAD`, **10 edge types**
  with 85 endpoint rules.
- `graph.v_property_gaps` holds **31 MISSING** rows — the site-check list. Each names a
  reader in `used_by`; a property is REQUIRED only if a real reader needs it.
- Known-wrong on purpose: `AIR_DRYER` is typed `AIR_COMPRESSOR`. See `design/edge-type.md` §9.
- `tx_impedance_pct` is empty on all 12 boards and OPTIONAL, which is why harmonics uses a
  blanket strict 5% TDD instead of per-board IEEE 519 limits.

## Loose end from the move

`graph.property.external_ref` for `tx_equipment_code` still holds
`docs/database/design/trafo_tenant_3.csv`. Migration 031 (**applied on dev 2026-10-01, not yet on
production**) moves Brick and SAREF references into `graph.vocabulary_alignment` and corrects
that path to `design/trafo_tenant_3.csv`, relative to this repository.

Migration 032 (**applied on dev 2026-10-01, not yet on production**) retires the unused
`DISTRIBUTION` node class: a level below a bus is a node type (`SUB_BOARD`), never a class.
`design/subgraph-v1.schema.json` already lists the five classes.

## Two rules worth not rediscovering

**Filter the effective window, not just `is_active`.** `graph.node` and `graph.edge` have two
independent retirement mechanisms. `is_active` alone over-reports — 222 rows versus 209
currently-effective ones — and it has already produced two wrong findings and one wrong
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
