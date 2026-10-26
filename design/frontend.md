# Custom frontend

A web frontend for the plant, replacing Grafana in the long run. Grafana stays for quick
visualisation; the custom frontend is where users build their own dashboards. Written
2026-10-22. §1 holds what is decided, the rest is proposed. Its shell (frame, canvas, widget
registry, layouts, channels) follows a reference study kept locally in `design/sb-dashboard/`
(gitignored).

This repository becomes a monorepo holding the MCP server and the frontend (§9).

## 1. Decided (2026-10-22)

| # | decision | from Grafana |
|---|---|---|
| 1 | **One time range per dashboard.** Every widget follows it. The plant is analysed over windows (a shift, a day, September), not at "now" | the dashboard time picker |
| 2 | **Refresh is a dashboard setting, off by default.** When off, a dashboard shows its time range and nothing polls. The shortest interval is 30 s | the `Refresh` picker; `min_refresh_interval` in grafana.ini |
| 3 | **Snapping tiles** on a 24-column grid (§4), not free-floating windows. Widgets keep a minimum width and height | the dashboard grid |
| 4 | **Each tenant is isolated by Postgres**, as for the agents (`design/mcp-tenancy.md` §4) | organizations |
| 5 | **Every user belongs to one tenant.** Internal users are in an **admin group**, which sees every tenant | replaces user–organization mapping |
| 6 | **The top bar always shows the current tenant.** Admins switch tenants there; everyone else sees their own, fixed | the organization switcher |
| 7 | **An admin reads a tenant through that tenant's own database role**, as its users do | — |
| 8 | **Both kinds of user are served**: operators watching in near real time (tenant 4 has two dashboards that refresh), and engineers reading long windows | — |
| 9 | **Raw or aggregate by range length**: a range of 6 hours or less reads `telemetry_data`, a longer one `telemetry_15min_agg`. A short range older than the minute data kept (14 days) reads 15-minute data instead, without telling the user no (§3) | as tenant 3's and 4's Grafana dashboards do |
| 10 | **The database is reached through a pool**, never one connection per widget, dashboard or user. The frontend has its own role per tenant, separate from the agent's | Grafana's data source pool |
| 11 | **One shared API for every tenant**, with a pool per tenant role | — |
| 12 | **Dashboards belong to the user who made them.** No other user can open them (admins can, §1, 17); no per-dashboard permissions | — |
| 13 | **New dashboards start from a static template or a blank canvas.** A template copied is the user's own to change | — |
| 14 | **Users and dashboards live in the same database, in their own schema** (`frontend`) | Grafana's own database |
| 15 | **Email and password log-in**, no SSO | — |
| 16 | **A super admin creates accounts, resets passwords and assigns tenants.** Nobody signs up | Grafana's server admin |
| 17 | **An admin can open a user's dashboard** and start from it, instead of rebuilding it | — |
| 18 | **The solver gets a minute-data path**, and the MCP server reads `telemetry_data` too | — |
| 19 | **Saved dashboards store a node's id and show its code.** The id (`graph.node.id`, the primary key) never changes; the code can | a variable's `__value` and `__text` |
| 20 | **`as_of` over a range: value widgets split the range at plant changes (C), topology widgets draw the plant on the range's last day (A)** (§3) | — |

Why 30 s: telemetry is polled every minute, and refreshing every 30 s catches data that arrives
late without querying faster than data can change.

Later, as Grafana does: exporting a dashboard as JSON and importing it, the only way a dashboard
passes between users.

## 2. Users, tenants and the admin group

- Three roles: **user** (one tenant), **admin** (every tenant, switches in the top bar) and
  **super admin** (an admin who also manages accounts). A user record holds an email, a password
  hash, its role, and a tenant if and only if it is a user.
- **A non-admin's tenant comes from their session only**; no request parameter can change it, and
  a request naming another tenant is refused, not filtered.
- An admin's current tenant is a session value too, set by the top bar's switcher. Switching
  reloads the dashboard list and every open widget for the new tenant.
