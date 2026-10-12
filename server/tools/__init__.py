"""The tools, in the order a model meets them (design/mcp-catalogue.md §2).

Each module defines NAME, TITLE, DESCRIPTION, FORMAT (its output schema file in design/),
input_schema(ctx) and an async run(ctx, args) returning (document, one-line summary). The input
schema is built per tools/list from the vocabulary loaded at startup, so enums follow the ontology.
"""
import functools
import json
import pathlib
from dataclasses import dataclass

from .. import timewin
from . import find, meters, readings, section, value, vocabulary

DESIGN = pathlib.Path(__file__).resolve().parent.parent.parent / "design"

PHASE_1 = (vocabulary, find, section)
PHASE_2 = (meters, readings, value)
ALL = PHASE_1 + PHASE_2


@dataclass
class Context:
    config: object
    db: object
    vocab: object


@functools.cache
def output_schema(fmt):
    return json.loads((DESIGN / fmt).read_text())


def by_name(name):
    return next((t for t in ALL if t.NAME == name), None)


# -- input schema pieces shared by the tools ---------------------------------------------------
def as_of(ctx, what="Describe the plant as it was on this day, in site time. Defaults to today."):
    return {"type": "string", "format": "date", "default": timewin.today(ctx.config.tz).isoformat(),
            "description": what}


def node(example="LVMDB_A5"):
    return {"type": "string", "minLength": 1,
            "description": f"Node code or name, e.g. {example}. Resolved by the server, which says which node it "
                           f"chose; on a miss it names the nearest nodes."}


def utility(ctx, what="Only this utility. Omit for all."):
    return {"enum": [u["code"] for u in ctx.vocab.utilities], "description": what}
