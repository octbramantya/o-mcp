"""The ontology and the quantity vocabulary, loaded once at startup (per tenant in the API).

They become the enums of the tools' input schemas (the ontology-as-enum rule in CLAUDE.md) and
the body of plant_vocabulary. A failed or empty load stops the server: stale or empty enums are
worse than no server. Restart after a migration that changes the vocabulary.
"""
from dataclasses import dataclass

from .db import rows

# Power factor quantities, decoded to a magnitude before any statistic (design/mcp-tools.md gap 4).
# One rule fits every meter model tenant 3 has (checked on dev 2026-10-12): Schneider's quadrant code
# on -2..2, the plain signed -1..1 of the Surya Nesia loggers, and the unsigned 0..1 of the Lovato
# DMG610 and Schneider PM710 all give the same magnitude under it. Only what the sign means differs
# by model, and the decoded value does not keep it, so no device or model is named here.
PF_ENCODED = ("PF_TOTAL", "PF_A", "PF_B", "PF_C", "DPF_TOTAL", "DPF_A", "DPF_B", "DPF_C")
# node_value refuses PF_TOTAL: its rule averages the encoded values, safe only after decoding
# (gap 4). PF_TRUE is the node-level power factor.
NOT_A_NODE_VALUE = ("PF_TOTAL",)


@dataclass
class Vocabulary:
    node_classes: list
    edge_classes: list
    node_types: list
    edge_types: list
    endpoints: list
    properties: list
    type_properties: list
    utilities: list
    quantities: list           # every quantity_term, with its rule when the solver has one
    derived: list              # graph.derived_quantity
    shift_names: list          # every shift name the tenant has, for "no shift filter"

    # -- lookups ------------------------------------------------------------------------------
    def quantity(self, code):
        return next((q for q in self.quantities if q["code"] == code), None)

    def quantity_by_id(self, qid):
        return next((q for q in self.quantities if q["quantity_id"] == qid), None)

    def node_value_quantities(self):
        """What node_value serves: every quantity with a solver rule, but PF_TOTAL, plus each
        derived quantity. Each as {code, utility, unit, description, kind}."""
        out = [{"code": q["code"], "utility": q["rule"]["utility"], "unit": q["unit"],
                "description": q["description"], "kind": "RULE", "quantity_id": q["quantity_id"],
                "rule": q["rule"]}
               for q in self.quantities if q["rule"] and q["code"] not in NOT_A_NODE_VALUE]
        out += [{"code": d["code"], "utility": d["utility"], "unit": d["unit"], "description": d["description"],
                 "kind": "DERIVED", "quantity_id": None, "rule": None, "from": d["from"]}
                for d in self.derived]
        return out

    def subtypes(self, code):
        """The type and every type below it."""
        out, frontier = {code}, {code}
        while frontier:
            frontier = {t["code"] for t in self.node_types if t["parent"] in frontier} - out
            out |= frontier
        return sorted(out)


async def load(conn, tenant):
    node_classes = await rows(conn, "SELECT code, description FROM graph.node_class ORDER BY code")
    edge_classes = await rows(conn, "SELECT code, description FROM graph.edge_class ORDER BY code")
    node_types = await rows(conn, """
        SELECT code, node_class AS class, parent_code AS parent, is_abstract AS abstract, name, description
        FROM graph.node_type ORDER BY code""")
    edge_types = await rows(conn, """
        SELECT code, edge_class AS class, utility_code AS utility, carries_flow, is_transform, description
        FROM graph.edge_type ORDER BY code""")
    endpoints = await rows(conn, """
        SELECT edge_type, from_kind, to_kind FROM graph.edge_type_endpoint ORDER BY 1, 2, 3""")
    properties = await rows(conn, """
        SELECT attr_key AS key, datatype, unit, min_value AS min, max_value AS max, enum_values, kind,
               description
        FROM graph.property ORDER BY attr_key""")
    # through v_type_property, so a subtype carries what it inherits, with where it is defined
    type_properties = await rows(conn, """
        SELECT node_type, attr_key AS key, requirement, used_by, defined_on
        FROM graph.v_type_property ORDER BY 1, 2""")
    utilities = await rows(conn, "SELECT code, name, base_unit FROM graph.utility ORDER BY display_order, code")
    quantities = await rows(conn, """
        SELECT t.quantity_id, t.code, t.unit, t.reading, t.description,
               CASE WHEN r.quantity_id IS NOT NULL THEN json_build_object(
                 'utility', r.utility_code, 'time_agg', r.raw_time_agg, 'network_agg', r.network_agg,
                 'conserved', r.conserved) END AS rule
        FROM graph.quantity_term t LEFT JOIN graph.quantity_rule r USING (quantity_id)
        ORDER BY t.code""")
    derived = await rows(conn, """
        SELECT d.code, d.utility_code AS utility, d.unit, d.description, d.formula,
               d.p_quantity_id, d.q_quantity_id,
               ARRAY[p.code, q.code] AS "from"
        FROM graph.derived_quantity d
        JOIN graph.quantity_term p ON p.quantity_id = d.p_quantity_id
        JOIN graph.quantity_term q ON q.quantity_id = d.q_quantity_id
        ORDER BY d.code""")
    shifts = await rows(conn, "SELECT DISTINCT shift_name FROM tenant_shift_periods WHERE tenant_id = %s",
                        (tenant,))
    for p in properties:
        for k in ("min", "max"):
            if p[k] is not None:
                p[k] = float(p[k])
    v = Vocabulary(node_classes, edge_classes, node_types, edge_types, endpoints, properties, type_properties,
                   utilities, quantities, derived,
                   # get_shift_period answers UNKNOWN for an hour no shift covers; keep those rows too
                   sorted({s["shift_name"] for s in shifts} | {"UNKNOWN"}))
    empty = [k for k in ("node_classes", "node_types", "edge_types", "utilities", "quantities") if not getattr(v, k)]
    if empty:
        raise RuntimeError(f"vocabulary is empty: {', '.join(empty)}")
    missing = [c for c in PF_ENCODED if not v.quantity(c)]
    if missing:
        raise RuntimeError(f"quantity terms missing for power factor decoding: {', '.join(missing)}")
    return v
