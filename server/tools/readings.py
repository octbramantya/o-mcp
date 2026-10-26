"""meter_readings: what one node's meters read over a window, per interval.

From public.telemetry_15min_agg only; raw telemetry_data is not exposed (design/mcp-catalogue.md §5,
open 3). The aggregation follows quantity_term.reading, server-side: a COUNTER becomes consumption
per interval (forward differences, with the guards graph.device_totals uses), a SAMPLE its mean, min
and max. Power factor is decoded before any statistic (design/mcp-tools.md, gap 4).
"""
from plant import readings, resolve, timewin

from .. import tools

NAME = "meter_readings"
TITLE = "Meter readings"
FORMAT = "readings-v1.schema.json"
DESCRIPTION = """\
Readings from the meters on one node (on the node or its feeder) over a window, per interval, in \
site time. Energy and volume registers (COUNTER) come back as consumption per interval, never as \
the register itself; instantaneous values (SAMPLE) as the mean, min and max of their 15-minute \
values. Power factor is decoded to 0..1 before any statistic. Windows are half-open: `end` is \
excluded. One point per device, quantity and interval, at most 500 in all: a week at `hour` is \
168 points per series; use `day` or `window` for longer spans. \
A reading is one meter's view. For a node without a meter, totals across nodes, or a power factor \
over a period, use node_value instead: summing children's readings misses unmetered load, and \
averaging power factor samples is not the power factor of the period."""

INTERVALS = ("15min", "hour", "day", "window")
MAX_POINTS = 500
MAX_DAYS = 31


def input_schema(ctx):
    return {
        "type": "object",
        "required": ["node", "quantities", "start", "end", "interval", "as_of"],
        "properties": {
            "node": tools.node(),
            "quantities": {"type": "array", "minItems": 1, "maxItems": 8, "uniqueItems": True,
                           "items": {"enum": [q["code"] for q in ctx.vocab.quantities]},
                           "description": "Quantity codes, e.g. ACTIVE_ENERGY_DELIVERED, PF_TOTAL, THD_VOLTAGE_LN. "
                                          "node_meters lists what a node's meters report; plant_vocabulary kind "
                                          "quantity says what each means."},
            "start": {"type": "string", "description": "Window start in site time, YYYY-MM-DD or YYYY-MM-DDTHH:MM."},
            "end": {"type": "string", "description": f"Window end in site time, excluded. At most {MAX_DAYS} days "
                                                     f"after start."},
            "interval": {"enum": list(INTERVALS), "default": "hour",
                         "description": "Point size. 15min is the finest stored; window gives one point for the "
                                        "whole window. hour and day follow site time."},
            "device": {"type": "string", "minLength": 1,
                       "description": "Only this device code, when the node has several meters (node_meters)."},
            "as_of": tools.as_of(ctx, "Which meters were on the node: as on this day, site time. Defaults to "
                                      "today; give a day inside the window if the meters changed since."),
        },
        "additionalProperties": False,
    }


async def run(ctx, args):
    cfg = ctx.config
    w = timewin.window(args["start"], args["end"], cfg.tz, MAX_DAYS)
    async with ctx.db.tx() as conn:
        nodes = await resolve.live_nodes(conn, cfg.tenant, args["as_of"])
        node, how = resolve.pick(nodes, args["node"], args["as_of"])
        doc = await readings.document(conn, cfg.tenant, ctx.vocab, cfg.tz, node, args["as_of"], args["quantities"],
                                      w, args["interval"], MAX_POINTS, args.get("device"))
    n = sum(len(s["points"]) for s in doc["series"])
    summary = (f"{node['code']}: {len(doc['series'])} series, {n} points, {args['interval']} intervals from "
               f"{timewin.iso(w.start)} to {timewin.iso(w.end)} (excluded); {len(doc['findings'])} finding(s).")
    return doc, (f"{how[0].upper()}{how[1:]}. " if how else "") + summary
