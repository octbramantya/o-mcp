#!/usr/bin/env python3
"""Check o-mcp/subgraph v1 documents against design/subgraph-v1.schema.json.

    uv run --no-project --with jsonschema tools/check_subgraph.py doc.json [doc.json ...]

Strict: the published schema lets later version-1 documents carry fields it does not list, but
here every object except a node's attrs must list all of its fields. So a field added to
tools/sld.sql and not to the schema fails, and the schema cannot drift behind the query.

Also checks what JSON Schema cannot express: each node code appears once, both ends of every
edge are nodes, and every node or edge a finding names is in the document.
Exits 1 if any document fails.
"""
import copy
import json
import pathlib
import sys

try:
    import jsonschema
except ImportError:
    sys.exit("check_subgraph.py: needs jsonschema. Run it as: "
             "uv run --no-project --with jsonschema tools/check_subgraph.py ...")

SCHEMA = pathlib.Path(__file__).resolve().parent.parent / "design/subgraph-v1.schema.json"


def strict(node, path=()):
    """Close every object that lists properties, except a node's free-form attrs."""
    if isinstance(node, dict):
        if "properties" in node and path[-1:] != ("attrs",):
            node.setdefault("additionalProperties", False)
        for k, v in node.items():
            strict(v, path + (k,))
    elif isinstance(node, list):
        for v in node:
            strict(v, path)
    return node


def cross_checks(doc):
    errors = []
    codes = [n["code"] for n in doc["nodes"]]
    dup = sorted({c for c in codes if codes.count(c) > 1})
    if dup:
        errors.append(f"node codes appear more than once: {dup}")
    known, ids = set(codes), {e["id"] for e in doc["edges"]}
    for e in doc["edges"]:
        for end in ("from", "to"):
            if e[end] not in known:
                errors.append(f"edge {e['id']}: {end} {e[end]!r} is not a node")
    for f in doc["findings"]:
        for name in [f.get("node"), f.get("from"), f.get("to"), *f.get("parents", [])]:
            if name is not None and name not in known:
                errors.append(f"{f['code']}: {name!r} is not a node")
        if "edge" in f and f["edge"] not in ids:
            errors.append(f"{f['code']}: edge {f['edge']} is not an edge")
    return errors


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__.split("\n\n")[1])
    validator = jsonschema.Draft202012Validator(strict(copy.deepcopy(json.loads(SCHEMA.read_text()))))
    failed = 0
    for path in sys.argv[1:]:
        doc = json.loads(pathlib.Path(path).read_text())
        errors = [f"{'/'.join(map(str, e.absolute_path)) or '(top)'}: {e.message}"
                  for e in sorted(validator.iter_errors(doc), key=lambda e: list(map(str, e.absolute_path)))]
        if not errors:
            errors = cross_checks(doc)
        if errors:
            failed += 1
            print(f"FAIL {path}")
            for e in errors[:20]:
                print(f"  {e}")
            if len(errors) > 20:
                print(f"  ... and {len(errors) - 20} more")
        else:
            print(f"ok   {path}  ({len(doc['nodes'])} nodes, {len(doc['edges'])} edges, "
                  f"{len(doc['findings'])} findings)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