- An admin reads a tenant through that tenant's role (§1, 7). There is no cross-tenant role and
  no dashboard spanning tenants: an admin sees what the tenant's users see, and Postgres still
  enforces it.
- Every tenant switch is logged with the user and both tenants.

**Log-in.** Email and password, no SSO. The API stores an Argon2id hash, never the password,
limits failed attempts per email and per address, and keeps the session in an `HttpOnly`,
`Secure`, `SameSite` cookie. Nobody signs up: a super admin creates each account, assigns its
tenant, and resets passwords (§1, 16). A reset sets a temporary password that must be changed at
the next log-in, and ends the user's open sessions. Every account change goes to the audit table.

**Opening a user's dashboard (§1, 17).** An admin can list and open the dashboards of the current
tenant's users, read-only. To work on one, the admin copies it into their own dashboards; the
user's original is never changed by anyone but its owner. Each open is audited.

## 3. Time and refresh

**Time range.** A dashboard stores its default range, absolute (`2026-09-01` to `2026-10-01`) or
relative (`last 30 min`, `last 24 h`, `today`). The picker sits on the dashboard's own toolbar,
beside the refresh picker, not in the global top bar, which is about who and where the user is.
Relative ranges resolve in the tenant's time zone (as `O_MCP_TZ` does for the MCP server); windows
are half-open, as the MCP tools have them. A per-widget override, as Grafana's panel "relative
time", can come later.

**Raw or aggregate (§1, 9).** The API picks the table from the range, never the widget: 6 hours or
less reads the minute data in `telemetry_data`, longer reads `telemetry_15min_agg`. Production
keeps `telemetry_data` for 14 days (a TimescaleDB retention policy; read 2026-10-22), so a short
range older than that falls back to 15-minute data:

| range | starts | reads | `graph.resolution` |
|---|---|---|---|
| ≤ 6 h | within the minute data kept | minutes | `minute` |
| ≤ 6 h | older | 15-minute buckets, electricity energy too | `15min` |
| > 6 h | any | 15-minute buckets, or the daily summary for whole days | unset |
 A short range
is where a user compares several quantities over, say, the last 30 minutes to see whether
something went wrong in that span, so it needs every minute. The widget shows which resolution
it drew.

**The solver on minute data (§1, 18).** Today the solver (`node_value`, the Sankey) reads the
15-minute aggregate and daily summaries, so a node without its own meter would have no minute
values. It gains a minute-data path for short ranges, and the MCP server reads `telemetry_data`
as well. That needs a tenant view of `telemetry_data` in each tenant's schema, granted to the
tenant roles, as 044 did for the other shared tables. `telemetry_data` is the largest table, so
the 6-hour limit applies to every reader, the agent included.

Decided: **a minute counterpart of `graph.device_totals`**, not the solver reading
`telemetry_data` itself. `graph.device_totals_minute` returns the same
`(device_id, quantity_id, total)`, so `solve_flow`, `graph.sankey` and the `get_node_*` functions
change resolution without being edited. **Built as migration 060** (on dev 2026-10-22), with
`prs.telemetry_data`.

- **The caller asks for minutes**, with `SET LOCAL graph.resolution = 'minute'` in its
  transaction; `device_totals` then hands every call to the minute function. It can't route by
  window length, as first proposed here: its callers pass bounds whose meaning depends on the
  source (`node_value` reads one site day of the daily summary as `p_start = p_end`). Unset,
  nothing changes for Grafana, the agent or `node_value`. `SET LOCAL` ends with the transaction,
  so it is safe under PgBouncer's transaction pooling.
- **The 6-hour rule is enforced in one place**: `device_totals_minute` refuses a longer window,
  for every caller. It also refuses a window that starts before the tenant's oldest minute
  reading. Nobody should see that error, since the API falls back to `15min` first; it is there
  so that a wrong cutoff fails loudly instead of the solver showing every node empty.
