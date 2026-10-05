# MCP tools — drafts

Drafts for the MCP server, written before the server exists so the response format and the
words a model reads are settled first. Nothing here runs yet.

## How a model learns what the response means

Three layers, because a model calling the tool has not read `design/subgraph-format.md`:

1. **The tool description.** Clients put it in the model's context with every request, so it is
   the one text the model reliably reads. It carries only what changes how the result is read.
2. **The output schema.** `design/subgraph-v1.schema.json`, registered as the tool's
   `outputSchema`, describes every field. Clients can validate results against it. Hosts differ
   on whether the model also sees it, so it is the precise definition, not the main teacher.
3. **The response itself.** Every finding carries a `message` to show a person as is, units are
   in the key names, and the full explanation is an MCP resource for when more is needed.

One source: the schema file. `tools/check_subgraph.py` fails any document with a field the
schema does not list, so the query cannot drift ahead of what the model is told.

## `plant_section`

Named for what it returns, not for the table it reads.

**Description** (what the model reads):

> Returns part of the plant's energy and water network as of a date: one node, everything it
> feeds down to `depth` levels, and whatever feeds into that part from outside. Edges point the
> way energy or water flows.
>
> Read each node's `scope`: `reached` nodes are the section you asked for; `parent` nodes feed
> into it from outside (a second board, a PV plant, a generator); `context` nodes are there only
> to complete an edge. `children_not_included` above zero means the section stops at that node,
> not that it feeds nothing. Units are in the attribute names (`_v` volts, `_kva` kVA, `_kw` kW,
> `_a` amperes). Edges with `carries_flow` false move no energy; leave them out of totals.
>
> `findings` are computed by the server; quote their `message` rather than working them out
> yourself. `MULTIPLE_LIVE_PARENTS` is an open question for the site, not a fact.
> `PROPERTY_GAP` lists values a report needs and the site has not supplied.
> For what a type, edge type or property means, call `plant_vocabulary`.

**Input schema:**

```json
{
  "type": "object",
  "required": ["root", "as_of"],
  "properties": {
    "root":    {"type": "string",
                "description": "Node code or name to start from, e.g. LVMDB_A5. Resolved by the server, which says which node it chose."},
    "as_of":   {"type": "string", "format": "date", "default": "<today>",
                "description": "Describe the plant as it was on this day. Defaults to today."},
    "depth":   {"type": "integer", "minimum": 1, "maximum": 4, "default": 1,
                "description": "Levels below root. From INCOMING_PLN, depth 2 returns about 57 nodes and depth 3 about 135."},
    "utility": {"enum": ["AIR", "ELECTRICITY", "GAS", "STEAM", "WATER"],
                "description": "Follow only this utility's edges. Omit for all."}
  }
}
```

- `utility` is filled from `graph.utility` when the tool is registered (the ontology-as-enum rule
  in CLAUDE.md); the five values above are tenant 3's today.
- `root` stays a string, not an enum of node codes: codes are plant data, not vocabulary, and a
  person types `LVMBD_A5` as often as `LVMDB_A5`. The server resolves it, by exact code, then
  name, then closest code, and on a miss returns the nearest candidates instead of an empty
  document.
- `as_of` is required with a default, per CLAUDE.md: the effective-window filter is in the
  server, never the model's job.

**Output:** `outputSchema` is `design/subgraph-v1.schema.json`. The result carries the document
as `structuredContent`, and the same JSON as a text block for clients that do not read structured
content. The SVG from `tools/sld.py` can be offered alongside as an image or a resource link; the
model reasons from the JSON.

**Resource:** `o-mcp://formats/subgraph/v1` serves `design/subgraph-format.md` and the schema,
for a model or person who wants the full explanation. A fallback, not a prerequisite.

## `plant_vocabulary`

