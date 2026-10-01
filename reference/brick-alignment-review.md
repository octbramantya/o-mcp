# Brick alignment review — validating `graph.node_type.external_ref`

Validated **2026-10-01** against the Brick ontology downloaded from source, parsed with
`rdflib` 7.6.0. Not from recall: every verdict below is a lookup in the distributed TTL.

| release | URL | declares | classes | object properties |
|---|---|---|---|---|
| 1.4.2 | `https://brickschema.org/schema/1.4/Brick.ttl` | `owl:versionInfo "1.4.2"` | 1530 | 28 |
| 1.4.1 | `https://brickschema.org/schema/Brick.ttl` (unversioned "latest") | `owl:versionInfo "1.4.1"` | — | — |
| 1.3.0 | `https://brickschema.org/schema/1.3/Brick.ttl` | `owl:versionInfo "1.3.0"` | 1438 | — |

**The unversioned URL is behind the versioned one** — `/schema/Brick.ttl` serves 1.4.1 while
`/schema/1.4/Brick.ttl` serves 1.4.2. Anything that fetches "latest" is not getting latest.
A further reason the release has to be recorded rather than assumed.

## Verdicts on the ten stored values

| `node_type` | stored `external_ref` | 1.3.0 | 1.4.2 | verdict |
|---|---|---|---|---|
| `GRID_INCOMER` | `brick:Electrical_Meter` | exists | exists | **wrong concept** |
| `PV_PLANT` | `brick:PV_Array` | exists | exists | works, but see below |
| `GAS_ENGINE` | `brick:Generator` | **absent** | **absent** | **invalid** |
| `SWITCHBOARD` | `brick:Switchgear` | exists | exists | **debatable** |
| `AIR_COMPRESSOR` | `brick:Air_Compressor` | **absent** | **absent** | **invalid** |
| `BOILER` | `brick:Boiler` | exists | exists | good |
| `WATER_TANK` | `brick:Water_Tank` | exists | **deprecated** | **fix** |
| `AHU` | `brick:Air_Handling_Unit` | exists | exists | good |
| `LIGHTING` | `brick:Lighting_System` | exists | exists | acceptable |
| `PUMP` | `brick:Pump` | exists | exists | good |

Three are broken and two more are category errors. **Five of ten are wrong**, which is worth
knowing before extending the scheme to anything else.

### The three that are broken

**`brick:Air_Compressor` does not exist, in either release.** The class is `brick:Compressor`
(`rdfs:subClassOf brick:HVAC_Equipment`). A one-word correction.

**`brick:Generator` does not exist, in either release.** Brick has no generator *equipment*
class at all. A search returns only `brick:Generator_Room` (deprecated), plus the points
`Emergency_Generator_Alarm` and `Emergency_Generator_Status`. The nearest concept is
`brick:Energy_Generation_System`, whose only subclass is `PV_Generation_System` — so it is a
parent with no engine under it. There is no honest value for `GAS_ENGINE`.

**`brick:Water_Tank` is deprecated in 1.4** and is `rdfs:subClassOf brick:Space` — a room,
not a piece of equipment, which is wrong for a node in our graph. Brick's own comment says
as much: *"This will likely be deprecated in future releases of Brick for the sake of clarity
w.r.t. equipment classification of tanks."* The replacement is `brick:Water_Storage_Tank`
(`<: Storage_Tank <: Tank <: Equipment`). Note this value was **valid in 1.3 and invalid in
1.4** — the clearest possible demonstration that an alignment without a version pin is not a
fact.

### The two category errors

**`GRID_INCOMER` → `brick:Electrical_Meter`.** `Electrical_Meter` is `<: brick:Meter`: it is
the *instrument*. Our `GRID_INCOMER` is the point of common coupling — a `SOURCE` node — and
the meter on it is modelled separately through `graph.measurement`. Typing the coupling point
as a meter conflates the two things 026 was careful to keep apart. Brick offers no
replacement: `Service`, `Utility`, `Substation`, `Feeder` and `Entrance` return no usable
equipment class (only deprecated room types).

**`SWITCHBOARD` → `brick:Switchgear`.** Brick's definition reads like a distribution board
— *"A main disconnect or service disconnect feeds power to a switchgear, which then
distributes power to the rest of the building through smaller amperage-rated disconnects"* —
but all five of its subclasses are switching **devices**: `Circuit_Breaker`,
`Disconnect_Switch`, `Isolation_Switch`, `Transfer_Switch`, `Automatic_Switch`. Our
`SWITCHBOARD` is the enclosure and busbar. `brick:Breaker_Panel` (`<: Electrical_Equipment`)
is the closer match. The ambiguity is Brick's, not ours.

### The two minor ones