- **15-minute electricity energy** (`graph.device_totals_15min`, also 060). Without a switch,
  electricity energy comes from the daily summary, which can't answer a window shorter than a day.
  With `15min` it is summed from the same 15-minute intervals the summary is built from. On dev,
  production's 2026-10-21 summed this way matches the summary for every device that consumed (358
  device registers, 174 of them flat). Bounds are naive UTC, `p_end` the last minute included (`[10:00, 10:30)` is
  10:00 to 10:29), as the 15-minute path's last bucket.
- **Cleaning.** Electricity energy otherwise comes from `daily_energy_cost_summary`, which can't
  answer a 30-minute window. The minute path sums forward differences of the register, with 15
  minutes of lookback, cleaned by the rules of the view the coarse path reads: electricity as
  `public.telemetry_intervals_cumulative` (what the daily summary sums), water as
  `public.telemetry_intervals_water`, air by 017's guards. Those views are built on the
  15-minute aggregate, so 060 restates their rules once, in `graph.register_step`, which both
  the minute and the 15-minute function use; the comparisons below keep it in step with the views.
- Cost exists only in the daily summary: `p_is_cost` on minutes is refused, not estimated. The
  shift filter doesn't apply.
- The 999,999 ceiling is per interval, so per minute it is looser than per 15 minutes.
- 060 computes one site day both ways, per device and register, and lists where they disagree by
  more than 1%. A disagreement is a finding, not something to tune away. On dev with production's
  2026-10-21 (`tools/dev_refresh.sh --raw`): 458 device registers, none differing on a non-zero
  amount, 174 flat.
- **A flat register is 0** (decided 2026-10-22). A device that reports all window while its
  register doesn't move totals 0 on minutes, as on 017's 15-minute branch, so a stopped machine reads
  as measured zero. The daily summary leaves such device-days out (it has no zero rows), so over
  whole days the same device looks unmeasured and the solver may work its node out from the
  neighbours: a node can read MEASURED 0 over the last 30 minutes and ROLLUP over the day.
  Proposed, not built: the daily branch of `device_totals` counts a device that reported but
  consumed nothing as 0, in its own migration with a before/after of the Sankey and `node_value`.
- Dev's `telemetry_data` has no indexes (no TimescaleDB on dev). Read production's hypertable
  indexes before timing anything.

**`as_of` across a range (§1, 20).** `graph.solve_flow` takes one `p_as_of` and solves the whole
window against the graph in effect that day (`migrations/051_solver_passthrough_split.sql`). The
two callers disagree on the default: `graph.sankey` uses the window's last day, `node_value`
today. A range can span a change in the plant, though rarely: on 2026-10-22 tenant 3's graph had
two dated changes in all, 2026-05-12 (`LVMDB_TEXTURE`'s edges end after 2026-05-11) and
2026-09-28 (`MC302_BARU` and `MC303_BARU` retired). Documentation corrections (`'-infinity'`) are not changes: they were never
true, so they apply to every range.

| option | how | for |
|---|---|---|
| A. End of range | one graph, the one in effect on the range's last day (`graph.sankey`'s default) | simple; wrong only for the part of the range before a change, where a retired meter's readings drop out |
| B. Today | `node_value`'s default | not recommended: past ranges drawn on today's plant |
| C. Split at changes | cut the range at its change dates, solve each piece on its own graph, combine by each quantity's rule (energy adds, means weighted by duration, maxima take the max) | exact; usually one piece, so no extra cost |
| D. A separate picker | a dashboard "plant as of" setting beside the time range, defaulting to A or C | an override few would use |

