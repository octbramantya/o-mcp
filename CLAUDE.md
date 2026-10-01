# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Ontology (node/edge types, properties) and topology (`graph.node` / `graph.edge`) for tenant 3 of the **valkyrie** Postgres database, plus the future MCP server over them. @README.md is the map of files and the current model state — read it before anything else.

## Where things live

- Graph migrations live in `migrations/`. `001–007`, `014`, `015` and `022` stayed in `../prs_diags/docs/database/migrations/`, and numbering is one sequence across both folders: a new migration takes the next number after the highest in either.
- Rewrite only comments in an applied migration, never its SQL: the file is the record of what ran, and `tools/migrate.sh status` flags hash changes.
- Migration 030 is rendered by `tools/gen_030.py` from `design/draft_load_types.csv`. Edit the CSV and regenerate; never hand-edit the `.sql`. Same discipline for any future generated migration.
- Never edit an already-applied migration to fix a value; write a new migration.
- `tools/validate_brick.py <Brick.ttl> <label>` checks Brick class names against a Brick release (needs `rdflib`). Its hardcoded list is `node_type.external_ref` as of 030; once 031 is applied it should read `graph.vocabulary_alignment` instead. Use the versioned URL (`/schema/1.4/Brick.ttl`); the unversioned one lags. Verdicts must come from the parsed TTL, not recall.

## Database rules

- Always filter the effective window, not just `is_active` (it over-reports and has caused wrong findings):
  `is_active AND effective_from <= CURRENT_DATE AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)`
- `effective_to = <date>` = the plant changed then (past reports stay valid). `effective_to = '-infinity'` = never true (wrong SLD; past reports retroactively wrong). An SLD redraw request is `'-infinity'`, not a date. `DELETE` only when the wrong belief has no evidential value.
- A property is REQUIRED only if a real reader needs it (named in `used_by`).
- Rebuild dev with `tools/dev_refresh.sh` before testing a migration (add `--telemetry FROM TO` when it touches the solver).
- Run migrations only through `tools/migrate.sh` (one at a time, in order, recorded in `graph.schema_migration`). `.env` is the dev database; production is a per-session `.env.prod`. Never copy dev data to production: promotion means replaying the same files.
- No credential fallbacks or defaults in code (`os.getenv(..., '<literal>')` fails open).
- **Ask before** applying anything to any database, even dev, and before editing files in `../prs_diags`. No standing permissions: the user grants access as needed.

## MCP server design (decided)

- Expose the plant, not the schema.
- Ontology vocabulary becomes JSON Schema enums at tool registration; resolution and endpoint validation happen server-side at invocation (never the model's job); a browsable resource is a fallback, not a prerequisite.
- Every topology tool takes a required `as_of` (default `CURRENT_DATE`); the effective-window filter lives inside the server.

## Lint

`uvx ruff check .` (config in `pyproject.toml`; ruff isn't installed globally).
