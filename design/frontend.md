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
| 21 | **The Value widget becomes Aggregate: one quantity across several nodes over the range.** A counter shows its total, a sampled quantity its minimum, average, 95th percentile and maximum per meter, on 1-minute data up to 6 hours and 15-minute data beyond, said in the widget (§5, "Aggregate"). Decided 2026-10-27 | — |
| 22 | **A Stat widget: one quantity at one node as a single figure, with its line underneath.** The figure is Aggregate's (§5, "Stat"); the line is Readings' at the automatic interval. Decided 2026-10-27 | the stat panel |
| 23 | **Figures show 2 decimals, thousands separated**, in every widget and chart tooltip, unless a widget says otherwise (`fmt` in `web/src/widgets/common.tsx`). Decided 2026-10-27 | a panel's decimals |
| 24 | **Finding a node is the left panel's job, not a widget's.** The node finder widget is retired; its filters (utility, type with its subtypes, metered) are in the Find tab, which groups today's nodes by type, so the type needs no column. A saved finder is drawn as a placeholder saying where it went (§5). Decided 2026-10-27 | — |
| 25 | **Readings widgets share their tooltip.** Hovering one shows every Readings chart's tooltip and pointer line at the same time, each chart snapping to its own nearest point, whatever its node, quantities or interval. Matched by time, not by `echarts.connect`, which places the others by the hovered chart's series and point index. On always; dashboard settings to turn it off come later. Stat's line doesn't join. Decided 2026-10-27 | shared tooltip (graph tooltip) |
| 26 | **A Compare widget: one quantity at several nodes as lines over the range**, Readings turned round, as a widget type of its own. Counters are added over a node's meters, sampled quantities a line per meter, `PF_TRUE` Stat's formula per interval; unmetered nodes are listed as "no meter"; at most 10 nodes; no stacking for now (§5, "Compare"). Decided 2026-10-28 | — |
| 27 | **Readings draws each unit on a scale of its own**: one axis for one unit, a dual axis (left and right) for two, and from three units one panel per unit, stacked on one time axis. A setting draws panels for two units too (§5, "Readings' units"). Decided 2026-10-28 | a series override's axis placement; a panel per unit |
| 28 | **Dark theme only, for now.** The colours are the tokens on `:root` in `web/src/styles.css`, which every widget, chart and the single-line diagram read; there is no light theme and no switch, whatever the browser or OS prefers. Decided 2026-10-29 | the dark theme |
| 29 | **An Activity Bar and a side bar replace the left panel, and Node information and Meters become one Reference view.** Find, Categories and Starred are icons on the bar, each opening its view in a resizable side bar; the icon of the open view closes it. Below a divider, Reference looks up a node, a device or a quantity as the plant is today, apart from any channel or range: one search over all three, every one on a page linking to its own page, Back and Forward. The bar is on every page of a site, not only dashboards. The two widgets are retired; a saved one is a placeholder pointing at Reference (§5, "The Activity Bar and side bar"). Decided 2026-10-30 | — |

Why 30 s: telemetry is polled every minute, and refreshing every 30 s catches data that arrives
late without querying faster than data can change.

Later, as Grafana does: exporting a dashboard as JSON and importing it, the only way a dashboard
passes between users. (Built in slice 3, §5.)

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

**Refresh.** Off by default; 30 s, 1 min, 5 min… when on. Each tick of the dashboard's interval
resolves the range again, and ticks pause while the browser tab is hidden. A widget skips a tick
while its data can't have moved (§6, "Caching"); the Refresh button reloads every widget. **The
30 s minimum is enforced by the server, not the UI** (§6): a browser can ask for anything.

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

**Built (2026-10-26)** in `web/src/dashboards/Canvas.tsx`: react-grid-layout's responsive grid, 24
columns above 768 px, rows of 30 px, 8 px gaps. Below 768 px the widgets stack in reading order and
can't be moved, so nothing laid out on a phone is saved. Widgets move by their header, and only
in edit mode.

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
| Meters (retired 2026-10-30, §1 29) | the devices reading a node, what each reports, last reading, status | `node_meters` |
| Readings | several nodes' quantities over the range, on one chart or stacked | `meter_readings`, at the resolution of §3 |
| Aggregate (was Value) | one quantity across several nodes over the range: a counter's total, a sampled quantity's minimum, average, 95th percentile and maximum per meter (below) | `node_value` for counters; a new read for sampled quantities |
| Stat | one quantity at one node as one figure over the range, with its line (below) | `/api/aggregate` and `/api/readings` |
| Compare | one quantity at several nodes over the range, a line per node or meter (below) | `/api/readings`, one call per node |
| Now | the last reading of a node's meters | `telemetry_data`, latest row per device |
| Node information (retired 2026-10-30, §1 29) | what feeds a node and what it feeds; its devices' brand, model, type, gateway and Modbus slave address, on the node or an edge (below) | `/api/section` (one level), `/api/meters` |
| Sankey | where energy, water or air goes, by category | `graph.sankey` |
| Diagnostics | silent meters, negative residuals, missing required properties | `graph.sankey_diagnostics`, `graph.v_property_gaps` |