`brick:PV_Array` exists but is `<: brick:Collection` — a grouping, not equipment. For a
metered array that injects into a board, `brick:PV_Generation_System`
(`<: Energy_Generation_System`) describes what our `PLTS_*` nodes actually are.
`brick:Lighting_System` is `<: System` where our `LIGHTING` nodes are circuits; a granularity
mismatch, not an error.

## The fourteen NULLs were honest

Probed every one against 1.4.2. Only two have a real match:

| `node_type` | Brick 1.4.2 |
|---|---|
| `MAIN_LV_BOARD`, `SUB_BOARD` | `brick:Breaker_Panel` — plausible |
| `MV_BUS` | nothing (`Bus_Riser` is a riser, not a bus) |
| `WATER_INTAKE` | nothing |
| `WATER_TREATMENT`, `CLARIFIER`, `SOFTENER`, `RO_UNIT`, `REACTION_TANK` | **nothing** |
| `CAPACITOR_BANK` | **nothing** — Brick has no capacitor class |
| `PRODUCTION_MACHINE` | **nothing** |
| `PROCESS_HEATER` | nothing (`Space_Heater` is space heating; `Water_Heater` is not this) |
| `WATER_PROCESS` | nothing (`Water_Loop` is an HVAC loop) |
| `GENERIC_LOAD` | nothing, by design |

**Brick has no water-treatment vocabulary whatsoever.** `Treatment`, `Clarifier`, `Softener`,
`Osmosis`, `Filtration`, `Sewage`, `Effluent`, `Dosing` and `Chemical` all return zero
classes. The only adjacent terms are `Separation_Tank` and `Waste_Storage`. Likewise no
`Capacitor`, no `Power_Factor` equipment. These are not gaps in our authoring — they are the
edge of Brick's scope.

## Brick cannot express our edge ontology

Brick 1.4.2 declares **28** object properties in total, of which the flow-relevant ones are
`feeds` / `isFedBy`, `hasPart` / `isPartOf`, `meters` / `isMeteredBy` and
`hasSubMeter` / `isSubMeterOf`.

Our ten `edge_type` relations — `GRID_INFEED`, `TRANSFORMER`, `SUPPLY_LV`, `PV_INJECTION`,
`GENERATOR_INFEED`, `PF_COMPENSATION`, `WATER_TREATMENT`, `WATER_SUPPLY`, `WATER_RETURN`,
`WATER_TRANSFER` — would collapse to `brick:feeds` almost entirely. The distinctions that
make the model useful (`is_transform`, `carries_flow`, the 85 endpoint rules) have nowhere to
go. **Our edge vocabulary is more specific than Brick's, not less.** That is an argument
against adding `external_ref` to `graph.edge_type`, not for it.

## What this implies for storing references

`NULL` currently means two different things, and the review has just made the difference
concrete: *"nobody has checked"* versus *"checked, and Brick has no equivalent"*. Eleven of
the fourteen NULLs are now the second kind, and that is a finding worth keeping — it stops
the next person re-running this exercise. A column cannot record it; it needs a `match`
value, something like `EXACT` / `CLOSE` / `NONE`, alongside the scheme and its version.

Which is the alignment-table shape:

```
graph.vocabulary_alignment (kind, code, scheme, scheme_version, uri, match, checked_on)
```

- `scheme_version` because `Water_Tank` was valid in 1.3 and deprecated in 1.4.
- `match` because `CLOSE` lets `SWITCHBOARD → Breaker_Panel` be recorded honestly instead of
  being either overclaimed as exact or left indistinguishable from unchecked.
- `uri` rather than a CURIE, because `brick:` is an undeclared prefix today.
- multiple rows per `code`, because nothing covers an industrial plant end to end — the water
  chain will need a different scheme from the HVAC loads.

## Proposed corrections

Pending a decision on where references live, the minimum factual fixes are:

| `node_type` | from | to |
|---|---|---|
| `AIR_COMPRESSOR` | `brick:Air_Compressor` | `brick:Compressor` |
| `WATER_TANK` | `brick:Water_Tank` | `brick:Water_Storage_Tank` |
| `GAS_ENGINE` | `brick:Generator` | `NULL` — no Brick equivalent exists |
| `GRID_INCOMER` | `brick:Electrical_Meter` | `NULL` — the meter is not the coupling point |
| `SWITCHBOARD` | `brick:Switchgear` | `brick:Breaker_Panel` (or keep, flagged `CLOSE`) |
| `PV_PLANT` | `brick:PV_Array` | `brick:PV_Generation_System` (or keep, flagged `CLOSE`) |

Reproduce with `tools/validate_brick.py` (needs `rdflib`; downloads nothing itself).
