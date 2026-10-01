# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Ontology (node/edge types, properties) and topology (`graph.node` / `graph.edge`) for tenant 3 of the **valkyrie** Postgres database, plus the future MCP server over them. @README.md is the map of files and the current model state — read it before anything else.

## Where things live

- Applied migrations are **not** here: they are in `../prs_diags/docs/database/migrations/` (`001…030`). New graph migrations (031+) are designed here but written into that folder — one numbered sequence, never split.
- Migration 030 is rendered by `tools/gen_030.py` from `design/draft_load_types.csv`. Edit the CSV and regenerate; never hand-edit the `.sql`. Same discipline for any future generated migration.
- Never edit an already-applied migration to fix a value; write a new migration.
- `tools/validate_brick.py <Brick.ttl> <label>` checks `node_type.external_ref` against a Brick release (needs `rdflib`). Use the versioned URL (`/schema/1.4/Brick.ttl`); the unversioned one lags. Verdicts must come from the parsed TTL, not recall.

## Database rules

- Always filter the effective window, not just `is_active` (it over-reports and has caused wrong findings):
  `is_active AND effective_from <= CURRENT_DATE AND (effective_to IS NULL OR effective_to >= CURRENT_DATE)`
- `effective_to = <date>` = the plant changed then (past reports stay valid). `effective_to = '-infinity'` = never true (wrong SLD; past reports retroactively wrong). An SLD redraw request is `'-infinity'`, not a date. `DELETE` only when the wrong belief has no evidential value.
- A property is REQUIRED only if a real reader needs it (named in `used_by`).
- Access: SSH tunnel `ssh -f -N -o ExitOnForwardFailure=yes -L 15432:localhost:5432 ec2-ssm`; credentials from gitignored `.env` via a `db.py` helper. No credential fallbacks/defaults in code (`os.getenv(..., '<literal>')` fails open).
- Default role is read-only (`grafReader`). **Ask before** executing anything that writes to the database, and before editing files in `../prs_diags`.

## MCP server design (decided)

- Expose the plant, not the schema.
- Ontology vocabulary becomes JSON Schema enums at tool registration; resolution and endpoint validation happen server-side at invocation (never the model's job); a browsable resource is a fallback, not a prerequisite.
- Every topology tool takes a required `as_of` (default `CURRENT_DATE`); the effective-window filter lives inside the server.

## Lint

`uvx ruff check .` (config in `pyproject.toml`; ruff isn't installed globally).
