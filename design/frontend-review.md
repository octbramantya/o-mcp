# Frontend review: handover

The handover between sessions for the review and redesign of `web/` slices 1–3 and the `api/` behind
them. Started 2026-10-27. `design/frontend.md` still holds the design: what is decided (§1) and what
each slice built (§5, §10). This file holds where the work stands, how the review is run, and the
questions and answers as they come. When an answer becomes a decision, it goes into
`design/frontend.md` §1 and is noted in the log below.

## 1. Where things stand (2026-10-27)

**Code**, on branch `frontend`, pushed to `origin/frontend`:

| commit | what |
|---|---|
| `beb8490`, `3c9308e` | `api/` slices 4 and 5: dashboards, then the plant reads on the MCP tools' queries, moved into `plant/` |
| `3f22a55` | `web/` slice 1: the frame, dashboards, canvas and seven widgets |
| `419defc` | `web/` slice 2: accounts, data health, the Now widget, `tools/web_check.py` |
| `83e5de0` | `web/` slice 3: starred nodes, the category tree, the drawn single-line diagram, export and import |

Not committed yet: `README.md` and `design/frontend.md` recording 063 and 064 on production, and
this file.

**Database.** Migrations 059–064 are on dev and production. 063 (row-level security on `frontend`)
and 064 (`frontend.starred_node`) went to production on 2026-10-27; backup first,
`logs/prod/frontend_backup_pre063.20261027-113611.dump`. Their checks passed there, and as
`grafReader` production shows the tenant row and no accounts or stars.

**Production roles.** The user gave `frontend_api` and `prs_frontend` LOGIN and passwords on the
production host, by hand, and created the first super admin there with
`python -m api --env-file .env.api create-super-admin`. Production's `frontend` schema now holds real
accounts: anything done in the frontend during the review (dashboards, stars, accounts, password
changes) is production data, audited.

## 2. How the review runs

The API and Vite run locally; the API reads **production** through the tunnel.

```bash
ssh -f -N -o ExitOnForwardFailure=yes -L 15432:localhost:5432 ec2-ssm   # the tunnel
uv run python -m api --env-file .env.api serve                            # terminal 1
cd web && npm run dev                                                      # terminal 2, http://localhost:5173/
```

Close the tunnel afterwards: `kill $(lsof -nP -tiTCP:15432 -sTCP:LISTEN)`.

| file | targets | used by |
|---|---|---|
| `.env.api` | production (`DB_LABEL=prod`, `localhost:15432`), `frontend_api` and `prs_frontend` only, no superuser | the API during the review |
| `.env.api-dev` | dev, plus dev's superuser | `api/tests` (`O_API_TEST_ENV=.env.api-dev`) and `tools/web_check.py --env-file .env.api-dev` |
| `.env` | dev | `tools/migrate.sh`, `tools/sld.py`, the MCP server |

- **TLS.** Outside dev, `server/config.py`'s `tls()` refuses `DB_SSLMODE=require`, so `.env.api`
  uses `verify-ca` with `DB_SSLROOTCERT` naming production Postgres's self-signed certificate,
  pinned outside the repository. `verify-full` can't work through the tunnel, because the host
  name is `localhost`. If the host's certificate changes, the API fails at the handshake: pin
  the new one.
- **Guards.** `api/tests` and `web_check` exit on any `DB_LABEL` but `dev`, so they can't run
  against `.env.api`. Run all checks against dev, with the API on `.env.api-dev`.
- **Connection limits.** `frontend_api` has `CONNECTION LIMIT 4`: the API's pool takes three, and
  one is left for `create-super-admin`. `prs_frontend` has 6. Stop the API before a second
  instance or the API tests.
- **Minute data.** Production keeps `telemetry_data` for 14 days. A range of 6 hours or less
  that is older than that reads 15-minute data, without saying so (§1, 9).
- **Today's daily figures** lag the 15-minute data by up to 45 minutes. `DATA_INCOMPLETE` says so
  (`design/frontend.md` §10).
- **`.env.prod`** holds production's write credentials from the migration. Delete it if it still
  exists.