The ontology a `plant_section` result is written in: what each node type, edge type and
property means, and which connections and properties each type allows. A tool rather than only a
resource because the model must be able to look a term up by itself, mid-answer, and every MCP
client supports tools; resources are application-controlled, and many clients surface them only
when the user attaches one.

Three layers, cheapest first:

| layer | what | when the model sees it |
|---|---|---|
| 1 | Any input that takes a type or class is a `oneOf` of `{const, description}`, not a bare `enum` | always, at no extra call |
| 2 | `plant_vocabulary` | when it decides it needs a definition |
| 3 | The same content at `o-mcp://ontology/{kind}` and `o-mcp://ontology/{kind}/{code}` | when a person or client attaches it |

All three come from one query, so a description is written once, in the database.

**Description** (what the model reads):

> Defines the terms `plant_section` uses: node classes, node types, edge types and properties.
> Call it when a type or property in a result is unfamiliar, or before saying what a type can
> connect to or which values a report needs. With no arguments it returns everything (a few
> kilobytes); `kind` and `code` narrow it.

**Input schema:**

```json
{
  "type": "object",
  "properties": {
    "kind": {"enum": ["node_type", "edge_type", "property"],
             "description": "Return only this kind of term. Omit for everything."},
    "code": {"type": "string",
             "description": "One term, e.g. SUB_BOARD, PV_INJECTION or main_breaker_a. Exact match; on a miss the server returns the nearest codes."}
  }
}
```

No `as_of`. The ontology has no valid-time history (`type-property.md`: like `node_class`,
`node_type` has none), so the CLAUDE.md rule for topology tools does not apply. If the ontology
ever gets history, `as_of` becomes required here too, and that is a version 2.

**Output:** a new format, `o-mcp/vocabulary` version 1, with its own schema file written when the
tool is built, under the same rules as `o-mcp/subgraph` (versioned, strict check, descriptions on
every field). Sketch:

```json
{
  "schema": "o-mcp/vocabulary", "version": 1,
  "node_classes": [{"code": "BUS", "description": "..."}],
  "node_types":   [{"code": "SUB_BOARD", "class": "BUS", "parent": "SWITCHBOARD", "abstract": false,
                    "name": "Sub board", "description": "...",
                    "properties": [{"key": "main_breaker_a", "requirement": "REQUIRED", "used_by": "..."}]}],
  "edge_types":   [{"code": "PV_INJECTION", "class": "FEEDER", "utility": "ELECTRICITY",
                    "carries_flow": true, "is_transform": false, "description": "...",
                    "endpoints": [{"from": "PV_PLANT", "from_is": "type", "to": "SUB_BOARD", "to_is": "type"}]}],
  "properties":   [{"key": "main_breaker_a", "datatype": "number", "unit": "A", "min": 1, "max": 10000,
                    "enum_values": null, "kind": "NAMEPLATE", "description": "..."}],
  "utilities":    [{"code": "WATER", "name": "...", "base_unit": "..."}]
}
```

- `endpoints[].from_is` / `to_is`: an endpoint rule names either a node type or a whole class
  (`SUPPLY_LV  MAIN_LV_BOARD -> LOAD`). The server says which, so the model never has to guess
  whether `LOAD` is a type.
- `abstract`: `SWITCHBOARD` and `WATER_TREATMENT` hold shared properties and are never assigned
  to a node. Read from `graph.node_type.is_abstract` (migration 041), which a trigger enforces.
- Abstract types are returned, because their properties are inherited and their names appear as
  `parent`.

**Resource:** `o-mcp://ontology/node_type`, `.../edge_type`, `.../property`, and
`.../{kind}/{code}` for one term, each the matching slice of the same document.

### Where each description comes from

Checked against the migrations on 2026-10-01:

