# Step 2 — typed edges: relation types, endpoint rules, edge properties

**Status:** **APPLIED to valkyrie 2026-09-28.** 027 then 028, both committed, both rehearsed
under ROLLBACK against live first. 218 edges typed across 10 relations, 0 illegal endpoints,
12 transformers named, and solver equivalence proven 0/0 on all five entry points against
real data. `graph_snapshot.py` updated to print the relation on each edge.
**Date:** 2026-09-28
**Migrations:** `027_fix_pv_injection.sql`, `028_create_edge_type.sql`, `029_fix_edge_gaps_window.sql`
(+ `028_pre_solver_bodies.sql`, the pre-028 solver definitions its undo needs)


---

## 1. Why

Step 1 typed the nodes. A node now says what it *is* — `AIR_COMPRESSOR`, `MAIN_LV_BOARD`,
`CAPACITOR_BANK` — and every attribute it carries is validated against a vocabulary.

The edges say almost nothing. There are 250 active edges in tenant 3 and they use three
labels between them:

| `edge_class` | utility | edges | edges with `attrs` |
|---|---|---:|---:|
| `FEEDER` | ELECTRICITY | 200 | 0 |
| `PIPE` | WATER | 39 | 0 |
| `COMPENSATION` | ELECTRICITY | 11 | 0 |

Five more classes exist in `ck_edge_class` — `CABLE`, `BUSTIE`, `HEADER_BRANCH`, `DUCT`,
`CONVERSION` — and none has ever been used. The vocabulary was declared in 008 and never
applied.

`edge_class` also describes the wrong thing. It names the *conveyance* — a feeder, a pipe —
not the *relation*. That is why 200 electricity edges share one label while meaning at least
five different things, and it is why three specific facts about this site are currently
unrepresentable:

**The twelve transformers do not exist in the graph.** Every one of them is a plain `FEEDER`:

| from | from V | to | to V | to `rated_kva` |
|---|---:|---|---:|---:|
| `FACTORY_AB` | 20 000 | `LVMDB_A1` … `A5`, `B2` | 400 | 2000 |
| `INCOMING_PLN` | 20 000 | `LVMDB_TEXTURE` | 400 | 1600 |
| `INCOMING_PLN` | 20 000 | `LVMDB_TEXTURE_2` | 400 | 2000 |
| `INCOMING_PLN` | 20 000 | `LVMDB_TF630` | 400 | 630 |
| `INCOMING_PLN` | 20 000 | `LVMDP_SPINNING_1` … `_3` | 400 | 2000/1600/2000 |

Those twelve are exactly the twelve rows of `trafo_tenant_3.csv`, and the `capacity_kva`
column matches each board's `rated_kva` to the kVA. The transformer's own identity —
`TF_A1`, `TF_SPINNING_1` — appears nowhere in the database. A 20 kV → 400 V transformation
with losses is currently indistinguishable from a 400 V cable between two boards.

**`COMPENSATION` already carries solver semantics, hardcoded.** `graph.solve_flow` and
`graph.get_node_quantity` each contain `e.edge_class <> 'COMPENSATION'`, and 024 repeats the
same predicate twice more. A capacitor bank is not a flow path, and that fact is currently
expressed by pasting a string comparison into every query that traverses the graph. The next
non-flow relation — a standby tie, a metering-only link — needs the same edit in the same
four places, and nothing makes them stay in step.

**Direction of water is a guess.** Five `PIPE` edges run `LOAD → WATER_TANK` and one runs
`REACTION_TANK → WATER_TANK`. These are return or recovery legs, not supply. Counted as
supply they inflate intake. Nothing in the schema distinguishes them.

So: the same move as step 1, applied to relations. Keep `edge_class` as the conveyance,
add `edge_type` as the relation, and put the semantics that are currently pasted into SQL
into a table where the solver can read them.

