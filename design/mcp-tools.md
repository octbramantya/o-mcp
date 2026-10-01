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
