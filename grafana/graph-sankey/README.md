# graph.sankey in Grafana

A Business Charts (Apache ECharts) panel over `graph.sankey`, and a table panel over
`graph.sankey_diagnostics`, to replace the panel over `prs.get_sankey_energy_flow_v2`
(`../prs_diags/docs/prs/sankey_query.md`). The design is `design/graph-sankey.md`.

| file | what it is |
|---|---|
| `sankey.sql` | the sankey panel's query |
| `sankey.js` | the Business Charts code for it |
| `diagnostics.sql` | the diagnostics table panel's query |

Nothing in them names a node, category or colour. Labels, colours (`category.display_color`) and
order come from the rows, so a node or category added to the graph appears without touching the
panel. The old panel's `nodeOrder` and `colorMap` lists are gone, and so is its `$group` variable:
`graph.sankey` returns one set of links for the whole range.

## Setup

In the dashboard that holds the old panel, leaving the old panel as it is:

1. **Variable** `node_detail`: Custom, values `FALSE,TRUE`, default `FALSE`. `FALSE` draws the
   category tree (down to WJL, Spinning, Compressor and so on) plus the boards whose residual sits
   on Production or Fabric. `TRUE` adds every node under its category: machines, boards,
   compressors.
2. **Sankey panel**: visualisation Business Charts; the PostgreSQL data source whose user is
   `grafReader` (it can execute the three `graph.sankey*` functions); the query `sankey.sql` in code
   mode, format Table; the code `sankey.js` in the panel's function editor. Height about 750 px
   with `node_detail = FALSE`, about 1,300 px with `TRUE`.
3. **Diagnostics panel**: visualisation Table, same data source, the query `diagnostics.sql`. Put it
   beside or under the sankey: the diagram doesn't draw negative residuals, and it can't show a
   silent meter.

## Reading it

- **Whole days, site time.** `daily_energy_cost_summary` is daily, so the range is turned into the
  days it touches in Asia/Jakarta, end day included. "Last 6 hours" draws today; "Last 7 days"
  draws 8 days. The subtitle says which days are drawn. Today's figures exist only once the
  summary's daily refresh has run.
- **Supply** is every source's out-flow: the grid incomer, the PV plants and the gas engine.
  Percentages are of Supply.
- **The categories can add up to more than Supply.** Negative residuals (a meter reading less than
  the meters below it) are left out of the diagram, so what's left of the positive ones exceeds
  Supply by the same amount. The subtitle gives the amount when it is over 0.1%, and the
  diagnostics panel names the meters.
- **Unassigned** is energy with no category. Since migration 058 it is only meter 94's reading
  beyond its feeds ("Incoming PLN 1 (unaccounted)", visible with `node_detail = TRUE`).
- **A faint link** was solved, not metered (`is_ambiguous`): today the gas engine, whose share of
  A1–A3 comes from FACTORY_AB's meter. Its tooltip says so.
- Labels under 0.1% of Supply are hidden so they don't overlap; the node and its tooltip stay.
- A drawn node's value is its own value: its reading minus what it passes on. A board drawn under
  Production is the part of the board no meter below it accounts for.

## Energy only

The sankey shows energy flow only (decided 2026-10-22). Its cost mode didn't balance: on
2026-10-20 to 21 (dev), Supply was 140 M IDR and the categories 174.6 M IDR, with Unassigned at
about 13,560 IDR/kWh against about 1,060 for the rest. Costs were priced per meter and then
subtracted like energy, and a PV-fed meter was priced at the grid tariff. A cost flow needs an
average price per kWh across grid, PV and gas engine first, which is out of scope. Migration 062
removes `p_is_cost` from the functions, and the old dashboard's `is_cost` variable has no effect
on these panels.

## Running beside the old panel

Keep both panels for a month before retiring the old one (`design/graph-sankey.md` §8, step 5).
Compare whole months. The new Production and Utilities totals should differ from the old by what
the reconcile explains: double counts gone, PV that was missing, Unassigned drawn as its own box,
and the corrections of migrations 046–058. Meter 74 read a third of Spinning 3 until 2026-10-20,
so months up to then show Spinning 3 as a negative residual in diagnostics.