**Aggregate (decided and built 2026-10-27).** The Value widget, renamed (§1, 21). Its use: one
quantity, voltage say, across a board and the boards it feeds (`INCOMING_PLN` and its direct
children), to see how that quantity behaved over the range at each of them.

- **Shape.** One quantity, several nodes: a row per node, or per meter where a node has more than
  one. The quantity is chosen in the settings; the nodes too, or a channel's node.
- **Counters** (`COUNTER` in `graph.quantity_term`: energy, volume) show **one figure, the total**
  over the range. Minimum, maximum and percentiles of a running register say nothing, and the
  peak 15-minute demand is left out. Totals keep going through the solver (`node_value`) even on a
  metered node, since a node's measured value isn't always one register: `LVMDB_A4` is meter 26
  plus ⅓ of PV A4 (048), `LVMDB_A5` is metered on its feeder edge (046). The solver applies those
  measurement rows; a raw register would undo them.
- **Sampled quantities** (`SAMPLE`: voltage, current, power, THD, frequency) show the **minimum,
  average, 95th percentile and maximum** over the range, **per meter**: two meters' voltages
  aren't merged into one figure. Meters on the node and on its feeder edge both count.
- **Which data.** As Readings (§3): 1-minute readings for a range of 6 hours or less within the
  minute data kept, 15-minute data beyond. The widget says which, in words: "from 1-minute
  readings", or "from 15-minute readings (the last reading in each 15 minutes)", since
  `telemetry_15min_agg` keeps each bucket's last reading, not its average, and a minimum or maximum
  of those can miss a short dip or spike.
- **How much a figure rests on.** Each row shows its reading count against those expected for the
  range, and the data's end, as Value's footer does now.
- **Quantities offered**: those the selected nodes' meters report, grouped (voltage, current,
  power factor, power, harmonics, energy). The eight power factor registers (`PF_TOTAL`,
  `PF_A`..`PF_C`, `DPF_TOTAL`, `DPF_A`..`DPF_C`) are offered since 2026-10-28 as "decoded, 0..1":
  each reading is decoded to its magnitude before any statistic, as Readings decodes it
  (`design/mcp-tools.md`, gap 4), so leading and lagging are not told apart, and the answer says so
  (`quantity.decoded`). `PF_TRUE`, worked out from the active and reactive energy, sits beside them:
  the power factor of the range's energy, where the registers give the meter's own readings.
- **Unmetered nodes are left out for now** for sampled quantities: the only one the solver can
  give them is `THD_VOLTAGE_LN`, their feeder's.
- **Unchanged underneath.** The widget's type stays `value` in saved dashboards (the document
  format doesn't change, §1, 19 and `design/dashboard-v1.schema.json`); only the label and
  settings change. `o-mcp/values` v1, which the MCP tool `node_value` also returns, isn't changed:
  sampled statistics get a route and format of their own, which the agent can be given later
  through `plant/`.
- **Settled 2026-10-27:** an unmetered node keeps its solved total for counters, with how it was
  found; `PF_TRUE` is one figure for the range (a spread per interval later); counters without a
  solver rule are left out; nodes are picked by hand or come from a channel, with no "and its
  children" set; the range is at most one year.

**Stat (decided and built 2026-10-27).** Grafana's stat panel: one node, from the settings or a
channel, one quantity, one figure, and a line under it.

- **The figure** is the Aggregate widget's, from `/api/aggregate`, so the two never disagree: a
  counter's total (through the solver, so `LVMDB_A4`'s ⅓ of PV and `LVMDB_A5`'s feeder meter
  apply), or for a sampled quantity one meter's average, minimum, 95th percentile or maximum. The
  default is **last**: the line's last point, which is the last reading at 1-minute and 15-minute
  points, and an hour's or a day's average on longer ranges; the caption says which.
- **The meter.** A sampled quantity is one meter's, the first listed unless the settings choose
  another; a node with several says which in the caption.
- **The line** is `/api/readings` at the automatic interval (§3): the chosen meter's values, or a
  counter's consumption added over the node's meters. That sum is the raw registers, so on a node
  whose measurement rows weight a meter (`LVMDB_A4`) the line's shape is right but its area isn't
  the figure. `PF_TRUE`'s line (since 2026-10-28) is its formula per interval, P / sqrt(P² + Q²) of
  the active and reactive energy each added over the node's meters, so the figure is the range's
  and the line each interval's. Unmetered nodes have no line. It can be turned off.
- **Quantities offered** are Aggregate's.
- **No thresholds or colours yet.** The figure's size follows the box.

**Node information (built 2026-10-28, retired 2026-10-30).** Merged with Meters into the side
bar's Reference view (§1, 29), whose node page holds what follows, as of today. For an operator
checking a device without the site's worksheet: one node, from the settings or a channel, on the
range's last day.

- **Fed by** and **Feeds**: the node's edges in and out, each with the node at the other end, its
  type, the edge type and utility, and "no flow" on a capacitor bank's edge. A click on a node puts
  it on the channel. It is the plant section one level down, which lists every edge into the node.
- **Devices**: each device on the node or its feeder edges, with where the model reads it (node,
  edge from X, or both, as `LVA5` on `LVMDB_A5` since 046: energy on the transformer edge, voltage
  THD on the board), brand and model, device type, the gateway's IP address and port, the Modbus
  slave address, and whether it reports.