---

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| 1 | Keep `edge_class`, add `edge_type` | Exactly the `node_class` / `node_type` split from 026. `edge_class` stays the conveyance (feeder, pipe); `edge_type` is the relation (transformer, PF compensation, water return). No existing constraint or query changes meaning. |
| 2 | Composite FK `(edge_type, edge_class)` → `edge_type (code, edge_class)` | Same device as `fk_node_node_type`. A `TRANSFORMER` edge cannot be labelled `PIPE`. MATCH SIMPLE skips the check while `edge_type` is NULL, so untyped edges are legal during the authoring pass. |
| 3 | `edge_type` is nullable | 026 left 98 loads untyped rather than inventing types. Same discipline: an edge with no confident type carries none and shows up in the gap view. |
| 4 | `carries_flow` is a column on `edge_type`, not a string test in queries | Turns `e.edge_class <> 'COMPENSATION'` into `WHERE et.carries_flow`. The rule stops being duplicated across four call sites. This is the edge counterpart of "the rating denominator is decided once". |
| 5 | Endpoint rules live in `graph.edge_type_endpoint` | The genuinely new capability, and one nodes could not provide: a relation constrains *what it may connect*. A capacitor bank feeding a load, or water flowing out of a load into an intake, becomes detectable. |
| 6 | Endpoint enforcement is **split**, exactly as 026 split attrs | Hard-reject only when both endpoints are typed; report everything else through a view. With 98 loads untyped, a hard rule would reject most of the graph. Present facts are validated; absent ones are reported. |
| 7 | **No edge properties in this step** | Corrected 2026-09-28. 026 already put the transformer's nameplate on the board node -- all 12 boards carry `rated_kva` and `tx_primary_v`, and `tx_impedance_pct` is already an allowed key there. Putting them on the edge as well would recreate the "one fact spelled three ways" problem step 1 removed. No edge carries `attrs` today and there is no edge-scoped fact waiting to be recorded, so `edge_type_property` and an edge attrs trigger would be machinery with nothing to hold. Deferred until an edge fact exists (`normally_open` on a bus tie is the likely first). |
| 8 | The transformer is the **edge**, not a new node | Adding 12 `CONVERSION` nodes would re-parent 12 boards, invalidate every `fed_by` in the seed CSVs, and change every path length the solver walks. The edge already sits exactly where the transformer sits. |
| 9 | `impedance_pct` is defined now even though we do not have it | It becomes a named MISSING row against `harmonics_report` instead of an absence nobody is tracking. See §6. |
| 10 | Unused classes stay in `ck_edge_class`, ungeseeded | `CABLE`, `BUSTIE`, `DUCT`, `HEADER_BRANCH`, `CONVERSION` get no `edge_type` rows until something uses them. Declaring types for hypothetical topology is how the current dead vocabulary happened. |

---

## 3. Schema

```sql
CREATE TABLE graph.edge_type (
    code         VARCHAR(40)  PRIMARY KEY,
    edge_class   VARCHAR(20)  NOT NULL,
    utility_code VARCHAR(20)  REFERENCES graph.utility (code),  -- NULL = any utility
    carries_flow BOOLEAN      NOT NULL,
    is_transform BOOLEAN      NOT NULL DEFAULT FALSE,
    description  TEXT         NOT NULL,

    CONSTRAINT ck_edge_type_code  CHECK (code ~ '^[A-Z][A-Z0-9_]*$'),
    CONSTRAINT ck_edge_type_class CHECK (edge_class IN
        ('FEEDER','CABLE','BUSTIE','PIPE','HEADER_BRANCH','DUCT','CONVERSION','COMPENSATION')),
    -- target of the composite FK from graph.edge
    CONSTRAINT uq_edge_type_code_class UNIQUE (code, edge_class)
);

ALTER TABLE graph.edge ADD COLUMN edge_type VARCHAR(40);
ALTER TABLE graph.edge ADD CONSTRAINT fk_edge_edge_type
    FOREIGN KEY (edge_type, edge_class) REFERENCES graph.edge_type (code, edge_class);

-- which (from, to) node kinds a relation may connect.
-- from_kind / to_kind hold a node_type code, or a node_class for the coarse rules
-- that must keep working while 98 loads are untyped.
CREATE TABLE graph.edge_type_endpoint (
    edge_type VARCHAR(40) NOT NULL REFERENCES graph.edge_type (code) ON DELETE CASCADE,
    from_kind VARCHAR(40) NOT NULL,
    to_kind   VARCHAR(40) NOT NULL,
    PRIMARY KEY (edge_type, from_kind, to_kind)
);

-- graph.edge_type_property and an edge attrs trigger are deliberately NOT created.
-- See decision 7: no edge-scoped fact exists to store yet, and the transformer's
-- nameplate already lives on the board node from 026.
```

