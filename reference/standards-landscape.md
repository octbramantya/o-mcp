# Which ontology fits an industrial plant?

Checked **2026-10-01** by fetching and parsing the actual distributions where they were
obtainable. Everything marked *verified* below was counted with `rdflib`; everything marked
*not verified* is knowledge I could not confirm from here, and is flagged as such on purpose.

## The short answer

There is no industrial equivalent of Brick — no single ontology covering a plant that is at
once an electrical network, a water treatment works, a compressed-air system and a factory
floor. The industrial standards are split **by discipline**, and each was built for a
different job:

| job the standard was built for | standards | covers which of our nodes |
|---|---|---|
| building operations / BAS | Brick, Haystack, ASHRAE 223P, RealEstateCore | AHU, LIGHTING, boards (weakly) |
| production management hierarchy | ISA-95 / IEC 62264, SAREF4INMA | PRODUCTION_MACHINE, and our functional taxonomy |
| process plant lifecycle & handover | ISO 15926, DEXPI, CFIHOS | the water train, piping, P&ID |
| electrical network | IEC CIM 61970/61968, IEC 61850 | MV_BUS, boards, transformers |
| water utility network | SAREF4WATR | intake, tanks, pumps, mains |
| machine / device information models | OPC UA companion specs, AAS (IEC 63278), eCl@ss, IEC CDD | compressors, pumps, nameplate properties |
| sensors and observations | W3C SOSA/SSN, QUDT | `graph.measurement`, units |

Your instinct about Haystack is right, and it generalises: Brick and Haystack are
**building-operations** vocabularies. They model what a BAS controls. They were never meant
to describe a dye house.

## What was verified

| source | fetched | content |
|---|---|---|
| Brick 1.4.2 | `brickschema.org/schema/1.4/Brick.ttl` | 1530 classes, 28 object properties |
| Brick 1.3.0 | `brickschema.org/schema/1.3/Brick.ttl` | 1438 classes |
| SAREF core 3.1.1 | `saref.etsi.org/core/v3.1.1/saref.ttl` | 75 KB |
| SAREF4INMA 1.1.2 | `saref.etsi.org/saref4inma/v1.1.2/` | **34 classes** |
| SAREF4WATR 1.1.1 | `saref.etsi.org/saref4watr/v1.1.1/` | **72 classes** |
| SAREF4GRID 1.1.1 | `saref.etsi.org/saref4grid/v1.1.1/` | 58 classes |

SAREF publishes 15 extensions: `agri auto bldg city dmgt ehaw ener envi grid inma lift mari
syst watr wear`. Note the version trap — `saref4watr` is at **v1.1.1**, not the v1.1.2 the
sibling extensions use; guessing the version returns a 404 HTML page, not a failure.

### SAREF4INMA — the ISA-95 hierarchy, no equipment taxonomy

34 classes, and the useful ones are `Site`, `Area`, `WorkCenter`, `ProductionEquipment`,
`ProductionEquipmentCategory`, `Factory`, plus `Item` / `Batch` / `MaterialBatch` for material
tracking and `IRDI` / `GTIN*` for identifiers.

This is a **production-management** ontology. It has no compressor, no pump, no boiler. Its
value to us is the hierarchy, which is what `graph_sankey_categories.csv` and the functional
taxonomy already express — *not* the physical graph. `PRODUCTION_MACHINE` maps to
`s4inma:ProductionEquipment` and that is as specific as it gets.

### SAREF4WATR — better than Brick on water, still no treatment train

72 classes, organised as `WaterAsset` → `SourceAsset` / `SinkAsset` / `StorageAsset` /
`TransportAsset`, plus `WaterInfrastructure` → `DistributionSystem` / `TreatmentPlant` /
`StorageInfrastructure` / `MonitoringInfrastructure`.

Directly useful to us, where **Brick had nothing at all**:

| our `node_type` | SAREF4WATR |
|---|---|
| `WATER_INTAKE` | `s4watr:Intake` (`<: TransportAsset`) |
| `WATER_TANK` | `s4watr:Tank` (`<: StorageAsset`) |
| `PUMP` (the WTP/WWTP pumps) | `s4watr:Pump` (`<: Actuator, WaterDevice`) |
| `WATER_TREATMENT` | `s4watr:TreatmentPlant` — plant level only |

It also carries `Tariff` with `ConsumptionBasedTariff` / `TimeBasedTariff` /
`ThresholdBasedTariff`, and a `KeyPerformanceIndicator` / `KeyPerformanceIndicatorAssessment`
pair. Those touch the PLN tariff and energy-baseline work, which no building ontology does.

But it is a water **utility network** vocabulary — rivers, lakes, aquifers, mains, hydrants,
manholes, estuaries. `CLARIFIER`, `SOFTENER`, `RO_UNIT` and `REACTION_TANK` have no match.
`TreatmentPlant` is one opaque box where we have a five-stage train.