- The device details are `public.devices.metadata` as recorded (`device_info`,
  `data_concentrator`, `communication`), given in `o-mcp/meters` v1 since 2026-10-28 (`brand`,
  `model`, `protocol`, `gateway`, `slave_id`, and each `graph_quantities` entry's `attached_to` and
  `edge`), so the agent's `node_meters` has them too (agreed 2026-10-28). A gateway is its IP
  address: `data_concentrator.number` is a leftover of an earlier design that nothing reads, and
  is left out.
- An edge out of the node shows no meter: a child's feeder meter is in the child's own answer.

**Readings' units (decided and built 2026-10-28).** Readings takes up to 8 quantities, and the
vocabulary has 14 units (V, A, kW, kVA, kVAr, kWh, %, Hz, °C, decoded power factor and more), but
the chart has drawn every line on one y-axis, so current flattens voltage and THD flattens
everything else. Each unit gets a scale of its own (§1, 27):

- **One unit**: one axis, as before.
- **Two units**: a **dual axis**. The first unit in the quantity list is on the left, the second on the right;
  each axis is named by its unit, and the legend marks the right axis's lines "(right)".
- **Three units or more**: **one panel per unit**, stacked in the widget on one shared time axis,
  labelled only under the last panel. Each panel is titled by its unit and holds every line of that
  unit, so two voltages still share one scale. More axes on one chart are not offered: past two,
  which line reads on which axis can't be told at a glance.
- **A setting, "Axes": Automatic (the above) or One panel per unit**, which draws panels for two
  units as well.
- **What counts as a unit**: the quantity term's `unit`; decoded power factor (0..1, no unit) is one
  unit of its own, and every `%` quantity (THD, harmonics, unbalance) shares one.
- **Scales** stay as they are per axis or panel: counters' bars start at zero, sampled quantities'
  lines fit their data.
- **The shared tooltip** (§1, 25) keeps working: the panels of one widget share one pointer line
  (ECharts' `axisPointer.link`) and one tooltip, the time once and every line at it in the legend's
  order, and a tooltip relayed from another chart is placed inside the first panel, not at the
  widget's mid-height, which can fall between two panels.
- **Every time axis spans the range**, not the data's extent, so panels line up and a meter that
  stopped reading shows where it stopped.
- Panels need height: a widget showing several is drawn taller by its user, not resized for them.
- Not chosen: a third or fourth y-axis, values normalised to each line's maximum (hides the values
  engineers read), and limiting Readings to one unit. Drawing a counter as its average rate per
  interval (kWh in an hour as kW), so energy and power share an axis, is left for later as a setting
  of its own.

**Compare (decided and built 2026-10-28).** The other way round from Readings: one quantity,
several nodes, a line each over the range. Aggregate's figures drawn over time, under its own type
`compare`, since Readings keeps one node and several quantities and each setting would otherwise
mean two things (§1, 26).

- **Settings** are Aggregate's (the quantity, offered and grouped as there, and the nodes, a
  channel's node first) plus Readings' interval. **At most 10 nodes**: past that a line chart
  stops being readable.
- **Counters**: one line per node, the consumption **added over the node's meters**, as Stat's
  line. That sum is the raw registers, so a node whose measurement rows weight a meter
  (`LVMDB_A4`, 048) or meter it on its feeder edge (`LVMDB_A5`, 046) has the right shape but not
  the solver's area.
- **Sampled quantities**: **one line per meter**, as Aggregate's rows: two meters' voltages aren't
  merged. The legend names the node, and the meter only where a node has more than one.
- **`PF_TRUE`**: Stat's formula per interval, P / sqrt(P² + Q²) of the active and reactive energy
  each added over the node's meters.
- **Unmetered nodes** have no line; they are listed under the chart as "no meter", as Aggregate
  lists them. Which they are comes from `GET /api/meters` on the range's last day (the devices
  readings would read), so no readings call is made for them.
- **No stacking for now.** Stacked bars of energy per board would count a board and its own
  children twice; it waits until the widget can tell when one chosen node feeds another.
- **Data**: `GET /api/readings` once per node with the one quantity, so a Stat on the same node
  shares the cached answer, and the 10,000-point limit holds per node. A `nodes=` route over one
  query comes only if that proves slow; it would need a format of its own, since `o-mcp/readings`
  v1 has one `query.node`.
- It joins the Readings charts' shared tooltip (§1, 25).

Diagnosed meter faults are shown, never hidden by the frontend. The analysis tools still to come
(power factor, harmonics, board loading; `design/mcp-catalogue.md` §2, layer 4) become widgets
once they are built.

The output formats (`design/*-v1.schema.json`) are the widgets' data contracts. The frontend
generates its TypeScript types from them, so a format change shows up as a type error.

**Frame.** The Activity Bar and side bar (since 2026-10-30; before, a left panel with tabs) hold
ways to choose a node: the finder, the category tree, a starred list; and the Reference view. The
bottom bar holds data health: the time of the latest telemetry, the number of silent
meters, refresh on or off, the tenant's clock.

