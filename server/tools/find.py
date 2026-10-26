"""plant_find: which nodes match. A list, not a subgraph."""
from plant import find

from .. import tools

NAME = "plant_find"
TITLE = "Find plant nodes"
FORMAT = "nodelist-v1.schema.json"
DESCRIPTION = """\
Lists the plant's nodes (boards, machines, sources, tanks, treatment stages) that match every filter \
given, as of a date. Use it to find a node's code before calling another tool, or to answer "which \
nodes are ...". `type` includes its subtypes (SWITCHBOARD finds main boards and sub-boards). Each row \
says whether the node has a meter of its own or on its feeder (`metered`) and how many live feeders it \
has; more than one is an open question for the site, which plant_section shows. \
For how nodes connect, use plant_section; for what a node's meters report, node_meters. \
Rows are capped at `limit`; `total` says how many matched."""

LIMIT_MAX = 200


def input_schema(ctx):
    v = ctx.vocab
    statuses = next((p["enum_values"] for p in v.properties if p["key"] == "site_status"), None) or []
    return {
        "type": "object",
        "required": ["as_of"],
        "properties": {
            "text": {"type": "string", "minLength": 1,
                     "description": "Part of a code or name, any case, e.g. TEXTURE or compressor."},
            "type": {"enum": [t["code"] for t in v.node_types],
                     "description": "Node type, subtypes included. Meanings: plant_vocabulary kind node_type."},
            "class": {"oneOf": [{"const": c["code"], "description": c["description"]} for c in v.node_classes],
                      "description": "Node class, the broad role."},
            "utility": tools.utility(ctx, "Only nodes with an edge of this utility."),
            "metered": {"type": "boolean",
                        "description": "true: a meter is on the node or its feeder. false: neither; the solver "
                                       "infers its values from its neighbours."},
            "site_status": {"enum": [*statuses, "none"],
                            "description": "Status the site has declared. none: nothing declared, which is not the "
                                           "same as normal."},
            "as_of": tools.as_of(ctx),
            "limit": {"type": "integer", "minimum": 1, "maximum": LIMIT_MAX, "default": 50,
                      "description": "Most rows to return."},
        },
        "additionalProperties": False,
    }


async def run(ctx, args):
    async with ctx.db.tx() as conn:
        doc = await find.nodelist(conn, ctx.config.tenant, ctx.vocab, args["as_of"],
                                  {k: args[k] for k in find.FILTERS if k in args}, args["limit"])
    total, returned = doc["total"], doc["returned"]
    if total > returned:
        summary = f"{total} nodes match; the first {returned} by code are listed. Narrow the filters or raise limit."
    else:
        summary = f"{total} nodes match."
    return doc, summary
