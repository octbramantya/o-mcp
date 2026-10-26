"""plant_section: one node and what it feeds, or what feeds it, as an o-mcp/subgraph v1 document.
The query is tools/sld.sql, the same file tools/sld.py draws from."""
from plant import resolve, section

from .. import tools

NAME = "plant_section"
TITLE = "Plant section"
FORMAT = "subgraph-v1.schema.json"
DESCRIPTION = """\
Returns part of the plant's energy and water network as of a date: one node, everything it feeds \
down to `depth` levels, and whatever feeds into that part from outside. With `direction: "up"` it \
walks the other way, from the node back towards its sources: what could have caused a problem here. \
Edges point the way energy or water flows.

Read each node's `scope`: `reached` nodes are the section you asked for; `parent` nodes feed into it \
from outside (a second board, a PV plant, a generator); `context` nodes are there only to complete \
an edge. `children_not_included` above zero means the section stops at that node, not that it feeds \
nothing. Units are in the attribute names (`_v` volts, `_kva` kVA, `_kw` kW, `_a` amperes). Edges \
with `carries_flow` false move no energy; leave them out of totals.

`findings` are computed by the server; quote their `message` rather than working them out yourself. \
`MULTIPLE_LIVE_PARENTS` is an open question for the site, not a fact. `PROPERTY_GAP` lists values a \
report needs and the site has not supplied. For what a type, edge type or property means, call \
plant_vocabulary. A node's siblings are plant_section of its feeder at depth 1."""

DEPTH_MAX = section.DEPTH_MAX


def input_schema(ctx):
    return {
        "type": "object",
        "required": ["root", "as_of"],
        "properties": {
            "root": tools.node(),
            "as_of": tools.as_of(ctx),
            "depth": {"type": "integer", "minimum": 1, "maximum": DEPTH_MAX, "default": 1,
                      "description": "Levels to follow from root. Down from INCOMING_PLN, depth 2 returns about 57 "
                                     "nodes and depth 4 the whole electricity network; water runs 12 levels deep."},
            "direction": {"enum": ["down", "up"], "default": "down",
                          "description": "down: what root feeds. up: what feeds root, back to the sources."},
            "utility": tools.utility(ctx, "Follow only this utility's edges. Omit for all."),
        },
        "additionalProperties": False,
    }


async def run(ctx, args):
    async with ctx.db.tx() as conn:
        nodes = await resolve.live_nodes(conn, ctx.config.tenant, args["as_of"])
        root, how = resolve.pick(nodes, args["root"], args["as_of"])
        doc = await section.subgraph(conn, ctx.config.tenant, root["code"], args["as_of"], args["depth"],
                                     args["direction"], args.get("utility"))
    reached = sum(1 for n in doc["nodes"] if n["scope"] == "reached")
    summary = (f"{root['code']} ({root['name']}), {args['direction']} {args['depth']} level(s) as of {args['as_of']}: "
               f"{reached} nodes reached, {len(doc['nodes']) - reached} outside, {len(doc['edges'])} edges, "
               f"{len(doc['findings'])} findings.")
    return doc, (f"{how[0].upper()}{how[1:]}. " if how else "") + summary