Decided: **C for value widgets, A for topology widgets** (a diagram can't add two graphs), with a
marker on the widget when the range spans a change ("plant changed on 2026-09-28"). B and D are
not needed now.

**Where C cuts: `graph.change_dates(tenant, start, end)`** (migration 059, on dev 2026-10-22). It
returns the days inside the range on
which the graph in effect changes. A dated `effective_from` is a change on that day; a dated
`effective_to` is a change on the day after, since `effective_to` is the last day in service.
It reads the rows that decide what the solver sees: `graph.node`, `graph.edge` and
`graph.measurement`, plus `node_category` for the Sankey. `'-infinity'` rows are not changes:
they were never true, so they apply to the whole range.

For September (2026-09-01 to 2026-10-01) it returns 2026-09-28, the day after `MC302_BARU` and
`MC303_BARU`'s last day, and the value is solved in two pieces: 09-01 to 09-28 against the graph of
09-27, and 09-28 to 10-01 against the graph of 09-30. A range with no change inside it, nearly
every range, gets one solve, as today.

It is a database function, not API code, because `node_value` needs the same cuts: the agent and
the frontend must not disagree on a window. **`node_value` splits on it** (2026-10-22): it no
longer takes `as_of`, looks nodes up on the network of the window's days (latest first, so a node
retired inside the window is still found), and reports the pieces in `query.pieces` with a
`PLANT_CHANGED` finding, both added to `o-mcp/values` within version 1. On dev, September solved in
two pieces matches the single solve at every node except `MC302_BARU` and `MC303_BARU`, which get 0
instead of nothing.

Pieces combine by the quantity's `raw_time_agg` (dev, 2026-10-22):

| rule | quantities | combined |
|---|---|---|
| `DELTA` | active, reactive and apparent energy, water, air | the pieces add |
| `AVG` | `PF_TOTAL` | not needed: `node_value` refuses it, and `PF_TRUE` is computed from the combined energies |
| `P95` | `THD_VOLTAGE_LN` | **falls back to A**: a range's 95th percentile can't be rebuilt from its pieces'. The whole range is solved on the last day's graph, with the change marker |

A new rule added to `graph.quantity_rule` must say how it combines before C uses it; until then it
falls back to A, like `P95`.

**Refresh.** Off by default; 30 s, 1 min, 5 min… when on. Widgets poll with the dashboard's
interval (TanStack Query's `refetchInterval`), and polling pauses while the browser tab is
hidden. **The 30 s minimum is enforced by the server, not the UI** (§6): a browser can ask for
anything.

**Window limits.** The MCP tools cap windows for a model's sake (`meter_readings` 31 days and 500
points, `node_value` 92 days). Engineers will want a year. The frontend's API sets its own
limits, and coarser intervals (day, month) instead of more points.

## 4. Canvas

react-grid-layout with vertical compaction and no overlap, on Grafana's grid: **24 columns**,
each a 24th of the dashboard's width, and rows of a fixed height. A widget's position and size
are whole columns and rows (`x`, `y`, `w`, `h`), as a Grafana panel's `gridPos`. Widths follow the
screen, so a dashboard fills a wide monitor and narrows on a laptop; heights stay fixed. A Grafana
panel's `gridPos` copies over unchanged.

Minimum sizes come from the widget registry when the dashboard is drawn, not from the saved
document, so a corrected minimum reaches old dashboards. Below a set width the dashboard stacks
its widgets in one column instead of squeezing them.

## 5. What widgets show

Each engineer builds the dashboard for their own work: one around the compressors' nodes and
their current and power factor, another around the key production nodes and their energy. So
widgets are general (a node, its quantities, the range), and the user's choice of nodes and
quantities is the widget's own settings.

Entities a user selects:

| entity | identifier | notes |
|---|---|---|
| node | see below | the main entity. Most widgets take one or more nodes |
| device (meter) | `public.devices` id | reached from a node through `node_meters` |
| category | `graph` category code | Production / Utilities and their children (`graph.sankey`) |

Quantities are a widget setting, not an entity.

**Channels** link widgets to one selected entity, and carry its kind as well as its id, so a
node widget ignores a device. The time range is not on the channel; it belongs to the
dashboard.

