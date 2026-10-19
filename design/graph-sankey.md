# `graph.sankey` — a sankey that follows the graph

**Status: built, on dev and production since 2026-10-19** (migrations 053 and 054; §10; 055 corrects the graph). Proposed 2026-10-15. It follows from the audit in
`design/graph-reconcile.md` (§1.9; local, gitignored) and extends the functional view in
`design/graph-network-design.md` §15: solve once on the physical graph, then roll the solved
values up the `FUNCTIONAL` category tree.

## 1. The requirement

> Every node (and so every device) inserted into the graph is picked up by the sankey
> automatically.

Today's dashboard (`prs.get_sankey_energy_flow`) names devices in `IN (...)` lists. It went
stale three ways, all documented in the audit:
- it missed two PV plants that were added later (167, 168);
- it read a PV meter as a compressor (27 for "Comp A5");
- it added nested meters together (74 ⊃ 72, 73, 105; 26 ⊃ 98).

So the rule for `graph.sankey` is that it **names no device and no node**. It names node
classes, node types and categories, and reads everything else from the graph in effect on
`as_of`.

## 2. Pipeline

```
graph.solve_flow(tenant, 'ELECTRICITY', start, end, 124, is_cost, shifts, as_of)
        │   _gn (node values), _ge (edge values)
        ▼
own value per node         (§3)  — partitions the supply; no meter counted twice
        ▼
category per node          (§4)  — explicit row > type default > inherited > Unassigned
        ▼
links                      (§5)  — sources → Supply → category tree → nodes
```

## 3. Each node's own value

A node's **own** value is the energy it consumes itself, net of whatever it passes on:

| node | own value |
|---|---|
| `SOURCE` valued `MEASURED` or `IN_EDGES` | value − Σ out-edge values: what its meter reads that no feed accounts for (§9.7), drawn under Unassigned as "*name* (unaccounted)" |
| other `SOURCE`, `STORAGE`, `SINK` | none (sources appear on the supply side, §5) |
| leaf (no flow-carrying out-edge) | its solved value |
| node with out-edges, valued `MEASURED` or `IN_EDGES` | value − Σ out-edge values, i.e. the `__UNACCOUNTED` residual `get_sankey_flow` already computes |
| node with out-edges, valued `OUT_EDGES` or `CHILDREN` | 0 (its value *is* its children; there is no residual to claim, §5.4 of the network design) |

Over the whole graph, Σ own values = Σ source out-flows. This is where the nesting errors
disappear. 74 contributes only 74 − 72 − 73 − 105 − 140, and 26 only 26 − 98 − 135, because
the meters below them are counted on their own nodes.

