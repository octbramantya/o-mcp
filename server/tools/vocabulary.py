"""plant_vocabulary: what a term means. No as_of: the ontology has no valid-time history
(design/mcp-tools.md)."""
import difflib

from ..errors import ToolError

NAME = "plant_vocabulary"
TITLE = "Plant vocabulary"
FORMAT = "vocabulary-v1.schema.json"
DESCRIPTION = """\
Defines the terms the other plant tools use: node classes and types, edge classes and types, \
properties, utilities, and the quantities meters report. Call it when a type, property or quantity \
in a result is unfamiliar, before saying what a type can connect to or which values a report needs, \
or to learn what a quantity code measures and how it is read (COUNTER or SAMPLE). \
Narrow it with `kind` and `code`: everything at once is about 65 kB, a third of it quantities."""

PROPERTY_FIELDS = ("key", "datatype", "unit", "min", "max", "enum_values", "kind", "description")
KINDS = ("node_class", "node_type", "edge_class", "edge_type", "property", "utility", "quantity")


def input_schema(ctx):
    return {
        "type": "object",
        "properties": {
            "kind": {"enum": list(KINDS), "description": "Return only this kind of term. Omit for every kind."},
            "code": {"type": "string", "minLength": 1,
                     "description": "One term, e.g. SUB_BOARD, PV_INJECTION, main_breaker_a or "
                                    "ACTIVE_ENERGY_DELIVERED. Exact match; on a miss the server names the "
                                    "nearest codes."},
        },
        "additionalProperties": False,
    }


def build(v):
    """The whole o-mcp/vocabulary v1 document."""
    props_of = {}
    for tp in v.type_properties:
        props_of.setdefault(tp["node_type"], []).append(
            {"key": tp["key"], "requirement": tp["requirement"], "used_by": tp["used_by"],
             "defined_on": tp["defined_on"]})
    type_codes = {t["code"] for t in v.node_types}
    class_codes = {c["code"] for c in v.node_classes}

    def end(kind):
        return "type" if kind in type_codes else "class" if kind in class_codes else "unknown"

    ends_of = {}
    for e in v.endpoints:
        ends_of.setdefault(e["edge_type"], []).append(
            {"from": e["from_kind"], "from_is": end(e["from_kind"]), "to": e["to_kind"], "to_is": end(e["to_kind"])})
    served = {q["code"] for q in v.node_value_quantities()}
    return {
        "schema": "o-mcp/vocabulary", "version": 1,
        "node_classes": [dict(c) for c in v.node_classes],
        "node_types": [dict(t, properties=props_of.get(t["code"], [])) for t in v.node_types],
        "edge_classes": [dict(c) for c in v.edge_classes],
        "edge_types": [dict(t, endpoints=ends_of.get(t["code"], [])) for t in v.edge_types],
        "properties": [{k: p[k] for k in PROPERTY_FIELDS} for p in v.properties],
        "utilities": [dict(u) for u in v.utilities],
        "quantities": [{"code": q["code"], "quantity_id": q["quantity_id"], "unit": q["unit"], "reading": q["reading"],
                        "description": q["description"], "rule": q["rule"], "node_value": q["code"] in served}
                       for q in v.quantities],
        "derived_quantities": [{"code": d["code"], "utility": d["utility"], "unit": d["unit"],
                                "description": d["description"], "from": list(d["from"]), "node_value": True}
                               for d in v.derived],
    }


SECTIONS = {"node_class": "node_classes", "node_type": "node_types", "edge_class": "edge_classes",
            "edge_type": "edge_types", "property": "properties", "utility": "utilities",
            "quantity": "quantities"}


def _key(item):
    return item.get("code", item.get("key"))


async def run(ctx, args):
    doc = build(ctx.vocab)
    kind, code = args.get("kind"), args.get("code")
    keep = {SECTIONS[kind]} if kind else set(SECTIONS.values()) | {"derived_quantities"}
    if kind == "quantity":
        keep.add("derived_quantities")
    for section in list(SECTIONS.values()) + ["derived_quantities"]:
        if section not in keep:
            doc[section] = []
    if code:
        for section in keep:
            doc[section] = [i for i in doc[section] if _key(i) == code or _key(i).upper() == code.upper()]
        if not any(doc[s] for s in keep):
            pool = sorted({_key(i) for s in keep for i in build(ctx.vocab)[s]})
            near = difflib.get_close_matches(code.upper(), [p.upper() for p in pool], n=6, cutoff=0.5)
            near = [p for p in pool if p.upper() in near]
            where = f" among {kind} terms" if kind else ""
            raise ToolError(f"No term {code!r}{where}. " +
                            (f"Nearest: {', '.join(near)}." if near else "Call without code to list them.") +
                            " Node codes are not terms; plant_find finds nodes.")
    counts = {s: len(doc[s]) for s in keep if doc[s]}
    return doc, "Terms: " + ", ".join(f"{n} {s.replace('_', ' ')}" for s, n in counts.items()) + "."
