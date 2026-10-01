# `o-mcp/subgraph` — format version 1

One JSON document describing part of the plant: a root node, everything below it down to a given
depth, and the parents that feed into that part from outside it. Produced by `tools/sld.sql`
(written by `tools/sld.py --save-json`), rendered by `tools/sld.py`, and intended as the response
shape of the MCP server's topology tools (`design/mcp-tools.md`).

**The definition is `design/subgraph-v1.schema.json`** (JSON Schema, a description on every
field). This page explains it; where the two differ, the schema is right and this page is the
bug. Check documents with:

```bash
uv run --no-project --with jsonschema tools/check_subgraph.py doc.json
```

The check is strict: it fails any field the schema does not list (except inside a node's
`attrs`), and it checks the guarantees below that JSON Schema cannot express.

## Versioning

Every document starts with `"schema": "o-mcp/subgraph"` and `"version": 1`. A reader checks both
before reading anything else, and refuses a document it does not know.

- **Adding** a field is allowed within version 1. Readers ignore fields they do not know.
- **Removing or renaming** a field, or **changing what a field means**, makes version 2.

One exception, made while nothing consumed the format: migration 034 (2026-10-01) added the
node class `TREATMENT` and narrowed `CONVERSION`, moving the water treatment types out of it,
within version 1. Migration 035 did the same for `SINK`, narrowing `LOAD`. Once a reader exists,
a change like that is a version 2.

## Guarantees

- Every list is present and is a list, possibly empty. Never `null`.
- Every edge's `from` and `to` is the `code` of a node in `nodes`.
- Each node appears once.
- Only rows live at `query.as_of` appear: `is_active`, `effective_from <= as_of`, and
  `effective_to` null or `>= as_of`, for nodes and edges alike.
- The order is stable: nodes by scope (`reached`, `parent`, `context`), then depth, then code;
  edges by `from`, `to`, `id`; findings by code, then subject.

## Top level

| field | type | meaning |
|---|---|---|
| `schema` | string | always `"o-mcp/subgraph"` |
| `version` | integer | `1` |
| `query` | object | what was asked; see below |
| `nodes` | list | the nodes; see below |
| `edges` | list | the edges; see below |
| `findings` | list | what the server noticed about these nodes and edges; see below |

### `query`

| field | type | meaning |
|---|---|---|
| `tenant` | integer | tenant id |
| `root` | string | the `node_code` asked for. If no live node has it, `nodes` is empty |
| `as_of` | date string | the day the plant is described as of |
| `depth` | integer | how many levels below the root were walked (at least 1) |
| `utility` | string or null | when set, only that utility's edges were followed and returned |

### `nodes[]`

| field | type | meaning |
|---|---|---|
| `code` | string | `graph.node.node_code`, unique per tenant |
| `name` | string | `node_name` |
| `class` | string | `SOURCE`, `BUS`, `CONVERSION`, `TREATMENT`, `STORAGE`, `LOAD` or `SINK`. `SINK` is where the utility leaves the graph unconsumed (an outfall, an overflow, or a recycle cut naming where it re-enters in `attrs.reenters_at`); keep it out of consumption totals. `CONVERSION` delivers a different utility from what it takes in (compressor, boiler); `TREATMENT` passes the same utility through, changed and with some lost (softener, RO unit). A main board and a sub-board are both `BUS`; `type` tells them apart (`MAIN_LV_BOARD`, `SUB_BOARD`) |
| `type` | string or null | `node_type`, from the ontology |
| `attrs` | object | the node's properties, as stored. Units are in the key: `nominal_v` and `tx_primary_v` in volts, `rated_kva` in kVA, `rated_kw` in kW, `main_breaker_a` in amperes. Absent means not recorded |
| `scope` | string | `reached`: on the walk down from the root. `parent`: not reached, but feeds a reached node (a second board, a PV plant, a generator). `context`: neither, but feeds a `parent` node; included only so its edge has both ends |
| `depth` | integer or null | for `reached` nodes, the fewest edges from the root (root = 0). A node reachable two ways gets the shorter. `null` for `parent` and `context` |
| `children_total` | integer | live outgoing edges of this node, in or out of the document |
| `children_not_included` | integer | of those, how many lead to a node not in the document. Non-zero means the drawing stops here |

### `edges[]`

| field | type | meaning |
|---|---|---|
| `id` | integer | `graph.edge.id` |
| `from`, `to` | string | node codes, in the direction energy or water flows |
| `type` | string or null | `edge_type`, from the ontology |
| `class` | string | `FEEDER`, `PIPE` or `COMPENSATION`: the conveyance. What the relation means is in `type` |
| `utility` | string | `utility_code` |
| `carries_flow` | boolean | false for edges that move no energy, such as a capacitor bank's connection |
| `effective_from` | date string | when the edge became true; `"-infinity"` means since before records began |
| `effective_to` | date string or null | null while it is still true |

Which edges are included: every live edge into a `reached` node, and every live edge into a
`parent` node. So a reached node's parents are all present, and so is a parent's own supply.

### `findings[]`

Every finding has a `code`, names its subject, and has a `message`: one sentence to show a person
as is. The server computes findings; readers display them and should not work them out again.

| code | fields (besides `message`) | meaning |
|---|---|---|
| `MULTIPLE_LIVE_PARENTS` | `node`, `parents[]` | a reached node with more than one live parent that is not a source. The plant may have only one; this is a question for the site, not a fact. Not raised for `STORAGE` nodes, where several inflows are ordinary |
| `IMPLICIT_BUS` | `node`, `children` | a node that is not a bus but has more than one flow child, so a busbar exists on site with no node of its own (`INCOMING_PLN` on tenant 3). Not raised for `STORAGE` nodes: a tank pools what it holds |
| `PROPERTY_GAP` | `node`, `property`, `kind`, `status`, `used_by`, `detail` | a row of `graph.v_property_gaps`: a property a real reader needs (`used_by`) that the node lacks. A property that is merely absent, and not needed, is not a gap |
| `EDGE_GAP` | `edge`, `from`, `to`, `status` | a row of `graph.v_edge_gaps` for an edge in the document |

Property and edge gaps come from the views, which judge the current values of the properties.
`attrs` has no history, so these findings do not change with `as_of`.