**PV and feeders need no special case.** A meter on a node reads everything through that node.
A meter on a feeder edge reads only that feeder. Once migration G6 moves device 28 to its
feeder (A5's meter is upstream of the PV junction), the solver gives every board load
correctly: A4 = 26, B2 = 12, Texture 2 = 163, A5 = 28 + 27. It also gives every grid feeder:
26 − 167, 12 − 11, 163 − 168, and 28. Checked on dev with made-up kWh (audit §1.6.1).

**Negative own values** are not energy. They are a meter disagreement: the children sum to
more than the parent, for example 72 + 73 + 105 + 140 > 74 in some window. They are returned
as a diagnostic (§6), never drawn and never netted silently against another node.

**Reverse flow.** A grid feeder behind a board meter that includes PV (A4, B2, Texture 2) is
unmetered, so when PV outruns the board's load the solver returns it as a negative edge. Today
`get_sankey_flow` drops it (`value > 0`). `graph.sankey` draws it as an **Export** link from
the board to the grid, sized by the negative value, so the supply side still balances. For A5
the export is measured directly, as 28's received energy (quantity 131). Daily sums will
rarely reverse; sub-day windows can.

## 4. Each node's category

The order of precedence:

1. **Explicit** — a `graph.node_category` row on the node (`resolve_category`, `hops = 0`).
   Weighted splits keep working.
2. **Type default** — a new table `graph.node_type_category (tenant_id, node_type,
   taxonomy_code, category_id)`. It is tenant-scoped because categories are. Proposed seed for
   tenant 3:

   | node type | category |
   |---|---|
   | `AIR_COMPRESSOR` | COMPRESSOR |
   | `BOILER` | BOILER |
   | `AHU` | HVAC |
   | `LIGHTING` | LIGHTING |

   `PUMP`, `GENERIC_LOAD`, `PRODUCTION_MACHINE`, `PROCESS_HEATER` and the boards get **no**
   default. A pump may be chiller-side (`COOLING2`) or wastewater (`WWTP`). A generic load may
   be a workshop or a lab. A production machine's department comes from its board. These types
   fall through to inheritance.
3. **Inherited** — the nearest categorised ancestor (`resolve_category`, `hops > 0`).
   Ambiguity stays visible (`is_ambiguous`).
4. **Unassigned** — drawn as `Unassigned` under the root, one node per uncategorised node, so a
   new node with no home shows up on the diagram the day it is inserted. Today it would have
   vanished into the Production residual.

Type defaults come before inheritance so that a utility on a production board leaves that
board's category without needing a row: `AHU_LINE3` under the COMPRESSOR-tagged Spinning 3
becomes HVAC by type. A new compressor lands in Compressor the day its node is inserted.

**Residuals of nodes with children.** The residual is the node's unmetered loads. Proposed
order: explicit row on the node, then **the shared category of its unmetered children if they
all agree**, then inherited, then Unassigned. Examples:
- `LVMDB_A5`'s unmetered children are `COMP_300HP` and `COMP_400HP`, so its residual is
  COMPRESSOR with no row on the board.
- `LVMDB_A4` has an explicit HVAC row, so its residual (`COOLING2`, the chiller side) is HVAC,
  which is the decided chiller.
- `COMP_INTERLACE` (73) has both lighting and compressors unmetered below it, so its residual
  falls back to its own category, COMPRESSOR.
- `FINISHING_21` keeps its explicit BOILER row (audit G4).

Coverage on dev, 2026-10-15, with the four type defaults and today's `node_category` rows:
34 consuming nodes resolve without a row (25 by type, 9 by inheritance), and **28 come out
Unassigned**:
- the main boards (`LVMDB_A1/A2/A5/B2`, `LVMDB_TEXTURE`, `LVMDB_TEXTURE_2`, `LVMDB_TF630`,
  `LVMDP_SPINNING_1/2`, `FACTORY_AB`), whose residuals are offices, lighting and unmetered
  loads;
- `MC_SP_A/B/C`, `LVSDP_SP2_1/2`;
- `HEATER_5/6/11` and `HEATER_TOTAL`;
- `MC_MOTOR_5/6`, `TRICOT`, `TWIST_PANEL`;
- `COOLING1`, `OFFICE`, `OFFICE_2`, `LABKNIT` and `FLR_124`.

The residual rule above takes `LVMDB_A5` out of that list. The rest is the G3 worklist: one row
on a board covers everything below it.

## 5. Links

| level | link | value |
|---|---|---|
| 1 | each `SOURCE` node → **Supply** | the source's out-flow (`GRID_INCOMER`, every `PV_PLANT`, `GAS_ENGINE`) |
| 2 | Supply → each top-level category (Utilities, Production, Unassigned) | Σ own values under it |
| 3… | category → child category, down the `FUNCTIONAL` tree | Σ own values under it |
| leaf | leaf category → node (optional detail level) | the node's own value (weighted by `node_category.weight` when split) |
| — | board → **Export** | negative solved grid feeders (§3). **Not built in v1** (§9.6): reported as diagnostics |

"Purchased Energy" is renamed Supply: PV is not purchased. The grid alone is the
`GRID_INCOMER` link. The `PURCHASED_ENERGY` category row is renamed in the same migration as
the type defaults.

Every label is `node_name` or `category_name`. Every colour is `category.display_color`
(NULL everywhere today; populate it), and a node inherits its category's colour. The panel
draws whatever comes back and hardcodes nothing. The `PLT SA` / `PLT SB` colour-key mismatch
then can't recur.

## 6. Interface

As built (054):

```sql
graph.sankey(p_tenant_id int, p_start date, p_end date,      -- p_end inclusive
             p_as_of date DEFAULT NULL,                      -- NULL = p_end
             p_quantity_id int DEFAULT 124, p_is_cost boolean DEFAULT false,
             p_taxonomy varchar DEFAULT 'FUNCTIONAL', p_node_detail boolean DEFAULT true)
RETURNS TABLE(source text, target text, value numeric, color text,
              link_kind text,         -- SUPPLY | CATEGORY | NODE
              is_ambiguous boolean)   -- from the solver or the category resolution

graph.sankey_diagnostics(<same arguments but p_node_detail>)
RETURNS TABLE(node_code text, kind text, value numeric, detail text)
  -- NEGATIVE_RESIDUAL, NEGATIVE_FLOW, NO_DATA, REVERSE_ENERGY,
  -- UNASSIGNED, AMBIGUOUS_CATEGORY, AMBIGUOUS_FLOW

graph.sankey_nodes(<same arguments but p_node_detail>)
RETURNS TABLE(node_id, node_code, node_class, label, val_src, value, own,
              category_id, category_how, weight,   -- EXPLICIT | TYPE | CHILDREN | INHERITED | UNASSIGNED
              category_ambiguous, flow_ambiguous, has_data)
```

`sankey_nodes` is the per-node table the other two read; a table panel can read it too. The
utility comes from the quantity (`graph.quantity_rule`). With `p_node_detail = false`, nodes on a
category that has child categories (`WORKSHOP` on Production) are still drawn, since nothing else
carries their energy.

- **Dates, not timestamps.** `daily_energy_cost_summary` is daily, so a 6-hour Grafana range
  can't be resolved. The panel passes `$__from` / `$__to` as dates in `Asia/Jakarta`, and the
  function never truncates to the month (today's function silently shows month-to-date).
- **One set of rows per call.** A multi-month range is one diagram. Today's per-bucket rows
  produce duplicate links.
- `p_as_of` defaults to `p_end` (passed as NULL), not `CURRENT_DATE`, so a past window is drawn with the graph
  that was in effect then. That matters for 158/159 and anything retired later.

## 7. Before it can be trusted

From the audit's corrections list:

| # | needed for | status |
|---|---|---|
| G6 | A5's load and grid feeder | **migration 046, applied on dev 2026-10-19**; A5 = 28 + 27 confirmed on September data |
| G2 | WTP 1 / WTP 2 labels | **migration 047, applied on dev 2026-10-19** |
| G7 | the chiller formula | **settled 2026-10-19**: 26 + 167/3 − 98 − 135, a stopgap until the site fixes A4's point of common coupling |
| G8 | meter 26 reads the A4 board on two phases and the grid feeder on one (a PCC mistake) | **migration 048, applied on dev 2026-10-19**: 167 × ⅓ added to the `LVMDB_A4` node (§9.2) |
| G9 | `LVMDB_TEXTURE` out of service since 2026-05-11 | **migrations 049 and 050, applied on dev 2026-10-19**: its 20 live edges end 2026-05-11, the day of meter 107's last reading (§9.3) |
| G10 | meter 74 (Spinning 3) reads about 1/3 of its children | **phase-B CT reversed** (per-phase check, §9.4); site to fix; no correction in the graph (user, 2026-10-19) |
| G11 | the gas engine's share of A1–A3 | **migration 051, applied on dev 2026-10-19** (§9.5): gas engine 234,879 kWh in September; `FACTORY_AB` residual 0 |
| G12 | `COMP_WINDER` fed from `LVSDP_COMP_23`, not `LVMDP_SPINNING_3` (user, 2026-10-19) | **migration 052, applied on dev 2026-10-19**: only `LVSDP_COMP_23` changes (42,696 → 154,372 kWh) |
| G13 | `SIPPA` fed from `WWTP`, not `FINISHING_22` (user's SLD, 2026-10-19) | **migration 055, applied on dev and production 2026-10-19**: `WWTP` retyped `SUB_BOARD`; `FINISHING_22`'s negative residual gone (§10) |
| G3 | the Unassigned nodes; `WORKSHOP` → PRODUCTION (decided 2026-10-19, **row added by 053**); `WWTP`, `LAB_DEVICE` homes | partly superseded by §4; rows for the rest (§10) |
| G1 | A3 unmetered loads | `LVMDB_A3` stays HVAC for now (2026-10-19); waiting on the SLD load list |
| G4 | Finishing 2.1 unmetered loads | open; nothing from site yet |

**Validation** needs real telemetry. Dev has none until `tools/dev_refresh.sh --telemetry`,
which reads production and so needs your go-ahead. Checks for one month:
1. Σ level-1 = 94 + 11 + 27 + 167 + 168.
2. Σ own values + Export = Σ level-1, to rounding.
3. The decided proxies: Comp A5 = 28 + 27, Comp SP3 = 74 − 140, Chiller A4 = 26 − 98 − 135,
   Boiler includes 3 and 8.
4. The new Production total against the old residual. The difference should be what the audit
   predicts: the double counts that are gone, plus the PV that was missing.
5. Every row of `graph.sankey_diagnostics` reviewed. A NEGATIVE_RESIDUAL is a meter or topology
   question for the site.

## 8. Build order

1. G6 (and G2), each its own migration. **Done: 046, 047.**
2. `graph.node_type_category` and its seed, the `PURCHASED_ENERGY` → Supply rename, and
   `display_color`. **Done: 053.**
3. `graph.sankey` and `graph.sankey_diagnostics`, with the checks in §7 as the migration's
   self-test. **Done: 054.** The self-test checks the balances on September 2026 rather
   than on synthetic data: they hold on any data, so they run again unchanged on production.
4. G3 rows for whatever is still Unassigned after a real-telemetry run.
5. The Grafana panel: query `graph.sankey`, and drop the colour map and the month subtitle.
   `prs.get_sankey_energy_flow` stays until the new panel has run alongside it for a month.

## 9. First real-data run (September 2026, dev, 2026-10-19)

Dev was rebuilt from production with September telemetry. `daily_energy_cost_summary` is a
production table the refresh does not copy, and its refresh function needs TimescaleDB, so dev's
copy was filled for kWh only (124, 131) from `telemetry_intervals_cumulative`: one row per device,
Jakarta day and quantity, all under `SHIFT1`. Shift and tariff splits are irrelevant to a
three-shift kWh sankey. The prototype ran §2–§5 inside a rolled-back transaction, with no objects
created. Note that `device_totals` treats `p_end` as **inclusive** (`daily_bucket <= p_end`), so a
September window is `2026-09-01`..`2026-09-30`.

Decisions taken on 2026-10-19:
- Unassigned (and unmetered residuals with no category) is drawn as its own visible box under
  Supply. It is not assumed to be Production or Utilities.
- "Purchased Energy" is renamed Supply.
- `WORKSHOP` → PRODUCTION. `LVMDB_A3` stays HVAC until G1.
- The Export link is investigated before it is built (§9.6).

### 9.1 Results, kWh

| | after 046/047 | + G8 and G9 simulated (G8 as a feeder meter) |
|---|---|---|
| Supply (drawn) | 2,631,791 | 2,399,847 |
| Σ own values | 2,515,819 | 2,399,847 (balances) |
| Production | 1,252,538 | 1,252,538 |
| Utilities | 991,635 | 1,092,071 |
| Unassigned | 448,479 | 250,705 |
| LVMDB_A5 load | 61,188 = 28 + 27 | same |

After 048 and 049 as applied (G8 as the phase-B correction): supply and Σ own values both
2,399,847; Production 1,252,538; Utilities 1,018,424; Unassigned 295,684; HVAC 317,634;
A4 = 189,256; chiller 26,789; `FACTORY_AB` residual +44,979 (G11). 050 changes no September value.
After 051: supply and Σ own values both 2,354,868, gas engine 234,879, `FACTORY_AB` residual 0.

| Chiller (A4 residual) | −10,034 (negative) | 100,436 = 26 + 167 − 98 − 135 |

Grid meter 94 read 1,961,384. The PV meters read 110,470 (A4), 49,764 (A5), 85,722 (B2) and
113,123 (Texture). The gas engine is drawn at 279,858, which is an even-split artefact (§9.5).

### 9.2 G8: meter 26 and A4's point of common coupling

Hourly totals for September, each the sum of 30 days:
- At night, 26 reads about 7,600 and compressor 98, which sits below it, about 6,500.
- From 09:00 to 14:00, 26 falls to about 3,000–4,000, while 98 stays at about 6,500.
- 26 also registers 312 kWh of received energy.

The per-phase active power locates the cause. September hourly means, in kW:

| | night | 10:00 |
|---|---|---|
| 26 phase A | 88 | 85 |
| 26 phase B | 92 | −77 |
| 26 phase C | 83 | 88 |
| 167 per phase (A ≈ B ≈ C, within 1%) | 0 | 163 |

Only phase B dips, and by PLTS A4's phase-B output. The user traced it on 2026-10-19 to a mistake
in A4's point of common coupling. On two phases the PV joins before meter 26, so the meter reads
grid + PV, i.e. the load. On the third it joins after, so the meter reads the grid only. The user
named that phase T; the meter labels it B.

So 26 = A4 load − ⅓ × 167, and with a balanced inverter:
- A4 load = 26 + 167/3 = 189,256 kWh;
- grid feeder = 26 − ⅔ × 167;
- A4 residual (the chiller side) = **26 + 167/3 − 98 − 135** = 26,789 kWh.

Migration 048 adds a second TOTAL row on the `LVMDB_A4` node: device 167 × ⅓, from
`'-infinity'`. The solver already sums a node's rows with their multipliers, so no code changes.
When the site corrects the PCC, the row ends on the last day before the fix.

**For readers of meter 26:** its per-phase power, current and power factor are the grid's on
phase B and the board's on A and C. The MCP `node_meters` tool shows the ⅓ multiplier but not
this.

### 9.3 G9: LVMDB_TEXTURE

Its 20 live edges were the incomer's transformer, 18 board feeds and a capacitor bank. So the
solver gave it its children's full load in (rule c, from children) while splitting each child's
feed evenly with Texture 2. Half the load (115,972 kWh in September) entered `LVMDB_TEXTURE` and
left nowhere. It also inflated Texture 2's residual (139,533, against 23,561 with the edges
closed).

The latest bucket of its meter (107) in production's `telemetry_15min_agg` is on 2026-05-11
(checked by the user, 2026-10-19). A document of 2026-08-18 only records Texture 2's new meter.
Migration 049 first ended the edges on 2026-08-17, and migration 050 moves that back to
2026-05-11, taking the meter's last day as the board's (valid time). Texture 2's edges still start
at `'-infinity'`, so before 2026-05-12 both boards remain parents.

### 9.4 G10: meter 74 (Spinning 3)

The user rechecked the Spinning 3 tree on 2026-10-19. `LVSDP_COMP_23` feeds both `COMP_INTERLACE`
(73) and `COMP_WINDER` (72), and `LVSDP_PROD_ATY` feeds `COMP_AIKI` (105). Migration 052 fixes
`COMP_WINDER`'s feed (G12). The user confirmed the meter gap: 105 alone registers far more than
74, which is being asked of the site.

The ratio of (72 + 73 + 105) to 74 holds at 3.0–3.15 every day of September, while the children's
load ranges from about 1,000 to 11,000 kWh a day. A constant ratio across varying load is a scale
error, not topology.

**Per-phase check (dev, 2026-10-19): phase B reads reversed.** September means for 74: P_A 106.9,
P_B **−112.7**, P_C 111.9 kW, with balanced currents (488 / 510 / 512 A). Phase B is negative in
every 15-minute interval, A and C never. So the meter computes A − B + C, about ⅓ of the load: a
reversed CT on phase B (polarity, or S1/S2 swapped at the meter). With B's sign flipped, the
children read 0.97–1.00 of 74 on all 30 days; the rest is `AHU_LINE3` (140, silent in September)
and unmetered load. The Spinning 3 tree is right. This is not meter 26's fault: 26's phase B is
positive at night and dips only with PV.

The incomer: 94's six feeds (84, 85, 90, 163 − 168, 74, 106) sum to 1,760,911 against 94's
1,961,384. With 74 corrected (75,384 → about 235,700), the gap falls from 200,473 to about 40,000,
2.0% of 94, a plausible size for transformer losses between the MV meter and the LV feed meters.

**Decision (user, 2026-10-19): no correction in the graph.** 74 stays as read, so
`LVMDP_SPINNING_3` stays a NEGATIVE_RESIDUAL of −156,202 and 94 keeps its 200,473 unaccounted: a
fault to act on, not to hide in the dashboard. For the site: check the polarity of meter 74's
phase-B CT. After the fix, the counter's past readings stay wrong; only the per-phase power could
rebuild them.

### 9.5 G11: the gas engine

`LVMDB_A1`–`A3` each have two unmetered in-edges, `FACTORY_AB` and `GAS_ENGINE`, so rule (b)
splits each board 50/50. That draws the gas engine at half of 23 + 24 + 25 (279,858) and leaves the
error on `FACTORY_AB` as a residual (+44,979 after 048–050). `FACTORY_AB` is an `MV_BUS` that
consumes nothing itself, so the total is determined:

- Σ(FACTORY_AB → A1..A3) = 84 − (26 − ⅔·167) − 28 − (12 − 11) = 324,837
- gas engine = 23 + 24 + 25 − 324,837 = **234,879** (42% of A1–A3)

Computed hourly, the same balance shows the engine is **not 24/7, and runs in campaigns**:
- September 1–14: about 87–90% of A1–A3 every day.
- September 15: stopped partway through the day.
- September 16–30: off.
- September 6, 24 and 25 are distorted by telemetry gaps.

The 2–5% left on off days (about 500 kWh a day) is the LV meters reading slightly *more* than
84 accounts for. Transformer losses would have the opposite sign, so this is meter disagreement,
and the rule assigns it to the engine. Even while running, the engine left about 2,000 kWh a day to
the grid. An even split would have invented about 140,000 kWh of gas output in the second half of
the month.

**The change**, migration 051 (applied on dev 2026-10-19). Its section 2.3 solves the windows
below before and after, inside the transaction, and aborts if anything outside the engine and
its six edges moves:
1. `FACTORY_AB.is_passthrough = TRUE`.
2. **New rule (a2).** For a passthrough node with a known value and several out-edges, its
   unknown out-edges carry value − known out-edges. Once every one of them leads to a valued target
   that has another unknown in-edge, that sum is split in proportion to the targets' values. The
   split is **capped**: never below 0 and never above the targets' total, and anything beyond stays
   on the parent as its residual. The edges are flagged ambiguous when there is more than one.
3. **Rule (b) splits evenly only as a last resort.** In the main loop it fills an in-edge only
   when it is the target's last unknown, and the result inherits the ambiguity of its siblings. The
   even split across several unknown in-edges moves to the exhaust phase, before rule (d).

**Impact, all quantities and windows compared** (124 and 89 for the month, September 5 and
September 20; water 5696 for the month and September 5):
- **What changes:** the `GAS_ENGINE` node and the six edges into A1–A3, and nothing else.
  `FACTORY_AB`'s residual follows from them.

  | | old | new |
  |---|---|---|
  | gas, kWh, September | 279,858 | 234,879 |
  | gas, kWh, Sept 5 (running) | 9,376 | 16,371 |
  | gas, kWh, Sept 20 (off) | 8,643 | 559 |
  | gas, kvarh, September | 234,273 | 45,487 |
  | gas, kvarh, Sept 20 | 7,753 | 0 |
  | `FACTORY_AB` residual, kWh, September | +44,979 | 0 |

- **Unchanged:** every other node and edge, in electricity and in water. The 15 water tanks and
  softeners already flagged passthrough did not trigger rule (a2), and deferring the even split
  changed no water value. That holds for September's data; a different flow pattern could trigger
  them.
- **Why the cap is needed:** reactive energy is not conserved across the transformers between 84
  and the board meters, which absorb reactive power. Uncapped, the engine on September 20 came out
  at −5,218 kvarh. Capped, it is 0 and the 5,218 stays on `FACTORY_AB` as transformer reactive
  losses. A monthly solve still nets the off days against the on days (45,487 kvarh); a sum of
  daily solves would not.
- **Readers:** only `solve_flow` reads `is_passthrough` (no view, MCP tool or other function).
  Through it, `get_node_quantity` (the MCP `node_value` tool), `get_node_derived` (the engine's PF
  from P and Q), `get_node_values`, `get_sankey_flow` and `graph.sankey` see the new engine and edge
  values. A1–A3's own values and categories are unchanged, because their meters fix them. `prs.*`
  functions do not read the graph.
- **History:** solver results are computed on read, so every past window changes with the
  function, which is intended. The engine's per-board split stays proportional and flagged
  ambiguous; a meter on the engine's output would make it exact. That is worth asking the site.

### 9.6 Export

After 046, the monthly September solve has no negative edge. The only one before it, −38,340 on
`FACTORY_AB → LVMDB_A5`, was the G6 error. Solving each day separately with G8 and G9 simulated
gives one negative edge on one day: `INCOMING_PLN → LVMDB_TEXTURE_2` on 2026-09-08 (−2,516). Every
meter shows a catch-up spike in the 08:00 and 09:00 hours that day, so it reads as a telemetry
gap, not export.

Real reverse flow does exist at 15-minute resolution, in the received-energy registers (131):
- 26: 312 kWh
- 84: 1,472 kWh
- 94 (the grid): 11 kWh
- 28, 12 and 163: 0

That is under 0.1% of supply. Recommendation: no Export link in the first version. The solver
reads 124 only, and a diagnostic reports any 131 above a threshold. Revisit if a PV plant is added
or the window drops below a day.

### 9.7 What this changes in §3–§5

- **Source residual.** A measured `SOURCE` whose out-edges sum to less than its meter (94: 200,473)
  gets a link to Unassigned, labelled as unmetered or losses, so the supply side shows the meter.
- **Negative own values** stay out of the links, as §3 says. While G10 is open, the positive
  values sum to 195,467 more than supply. Diagnostics must show this next to the diagram.
- **Type defaults** cover 25 nodes but only 2,669 kWh in September, because most of those nodes
  are unmetered and get no value of their own. Explicit rows still carry 85% of the energy.
- **Unassigned with value after 048/049** (plus `FACTORY_AB`'s +44,979, which G11 removes): the residuals of Spinning 2 (80,865), Spinning 1
  (60,764), TF630 (32,173), B2 (24,597), Texture 2 (23,561) and A1 (3,259); `MC_MOTOR_5` (25,246,
  metered with no category); `HEATER_TOTAL` (239). This is the G3 worklist.

## 10. As built (migrations 053 and 054, dev, 2026-10-19)

**053** adds `graph.node_type_category` (per tenant and taxonomy; a composite foreign key keeps
the category in both; abstract types refused, and a type with a default can't be made abstract),
seeds the four defaults of §4, renames the root to `SUPPLY` / Supply, gives all 28 categories a
colour (Utilities warm, Fabric blue and teal, Yarn violet; Unassigned is grey in the function, not
a row), and adds `WORKSHOP` → PRODUCTION.

**054** adds `graph.sankey_nodes`, `graph.sankey` and `graph.sankey_diagnostics` (§6). Two
departures from §4:
- **Inheritance walks the solver's edges and stops at a type default too.** `resolve_category`
  stops only at explicit rows, so a pump under `AHU_LINE3` would have inherited Compressor from
  Spinning 3. Several ancestors at the same distance share the node evenly, flagged ambiguous.
- **The CHILDREN rule reads only unmetered children, so a single unmetered child decides a
  board's residual.** `TRICOT`'s residual is now HVAC (its only unmetered child is `AHU_14`), and
  a new unmetered compressor on `LVMDB_A1` would turn A1's residual into Compressor. That is the
  rule as designed; an explicit row on the board overrides it.

The self-test (054 §4) checks September 2026 and aborts the migration if any of these fail: weights
sum to 1 per node; supply = Σ own values; the root and the NODE links each carry exactly the
positive own values; every category passes on what it receives, with and without node detail;
positive + negative = supply; no self-link, non-positive link, missing colour, or source label
used as a target. A call takes about 130 ms on dev; `grafReader` can run all three.

September 2026 on dev, kWh:

| | |
|---|---|
| Supply (6 sources) | 2,555,340: grid 1,961,384, gas 234,879, PV 113,123 + 110,470 + 85,722 + 49,764 |
| Utilities | 1,018,424 (Compressor 579,467, HVAC 317,634, Boiler 73,623, WTP 45,694, Lighting 2,006) |
| Production | 1,252,538 (Fabric 953,665, Yarn 298,006, Workshop 867) |
| Unassigned | 451,177, of which 200,472 is meter 94 beyond its six feeds |
| negative residuals (not drawn) | −166,799 |

Category by: EXPLICIT 73 nodes (1,969,943), TYPE 25 (2,669), CHILDREN 2 (64,372: `LVMDB_A5`,
`TRICOT`), INHERITED 8 (68,136), UNASSIGNED 31 (450,221).

Diagnostics:
- **NEGATIVE_RESIDUAL**, 3 rows. `LVMDP_SPINNING_3` −156,202 (G10). `FINISHING_22` −9,641: its meter (5)
  reads 76,848, and `SIPPA` (138) + `WWTP` (139) below it read 86,489. `LVMDB_A2` −956: 24 is 0.5%
  under its six metered children, a site question.
  - `FINISHING_22` was the SLD (G13). SIPPA's load shows inside 139: over 31 steps of more than
    10 kW, 139 moved by 0.95 × SIPPA's step in the same 15 minutes (r = 0.85), with the same per-phase
    currents, and the residual was negative only on days SIPPA ran. The user's SLD has WWTP feeding
    SIPPA. **Migration 055 (dev)** retypes `WWTP` to `SUB_BOARD` and moves SIPPA under it
    (`'-infinity'` correction). Own values: `FINISHING_22` +4,102, `WWTP` 59,002; Garuk 76,848 = meter 5
    (86,489 before); nothing else moves.
- **NO_DATA**, 7 meters in effect with no September reading: 88 (`AHU_LINE1`), 140 (`AHU_LINE3`),
  64, 59, 62, 63 (`HEATER_10/11/7/8`; 8 is inactive), 81 (`MC_SP_I`).
- **REVERSE_ENERGY**, 2 meters at 0.1% or more of delivered: 84 (1,472) and 26 (312).
- **UNASSIGNED**, 9 rows with value: the G3 worklist of §9.7, plus 94's unaccounted 200,472.
- **AMBIGUOUS_FLOW**: the gas engine's six edges.

**Two broad classes only** (user, 2026-10-19). The client asks for Production and Utilities, so
there is no Office or General & Admin category until the client asks for one or says offices
should come out of Production; then the boards are classified panel by panel from the SLD, not
guessed. The SLD already has two unmetered office feeds, `OFFICE` (Office RND, on A2) and
`OFFICE_2` (Office TF630kv), left without a row. **Migration 056 (dev)** puts `FLR_124` (Work Panel
Fl. 1, 2, 4, the only unmetered panel on Spinning 1) under Production, so Spinning 1's residual
(60,764) moves from Unassigned to Production through the CHILDREN rule.

**Deferred: a tolerance for small residuals** (user, 2026-10-19). `LVMDB_A2`'s −956 (−0.54%) is
meter tolerance, not a fault: no reversed phase, 24 tracks its children at r = 0.989, and the gap
(−10.9 to +7.5 kW, 90% of intervals) does not depend on load (r² = 0.01). Yet
`sankey_diagnostics` reports it as NEGATIVE_RESIDUAL beside Spinning 3's −156,202. A later
version could report residuals within about ±1% of the node's value as their own kind
(METER_TOLERANCE), still shown, so real faults stand out. One consequence to keep in mind: a
board's small unmetered loads (`COOLING1`, `OFFICE` on A2) sit inside that tolerance and are
invisible either way.

On production since 2026-10-19 (053–055; same September figures as dev). Still to do: the G3 rows, then the Grafana panel (§8 items 4 and 5).
