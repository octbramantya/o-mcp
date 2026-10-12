# Tenancy and authorization for the agents

How one Hermes agent per tenant is kept to its own tenant. Written 2026-10-12, before migration
044, which depends on it. Decided the same day: one `t4g.small` per tenant, one database role per
tenant, `pfn_mcp_reader` removed. Database enforcement is proposed (§4), not yet decided.

`graph` holds only tenant 3 today, the most complex. Tenant 4 is next: it will mostly share tenant
3's vocabulary, with its own graph. So this is designed for a second tenant now, not in theory.

## The requirement

`valkyrie` holds every tenant. Grafana separates them by organization, and every query filters
`tenant_id`; Postgres enforces nothing (no row-level security on any table, checked on dev
2026-10-12). The plan is **one Hermes agent per tenant**, serving that tenant's users and building
a memory of that tenant only. An agent must not reach another tenant's data, nor learn whether
other tenants exist, **even when its model is instructed to by an injected prompt** ("are there
other tenants on this database, and what do they use?").

## The principle: the model is not a security boundary

Whatever an agent's model can be told, it can be told by an attacker: email and chat reach it
unfiltered, and an allowlist only narrows who can try. So nothing the model decides may widen
what it can reach. Each boundary sits below the model, and each holds even if the one above it
fails:

| layer | what holds the boundary | holds even if |
|---|---|---|
| 1. Agent | one Hermes instance per tenant: its own Unix user, memory, gateways and allowlist | — |
| 2. Credential | the agent holds one bearer token, which opens one tenant's MCP server and nothing else | the model is fully controlled by an attacker |
| 3. Tool surface | no tool takes a tenant; the tenant is fixed by the server's configuration | the token is used by someone other than the agent |
| 4. Database | the server's database role can read only its tenant's rows, enforced by Postgres | the server has a bug that forgets a `tenant_id` filter, or its password leaks |
| 5. Shared vocabulary | the ontology every tenant reads describes types, never one tenant's plant | — |
| 6. Audit | each call is logged with its tenant; each tenant has its own database role | — (it detects, it does not prevent) |

Layer 3 already holds in the built server: `O_MCP_TENANT` is configuration, no input schema has
a tenant, node names resolve only among the tenant's own nodes, and database errors reach the
model as one generic sentence. Asked "are there other tenants?", the agent has no tool that could
answer. Layers 2, 4 and 5 are new work; layer 1 is deployment.

## 1. Agent: one instance per tenant

- Each tenant's agent runs as its own Unix user, with its own memory, skills and configuration
  directories, readable by that user only. No shared memory, no shared skills directory.
- Its own gateways: one Telegram bot and one mailbox per tenant, each with an allowlist of that
  tenant's users. The allowlist is the tenant's Grafana organization membership, kept by hand
  until something syncs it.
- The terminal tool off, or sandboxed with **no network route to loopback or the VPC**: with
  several agents on one host, a sandbox that shares the host network can reach every tenant's MCP
  server and needs only a token (`mcp-server.md` §1, condition 3, now per tenant).
- Its system prompt names its tenant and says the tools see nothing else. That helps answers; it
  is not a control.

**Hosting (decided 2026-10-12): one `t4g.small` per tenant**, in the database's VPC, running that
tenant's Hermes and its MCP server and reaching Postgres over the private network through
PgBouncer. Hermes and the MCP tools are add-ons, so an instance per tenant bills per tenant; it also
keeps a host escape inside one tenant. `mcp-server.md` §1 and §7 describe that instance as if there
were one; they hold per tenant. The database's security group allows 6432 from each tenant's
instance.

## 2. Credential: one token, one tenant

One MCP server process per tenant, each with its own `O_MCP_TOKEN` and `O_MCP_TENANT`, its own
systemd unit and environment file, and its own database role. The agent's MCP configuration holds
only its own token. This is the server as built; it only has to be run once per tenant.

Rejected: one multi-tenant server that maps tokens to tenants. It is one process instead of N, but
its database credential then has to read every tenant, which puts layers 2 and 4 back on the
server's code alone.

## 4. Database: a role per tenant, enforced by Postgres

A login role per tenant, named for its tenant schema: `prs_hermes_agent` for tenant 3,
`iop_hermes_agent` for tenant 4 (decided: one database role per tenant), that Postgres
itself keeps to tenant N. Probed on dev
2026-10-12 inside a transaction that was rolled back: Grafana's `grafReader` still saw both tenants
(43 and 107 devices), the probe role saw only tenant 3's 107, even when asking for tenant 4 by name,
`graph.get_node_quantity` ran normally for tenant 3 as the probe role, and a read of the base
telemetry table was refused.

Two mechanisms, because the tables are of two kinds:

- **`graph` tables** (`node`, `edge`, `measurement`, `category`, `node_category`): row-level
  security with two policies each. A permissive policy for everyone, `USING (true)`, keeps every
  existing role exactly as it is; a **restrictive** policy `TO <schema>_hermes_agent USING (tenant_id = N)`
  narrows only the tenant role. The solver names these tables with their schema (`graph.node`),
  so a view could not stand in for them; RLS applies whatever the name.
- **`graph` views** (`v_property_gaps`, `v_edge_gaps`, `v_type_property`, `v_coverage`,
  `v_device_attachment`, `v_category_tree`, `v_taxonomy_coverage`) are owned by `postgres` and so,
  by default, read their tables with the owner's rights, which **bypass row-level security**.
  Probed on dev: with a policy allowing no rows, the role still got all 31 rows of
  `v_property_gaps`; with `security_invoker = true` on the view, none. So 044 sets
  `security_invoker` on every `graph` view. For `grafReader` nothing changes (it has `SELECT` on
  every `graph` table, migration 010); a view that also reads a `public` base table
  (`v_device_attachment` reads `public.devices`) is refused to the tenant role, which fails closed.
  A new `graph` view must set it too.
- **`public` tables the server and solver read** (`devices`, `quantities`, `telemetry_15min_agg`,
  `daily_energy_cost_summary`, `telemetry_intervals_water`, `tenant_shift_periods`): views filtered
  to tenant N under the same names, **in the tenant's own schema**, `prs` for tenant 3 and `iop`
  for tenant 4, and the role's `search_path` set to `<tenant schema>, graph, public`.
  `graph.device_totals` names these tables without a schema and no graph function pins its
  `search_path`, so the solver reads the views without being changed. The role gets the views,
  not the base tables, so **anything that names `public.<table>` directly is refused**: it fails
  closed. (`quantities` has no `tenant_id`; its view is the table.) The server's own queries drop
  their `public.` prefixes to go through the views too. RLS is not an option for these tables:
  on production `telemetry_15min_agg` is a TimescaleDB continuous aggregate, a view.

### What production showed (read-only, as `grafReader`, 2026-10-12)

| | found | what it means for step 3 |
|---|---|---|
| tenant schemas | `prs` (tenant 3: 3 tables, 38 functions, 21 of them filter `tenant_id = 3`) and `iop` (tenant 4: 8 tables, 7 views, 17 functions, 9 filter `tenant_id = 4`). Both owned by `postgres`; `USAGE` for `grafReader` and `agenticpg` | the views go here, one schema per tenant, as the user asked; no new schema |
| name clashes | neither schema has an object named like the six tables | the views can take the same names |
| tenant-schema code | most `prs`/`iop` functions name the shared tables without a schema (`daily_energy_cost_summary` 24 times in `prs`, `devices` 9 times in `iop`, ...); none sets `search_path` or pins it | **those functions read whatever the caller's `search_path` finds first.** For every role today that is `public`, so nothing changes. A session with `prs` first on its path would read the tenant views instead: the same tenant's rows, since the `prs` functions already filter tenant 3, but the 11 `prs` functions that take a `p_tenant_id` would answer nothing for another tenant |
| `search_path` settings | none on any role or database | nobody's queries change when the views appear. Rule from now on: putting a tenant schema on a role's `search_path` makes that role tenant-scoped for the shared tables; do it only to mean that |
| `telemetry_15min_agg` | a continuous aggregate, materialized only, 42 chunks | a tenant filter in front of it keeps chunk exclusion: a 7-day query through the inlined filter scanned 1 chunk (`EXPLAIN`, not run) |
| TimescaleDB grants | a grant on the aggregate is copied to its materialized hypertable, partial and direct views and every chunk (`pfn_mcp_reader` holds `SELECT` on about 100 internal objects) | **grant the tenant role the views only, never the aggregate**; a view owned by `postgres` reads it with the owner's rights |
| row-level security | on 7 tables (`auth.*`, `cron.*`, `deprecated_tables.device_alerts`), none in `graph` or `public` | the `graph` policies are new. The old `device_alerts` policy keys on `current_setting('app.current_tenant_id')`, which any session can set for itself; a restrictive policy `TO` a role cannot be talked around that way |
| `pfn_mcp_reader` | `LOGIN`; `SELECT` on 13 `public` objects (including `telemetry_data` and `tenants`) and the TimescaleDB internals; full write on the old server's `mcp.conversations`, `mcp.messages`, `mcp.tenant_branding`; `USAGE` on `mcp` and `public` | far more than `mcp-server.md` §4 recorded. Dropping it revokes all of that (`DROP OWNED BY` in `valkyrie`); the `mcp` tables, owned by `postgres`, stay |
| databases a new login can reach | `postgres` and `valkyrie` (`CONNECT` from `PUBLIC`) | PgBouncer exposing only `valkyrie` is the boundary; the role is also refused by `pg_hba` if it lists roles per database (not readable as `grafReader`) |
| `agenticpg` | a login role with `SELECT` across `public`, `iop`, `maintenance` and TimescaleDB internals | pgAgent's role (per the user); unrelated to the agents here |

What this costs, and what to check before migration 044:

- Enabling RLS on `graph.*` touches tables other roles read. The permissive policy keeps them
  unchanged, and the table owner bypasses RLS, but rehearse on a fresh copy of production with
  Grafana's dashboards and the pgAgent jobs, as for any migration.
- Every future solver function must keep the `public` tables unqualified, or it fails for the
  tenant roles. Failing is the safe direction; a comment in each function and a test as the MCP
  role catch it.
- The tenant role gets `USAGE` on its tenant schema, which also lets it call the schema's functions
  (`EXECUTE` is `PUBLIC`'s by default). They run as the role, so they read the tenant views and
  are refused the schema's own tables, which are not granted. Harmless; not something the server
  calls.
- PgBouncer pools per role, so each tenant role gets its own pool and its own
  `max_user_connections`. The per-role limits of `mcp-server.md` §4 apply per tenant.
- `PUBLIC` already holds `CONNECT`, `USAGE` on `public`, `TEMPORARY`, and `EXECUTE` on the graph
  functions. The tenant role gets nothing beyond them, and nothing is taken from `PUBLIC` (that
  would affect every role).


## 5. Shared vocabulary: types, never a tenant's plant

`graph.node_type`, `edge_type`, `property`, `quantity_term`, `quantity_rule` and `derived_quantity`
have no `tenant_id`: every tenant's agent reads them, through `plant_vocabulary` and the input
schemas. Two descriptions written for tenant 3 would tell another tenant's agent about tenant 3:

| term | what it says about tenant 3 |
|---|---|
| `quantity_term` `PF_TOTAL` | "The PV loggers (PLTSC, PLTSD) report a plain signed PF instead": two of tenant 3's device codes. **Rewritten by migration 043** (applied on dev 2026-10-12): Schneider meters by quadrant, generic power meters and PLCs on -1 to 1 |
| `node_type` `PROCESS_HEATER` | "The ten Texture heaters sit under HEATER_TOTAL" |

The rule: **a shared description says what a type or quantity is, never where one tenant has it.**
Tenant facts belong in tenant rows. Both rewrites are a data migration, like 042.

**Power factor encoding is a meter model's, not a tenant's.** Checked on dev, per model
(`devices.metadata.device_info`): Schneider PM2220, PM5110, PM2200 and PM5560 report -2..2 by
quadrant; the Surya Nesia loggers (PLTSC, PLTSD) a plain signed -1..1; Lovato DMG610 and
Schneider PM710 an unsigned 0..1. One decoding gives the right magnitude for all of them (above 1:
2 minus it; below -1: it plus 2; -2: no load; otherwise its absolute value), so the server dropped
its list of tenant 3's device codes (`PF_PLAIN_DEVICES`) on 2026-10-12, with identical readings on
all four PV meters. What differs by model is only what the sign means (leading or lagging, import
or export), which no tool reports. (PLTSC and PLTSD are a custom PLC, per the site.) If the sign is ever needed, the encoding belongs in a shared table keyed by
manufacturer and model: meter models are vocabulary, the same for every tenant.

## 6. Audit

The server already logs one JSON line per call; it adds the tenant. With a role per tenant, every
query in `pg_stat_activity` and the Postgres log names its tenant too. A refused read
(`permission denied` from a tenant role) is a bug or an attack; worth an alert once one exists.

## Users within a tenant

All of a tenant's users see the whole tenant, as Grafana's organizations do today. Narrowing per
user (one department, say) would need the user's identity to reach the server from the gateway,
never from the model, and Hermes sends an MCP server the same static headers for every user. Not
designed until it is needed.

## What changes in migration 044

**Applied on dev 2026-10-12**, with every check inside it passing. The MCP server then ran as
`prs_hermes_agent` on dev (`LOGIN` set by hand for the test, then removed): it logged that the role
sees only tenant 3, all 21 tests passed, among them one that the base tables and tenant 4's solver
answer are refused, and `tools/mcp_smoke.py` passed with the same values as before. The server's
queries name the shared `public` tables without a schema since then (`server/db.py`).

Renumbered 2026-10-12: 043 became the `PF_TOTAL` description (§5), applied on dev first.
`mcp-server.md` §4 planned one role, `pfn_mcp_reader`, re-granted. With the above, 044 instead:

1. creates `prs_hermes_agent` (`NOLOGIN` in the migration; `LOGIN` and the password set by hand on
   production, as planned), with the limits of `mcp-server.md` §4 and
   `search_path = prs, graph, public`;
2. creates the six tenant views in `prs` (dev has `prs` and `iop` too, copied by
   `tools/dev_refresh.sh`; 2.1 refuses to run without `prs`), grants them, `USAGE` on `prs` and
   `graph`, and `SELECT` on `graph`;
3. enables RLS on the five `graph` tables with the two policies each, and sets
   `security_invoker` on the seven `graph` views;
4. drops `pfn_mcp_reader` (decided 2026-10-12; its server is decommissioned): `DROP OWNED BY` to
   revoke its grants, then `DROP ROLE`;
5. verifies as the new role: no row of another tenant in any granted table or view, a read of
   `public.telemetry_15min_agg` refused, and the solver answering for tenant 3.

As built, the `prs` views are `security_barrier`: the role may create temporary functions, and a
barrier keeps one from seeing rows before the tenant filter. The comparisons the server uses are
leakproof, so tenant, device and window conditions still reach the index (`EXPLAIN` on dev).
2.1 also refuses to run if `security_invoker` would lock any current reader of a `graph` view out
of a table behind it, and 2.8 checks, before committing, that `grafReader` counts the same rows as
the owner in every `graph` table and view it reads.

A second tenant is a later migration repeating 2.2-2.5 with `iop`, `iop_hermes_agent` and tenant 4.
One template, so that adding a tenant is mechanical.

## Decisions needed

1. ~~Hosting~~: one `t4g.small` per tenant (2026-10-12).
2. ~~Database enforcement~~: row-level security on `graph`, `security_invoker` on its views, and
   tenant views in the tenant's own schema (2026-10-12; `prs` and `iop` per the user, after the
   production check above).
3. ~~`pfn_mcp_reader`~~: dropped in 044 (2026-10-12).
4. ~~`PROCESS_HEATER`~~: rewritten generically by migration 045 (applied on dev 2026-10-12).
5. ~~Views in `prs`~~: accepted 2026-10-12. The `prs` and `iop` functions are due for a revisit
   anyway, and their `p_tenant_id` parameters are redundant in a schema that is already one
   tenant's. Rule: a tenant schema on a role's `search_path` makes that role tenant-scoped.
6. Role names: `<tenant schema>_hermes_agent` (2026-10-12). `agenticpg` is pgAgent's role and
   outside this design.