`graph.v_edge_gaps` reports, per active edge: `UNTYPED` (no `edge_type`),
`ENDPOINT_UNTYPED` (a rule cannot be checked because an endpoint node is untyped), and
`ILLEGAL_ENDPOINT` (both endpoints typed and the pair is not permitted). It is the edge
counterpart of `v_property_gaps` and feeds the same site-check list.

---

## 4. Seed

### 4.1 Relation types

Every row below is grounded in edges that exist today; the counts are from live.

| `code` | `edge_class` | utility | `carries_flow` | `is_transform` | edges |
|---|---|---|:-:|:-:|---:|
| `GRID_INFEED` | FEEDER | ELECTRICITY | yes | no | 1 |
| `TRANSFORMER` | FEEDER | ELECTRICITY | yes | **yes** | 12 |
| `SUPPLY_LV` | FEEDER | ELECTRICITY | yes | no | 148 |
| `PV_INJECTION` | FEEDER | ELECTRICITY | yes | no | 4 (was 36 — see §7a) |
| `GENERATOR_INFEED` | FEEDER | ELECTRICITY | yes | no | 3 |
| `PF_COMPENSATION` | COMPENSATION | ELECTRICITY | **no** | no | 11 |
| | | | | | **179** electricity |

Electricity reconciles twice over. **Today**, before §7a: 148 + 12 + 36 + 3 + 1 = 200 FEEDER,
plus 11 COMPENSATION = 211. **After §7a**, which replaces 36 PV→load edges with 4 PV→board
edges: 148 + 12 + 4 + 3 + 1 = 168 FEEDER, plus 11 = 179. The 32-edge drop is the double-count
leaving the graph.
| `WATER_TREATMENT` | PIPE | WATER | yes | no | 20 |
| `WATER_SUPPLY` | PIPE | WATER | yes | no | 11 |
| `WATER_RETURN` | PIPE | WATER | yes | no | 6 |
| `WATER_TRANSFER` | PIPE | WATER | yes | no | 2 |
| | | | | | **39** = PIPE |

**The two incomers are modelled asymmetrically, and the transformer counts show it.**
`FACTORY_AB` is an `MV_BUS` feeding 6 transformers. `INCOMING_PLN` is a `GRID_INCOMER` that
feeds 6 transformers *directly*, with no MV bus node between. So `TRANSFORMER` has two legal
from-sides, and `GRID_INFEED` describes exactly one edge — `INCOMING_PLN → FACTORY_AB`.
Worth deciding later whether `INCOMING_PLN` should gain an MV bus for symmetry; it is not
required for this step and would move 6 edges.

`PF_COMPENSATION.carries_flow = false` reproduces `edge_class <> 'COMPENSATION'` exactly.
That equivalence must be proven row-for-row before 027 commits — see §7.

### 4.2 Endpoint rules

Derived from the live endpoint survey, which is already highly regular now that the nodes
are typed:

```
GRID_INFEED        GRID_INCOMER   -> MV_BUS
TRANSFORMER        MV_BUS | GRID_INCOMER -> MAIN_LV_BOARD
GENERATOR_INFEED   GAS_ENGINE     -> MAIN_LV_BOARD
PV_INJECTION       PV_PLANT       -> MAIN_LV_BOARD | SUB_BOARD
PF_COMPENSATION    MAIN_LV_BOARD | SUB_BOARD -> CAPACITOR_BANK
SUPPLY_LV          MAIN_LV_BOARD | SUB_BOARD -> SUB_BOARD | LOAD(class) | CONVERSION(class)
WATER_TREATMENT    WATER_INTAKE | CLARIFIER | SOFTENER | RO_UNIT | REACTION_TANK -> ...
WATER_RETURN       LOAD(class) | REACTION_TANK -> WATER_TANK
WATER_TRANSFER     WATER_TANK     -> WATER_TANK
```

`PF_COMPENSATION` is the sharpest of these: a capacitor bank may only ever be the *to* side,
and only from a board. The 11 live edges satisfy it.

### 4.3 Edge properties

None. See decision 7.

The transformer facts live on the board node, where 026 put them: `rated_kva`,
`tx_primary_v`, and `tx_impedance_pct` (allowed, not yet filled). The edge records that a
transformation happens -- `edge_type = 'TRANSFORMER'`, `is_transform = true` -- and the
nameplate stays in one place.

The one transformer fact recorded nowhere is the equipment's own name (`TF_A1`,
`TF_SPINNING_1`, from `trafo_tenant_3.csv`). That belongs beside the other transformer
attributes on the board, as a node property `tx_equipment_code`, not on the edge. §4.4 adds it.

### 4.4 One new node property: `tx_equipment_code`

`text`, kind `RECORD`, OPTIONAL on `MAIN_LV_BOARD`. Populated for all 12 boards from
`trafo_tenant_3.csv`, which is the only place those names currently exist. Small, and it
closes the last gap between that CSV and the database.

---

## 5. What this changes for the readers

- `solve_flow` and `get_node_quantity` drop the literal `edge_class <> 'COMPENSATION'` in
  favour of a join on `carries_flow`. **Behaviour must be identical on day one.**
- `harmonics_report.py` gains a real path to a per-board short-circuit estimate once
  `impedance_pct` is filled: `Isc ≈ rated_kva / (√3 · V · Z%)`, and with `I_L` already
  measured, the IEEE 519 table becomes selectable per board instead of the blanket strict
  5 % TDD currently applied to everything.
- `graph_snapshot.py` can print the relation on each edge, so a transformer stops looking
  like a cable in the topology dump.
- A new `graph.v_edge_gaps`, alongside `v_property_gaps`, reports UNTYPED edges,
  endpoint violations, and MISSING edge properties into the same site-check list.

---

## 6. The payoff worth naming -- and a correction

**Correction (2026-09-28):** an earlier draft of this section claimed that typing the
transformer edges would create twelve named slots for `tx_impedance_pct`. That was wrong.
026 already created them, on the board nodes. Nothing in this step is needed to hold the
value.

What is true, and still worth doing: the strict 5 % TDD limit applied to every board was
chosen *because* there is no impedance data. Twelve values off nameplates or test
certificates, with `I_L` already measured, would let the IEEE 519 limits be set per board on
the real `Isc/I_L` table rather than assumed worst case.

Two things stand between here and there, neither of them schema:

1. **The values.** `tx_impedance_pct` is empty on all 12 boards.
2. **A reader.** It is `OPTIONAL`, so `v_property_gaps` does not report it, and the project
   rule is that a property may only be `REQUIRED` if `used_by` names a reader that needs it.
   `harmonics_report.py` does not use it yet. Marking it `REQUIRED` before the reader exists
   would break that rule; leaving it `OPTIONAL` keeps it off the site-check list. **Worth
   deciding explicitly** -- the honest sequence is to teach the reader to use it, then make
   it required, then collect.

---

## 7. Test plan

Same shape as 026: build a local PostgreSQL 16 cluster from a live copy of `graph`, apply,
verify, then apply to valkyrie only on request.