### SAREF4GRID — not what the name suggests

58 classes, and they are DLMS/COSEM: `GetOperation`, `SetService`, `CosemOperationInput`,
`ObisInput`, `DayProfile`, `ActivityCalendar`, `Firmware`, `NetworkInterface`. This is a
**smart-meter communications** ontology. Nothing about electrical topology — no bus, board,
transformer or capacitor. Do not reach for it on the strength of its name.

### Obtainable, machine-readable, not yet examined

| source | status |
|---|---|
| OPC UA companion nodesets | **free on GitHub** (`OPCFoundation/UA-Nodeset`). Published sets include `Pumps`, `Machinery`, `ISA-95`, `IEC61850`, `DEXPI`, `PADIM`, `I4AAS`, `MachineTool`, `PlasticsRubber`, `Woodworking` — 70-odd in all |
| IDTA AAS submodel templates | **free on GitHub** (`admin-shell-io/submodel-templates`). The Digital Nameplate template is close in spirit to our `kind = 'NAMEPLATE'` properties |
| DEXPI specifications | **freely downloadable**. P&ID data exchange for process plants, built on the ISO 15926 reference data library. The closest thing to a standard for what `reference/wtp-pid.xml` contains |

### Not verified

- **ISO 15926 part 4 RDL** — the POSC Caesar library at `data.posccaesar.org/rdl/` responds,
  but it is a JavaScript application with no plain HTTP search and no SPARQL endpoint I could
  reach (`/sparql` → 404, direct `RDS…` IRIs → 404). **I could not confirm whether it
  contains clarifier / softener / reverse-osmosis classes.** If any library does, this is the
  likeliest, and DEXPI would be the route in.
- **eCl@ss** and **IEC CDD (61360)** — property/class libraries for industrial equipment, the
  canonical answer to "what attributes does a transformer have". Behind licensing; not checked.
- **CFIHOS** (IOGP JIP36) equipment classes and attribute lists — from knowledge, not checked.
- **IEC CIM** — the right vocabulary for our electrical topology. The IEC documents are
  paywalled; ENTSO-E CGMES profiles are the usual free route. Not checked.

## What nothing covers

Across everything actually examined, these have **no match in any scheme**:

`CLARIFIER` · `SOFTENER` · `RO_UNIT` · `REACTION_TANK` · `CAPACITOR_BANK` · `MV_BUS` ·
`PROCESS_HEATER` · `WATER_PROCESS` · `GENERIC_LOAD`

Water-treatment unit operations and power-factor equipment are the two real holes. Both are
ordinary in an industrial plant and absent from the building ontologies entirely.

## What this settles

A single `external_ref VARCHAR(120)` cannot hold this, and the reason is no longer an
argument — it is a measurement. One `node_type` legitimately aligns to **more than one**
scheme at **different fidelities**:

| `node_type` | Brick 1.4.2 | SAREF4WATR 1.1.1 | SAREF4INMA 1.1.2 |
|---|---|---|---|
| `WATER_TANK` | `Water_Storage_Tank` — CLOSE | `Tank` — EXACT | — |
| `WATER_INTAKE` | **NONE** | `Intake` — EXACT | — |
| `PUMP` | `Pump` — CLOSE (`<: HVAC_Equipment`) | `Pump` — EXACT | — |
| `AHU` | `Air_Handling_Unit` — EXACT | — | — |
| `PRODUCTION_MACHINE` | **NONE** | — | `ProductionEquipment` — CLOSE |
| `CLARIFIER` | **NONE** | **NONE** | **NONE** |

So the shape is:

```
graph.vocabulary_alignment (kind, code, scheme, scheme_version, uri, match, checked_on)
```

with `match ∈ (EXACT, CLOSE, NONE)`. `NONE` is a real, hard-won row — it records that someone
fetched the distribution and looked — and a nullable column cannot distinguish it from "not
yet checked". Eleven of our fourteen unaligned types are now `NONE` against Brick, and that
knowledge is worth keeping.

## Recommendation

**Adopt none of them. Align to several.** Our vocabulary stays authoritative, because it is
the only one that matches this plant: a `TRANSFORMER` edge with `is_transform`, a
`PF_COMPENSATION` edge with `carries_flow = false`, and 85 endpoint rules have no home in any
standard examined — Brick would collapse all ten of our edge relations onto `brick:feeds`.

Alignment is worth recording where it exists, for the day something outside this system has
to read the model, which is what the MCP server will be. It is not worth adopting a standard
whose shape would cost us the distinctions the reports actually depend on.

Priority if effort is ever spent: **SAREF4WATR for the water graph** (immediate, free,
covers four types Brick cannot), then DEXPI/ISO 15926 for the treatment train if that library
turns out to have unit operations, then CIM for the electrical side only if an external
consumer ever demands it.