## 3. The checks

Run them against dev after any change. Each passed at `83e5de0`.

```bash
uvx ruff check .
uv run pytest                                                   # unit tests, server and api
O_API_TEST_ENV=.env.api-dev uv run pytest api/tests             # the API against dev (~3 min, API stopped)
cd web && npx tsc -b && npm test && npm run build               # types, vitest (22 tests), build
uv run --with playwright python tools/web_check.py --env-file .env.api-dev   # API on .env.api-dev and Vite running
```

- **The single-line diagram.** `web/src/widgets/sld.ts` is `tools/sld.py` ported line for line.
  `sld.test.ts` renders the ten documents in `web/src/widgets/sld-fixtures/` with both and
  requires identical SVG; it needs `uv`. If the redesign changes the drawing, decide first
  whether `tools/sld.py` changes with it, or whether the parity test retires.
- **The data formats.** The formats are the widgets' contracts. After changing a
  `design/*-v1.schema.json`, run `npm run types`. A change within version 1 must stay
  backward-compatible (`design/subgraph-format.md`).
- **The dashboard document.** `design/dashboard-v1.schema.json` is checked by the API on every
  save. Saved dashboards on production now depend on it, so a redesign that changes it needs a
  version, or a migration of the saved documents.

## 4. Map of the frontend

| area | files |
|---|---|
| frame | `web/src/frame/Frame.tsx` (top bar, site switch), `LeftPanel.tsx` (Find, Categories, Starred), `DataHealth.tsx` (bottom bar) |
| dashboards | `web/src/dashboards/`: `ListPage`, `DashboardPage` (edit, save, discard, export), `Canvas` (24-column grid), `WidgetFrame`, `store.ts` (zustand), `document.ts` (format, channels A–D), `transfer.ts` (export and import) |
| widgets | `web/src/widgets/`: one file each (Value, Readings, Now, Finder, Section, Meters, Sankey, Diagnostics); `registry.ts` (minimum sizes, settings); `sld.ts` |
| time | `web/src/time/`: `range.ts` (parsing, resolution), `TimePicker.tsx` |
| data | `web/src/api/`: `client.ts`, `hooks.ts` (TanStack Query keys per site), `types.ts`; `web/src/types/formats/` generated |
| accounts | `web/src/admin/AccountsPage.tsx`, `web/src/auth/LoginPage.tsx` |
| templates | `web/src/templates/tenant-3-energy.json`, the only one so far |
| API | `api/app.py` (routes, sessions, dashboards, stars), `api/reads.py` (plant reads, 30 s cache), `api/tenants.py` (a pool per site), `plant/` (queries shared with the MCP server) |

## 5. Known gaps when the review started

These are already known; the review needn't rediscover them. Each is open unless the log says
otherwise.

- **Serving and deployment** (`design/frontend.md` §10):
  - Not yet decided how `web/dist` is served in production. It must be served from the API's origin, because the cookie is `SameSite=Strict`.
  - Behind a reverse proxy, the client's address must come from a trusted `X-Forwarded-For`.
  - The roles have no PgBouncer entries yet.
- **Data:**
  - The category tree and the sankey cover electricity only.
  - The sankey has no cost mode (062).
  - Whether the daily path also counts a flat register as 0 is still a proposal (§3).
- **Section widget:** the drawn diagram shows only what a node feeds. "Path to source" (direction up) is still the indented list.
- **Templates:** there is one, tenant 3's energy dashboard, and no other site has one.
- **Starred nodes:** stars are per account and site. A node that leaves the plant stays starred and is shown as "not in the plant today".
- **Export and import:** only within the same site.

## 6. Review log

Add each question, its answer, and what changed (a commit, or a line in `design/frontend.md` §1),
newest last. Keep open questions in §7 until they are answered.

| date | topic | question or finding | answer or decision | change |
|---|---|---|---|---|
| 2026-10-27 | setup | review against production's data | `.env.api` on production through the tunnel; checks stay on dev | 063, 064 on production; this file |

## 7. Open questions

(none yet)