1. `edge_type` seeded, all 250 active edges typed, 0 NULL `edge_type` — or an explicit list
   of those deliberately left untyped.
2. Endpoint check: 0 violations among edges whose endpoints are both typed.
3. **Solver equivalence.** Capture `graph.solve_flow`, `get_node_values`,
   `get_sankey_flow` and `get_node_quantity` output for tenant 3 before and after; require a
   row-for-row identical result. The `carries_flow` rewrite is only safe if it is a no-op.
4. Trigger rejection tests: unknown key, wrong datatype, out-of-range, a key not permitted
   on that relation, an endpoint pair not in `edge_type_endpoint`, and `null` accepted as
   UNKNOWN.
5. `v_edge_gaps` counts match the predicted MISSING list (24 = 12 × `impedance_pct` +
   12 × `vector_group`).

---

## 7a. Prerequisite: the PV edges are wrong, and they double-count

Confirmed from the SLD 2026-09-28: each PLTS has its own meter, and the board meter (e.g.
`LVMDB_A5`) is tapped *after* the PV tapping point, so **the board meter already includes the
PV contribution**. PV injects into the board; it does not feed machines directly.

The graph says otherwise. All 36 `PV_PLANT →` edges point at loads, and **every one of those
loads already has its board as a parent** — `COMP_300HP` is fed by both `LVMDB_A5` and
`PLTS_A5`. The PV edges are parallel paths to the same loads, and the board's own meter
already contains what they carry.

That is not a modelling preference. It is a live defect, measured on 2026-09-07…14,
quantity 124 (active energy delivered):

| PV node | measured generation | credited by `get_sankey_flow` | over-credited |
|---|---:|---:|---:|
| `PLTS_B2` | 22 130.3 kWh | 83 481.0 kWh | **+61 350.8 kWh** |
| `PLTS_A4` | 30 085.6 | 30 085.6 | 0 |
| `PLTS_A5` | 12 259.7 | 12 259.7 | 0 |
| `PLTS_TEXTURE` | 30 942.7 | 30 942.7 | 0 |

The B2 branch emits **every load twice at identical value** — `LVMDB_B2 → FINISHING_1` 21 118.7
and `PLTS_B2 → FINISHING_1` 21 118.7, and the same for all 13 loads. Anyone summing Sankey
links by target sees each B2 load at twice its true consumption, and PLTS_B2 credited with
3.8× the energy it generated.

`PLTS_A5` looks clean only because its loads measured 0 kWh that week; `PLTS_A4` and
`PLTS_TEXTURE` happen to reconcile in this window. The defect is structural, not confined to B2.

### The fix

Replace the 36 `PV_PLANT → load` edges with 4 `PV_PLANT → board` edges:

```
PLTS_A4      -> LVMDB_A4
PLTS_A5      -> LVMDB_A5
PLTS_B2      -> LVMDB_B2
PLTS_TEXTURE -> ?            -- see Q2 below
```

The loads keep their existing board parent and are unaffected. Grid import at a board then
becomes `board_meter − PV_meter`, which is what the SLD describes.

**This belongs in its own migration, before the typing.** Same sequencing as 025 → 026: fix
the topology first, then type it. `027_fix_pv_injection.sql` was **APPLIED to valkyrie
2026-09-28**: rehearsed under ROLLBACK first, then committed. 36 edges removed, 4 added, 218
active / 4 inactive, and `PLTS_B2`'s credit fell from 83 481.0 to 22 130.3 kWh against 22 130.3
measured. The rehearsal earned its keep — it caught a `DELETE` missing `AND e.is_active` that
would have destroyed retired edge 178 (`PLTS_TEXTURE → MC_MOTOR_13`) while every active-edge
post-condition still passed. `028` takes the
edge types. Typing edges that are pointing at the wrong nodes would only make the error
harder to see.

`PV_INJECTION`'s endpoint rule tightens accordingly, and becomes the guard that stops this
recurring:

