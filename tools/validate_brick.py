"""Validate the external_ref values stored in graph.node_type against a Brick release."""
import sys

from rdflib import OWL, RDF, RDFS, Graph, Namespace, URIRef

BRICK = Namespace("https://brickschema.org/schema/Brick#")
SKOS  = Namespace("http://www.w3.org/2004/02/skos/core#")

# exactly what graph.node_type.external_ref holds today, with the node_type it sits on
STORED = [
    ("GRID_INCOMER",   "SOURCE",     "Electrical_Meter"),
    ("PV_PLANT",       "SOURCE",     "PV_Array"),
    ("GAS_ENGINE",     "SOURCE",     "Generator"),
    ("SWITCHBOARD",    "BUS",        "Switchgear"),
    ("AIR_COMPRESSOR", "CONVERSION", "Air_Compressor"),
    ("BOILER",         "CONVERSION", "Boiler"),
    ("WATER_TANK",     "STORAGE",    "Water_Tank"),
    ("AHU",            "LOAD",       "Air_Handling_Unit"),
    ("LIGHTING",       "LOAD",       "Lighting_System"),
    ("PUMP",           "LOAD",       "Pump"),
]

g = Graph()
g.parse(sys.argv[1], format="turtle")
label = sys.argv[2]

def exists(local):
    u = BRICK[local]
    return (u, RDF.type, OWL.Class) in g or (u, RDF.type, RDFS.Class) in g or any(g.triples((u, None, None)))

def parents(local):
    return sorted(str(o).split("#")[-1] for o in g.objects(BRICK[local], RDFS.subClassOf)
                  if isinstance(o, URIRef) and "#" in str(o))

def definition(local):
    for p in (SKOS.definition, RDFS.comment):
        for o in g.objects(BRICK[local], p):
            return " ".join(str(o).split())
    return ""

def deprecated(local):
    return bool(list(g.objects(BRICK[local], OWL.deprecated)))

print(f"\n{'='*78}\nBrick {label}: {len(set(g.subjects(RDF.type, OWL.Class)))} owl:Class declarations\n{'='*78}")
for code, klass, local in STORED:
    ok = exists(local)
    mark = "OK     " if ok and not deprecated(local) else ("DEPREC " if ok else "MISSING")
    print(f"\n[{mark}] {code} ({klass})  ->  brick:{local}")
    if ok:
        ps = parents(local)
        if ps:
            print(f"           subClassOf: {', '.join(ps)}")
        d = definition(local)
        if d:
            print(f"           def: {d[:200]}")

# Usage:
#   curl -sSLo Brick-1.4.ttl https://brickschema.org/schema/1.4/Brick.ttl
#   python validate_brick.py Brick-1.4.ttl 1.4.2
#
# Needs rdflib. Note /schema/Brick.ttl (unversioned) served 1.4.1 while
# /schema/1.4/Brick.ttl served 1.4.2 on 2026-10-01 -- always fetch the versioned URL.
# Findings: reference/brick-alignment-review.md
