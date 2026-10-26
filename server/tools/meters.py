"""node_meters: the instruments on one node. Which devices read it or its feeder, what each reports,
when each last reported against the status the site declared (design/mcp-tools.md, gap 5), and which
quantities node_value can give for the node, measured or inferred.

graph.v_device_attachment is not used: it filters is_active only, not the effective window
(design/mcp-catalogue.md §5, open 4). graph.measurement is filtered here instead.
"""
from plant import meters, resolve

from .. import tools

NAME = "node_meters"
TITLE = "Meters on a node"
FORMAT = "meters-v1.schema.json"
DESCRIPTION = """\
What is measured at one node, as of a date. Lists each device (meter) on the node or on its feeder: \
the quantities the network model reads from it, everything it actually reported in the last 7 days \
before `as_of` ends, and when it last reported, next to the status the site declared. Also lists the \
quantities node_value can give for this node and how: MEASURED here, INFERRED from neighbouring \
meters by flow balance, INHERITED from the feeder, DERIVED, or NOT_AVAILABLE. A node with no meter \
still has inferred values; this is the tool that says so. \
Quote `findings[].message` as is: a silent meter with nothing on record to explain it is a finding, \
not a fault diagnosis. For the readings themselves, call meter_readings."""


def input_schema(ctx):
    return {
        "type": "object",
        "required": ["node", "as_of"],
        "properties": {
            "node": tools.node(),
            "as_of": tools.as_of(ctx, "Attachments as they were on this day, in site time, and readings up to the "
                                      "end of it (or now, for today). Defaults to today."),
        },
        "additionalProperties": False,
    }


async def run(ctx, args):
    cfg = ctx.config
    async with ctx.db.tx() as conn:
        nodes = await resolve.live_nodes(conn, cfg.tenant, args["as_of"])
        node, how = resolve.pick(nodes, args["node"], args["as_of"])
        doc = await meters.document(conn, cfg.tenant, ctx.vocab, cfg.tz, node, args["as_of"])
    devices = doc["devices"]
    summary = (f"{node['code']} ({node['name']}): {len(devices)} device(s), "
               f"{sum(d['observed'] == 'REPORTING' for d in devices)} reporting at {doc['query']['observed_at']}; "
               f"{len(doc['findings'])} finding(s).")
    return doc, (f"{how[0].upper()}{how[1:]}. " if how else "") + summary