**A node's identity (§1, 19).** Codes change in place (047 swapped `WTP_1` and `WTP_2`'s codes), but
`graph.node.id` doesn't: it is the primary key, one row per node (dev, 2026-10-22: 190 rows, 190
ids, codes unique per tenant). A saved dashboard and a channel store the id; the frontend shows
the current code and name, looked up when drawn, as a Grafana variable keeps `__value` for queries
and `__text` for display. The user never sees an id. A node retired since the dashboard was saved
is still found by its id and shown as retired, not dropped. The same holds for devices
(`public.devices` id) and categories.

A first widget list, from what the MCP server and the database already answer:

| widget | shows | source |
|---|---|---|
| Single-line diagram | a node and what it feeds, `depth` levels; a click selects the node | `plant_section` (`tools/sld.sql`) |
| Path to source | what feeds a node, up to the incomer | `plant_section`, `direction: "up"` |
| Node finder | nodes by text, type, class, utility, metered | `plant_find` |
| Meters | the devices reading a node, what each reports, last reading, status | `node_meters` |
| Readings | several nodes' quantities over the range, on one chart or stacked | `meter_readings`, at the resolution of §3 |
| Value | one resolved quantity for one or more nodes over the range, with `origin` | `node_value` |
| Now | the last reading of a node's meters | `telemetry_data`, latest row per device |
| Sankey | where energy, water or air goes, by category | `graph.sankey` |
| Diagnostics | silent meters, negative residuals, missing required properties | `graph.sankey_diagnostics`, `graph.v_property_gaps` |

Diagnosed meter faults are shown, never hidden by the frontend. The analysis tools still to come
(power factor, harmonics, board loading; `design/mcp-catalogue.md` §2, layer 4) become widgets
once they are built.

The output formats (`design/*-v1.schema.json`) are the widgets' data contracts. The frontend
generates its TypeScript types from them, so a format change shows up as a type error.

**Frame.** The left panel holds ways to choose a node: the finder, the category tree, a starred
list. The bottom bar holds data health: the time of the latest telemetry, the number of silent
meters, refresh on or off, the tenant's clock.

## 6. Database connections

The browser never reaches Postgres. The frontend's API does, through the same layers as the MCP
server:

- **PgBouncer** on the database host, transaction mode, with a cap per role
  (`max_user_connections`);
- **a small pool per role in the API process** (`psycopg_pool`, as `server/db.py`);
- **limits on the role**: `CONNECTION LIMIT`, `statement_timeout`,
  `idle_in_transaction_session_timeout`; and one transaction per request, with `SET LOCAL`.

**A login role per tenant for the frontend**, separate from the agent's (`prs_hermes_agent`) but
under the same row-level security and tenant views. PgBouncer pools per role, so dashboards and
the agent cannot use up each other's connections, and each has its own limits. A further role
writes the `frontend` schema (§8); the tenant roles cannot reach it.

The cap bounds connections; it doesn't bound requests, which queue behind it. **The load is
viewers × widgets ÷ refresh interval**: ten operators on a 12-widget dashboard at 30 s is four
queries a second, and a cold solver call takes seconds. So the API, which open-source Grafana
does not do:

- **caches results** by tenant, query and window, for the shortest refresh interval (30 s). This
  is also what enforces the minimum: a faster refresh gets the cached answer;
- **rounds relative ranges to the minute**, so `last 24 h` from ten viewers is one cache key;
- **runs identical in-flight requests once** and gives every caller the answer;
- optionally takes **one request per dashboard refresh** instead of one per widget.

Users' own dashboards make identical requests rarer than on shared Grafana dashboards, so the
cache matters most where several people open the same template. The tenant 4 refresh
dashboards are the first load test.

## 7. The API

One API serves every tenant (§1, 11), with a pool per tenant role. Each request's pool is chosen
from the session's tenant (§2), and Postgres enforces the rest, so a bug in choosing the pool is
the one way across tenants. Tests pin it: a non-admin session asking for another tenant is
refused, and an admin's request runs as the selected tenant's role.

