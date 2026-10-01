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
| `tools/gen_030.py` | renders migration 030 from `design/draft_load_types.csv`. Regenerate; never hand-edit the `.sql` |

## What deliberately stayed in `../prs_diags`

**Applied migrations**, in `../prs_diags/docs/database/migrations/` (`001…030`). They are
one numbered sequence against one live database, and splitting a sequence across two folders
invites two migration 031s. The graph lineage inside it is
`008 009 010 011 012 016 024 025 026 027 028 029 030` plus `rollback_graph.sql` and
`028_pre_solver_bodies.sql`.

**Convention: future graph migrations are still written into that folder**, designed from
here. If that ever stops feeling right, move the whole `migrations/` directory at once
rather than part of it.

Also left behind, because they are not ontology: the general valkyrie reference
(`docs/database/README.md`, `public-views.md`, `public-functions.md`, `schema/`), the
maintenance and cleanup notes, the Grafana/Sankey visualisation docs
(`docs/prs/sankey*.md`), and `scripts/` — `graph_seed_export.py` and `wages_sync.py` are
graph authoring tools but they import `scripts/db.py`, so they move only together with it.

## Current state of the model (2026-10-01)

Tenant 3, applied and verified on valkyrie:

- **188 nodes, 222 edges.** Every node carries a `node_type`; `graph.v_edge_gaps` is empty.
- **22 node types** across `SOURCE / BUS / CONVERSION / STORAGE / LOAD`, **10 edge types**
  with 85 endpoint rules.
- `graph.v_property_gaps` holds **31 MISSING** rows — the site-check list. Each names a
  reader in `used_by`; a property is REQUIRED only if a real reader needs it.
- Known-wrong on purpose: `AIR_DRYER` is typed `AIR_COMPRESSOR`. See `design/edge-type.md` §9.
- `tx_impedance_pct` is empty on all 12 boards and OPTIONAL, which is why harmonics uses a
  blanket strict 5% TDD instead of per-board IEEE 519 limits.

## Loose end from the move

`graph.property.external_ref` for `tx_equipment_code` still holds the string
`docs/database/design/trafo_tenant_3.csv`, which is now
`../o-mcp/design/trafo_tenant_3.csv`. Migration 028 was left matching what was applied
rather than edited after the fact, so correcting the stored value needs a one-line
migration 031.

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

## Reaching the database

```bash
ssh -f -N -o ExitOnForwardFailure=yes -L 15432:localhost:5432 ec2-ssm
```

Credentials come from a gitignored `.env` read by a `db.py` helper with no fallbacks — the
old pattern of `os.getenv('IOP_DB_PASSWORD', '<literal>')` failed open, and silently. The
role is read-only (`grafReader`) by default; write credentials are granted per session and
reverted.

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
