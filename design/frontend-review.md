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
| `d2c755f` | 063 and 064 on production; this file |
| `212a467` | review round 1: sticky toolbar, collapsible left panel, channel picker, access log; the minute-data check (`minutes_kept`) and migration 065 |
| `c0d088b` | 065 on production |

The commit after `c0d088b` holds the Aggregate widget (§6, "built"): `api/aggregate.py`,
`plant/aggregate.py`, `design/aggregate-v1.schema.json`, `p95` in `plant/readings.py` and
`design/readings-v1.schema.json`, `web/src/widgets/Value.tsx`, the generated types, the dev test
`test_aggregate`, and the docs. Every check in §3 passed on it.

The commit after that holds the Stat widget (§6), `web/src/widgets/Stat.tsx`, and figures at 2 decimals
everywhere (`fmt` in `web/src/widgets/common.tsx`, tested in `common.test.ts`). `web_check` adds a
Stat to its dashboard. Frontend only: no API, format or migration change.

**Database.** Migrations 059–065 are on dev and production. 063 (row-level security on `frontend`)
and 064 (`frontend.starred_node`) went to production on 2026-10-27; backup first,
`logs/prod/frontend_backup_pre063.20261027-113611.dump`. Their checks passed there, and as
`grafReader` production shows the tenant row and no accounts or stars. 065 (the minute-data check
in `graph.device_totals_minute`) went the same day; backup first,
`logs/prod/graph_backup_pre065.20261027-124011.dump`.

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