```
PV_INJECTION       PV_PLANT -> MAIN_LV_BOARD | SUB_BOARD
```

---

## 8. Open questions

These change the seed and I cannot settle them from the data.

**Settled 2026-09-28.** `HEATER_TOTAL` is a real panel: `HEATER_5` and `HEATER_6` are
confirmed unmetered loads under it, so the head-plus-residual reading was right. The 12
`LOAD -> LOAD` edges are therefore `SUPPLY_LV` with `carries_flow = true`, and `SUBMETER_OF`
is **dropped from the seed** -- nothing uses it. `SUPPLY_LV` rises from 136 to 148, and the
FEEDER total reconciles as 148 + 12 + 36 + 3 + 1 = 200.

**Correction (2026-09-28):** the claim that `HEATER_11` had no feed from `HEATER_TOTAL` was
wrong — it came from reading an alphabetically sorted list (`HEATER_1, _10, _11, _2 …`) as if
it ended at 10. All **ten** heater nodes already have a feed from `HEATER_TOTAL`. There is no
missing edge and nothing to fix, so this is out of §7a entirely.

What the check did surface: the heaters are numbered 1–8, 10, 11 — **there is no `HEATER_9`
node at all**. Either the site numbering skips 9, or a ninth heater exists and was never
added. That is a node question, not an edge one; see Q3.

Remaining:

1. **Which board does `PLTS_TEXTURE` inject into?** Its 16 loads sit under *two* boards --
   `LVMDB_TEXTURE` and `LVMDB_TEXTURE_2` -- so the SLD has to say which one carries the PV
   tap, or whether the array is split across both. Every other PLTS maps unambiguously to a
   single board. This is the last thing blocking §7a.

2. **`HEATER_TOTAL`, `MDP_MC_13` and `WJL3` are `node_class = 'LOAD'`** but behave as panels.
   They should be `SUB_BOARD`. That is a node change, so it belongs to the untyped-load
   authoring pass rather than here -- recorded so it is not lost.

3. ~~**Is there a `HEATER_9`?**~~ **Settled 2026-09-28: no.** `HEATER_9` appears in no SLD.
   The numbering simply skips 9, and the nodes 1-8, 10, 11 are the complete set. Recorded so
   the gap in the sequence does not get re-investigated; revisit only if site says otherwise.
   `HEATER_5` and `HEATER_6` remain genuinely unmetered loads under `HEATER_TOTAL`.

4. **Bus ties.** `BUSTIE` has never been used. Are there ties between the LV boards? If any
   are normally closed, the graph is missing real paths; `normally_open` exists in §4.3 for
   exactly this.