**Built so far (2026-10-26), on dev:** log-in, sessions, the tenant switch and the super admin's
accounts (`api/app.py`, `api/auth.py`), Starlette on a pool of `frontend_api`. JSON in and out;
everything that changes state is a POST with an `application/json` body, which with the
`SameSite=Strict` cookie keeps other sites out without a CSRF token.

| route | who | does |
|---|---|---|
| `POST /api/login` | anyone | email and password; sets the session cookie; returns what `/api/me` does |
| `POST /api/logout`, `GET /api/me`, `POST /api/password` | any session, also before a forced change | end the session; the account, current tenant and switchable tenants; change the password (ends the account's other sessions) |
| `POST /api/tenant` | any session | switch the session's tenant: a user may only name their own (403 otherwise), an admin any active one (audited) |
| `GET/POST /api/admin/users`, `POST /api/admin/users/{id}/reset-password`, `…/disable`, `…/enable`, `…/assign` | super admin | list and create accounts (a temporary password, shown once); reset, disable, enable; set role and tenant together. Never on their own account |

- A session lasts 12 hours, ends after 2 hours idle, and is checked against the account on every
  request; a reset, disable, or role or tenant change revokes it.
- Failed log-ins are counted from `frontend.audit`: 5 per email or 20 per address in 15 minutes
  lock further attempts out, right password or not. Locked-out tries are logged, not counted.
- An account with `must_change_password` reaches only `/api/me`, `/api/password` and `/api/logout`.
- An admin's session starts with no tenant; the frontend asks them to pick one.
- The first super admin comes from the command line (`python -m api create-super-admin`).

**Plant reads (2026-10-26), on dev.** A pool per active row of `frontend.tenant`, as its `db_role`
(`prs_frontend` for tenant 3), with the password from `O_API_TENANT_<id>_PASSWORD`
(`api/tenants.py`). The API refuses to start if a pool's `current_user` isn't that role or sees
another tenant's devices. `Tenants.for_session` is the one place a session becomes a pool: an
admin with no tenant chosen gets 409, and a user's session naming a tenant other than their own
gets 403. The plant read runs after the frontend transaction has closed, so a slow solve holds no
`frontend_api` connection.

`GET /api/values?quantity=&nodes=<ids>&start=&end=` (`api/values.py`): one quantity for up to 50
nodes by `graph.node.id`, over a site-time window of up to 92 days. The resolution is chosen as in
§3: whole site days read as before; a window of 6 hours or less starting within the minute data
reads minutes; anything else reads 15-minute buckets, electricity energy included. The window is
snapped outwards to its resolution. The answer carries `resolution`, the snapped `window`, the
`pieces` it was solved in, and per node the value, origin and parts, with the findings
`NOT_IN_NETWORK`, `NO_VALUE` and `PLANT_CHANGED` as `node_value` has them. It also names the
`source` the solve read and its `data_until`: the last minute or bucket inside the window, for the
whole tenant, or for the daily summary the earlier of its last day's end and that day's
`last_refreshed` (a cron job fills it). Short of the window's end the answer carries
`DATA_INCOMPLETE`, so a range running to now, a stalled feed or a day not yet summarised is
labelled, not shown as a drop. A single silent meter isn't caught here. Answers are cached for
30 s by tenant, quantity, nodes and the window rounded to the minute, and identical requests in
flight run once (`api/cache.py`, one process).

## 8. Users and dashboards: the `frontend` schema

In `valkyrie`, beside the plant, in a schema of their own (§1, 14), written only by the API's own
role, `frontend_api`. Row-level security (063) shows `frontend_api` every row, `grafReader` only
`frontend.tenant` (so `tools/dev_refresh.sh` can copy the schema's structure), and everyone else
nothing. **Built as migration 061** (on dev 2026-10-22), with `prs_frontend`, tenant 3's
read role for the frontend (§6): the `tenant_3` policies name it beside `prs_hermes_agent`, and it
can't reach `frontend`. Both roles are `NOLOGIN` until set by hand, as 044's.

| table | holds |
|---|---|
| `frontend.tenant` | the tenants the frontend serves: name for the top bar, the database role the API reads it through, time zone. Its own table because `public.tenants` isn't readable by the role dev is refreshed with, and the API needs the role and zone anyway. Tenant 3 only so far, named `PRS` |
| `frontend.app_user` | email (unique ignoring case), Argon2id hash, role (`user` / `admin` / `super_admin`), tenant (set for `user`, empty otherwise, by check), must change password, created and by whom, password changed, last log-in, disabled |
| `frontend.session` | server-side sessions, so a password reset or a disabled account ends them: the SHA-256 of the cookie's token, the user, the session's current tenant (an admin's is what they switched to), expiry, revoked |
| `frontend.dashboard` | owner, tenant (a user's must be their own, by trigger), title, the document (JSONB) and its format version, the template it came from, created, updated, deleted |
| `frontend.audit` | append-only to `frontend_api`: log-ins, failed log-ins, log-outs, tenant switches, account changes, an admin opening or copying a user's dashboard |

**A dashboard belongs to its owner and a tenant.** An admin's dashboards are per tenant, since
they name that tenant's nodes. The API returns a dashboard to its owner, and read-only to an
admin in the same tenant (§2); no user sees another user's. The document holds the time range, refresh, channels, and each widget's type,
position, size, channel and own settings, with a version number migrated on read.

**Templates are static documents shipped with the frontend**, per tenant where they name nodes.
Starting from one copies it into `frontend.dashboard` as the user's own; changing a template later
doesn't touch the copies.

Migrations for `frontend` go in `migrations/`, in the one numbering sequence, through
`tools/migrate.sh`.

## 9. The monorepo

| path | what |
|---|---|
| `plant/` | the plant queries both use (below) |
| `server/` | the MCP server, as today |
| `api/` | the frontend's HTTP API: log-in, sessions, tenants, dashboards, and the plant queries |
| `web/` | the frontend (React, Vite, TypeScript) |
| `design/`, `migrations/`, `tools/`, `deploy/` | as today, shared by both |

The plant queries are written once, in `plant/` (decided 2026-10-26): time windows (`timewin`),
node resolution (`resolve`), the vocabulary (`vocab`), and solving a value over a window cut at
plant changes (`value`). `server/` and `api/` both import it; neither imports the other, so the API
doesn't start with the MCP server's settings. `plant/` raises `PlantError`, which the server
answers as a tool error and the API as a 400. The repository's name follows.

## 10. Open

Open: whether the daily path also counts a flat register as 0 (§3, proposed).

Built on dev 2026-10-22: `graph.change_dates` (059) and `node_value` splitting on it, `prs.telemetry_data` and `graph.device_totals_minute`
(060), the `frontend` schema with `frontend_api` and `prs_frontend` (061). Before production:

- read production's `telemetry_data` indexes and time a 6-hour solve;
- deploy the `node_value` change to the agent with 059.

Next to build: dashboards in `api/`, more plant routes as widgets need them (topology, readings,
sankey), then `web/` (§9). A whole-day range that includes today takes the daily path, which reaches as far as the
daily summary's last refresh. On production (read 2026-10-26 13:50 site time) today's rows were
refreshed at 13:30 and the days before last at 23:30, so the job runs at least hourly at :30 and
recomputes the last three days each time (`refresh_daily_energy_costs`); its schedule is in `cron`,
which `grafReader` can't read. "Today" is then up to an hour behind the 15-minute data, and says so
with `DATA_INCOMPLETE`. Before `api/` is deployed:

- behind a reverse proxy, the client's address (for the per-address limit and the audit) must come
  from a trusted `X-Forwarded-For`; today it is the peer's;
- LOGIN and passwords for `frontend_api` and `prs_frontend`, and their PgBouncer entries, by hand.