Close the tunnel afterwards: `kill $(lsof -nP -tiTCP:15432 -sTCP:LISTEN)`. If the API logs
`connection to server at "127.0.0.1", port 15432 failed: ... Connection refused` at start-up, the
tunnel is down: open it again. The API logs one line per request (`o-mcp-api.access`: method, path
and query, status, milliseconds, user, site).

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
- **`.env.prod`** (production's write credentials for a migration) was deleted after 065. Create it
  for a migration only, and delete it after.
- **Dev's minute data** (`tools/dev_refresh.sh --raw`) holds the solver's quantities only, so on dev
  a short window of voltage or current has no readings; production keeps every quantity.

## 3. The checks

Run them against dev after any change. Each passed on 2026-10-27 with the Aggregate widget
(§1): 47 unit tests, 33 API tests against dev, 22 vitest tests, the MCP server's tests
against dev, and `web_check`. With the Stat widget: 25 vitest tests, the build, and `web_check`
(the API and `plant/` didn't change).

```bash
uvx ruff check .
uv run pytest                                                   # unit tests, server and api
O_API_TEST_ENV=.env.api-dev uv run pytest api/tests             # the API against dev (3–8 min, API stopped)
cd web && npx tsc -b && npm test && npm run build               # types, vitest (25 tests), build
uv run --with playwright python tools/web_check.py --env-file .env.api-dev   # API on .env.api-dev and Vite running
O_MCP_TEST_ENV=.env O_MCP_TEST_WINDOW=2026-10-20:2026-10-22 O_MCP_TENANT=3 O_MCP_TZ=Asia/Jakarta uv run pytest server/tests   # after a change in plant/
```

- **`web_check`'s browser.** If Playwright asks for `playwright install`, point it at a browser
  already downloaded: `--chromium ~/Library/Caches/ms-playwright/chromium_headless_shell-1234/chrome-headless-shell-mac-arm64/chrome-headless-shell`.
- **The dev tests' accounts** are named per test (`boss7`, `gus`...) and must be unique across the
  file: a name used twice fails the second test with 409 when the whole file runs, though each
  passes alone.

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
| widgets | `web/src/widgets/`: one file each (Value, shown as Aggregate; Stat, Readings, Now, Finder, Section, Meters, Sankey, Diagnostics); `registry.ts` (minimum sizes, settings); `common.tsx` (`fmt`, pickers, the chart host); `sld.ts` |
| time | `web/src/time/`: `range.ts` (parsing, resolution), `TimePicker.tsx` |
| data | `web/src/api/`: `client.ts`, `hooks.ts` (TanStack Query keys per site), `types.ts`; `web/src/types/formats/` generated |
| accounts | `web/src/admin/AccountsPage.tsx`, `web/src/auth/LoginPage.tsx` |
| templates | `web/src/templates/tenant-3-energy.json`, the only one so far |
| API | `api/app.py` (routes, sessions, dashboards, stars, the access log), `api/reads.py` (plant reads, 30 s cache), `api/values.py` and `api/aggregate.py` (the Value and Aggregate reads), `api/tenants.py` (a pool per site), `plant/` (queries shared with the MCP server) |

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
| 2026-10-27 | dashboard | the toolbar (title, range, edit, save) scrolls away below a tall canvas | sticky at the top of `main` | `styles.css` `.toolbar` |
| 2026-10-27 | frame | the left panel can't be hidden | « in its tab row collapses it to a 28 px strip, » brings it back; remembered per browser (`localStorage`) | `Frame.tsx`, `LeftPanel.tsx` |
| 2026-10-27 | channels | how does the left panel fill channels B–D? | it can't: a click always sets A. B–D are set from a widget on that channel (Finder, Section). Decided: a picker (A–D) at the top of the panel, not saved with the dashboard | `LeftPanel.tsx` |
| 2026-10-27 | logging | what do the API and Vite log? | API: stderr, INFO and up, start-up lines and the traceback of any unhandled error; no access log, no timings. Account events in `frontend.audit`. Frontend: nothing beyond Vite's dev output; a widget's error shows in the widget only. Decided: an access log; client errors to the API not yet | `api/app.py` `AccessLog` |
| 2026-10-27 | readings | Readings times out (20 s) on "Last 1 hour" | the API's check for minute data, `min(timestamp)` on `telemetry_data`, is a full scan of every chunk through `prs.telemetry_data` (security_barrier): ~74 M rows, still running at 25 s as `prs_frontend` on production. `graph.device_totals_minute` (060) has the same check, so short Value windows would fail next. Both now ask "is there a reading at or before the start", 0.05 ms on production | `api/values.py` `minutes_kept`; migration 065 (dev and production 2026-10-27) |
| 2026-10-27 | value | what is the Value widget for, and why only 10 quantities? | one quantity per node over the range, solved on the graph; the quantities are those with a solver rule (`graph.quantity_rule`) | — |
| 2026-10-27 | value | what does 1.57 % THD_VOLTAGE_LN at `INCOMING_PLN`, measured, mean? | the 95th percentile of the meter's L-N voltage THD over the range: of 1-minute readings up to 6 hours, of 15-minute snapshots (each bucket's last reading) beyond. The widget doesn't say so | §1, 21 |
| 2026-10-27 | value | rename to Aggregate, with min, max and P95 for instantaneous values | decided: one quantity across several nodes; counters a total through the solver, sampled quantities minimum, average, 95th percentile and maximum per meter; 1-minute data up to 6 hours, 15-minute beyond, said in words; encoded power factor out; unmetered nodes left out for sampled quantities. Then: unmetered counters keep the solved total, `PF_TRUE` one figure, counters without a rule out, nodes by hand or channel, a year at most | `design/frontend.md` §1, 21 and §5 "Aggregate" |
| 2026-10-27 | value | built | `/api/aggregate`, `o-mcp/aggregate` v1, the widget shown as Aggregate (type still `value`). A channel's node comes first, before the chosen nodes. The quantity picker is grouped, its sampled quantities narrowed to what the chosen nodes' meters reported in the last week. Found on the way: `telemetry_15min_agg` keeps each bucket's last reading, not its mean, which `o-mcp/readings`' descriptions had wrong (corrected, text only); dev's minute copy holds the solver's quantities only, so a short window of voltage has no readings on dev | `api/aggregate.py`, `plant/aggregate.py`, `web/src/widgets/Value.tsx` |
| 2026-10-27 | value | a channel's node, and the encoded power factor registers, in Aggregate | not answered; built with the defaults: the channel's node is the first row (a dot marks it), before the chosen nodes; `PF_TOTAL`, `PF_A`..`C` and `DPF_*` stay out, though readings already decodes them to a magnitude (0..1, lead or lag lost), so they could come back as "power factor (magnitude)" | open, §7 |
| 2026-10-27 | stat | a Stat widget: one metered node, one quantity, as Grafana's, with a small line inside | built: the figure is Aggregate's (`/api/aggregate`): a counter's total, or one meter's last, average, minimum, P95 or maximum (default last); a node with several meters picks one; the line is Readings' at the automatic interval, a counter's summed over the node's meters, and can be turned off; quantities as Aggregate's. Checked on dev: `LVMDB_A5`'s energy over 2 hours of minute data, `LVMDB_A4`'s `VOLTAGE_AN` P95 and last over 2 days, both meters | `design/frontend.md` §1, 22 and §5 "Stat"; `web/src/widgets/Stat.tsx` |
| 2026-10-27 | figures | the Value widget's numbers aren't formatted | `fmt` showed up to 1 decimal under 100 and none above, and widgets asked for 0 or 3. Decided: 2 decimals, thousands separated, everywhere, including the Readings tooltip and the Sankey's tooltip and share of supply. `sld.ts` keeps `tools/sld.py`'s six significant digits (the parity test) | `design/frontend.md` §1, 23; `web/src/widgets/common.tsx` |
| 2026-10-27 | dashboard | editing a widget means finding Edit in the toolbar first | each widget's header shows an Edit on hover (always on touch screens), which puts the whole dashboard in edit mode, as the toolbar's does; not on a read-only dashboard. `web_check` enters edit mode through it | `WidgetFrame.tsx`, `styles.css` |

## 7. Open questions

- **Client errors.** Should a widget's error be posted to the API and logged there?
- **Stat:**
  - Thresholds and colours (Grafana colours the figure by threshold): wanted?
  - On a node whose measurement rows weight a meter (`LVMDB_A4`), a counter's line is the raw
    registers' sum, so its area isn't the figure. Draw the line from the solver per interval instead?
  - Small figures (THD, power factor) at 2 decimals lose precision: a per-widget decimals setting?
- **Aggregate:**
  - Confirm the defaults: the channel's node first, before the chosen nodes; the encoded power
    factor registers out, or back as a magnitude?
  - Not yet seen on production's data. A year of 15-minute data across many nodes is untimed (dev
    holds about two days); the statement timeout is 20 s.
  - The Totals group isn't narrowed by utility: a water total is offered for an electrical board.
  - No MCP tool for it yet; `plant/aggregate.py` is where one would start.
- **A dev test that failed once.** `test_accounts_sessions_and_tenants` failed once in a full run
  (2026-10-27, morning) and has passed since, alone and in every full run; the cause wasn't found.