5. ~~**Stale edges from two successive re-parents.**~~ **Withdrawn 2026-09-29 — this was my
   error, not the data's.** The superseded edges already carry `effective_to`, so they were
   retired correctly by whoever made those changes. `MC303_1_9`'s ancestry today is exactly
   `LVMDP_SPINNING_1` then `INCOMING_PLN`, and the solver -- which filters the effective
   window -- has always seen it that way. `MC302_BARU` and `MC303_BARU` have no current parent
   because the nodes themselves are inactive: decommissioned, edges retired, entirely
   consistent.

   **The real finding, which caused the mistake:** `is_active` and the effective window are
   two independent mechanisms, and 9 edges are `is_active = true` with
   `effective_to = '-infinity'`. Any query filtering on `is_active` alone over-reports, and
   several of mine did. Worse, **`graph.v_edge_gaps` as shipped in 028 filters only
   `ed.is_active`**, so it reports retired edges as live gaps -- the same trap, now baked into
   a view. Fixed by `029_fix_edge_gaps_window.sql`, **applied to valkyrie 2026-09-29**:
   7 of the 9 retired edges were being reported as gaps (the other 2 point at inactive
   nodes, which the new filter also excludes), and the gap count fell 126 -> 119.

   **Settled 2026-09-29 -- valid time vs documentation correction.** I proposed a migration 030
   to date those nine `effective_to = '-infinity'` rows (2026-09-21, 2026-09-28, both knowable
   from the replacing edge's `created_at`). That would have been wrong, and the reason is the
   convention this graph now follows:

   | encoding | meaning |
   |---|---|
   | `effective_to = <date>` | the plant changed on that date; reports built on the old topology stay valid |
   | `effective_to = '-infinity'` | never true -- recorded from an SLD that was simply incorrect, so reports built on it are retroactively wrong |
   | `DELETE` | only when the wrong belief has no evidential value |

   The site engineer does not insert panels. They "just realized" the SLD we hold was incorrect
   and requested a redraw through our engineer, so `LVMDB_TF630 -> MC303_1_9` was **never** the
   true topology -- an `as_of 2026-09-01` query is right not to return it. A date would falsely
   assert a physical change. The nine rows are correct as they stand; 030 was abandoned.

   Consequence for 027: deleting the 36 `PV_PLANT -> load` edges was the weaker choice. The
   same correction expressed as `effective_to = '-infinity'` would have kept the wrong belief
   visible beside the right one. Future corrections of this kind should set `-infinity`, not
   `DELETE`.

   One thing still open:

   - **18 Texture nodes have two live board parents**, `LVMDB_TEXTURE` and
     `LVMDB_TEXTURE_2` -- the `MC_MOTOR_*` set plus `COMP_ELITE`, `COMP_FUSHENG300HP`,
     `HEATER_TOTAL`, `HVAC_AHU`, `LABKNIT`, `MDP_MC_13`. This is the last genuine parentage
     ambiguity in the electricity graph; everything else that looked ambiguous was the
     `is_active` artefact above. The other 7 multi-parent nodes are boards with two real
     sources (grid + gas engine, grid + PV) and are correct.

6. **Transformer impedance and vector group** -- on the nameplates or test certificates?
   This is §6.

---

## 9. Not in this step

- ~~Typing the 98 untyped LOAD nodes.~~ **Done in `030_type_loads.sql`**, applied to valkyrie
  **2026-09-29**. 100 nodes, not 98 — the count
  here was of *active* nodes and missed `MC302_BARU` / `MC303_BARU`, which are inactive with
  every edge at `effective_to = '-infinity'`. Types come from `draft_load_types.csv`, reviewed
  and accepted as a first pass rather than a site-verified inventory: waiting for a complete
  assessment would take months, and retyping is one `UPDATE`.

  Two new types under `LOAD`: `PROCESS_HEATER` and `WATER_PROCESS`. Six nodes are
  reclassified — `AIR_DRYER`, `COMP_300HP`, `COMP_400HP` to `CONVERSION/AIR_COMPRESSOR`, and
  `WJL3`, `HEATER_TOTAL`, `MDP_MC_13` to `BUS/SUB_BOARD`, all three of which have children.
  `node_class` is not read by `solve_flow` or `get_node_quantity`, so no number moves.

  The gap views tell the story: `v_edge_gaps` 119 → **0**, because every
  `ENDPOINT_UNTYPED` row existed only because a load had no type. `v_property_gaps` loses its
  UNTYPED rows and gains 8 MISSING ones — `rated_kw` on the three compressors,
  `main_breaker_a` and `nominal_v` on the three boards. That trade is the point: an unnamed
  thing becomes a named question with a named reader.

  Left open deliberately: `AIR_DRYER` is typed `AIR_COMPRESSOR` because that is what the
  review accepted, but a dryer is not a compressor and will inflate any aggregate summing the
  type as air production. Flagged `REVIEW:` in 030 §2.4; the fix is one `UPDATE` plus an
  `AIR_DRYER` type and its endpoint rows.
- Time-varying topology (`effective_from` / `effective_to` on typed edges) beyond what the
  existing columns already do.
- Any change to `ck_edge_class`. The five unused classes stay declared and unseeded.