**Built (2026-10-26), `web/` slice 1.** The frame:
- a top bar with the site, which an admin switches there; the account; the password; log-out;
- a left panel listing every node in effect today, where a click puts the node on channel A;
- a bottom bar with the site's clock and the open dashboard's refresh.

Widgets (`web/src/widgets/`, one file each):

| widget | route |
|---|---|
| value (Aggregate) | `/api/aggregate` |
| stat | `/api/aggregate`, `/api/readings` |
| readings | `/api/readings` |
| now (slice 2) | `/api/now` |
| node finder (retired 2026-10-27, §1 24) | `/api/nodes` |
| plant section | `/api/section`, an indented tree, not yet a drawn single-line diagram |
| meters (retired 2026-10-30, §1 29) | `/api/meters` |
| node information (2026-10-28, retired 2026-10-30) | `/api/section`, `/api/meters` |
| sankey | `/api/sankey`, drawn as the Grafana panel draws it |
| diagnostics | `/api/diagnostics` |

- **Channels:** four (A–D), each holding a `{kind, id}` entity. A finder, section or diagnostics
  row puts its node on the widget's channel, and node widgets on that channel follow it.
- **Loading:** while a widget reloads, its previous answer stays on screen, dimmed and marked
  "Loading…", so it is never read as the new one.
- **Errors:** an error boundary around each widget keeps one failure off the others.
- **Not yet (built in slice 3):** the category tree, the starred list and a drawn single-line diagram.

**`web/` slice 2 (2026-10-27):**
- **Account screen** (`/accounts`, super admin only): create an account, reset its password (the
  temporary password shown once), disable or enable it, and set role and site together.
- **Data health in the bottom bar** (`GET /api/status`, polled every minute while the tab is
  visible). It shows how far minute data, 15-minute data and the daily summary reach, coloured by
  age, and how many meters are silent. Meters on nodes the site turned off are counted apart. A
  silent meter's node goes onto channel A with one click.
- **The Now widget** (`GET /api/now`): the last reading of each of a node's meters at the range's
  end, which for a range running to now is now.
- **Checks:**
  - Vitest unit tests for the time-range parsing (`npm test`);
  - `tools/web_check.py`, which drives the whole frontend in a headless browser against dev, from
    log-in and an account to a saved dashboard, at desktop and phone widths, and removes what it
    created.

**`web/` slice 3 (2026-10-27):**
- **The left panel** has three tabs:
  - **Find:** the text search, as before. Since 2026-10-27 (§1, 24) also the retired finder
    widget's filters: utility (only those with a node), type (its subtypes included) and metered
    only. Results are grouped by type, folded until a search or a type narrows them; a dot marks
    a metered node. It lists today's plant, filtered in the browser on the list the panel already
    holds, where the widget read `/api/nodes` as of the range's last day.
  - **Categories:** the sankey's category tree for electricity (`GET /api/categories`). Each node
    is under the category `graph.sankey` puts it in; a node split between categories appears
    under each, with its share.
  - **Starred:** the account's starred nodes. A ☆ beside any node in the panel stars it. Stars
    are kept per account and site in `frontend.starred_node` (064), so they follow the person
    between browsers (decided 2026-10-27). A starred node that leaves the plant stays listed and
    says so.
- **The single-line diagram:** the plant section widget now draws what a node feeds as a
  single-line diagram (`web/src/widgets/sld.ts`), and keeps the indented list as a setting and
  for what feeds a node.
  - It is `tools/sld.py`'s layout and drawing ported line for line. `sld.test.ts` renders
    ten saved documents from dev with both and requires the same SVG text. These include
    2026-05-01's stacked Texture busbars.
  - In the frontend it takes the theme's colours, fits the widget's width or shows actual size,
    and a click on a node's code puts the node on the channel.
- **Export and import:** Export downloads the dashboard as edited, as a JSON file: the title,
  the site and the `o-mcp/dashboard` document, `kind: o-mcp/dashboard-export`. Import on the list
  page makes it a new dashboard of one's own. The file is refused in another site, since node ids
  are a site's own. The API checks the document as on every save. Only one's own dashboards are
  exported: an admin copies a user's, and the copy is audited.
- **Fixed:**
  - Discard now reopens the saved copy. Before, a refetch that returned what the cache held kept
    the same object, so the edits stayed.
  - The browser check now reports any dialog.

**The Activity Bar and side bar (2026-10-30, §1 29).** The left panel's three tabs become icons on
an Activity Bar, 44 px down the left of every page of a site, and Node information and Meters
leave the canvas for a fourth, Reference, below a divider.
- **The bar** (`web/src/frame/SideBar.tsx`): Find, Categories and Starred (with its count), then
  Reference. An icon opens its view in the side bar; the icon of the open view closes it. The
  side bar's right edge resizes it (200 to 640 px, at most half the window; a double-click resets
  300). The view, open or closed, and the width are remembered per browser; on a phone the bar
  lies over the page and each visit starts with it closed.
- **Find, Categories and Starred** are the panel's tabs as they were. On a dashboard a click puts
  the node on the channel picked at the top, and ⓘ (on hover) opens it in Reference without
  touching the channel. On a page without a dashboard there is no channel, so a click opens
  Reference.