| term | source | state |
|---|---|---|
| node type | `graph.node_type.description` (nullable) | filled for all 24 types (22 in 026, 2 in 030). Boards, sources and water stages are precise; some loads only restate the name (`PUMP`: "Pump load.") |
| edge type | `graph.edge_type.description` (NOT NULL) | all 10, and the best in the ontology: `PV_INJECTION` says where the meter is tapped, `PF_COMPENSATION` why it carries no flow |
| property | `graph.property.description` (NOT NULL), plus `datatype`, `unit`, range, `enum_values`, `kind` | all 26. The rating rules live here: `rated_kva` and `main_breaker_a` say which is the loading denominator on which board |
| type ↔ property | `graph.type_property` (`requirement`, `used_by`) | complete; no description needed |
| endpoint rule | `graph.edge_type_endpoint` | 85 rules; no description needed |
| utility | `graph.utility` (`name`, `base_unit`) | no description column; the names are self-explanatory |
| quantity | `graph.quantity_term` (`code`, `unit`, `reading`, `description`), migration 037; `graph.derived_quantity.description` for `PF_TRUE` | 97 terms: every quantity tenant 3's meters report, plus air. A quantity a meter starts reporting later has no term until a new CSV row and migration |
| node class | **nowhere in the database** | only the check constraint (five values since 032), `design/graph-network-design.md`, and the class description in `subgraph-v1.schema.json` |
| edge class | **nowhere in the database** | only `ck_edge_type_class` (eight values) |

### Gaps to close before building

1. **Node and edge classes have no table.** *Closed by migration 033: `graph.node_class` and `graph.edge_class`, and endpoint rules checked by trigger.* The definitions would live in server code, which
   breaks "a description is written once, in the database". Either a small migration adds
   `graph.node_class` and `graph.edge_class` (code, description) with the check constraints
   becoming foreign keys, or the server reads the class text from `subgraph-v1.schema.json` so it
   at least has one source. The migration is the cleaner of the two.
2. **No `is_abstract` column on `node_type`.** *Closed by migration 041: the column, set on
   `SWITCHBOARD` and `WATER_TREATMENT`, and triggers refusing an abstract type on a node and
   refusing to make a type in use abstract.* "Has subtypes" is right for the two abstract types
   today, but a future abstract type with no subtypes yet, or a concrete type that gains one,
   would be misreported.
3. **Thin load descriptions.** `PUMP`, `AHU`, `LIGHTING` and `PRODUCTION_MACHINE` restate their
   names. Harmless for a model, but this is where a sentence on what the type covers (and what it
   does not, such as `AIR_DRYER` typed `AIR_COMPRESSOR`) would help most. A data migration, no
   schema change.
4. **Meter power factor is encoded.** *Decided 2026-10-02.* Schneider meters report `PF_TOTAL`
   (1072), `PF_A..C` and `DPF_*` on -2..2 by quadrant, and the PV loggers `PLTSC`/`PLTSD`
   report a plain signed value (`graph.quantity_term.description` has the decoding). The server
   never returns a statistic of the raw values: it decodes each reading first, or offers
   `PF_TRUE` instead. `quantity_rule` for 1072 says `AVG`, which is only safe after decoding.
5. **A node's status is declared by hand; whether its meter reports is observed.** *Decided
   2026-10-05.* `site_status` (OPTIONAL on every equipment type since migration 039) records only
   what the site has reported, so it cannot notice a meter switched off without notice, and
   `public.devices.status` can't either: all 8 devices silent in the dev week read `ONLINE`. The
   server computes each device's last reading from telemetry at question time and reports it
   next to the declared status, never storing it by hand:

   | declared | observed | the server says |
   |---|---|---|
   | none or `normal` | reporting | nothing to add |
   | none or `normal` | silent since X | not reporting since X, with no explanation on record |
   | `inactive` | silent | expected: turned off on site since `site_status_as_of` |
   | `inactive` | reporting | the status is probably out of date; ask the site |

   An absent status is "nothing reported", never "normal". `attrs` has no history, so for an
   `as_of` before `site_status_as_of` the server states no status.