- **Reference** (`web/src/frame/reference/`) is a lookup, not a widget: no channel, no time range,
  the plant as it is today. One search box finds nodes (code, name), devices (code, name, brand,
  model, gateway address, slave ID) and quantities (code, description, unit, id) in lists the
  browser already holds; every node, device and quantity on a page opens its own page, and Back
  and Forward walk the pages seen in the session (dropped on a site switch).
  - **Node:** class, type, utilities and the site's status; Fed by and Feeds, each edge with its
    type, utility and the meter on it; the devices on the node or its feeder, with where the model
    reads each, brand and model, gateway, slave ID and whether it reports; and the values the
    node can be given and how (`/api/section` one level down, `/api/meters`).
  - **Device:** the register's details, where the model reads it today by node (on the node, or
    on the feeder from another), each quantity linked, and the quantities it reported in the last
    day beside those the model reads and didn't get. No reading times, as in the Meters widget
    since 2026-10-29: a 15-minute bucket's time reads as the last reading.
  - **Quantity:** its vocabulary entry (unit, counter or sample, whether the solver resolves it
    for every node, the derived quantities it feeds) and the devices carrying it: those the model
    reads it from, at which node, and those that reported it in the last day without the model
    reading it.
  - The index is `GET /api/devices` (§7), `o-mcp/devicelist` v1: every device of the register,
    its graph mappings by node and what it reported in the last day (one day, not `meters`' seven:
    the list reads every device's buckets). Measured on dev: 107 devices in 1.7 s, cached until
    the 15-minute data moves.
- **Retired widgets:** a saved `meters` or `nodeinfo` widget is drawn as a placeholder pointing at
  Reference, removed by hand, as the finder was. The template's Meters widget is gone and the
  plant section takes the full width.

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

- **caches results** by tenant, query and window, **until the data they read moves** (below); an
  answer from the graph alone for the shortest refresh interval (30 s). This is also what enforces
  the minimum: a faster refresh gets the cached answer;
- **rounds relative ranges to the minute**, so `last 24 h` from ten viewers is one cache key;
- **runs identical in-flight requests once** and gives every caller the answer;
- **tells the browser when the data can next move**, and the widget doesn't ask before then;
- gzips its answers;
- optionally takes **one request per dashboard refresh** instead of one per widget.

Users' own dashboards make identical requests rarer than on shared Grafana dashboards, so the
cache matters most where several people open the same template. The tenant 4 refresh
dashboards are the first load test.

### Caching (decided and built 2026-10-28)

**Measured first, on production** (2026-10-28, as `grafReader` through the tunnel, the API's own
read functions; the harness stayed out of the repository):

- **How often each source moves.** Minute data (`telemetry_data`) lands within about 40 s of each
  minute. `telemetry_15min_agg` is a continuous aggregate, **materialized only**, refreshed every
  5 minutes (job 1004, `end_offset` 5 minutes) and only for whole buckets: it changes once per
  15 minutes and trails real time by 15 to 30. The daily summary is refreshed every 30 minutes
  (pgAgent job 4).
- **What a read costs the database.** Readings: 1 to 60 ms of planning and execution, from an hour
  of minutes to 30 days hourly. Through the tunnel the same requests took 190 to 990 ms: 6 to 8 round trips
  at about 23 ms each, and moving the rows (2,884 rows took about 500 ms). The solver behind Values
  and Aggregate's totals is the real cost: 180 ms for 5 boards over a day, 830 ms over 7 days,
  540 ms over 6 hours of minutes, 4.6 s once cold.
- **What one viewer's refresh did.** Six widgets (four Readings, one Aggregate, one Now) at 30 s for
  20 minutes, through the 30 s cache: the minute rounding made every other tick a hit, and each
  widget ran 21 queries. For the widgets on 15-minute data, 20 of those 21 returned what the one
  before had (the Aggregate total 17 of 21). Now's changed every time.

**Decided:**

- **A, an answer is kept until its source moves.** Each answer reads one or more sources (minute data,
  the 15-minute aggregate, the daily summary) and is valid while they stay where they were when it
  was computed. Readings over 6 hours, every Aggregate or Value over 6 hours, the sankey and
  the meters then run once per aggregate refresh instead of every other tick; windows of 6 hours or
  less still run once a minute, since their data does move every minute, and they are the cheap ones.
- **The browser waits.** Each answer from telemetry carries `X-Fresh-Until`, the earliest time its
  sources can move; a widget on a refresh tick before then keeps its window, so its queries aren't
  asked again.
- **No per-widget refresh limit for Values and Aggregate.** Over 6 hours A already gives them the
  data's own pace, about every 15 minutes, and recomputes as soon as new data lands; 6 hours or less,
  the value moves every minute, which is why someone picks such a window. One viewer's minute solve
  is 0.5 to 1 s a minute per widget, about 1 to 2% of one connection. Watch many viewers on different
  minute windows.
- **Not now, B (caching the past apart from the live end, server side) and C (the browser asking
  for what's new only).** They save transfer, and the API will run on the database's host; the
  Readings queries themselves are milliseconds. Gzip covers the browser's leg. Time a cold year
  across many nodes there before deciding B (§7 Aggregate, "not yet seen on production").
- **Not rounding long windows' keys to their interval.** For one viewer the browser's wait already
  keeps the window, and a shared answer would carry another request's `requested` window.

**Built** (`api/fresh.py`, `api/cache.py`, `web/src/widgets/fresh.ts`):

- **The marks.** Per tenant, at most every 15 s and only while requests come in, one query reads the newest
  minute, the newest bucket and the daily summary's last refresh, and (once, at the first read) looks
  up the aggregate's refresh policy in `timescaledb_information`. When the policy is visible, the
  15-minute version is its last successful run, so a late reading that lands in an
  older bucket is seen too, and the next change is its `next_start`. Without TimescaleDB (dev) or
  the policy, it is the newest bucket and no next change is known. If the aggregate isn't
  materialized only, it follows the minute data. The query costs about 51 ms on production (49 ms of
  it planning across chunks); the log says which version the 15-minute data uses.
- **The cache** keeps each answer with the version of the sources it read, taken before it was
  computed, so it is never newer than its data says; at most 15 minutes, as the graph may change under
  it. A request at a newer version doesn't share a computation started at an older one. Each read
  declares its sources from the request alone (`api/reads.py` `readings_sources`,
  `api/values.py` `fresh_sources`): a window of 6 hours or less is minute and 15-minute data (minutes
  when kept), whole days the daily summary for electricity energy, the rest 15-minute data; Now
  reads minutes, the meters 15-minute data, the status all three. The vocabulary, the finder, a section and the
  categories read the graph alone and keep the 30 s TTL.
- **`X-Fresh-Until`** (UTC): the soonest next change among the answer's sources, never before now,
  at most 5 minutes ahead. Minute data: a minute after the newest, so usually now; the aggregate: its
  `next_start`; the summary: the next hour or half hour. Unknown means now.
- **The browser** (`useHeldView`): a widget whose queries move with the refresh tick keeps its last
  window while its answers' time hasn't come, unless the range, the widget's settings, the
  tenant or a press of Refresh changed. The time is kept by answer, so two widgets sharing a
  query (Node information and Meters) both see it. An answer that doesn't say holds nothing.
- **Gzip** for anything over 1 KB (Starlette's `GZipMiddleware`).

Checked on dev: the API's unit and dev tests, header and gzip included, and `tools/web_check.py`. Dev has
neither TimescaleDB nor live data, so nothing is held there; `api/fresh.py` was read on production
as `grafReader`: it found job 1004, and its next change was the job's `next_start`. The API on
production's data as `prs_frontend` sees the policy too (2026-10-28: "tenant 3: the 15-minute data's
version is its refresh job 1004").

## 7. The API

One API serves every tenant (§1, 11), with a pool per tenant role. Each request's pool is chosen
from the session's tenant (§2), and Postgres enforces the rest, so a bug in choosing the pool is
the one way across tenants. Tests pin it: a non-admin session asking for another tenant is
refused, and an admin's request runs as the selected tenant's role.

**Built so far (2026-10-26), on dev:** log-in, sessions, the tenant switch, the super admin's
accounts and users' dashboards (`api/app.py`, `api/auth.py`), Starlette on a pool of `frontend_api`. JSON in and out;
everything that changes state is a POST with an `application/json` body, which with the
`SameSite=Strict` cookie keeps other sites out without a CSRF token.

| route | who | does |
|---|---|---|
| `POST /api/login` | anyone | email and password; sets the session cookie; returns what `/api/me` does |
| `POST /api/logout`, `GET /api/me`, `POST /api/password` | any session, also before a forced change | end the session; the account, current tenant and switchable tenants; change the password (ends the account's other sessions) |
| `POST /api/tenant` | any session | switch the session's tenant: a user may only name their own (403 otherwise), an admin any active one (audited) |
| `GET/POST /api/admin/users`, `POST /api/admin/users/{id}/reset-password`, `…/disable`, `…/enable`, `…/assign` | super admin | list and create accounts (a temporary password, shown once); reset, disable, enable; set role and tenant together. Never on their own account |
| `GET/POST /api/dashboards` | any session, in its tenant | the caller's own dashboards (no documents); create one from a blank canvas or a template's document, `from_template` naming it |
| `GET/POST /api/dashboards/{id}`, `POST …/delete`, `…/copy` | the owner; an admin reads | open; save title or document, with the `updated_at` last read (a stale save is 409, checked in the `UPDATE`); delete (`deleted_at`); copy into the caller's own. An admin opens and copies the current tenant's users' dashboards, read-only (403 on save or delete), each audited |
| `GET /api/admin/dashboards` | admin | the current tenant's users' dashboards, with their owners |
| `GET/POST /api/stars` | any session, in its tenant | the caller's starred node ids, in the order starred; star or unstar one (`{node_id, starred}`), at most 200. Ids aren't checked against the plant (§1, 19) |

- A session lasts 12 hours, ends after 2 hours idle, and is checked against the account on every
  request; a reset, disable, or role or tenant change revokes it.
- Failed log-ins are counted from `frontend.audit`: 5 per email or 20 per address in 15 minutes
  lock further attempts out, right password or not. Locked-out tries are logged, not counted.
- An account with `must_change_password` reaches only `/api/me`, `/api/password` and `/api/logout`.
- An admin's session starts with no tenant; the frontend asks them to pick one.
- The first super admin comes from the command line (`python -m api create-super-admin`).
- Dashboards (2026-10-26): every route works in the session's tenant, so an admin chooses one
  first (409). Another user's dashboard, a deleted one and an unknown id are all 404, so an id
  reveals nothing; a user never sees an admin's dashboards. The document is the frontend's: the API
  checks it against `design/dashboard-v1.schema.json` (§8), at most 256 KiB, at `format_version` 1,
  and never reads a widget's settings.

**Plant reads (2026-10-26), on dev.** A pool per active row of `frontend.tenant`, as its `db_role`
(`prs_frontend` for tenant 3), with the password from `O_API_TENANT_<id>_PASSWORD`
(`api/tenants.py`). The API refuses to start if a pool's `current_user` isn't that role or sees
another tenant's devices. `Tenants.for_session` is the one place a session becomes a pool: an
admin with no tenant chosen gets 409, and a user's session naming a tenant other than their own
gets 403. The plant read runs after the frontend transaction has closed, so a slow solve holds no
`frontend_api` connection.

`GET /api/aggregate?quantity=&nodes=<ids>&start=&end=` (`api/aggregate.py`, `plant/aggregate.py`): the
Aggregate widget's read (§5), an `o-mcp/aggregate` v1 document (`design/aggregate-v1.schema.json`), over
up to 50 nodes and a year. A counter with a solver rule, or `PF_TRUE`, is a `TOTAL`: `/api/values`' own
answer per node, so the resolution, pieces and findings are the same. A sampled quantity is a
`SPREAD`: per meter on each node (on the node or its feeder edge, on the window's last day), the
minimum, mean, 95th percentile and maximum of its readings, with the count of readings against
those expected; minute data for a window of 6 hours or less within the minute data kept, else
15-minute values, as Readings chooses. The eight encoded power factor registers and the counters
with no rule are refused. Readings' window point gained `p95` for it, within `o-mcp/readings` v1.

`GET /api/values?quantity=&nodes=<ids>&start=&end=` (`api/values.py`): one quantity for up to 50
nodes by `graph.node.id`, over a site-time window of up to 92 days. The resolution is chosen as in
§3: whole site days read as before; a window of 6 hours or less starting within the minute data
reads minutes; anything else reads 15-minute buckets, electricity energy included. The window is
snapped outwards to its resolution. The answer carries `resolution`, the snapped `window`, the
`pieces` it was solved in, and per node the value, origin and parts, with the findings
`NOT_IN_NETWORK`, `NO_VALUE` and `PLANT_CHANGED` as `node_value` has them. It also names the
`source` the solve read and its `data_until`: the last minute or bucket inside the window, for the
whole tenant, or for the daily summary the earlier of its last day's end and the quarter
before that day's `last_refreshed` (the run's start, when that quarter hasn't all arrived). Short of the window's end the answer carries
`DATA_INCOMPLETE`, so a range running to now, a stalled feed or a day not yet summarised is
labelled, not shown as a drop. A single silent meter isn't caught here. Answers are cached by
tenant, quantity, nodes and the window rounded to the minute until the data they read moves, and
identical requests in flight run once (`api/cache.py`, `api/fresh.py`, one process; §6, "Caching").

**The other plant reads (2026-10-26), on dev** (`api/reads.py`). Each runs the MCP tool's own query,
moved into `plant/` (`find`, `section`, `meters`, `readings`, and the vocabulary document), so the
agent and the frontend can't disagree, and answers in the tool's v1 format. The formats gained,
within version 1, the node's `id` (nodelist, subgraph, meters), and in readings `query.node_id`,
each series' `device_id` and the `minute` interval. Nodes are given by id and looked up on the
network of `as_of`; a node not in effect that day is refused by its code. Every answer is cached as
the values are.

| route | takes | answers |
|---|---|---|
| `GET /api/vocabulary` | — | `o-mcp/vocabulary` v1: the pickers' types, classes, utilities and quantities |
| `GET /api/nodes` | `as_of`, `text`, `type` (subtypes included), `class`, `utility`, `metered`, `site_status`, `limit` (≤ 500) | `o-mcp/nodelist` v1, the finder |
| `GET /api/section` | `node`, `as_of`, `depth` (≤ 12), `direction` (`down`/`up`), `utility` | `o-mcp/subgraph` v1, the single-line diagram and the path to source |
| `GET /api/meters` | `node`, `as_of` | `o-mcp/meters` v1: devices, last readings, what can be resolved |
| `GET /api/devices` | `as_of` | `o-mcp/devicelist` v1: every device of the register, its hardware, where the model reads it on `as_of` (by node; a feeder's on the node the edge goes into) and the quantities it reported in the last day. The Reference view's index; no MCP tool yet |
| `GET /api/readings` | `node`, `quantities` (≤ 8), `start`, `end` (≤ 92 days), `interval`, `device` | `o-mcp/readings` v1 on the meters in effect on the window's last day, at most 10,000 points |
| `GET /api/sankey`, `GET /api/diagnostics` | `start`, `end` (≤ 92 days), `quantity`, `node_detail` | `graph.sankey`'s links; `graph.sankey_diagnostics` with node ids, and `graph.v_property_gaps` |
| `GET /api/now` | `node`, `at` (default now), `quantities` | each of the node's meters' last minute reading in the 15 minutes before `at`, instantaneous values by default, power factor decoded (`plant/now.py`) |
| `GET /api/categories` | `as_of`, `quantity` | the sankey's categories (`graph.category`, `FUNCTIONAL`) and the nodes in each on `as_of`, with how each was found and its weight (`graph.sankey_nodes` over that one day). The side bar's Categories view |
| `GET /api/status` | `at` (default now) | the latest minute and 15-minute data in the last 24 h, the daily summary's last refresh, and the meters the graph reads that have had no 15-minute data for over 2 hours, apart from those on nodes the site turned off (`plant/status.py`) |

- Topology widgets pass their range's last day as `as_of` (§3, A); readings and the sankey take
  the window and use its last day themselves.
- Readings' `interval` defaults to `auto`: minutes for 6 hours or less within the minute data (§3),
  then 15 minutes up to 2 days, hours up to 31, days beyond. A widget may ask for `15min`, `hour`,
  `day` or `window`, never minutes outside that rule.
- The sankey works in whole site days, as `graph.sankey` does: a window not on midnights draws every
  day it touches, as the Grafana panel. It takes the conserved quantities the solver sums (energy,
  water, air; `ACTIVE_ENERGY_DELIVERED` by default) and is drawn on the window's last day, with
  `PLANT_CHANGED` when the plant changed inside it and `DATA_INCOMPLETE` as `/api/values`.
- Property gaps are as of today: node properties have no history.
- `at` is clamped to now: nothing is read after it.

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
| `frontend.starred_node` | an account's starred nodes per tenant (064, on dev and production 2026-10-27): user, tenant (a user's own, by trigger), `graph.node.id` with no foreign key, as in a document. Deleted with the account |

**A dashboard belongs to its owner and a tenant.** An admin's dashboards are per tenant, since
they name that tenant's nodes. The API returns a dashboard to its owner, and read-only to an
admin in the same tenant (§2); no user sees another user's. The document holds the time range, refresh, channels, and each widget's type,
position, size, channel and own settings, with a version number migrated on read.

**The document's format is `o-mcp/dashboard` v1** (`design/dashboard-v1.schema.json`, fixed
2026-10-26):
- `time` is `{from, to}`, each a Grafana-style relative time (`now-24h`, `now/d`; a rounded `to` is
  the end of its unit) or a site date or minute;
- `refresh` is null or at least 30 seconds;
- `channels` maps A–D to an entity;
- `widgets` holds up to 60, each with an id, type, title, `x`/`y`/`w`/`h` on the 24-column grid, a
  channel and its own `settings`.

The API checks every save against the schema (400 naming the first error). web/ generates its
types from it, and `migrate` in `web/src/dashboards/document.ts` is where a version 2 will be
read. A type the frontend doesn't know is drawn as a placeholder, never dropped.

**Templates are static documents shipped with the frontend**, per tenant where they name nodes.
Starting from one copies it into `frontend.dashboard` as the user's own; changing a template later
doesn't touch the copies. Built: `web/src/templates/`, so far tenant 3's "Energy overview" (sankey,
and value, now, readings, section, meters and diagnostics on channel A; the finder left it on
2026-10-27).

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

Built 2026-10-26: the plant routes the widget list needs (§7), and `web/` slice 1 (§5): the frame,
the dashboards, the canvas, seven widgets and the document format (§8). Checked in a headless
browser against dev, from log-in to a saved dashboard, at desktop and phone widths. Run it with the
API on `O_API_BIND` and `cd web && npm run dev` (Vite forwards `/api`; `O_API_URL` names another
API). Slice 2 (2026-10-27): the account screen, data health, the Now widget, and the checks (§5).
Slice 3 (2026-10-27): the category tree, starred nodes (064), the drawn single-line diagram, and
export and import (§5). Next: the full review of slices 1–3. 063 and 064 are on production since 2026-10-27.

Open: how `web/dist` is served in production. It must be the API's origin (the cookie is
`SameSite=Strict`): the reverse proxy serving both, or Starlette serving the files. A whole-day range that includes today takes the daily path, which reaches as far as the
daily summary's last refresh. On production (read 2026-10-26 13:50 site time) today's rows were
refreshed at 13:30 and the days before last at 23:30. pgAgent job 4 runs
`refresh_daily_energy_costs` every 30 minutes, on the hour and the half hour (its log, read by the
user the same day), in about 2 minutes, recomputing the last three site days each time, and
`last_refreshed` is the run's start. "Today" is then up to 45 minutes behind the 15-minute data,
and says so with `DATA_INCOMPLETE`. Before `api/` is deployed:

- behind a reverse proxy, the client's address (for the per-address limit and the audit) must come
  from a trusted `X-Forwarded-For`; today it is the peer's;
- LOGIN and passwords for `frontend_api` and `prs_frontend`, and their PgBouncer entries, by hand.
