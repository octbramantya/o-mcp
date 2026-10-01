#!/usr/bin/env python3
"""Draw a single-line diagram (SVG) of one node and its descendants, from graph.node / graph.edge.

    tools/sld.py INCOMING_PLN                      # level 1, as of today, dev (.env)
    tools/sld.py INCOMING_PLN --depth 2 --as-of 2026-09-01
    tools/sld.py LVMDB_TEXTURE -d 2 -o texture.svg
    tools/sld.py --json data.json -o out.svg       # render a saved query result, no database

Read-only. The query is tools/sld.sql, which returns one o-mcp/subgraph v1 document (defined in
design/subgraph-format.md); --save-json writes that document, --json renders one. The query runs
through psql with the connection from the env file (-e, default .env) and nowhere else, the same
rule as tools/_env.sh: the file is parsed, never sourced, every key is required, and PG* variables
are cleared. Without -o the SVG goes to
logs/<DB_LABEL>/sld_<ROOT>_d<DEPTH>_<AS_OF>.svg.

Layout, the way site drawings read: every bus has its incoming feeders above it, side by side
(transformer, PV or generator, the supply of a second board), and its outgoing feeders below.
Boards that feed the same loads are drawn as stacked busbars; each load drops through them and
gets a dot on every bar it is connected to, and each bar spans only what is connected to it.

Everything drawn comes from the document. The findings in it are drawn, not recomputed: a node
with two live parents says so, and a property gap from graph.v_property_gaps shows as "missing ..."
and as "? A" on its breaker; a deliberate blank shows nothing. A node with several children but no
bus node is drawn fanning out from a bar, labelled "implicit bus" when the document has an
IMPLICIT_BUS finding for it (never for a tank), and a parent that fits none of the above is named
"also fed by".
"""
import argparse
import datetime
import json
import os
import pathlib
import subprocess
import sys
from collections import defaultdict
from html import escape

ROOT_DIR = pathlib.Path(__file__).resolve().parent.parent
SQL = ROOT_DIR / "tools/sld.sql"
ENV_KEYS = ("LABEL", "HOST", "PORT", "NAME", "USER", "PASSWORD")

INK, MUTED, MV, LV, WARN, PAPER = "#1f2937", "#6b7280", "#b91c1c", "#1d4ed8", "#b45309", "white"

SLOT = 160          # horizontal space per leaf or per feeder
MARGIN = 60
TOP = 80            # title block
BAR_GAP = 36        # between stacked busbars
EDGE_TX, EDGE_INJ, EDGE_PLAIN, STUB = 150, 120, 70, 24    # feeder section heights
INJECTION_TYPES = {"PV_INJECTION", "GENERATOR_INFEED"}
SCHEMA, VERSION = "o-mcp/subgraph", 1     # design/subgraph-format.md


# ---------------------------------------------------------------------------
# data
# ---------------------------------------------------------------------------
def load_env(path):
    if not path.is_file():
        sys.exit(f"sld.py: {path} not found. Copy .env.example and fill it in.")
    vals = {}
    for raw in path.read_text().splitlines():
        if "=" in raw and not raw.lstrip().startswith("#"):
            k, v = raw.split("=", 1)
            vals[k.strip()] = v.strip().strip("\r").strip('"').strip("'")
    conn = {}
    for k in ENV_KEYS:
        if not vals.get(f"DB_{k}"):
            sys.exit(f"sld.py: {path} is missing DB_{k}. See .env.example.")
        conn[k] = vals[f"DB_{k}"]
    return conn


def query(conn, tenant, root, as_of, depth, utility):
    env = {k: v for k, v in os.environ.items() if not k.startswith("PG")}
    env.update(PGPASSWORD=conn["PASSWORD"], PGCONNECT_TIMEOUT="5")
    cmd = ["psql", "-X", "-At", "-v", "ON_ERROR_STOP=1",
           "-h", conn["HOST"], "-p", conn["PORT"], "-U", conn["USER"], "-d", conn["NAME"],
           "-v", f"tenant={tenant}", "-v", f"root={root}", "-v", f"as_of={as_of}",
           "-v", f"depth={depth}", "-v", f"utility={utility or ''}", "-f", str(SQL)]
    run = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if run.returncode:
        sys.exit(f"sld.py: query failed on {conn['LABEL']}:\n{run.stderr.strip()}")
    return json.loads(run.stdout)


def from_v1(doc):
    """Check an o-mcp/subgraph document is version 1, and reshape it for the layout: reached nodes,
    edges into them, and the unreached parents with their own supply, each edge carrying its
    parent's details."""
    if doc.get("schema") != SCHEMA or doc.get("version") != VERSION:
        sys.exit(f"sld.py: expected {SCHEMA} version {VERSION}, got {doc.get('schema')!r} version "
                 f"{doc.get('version')!r}. Re-run the query to get the current format.")
    q = doc["query"]
    nodes = {n["code"]: dict(n, n_children=n["children_total"]) for n in doc["nodes"]}
    reached = {c for c, n in nodes.items() if n["scope"] == "reached"}

    def edge(e):
        f = nodes[e["from"]]
        return {"from": e["from"], "to": e["to"], "edge_type": e["type"], "utility": e["utility"],
                "carries_flow": e["carries_flow"], "from_depth": f["depth"], "from_class": f["class"],
                "from_name": f["name"], "from_type": f["type"], "from_attrs": f["attrs"]}

    return {"tenant": q["tenant"], "as_of": q["as_of"], "depth": q["depth"], "utility": q["utility"],
            "root": q["root"] if q["root"] in reached else None,
            "nodes": [n for c, n in nodes.items() if c in reached],
            "edges": [edge(e) for e in doc["edges"] if e["to"] in reached],
            "parents": [n for c, n in nodes.items() if n["scope"] == "parent"],
            "up_edges": [edge(e) for e in doc["edges"] if e["to"] not in reached],
            "findings": doc["findings"]}


# ---------------------------------------------------------------------------
# layout
# ---------------------------------------------------------------------------
def is_injection(e):
    return e["from_class"] == "SOURCE" and e["edge_type"] in INJECTION_TYPES


def unfed_source(e):
    """A PV plant or generator the walk did not reach: drawn as a feeder of the bus it feeds."""
    return e["from_class"] == "SOURCE" and e["from_depth"] is None


def supply_key(e):
    """The main supply first: a non-injecting parent, a flow edge, then by code."""
    return is_injection(e), not e["carries_flow"], e["from"]


def edge_label(e):
    return f"{e['from']} ({e['edge_type']})" if e["from_class"] == "SOURCE" else e["from"]


class Layout:
    """Units, not nodes, are laid out: a unit is one node, or a group of buses that feed the same
    drawn children (stacked busbars). Each unit is as wide as its children or its feeders."""

    def __init__(self, data):
        self.nodes = N = {n["code"]: dict(n) for n in data["nodes"] or []}
        self.root = root = data["root"]
        if root is None or root not in N:
            sys.exit(f"sld.py: no node in the effective window matches the root (as_of {data['as_of']})")
        self.depth = data["depth"]
        self.gaps, self.multi = defaultdict(set), {}     # from the document's findings, not worked out here
        self.implicit = set()
        for f in data.get("findings") or []:
            if f["code"] == "PROPERTY_GAP":
                self.gaps[f["node"]].add(f["property"])
            elif f["code"] == "MULTIPLE_LIVE_PARENTS":
                self.multi[f["node"]] = f["parents"]
            elif f["code"] == "IMPLICIT_BUS":
                self.implicit.add(f["node"])
        edges = sorted(data["edges"] or [], key=lambda e: (not e["carries_flow"], e["from"]))
        parents_info = {p["code"]: p for p in data.get("parents") or []}
        up_edges = data.get("up_edges") or []

        self.parent, self.supply, self.kind = {}, {}, {}
        self.inject, self.links, self.also = defaultdict(list), defaultdict(list), defaultdict(list)
        self.rep = {c: c for c in N}

        self._incoming(root, sorted((e for e in edges if e["to"] == root), key=supply_key))

        # tree edges: each node hangs under one parent, one level up
        rest = []
        for e in edges:
            t = e["to"]
            if t == root:
                continue
            if t not in self.parent and e["from_depth"] is not None and e["from_depth"] == N[t]["depth"] - 1:
                self.parent[t], self.supply[t], self.kind[t] = e["from"], e, "tree"
                self.links[t].append(e["from"])
            else:
                rest.append(e)

        # every other in-edge: an injecting source becomes a feeder above the bus; a second board at
        # the parent's level joins the parent's group; anything else is named, not drawn
        for e in rest:
            f, t = e["from"], e["to"]
            pp = self.parent.get(t)
            if f == pp:
                continue
            if unfed_source(e) and N[t]["class"] == "BUS":
                self.inject[t].append(e)
            elif (e["from_class"] == "BUS" and pp and N[pp]["class"] == "BUS"
                  and (e["from_depth"] == N[pp]["depth"] or (e["from_depth"] is None and f in parents_info))):
                if f not in N:
                    N[f] = dict(parents_info[f], depth=N[pp]["depth"], co=True)
                    self.rep[f] = f
                self._union(f, pp)
                self.links[t].append(f)
            else:
                self.also[t].append(edge_label(e))

        for c in [c for c, n in N.items() if n.get("co")]:   # a second board's own supply
            self._incoming(c, sorted((e for e in up_edges if e["to"] == c), key=supply_key))

        # units
        self.unit = {c: self._find(c) for c in N}
        self.members = defaultdict(list)
        for c in sorted(N, key=lambda c: (c != root, bool(N[c].get("co")), c)):
            self.members[self.unit[c]].append(c)
        self.kids = defaultdict(list)
        for c in sorted(self.parent, key=lambda c: (not self.supply[c]["carries_flow"], c)):
            self.kids[self.parent[c]].append(c)
        self.linked = defaultdict(list)       # every drawn child hanging from a bar
        for c, ps in self.links.items():
            for p in ps:
                self.linked[p].append(c)

        self.feeders = {}
        for u, ms in self.members.items():
            fs = []
            for m in ms:
                if m in self.supply:
                    fs.append((m, self.supply[m], self.kind[m]))
                fs += [(m, e, "inject") for e in self.inject[m]]
            self.feeders[u] = fs

        self.ukids = defaultdict(list)
        for u, ms in self.members.items():
            for m in ms:
                for k in self.kids[m]:
                    ku = self.unit[k]
                    if self._uparent(ku) == u and ku not in self.ukids[u]:
                        self.ukids[u].append(ku)

        self.W, self.ux, self.fx, self.main_x = {}, {}, {}, {}
        self.levels = defaultdict(list)
        ru = self.unit[root]
        self._width(ru)
        self._place(ru, 0)
        self.slots = self.W[ru]
        self._colour()

    def _incoming(self, c, es):
        if not es:
            return
        first = es[0]
        self.supply[c] = first
        self.kind[c] = "inject" if unfed_source(first) and is_injection(first) else "stub"
        for e in es[1:]:
            if unfed_source(e) and self.nodes[c]["class"] == "BUS":
                self.inject[c].append(e)
            else:
                self.also[c].append(edge_label(e))

    def _find(self, c):
        while self.rep[c] != c:
            self.rep[c] = self.rep[self.rep[c]]
            c = self.rep[c]
        return c

    def _union(self, a, b):
        ra, rb = self._find(a), self._find(b)
        if ra != rb:
            self.rep[ra] = rb

    def _uparent(self, u):
        for m in self.members[u]:
            if m in self.parent:
                return self.unit[self.parent[m]]
        return None

    def _width(self, u):
        w = sum(self._width(k) for k in self.ukids[u])
        self.W[u] = max(w, len(self.feeders[u]), 1)
        return self.W[u]

    def _place(self, u, left):
        self.levels[self.nodes[self.members[u][0]]["depth"]].append(u)
        W = self.W[u]
        cx = MARGIN + (left + W / 2) * SLOT
        self.ux[u] = cx
        fs = self.feeders[u]
        self.fx[u] = [cx + (i - (len(fs) - 1) / 2) * SLOT for i in range(len(fs))]
        for (m, e, _), x in zip(fs, self.fx[u], strict=True):
            if m not in self.main_x and e is self.supply.get(m):
                self.main_x[m] = x
        for m in self.members[u]:
            self.main_x.setdefault(m, cx)
        pos = left + (W - sum(self.W[k] for k in self.ukids[u])) / 2
        for k in self.ukids[u]:
            self._place(k, pos)
            pos += self.W[k]

    def _colour(self):
        N, self.colour = self.nodes, {}
        rs = self.supply.get(self.root)
        for c in sorted(N, key=lambda c: (N[c]["depth"], bool(N[c].get("co")))):
            own = volt_colour(N[c]["attrs"])
            if own:
                self.colour[c] = own
            elif c in self.parent:
                self.colour[c] = self.colour.get(self.parent[c], INK)
            elif c == self.root and rs:
                self.colour[c] = volt_colour(rs["from_attrs"]) or INK
            else:
                self.colour[c] = self.colour.get(self.members[self.unit[c]][0], INK)

    def more(self, c):
        """Children of c that are not drawn hanging from c."""
        return self.nodes[c]["n_children"] - len(self.linked[c])


def volt_colour(attrs):
    v = (attrs or {}).get("nominal_v")
    if v is None:
        return None
    return MV if v >= 1000 else LV


def kv(v):
    if v is None:
        return "? V"
    return f"{v / 1000:g} kV" if v >= 1000 else f"{v:g} V"


def short(s, n=24):
    return s if len(s) <= n else s[: n - 1] + "…"


# ---------------------------------------------------------------------------
# drawing
# ---------------------------------------------------------------------------
class Svg:
    """Three layers so that symbols sit on lines and text sits on both."""

    def __init__(self):
        self.layers = {"l": [], "s": [], "t": []}

    def svg(self):
        return self.layers["l"] + self.layers["s"] + self.layers["t"]

    def text(self, x, y, s, size=11, fill=INK, anchor="middle", weight="normal", italic=False, halo=False):
        self.spans(x, y, [(s, fill, weight, italic)], size, anchor, halo)

    def spans(self, x, y, parts, size=11, anchor="middle", halo=False):
        extra = f' stroke="{PAPER}" stroke-width="4" stroke-linejoin="round" paint-order="stroke"' if halo else ""
        body = "".join(
            f'<tspan fill="{fill}" font-weight="{weight}"{" font-style=" + chr(34) + "italic" + chr(34) if it else ""}>'
            f"{escape(str(s))}</tspan>" for s, fill, weight, it in parts)
        self.layers["t"].append(f'<text x="{x:g}" y="{y:g}" font-size="{size}" text-anchor="{anchor}"{extra}>'
                                f"{body}</text>")

    def line(self, x1, y1, x2, y2, stroke=INK, w=2, dash=None, layer="l"):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.layers[layer].append(f'<line x1="{x1:g}" y1="{y1:g}" x2="{x2:g}" y2="{y2:g}" stroke="{stroke}"'
                                  f' stroke-width="{w}"{d}/>')

    def shape(self, s):
        self.layers["s"].append(s)

    def bar(self, x0, x1, y, col, w=5):
        self.line(x0, y, x1, y, col, w, layer="s")

    def dot(self, x, y, col):
        self.shape(f'<circle cx="{x:g}" cy="{y:g}" r="4" fill="{col}"/>')

    def breaker(self, x, y, amps, stroke, gap=False):
        """IEC circuit breaker, a square with an X; y is the top. Returns the bottom. An unknown
        rating reads "? A" only when it is a reported property gap; a deliberate blank shows nothing."""
        s = 16
        self.shape(f'<rect x="{x - s / 2:g}" y="{y:g}" width="{s}" height="{s}" fill="{PAPER}"'
                   f' stroke="{stroke}" stroke-width="2"/>')
        self.line(x - s / 2, y, x + s / 2, y + s, stroke, 1.5, layer="s")
        self.line(x + s / 2, y, x - s / 2, y + s, stroke, 1.5, layer="s")
        if amps is not None:
            self.text(x + 14, y + 12, f"{amps} A", 11, MUTED, "start")
        elif gap:
            self.text(x + 14, y + 12, "? A", 11, WARN, "start")
        return y + s

    def transformer(self, x, y, attrs, hv, lv, gaps=()):
        """Two overlapping circles, primary above secondary; y is the top. Returns the bottom."""
        r = 17
        self.shape(f'<circle cx="{x:g}" cy="{y + r:g}" r="{r}" fill="none" stroke="{hv}" stroke-width="2"/>')
        self.shape(f'<circle cx="{x:g}" cy="{y + r * 2.3:g}" r="{r}" fill="none" stroke="{lv}" stroke-width="2"/>')
        if "rated_kva" in attrs:
            self.text(x + 24, y + 22, f"{attrs['rated_kva']} kVA", 11, INK, "start", "bold")
        elif "rated_kva" in gaps:
            self.text(x + 24, y + 22, "? kVA", 11, WARN, "start", "bold")
        p, s = attrs.get("tx_primary_v"), attrs.get("nominal_v")
        self.text(x + 24, y + 37, f"{p / 1000:g}/{s / 1000:g} kV" if p and s else "? kV", 11, MUTED, "start")
        if attrs.get("tx_equipment_code"):
            self.text(x + 24, y + 51, attrs["tx_equipment_code"], 9, MUTED, "start")
        return y + r * 3.3

    def source(self, x, y, node_type, col):
        """PV plant: a box marked PV. Generator: a circle marked G. Other sources: a circle with ~."""
        t = node_type or ""
        mark = "PV" if t.startswith("PV") else "G" if "GEN" in t else "~"
        if mark == "PV":
            self.shape(f'<rect x="{x - 18:g}" y="{y:g}" width="36" height="24" fill="{PAPER}"'
                       f' stroke="{col}" stroke-width="2"/>')
        else:
            self.shape(f'<circle cx="{x:g}" cy="{y + 12:g}" r="12" fill="{PAPER}" stroke="{col}" stroke-width="2"/>')
        self.text(x, y + 16, mark, 11 if mark == "PV" else 12, col, weight="bold")
        return y + 24


def symbols(svg, x, y0, y1, e, attrs, hv, lv, gaps=()):
    """The equipment on one feeder, bottom-aligned at y1: transformer and LV main, or a breaker."""
    dash = None if e["carries_flow"] else "5 4"
    if e["edge_type"] == "TRANSFORMER":
        top = y1 - EDGE_TX + 25
        svg.line(x, y0, x, top, hv, 2, dash)
        y = svg.transformer(x, top, attrs, hv, lv, gaps)
        svg.line(x, y, x, y + 20, lv)
        y = svg.breaker(x, y + 20, attrs.get("main_breaker_a"), lv, "main_breaker_a" in gaps)
        svg.line(x, y, x, y1, lv)
    elif attrs.get("main_breaker_a") is not None or "main_breaker_a" in gaps:
        b = y1 - 36
        svg.line(x, y0, x, b, lv, 2, dash)
        y = svg.breaker(x, b, attrs.get("main_breaker_a"), lv, "main_breaker_a" in gaps)
        svg.line(x, y, x, y1, lv, 2, dash)
    else:
        svg.line(x, y0, x, y1, lv, 2, dash)


def glyph(svg, n, col, x, y):
    """A node that is not a bar. Returns the y where its labels start."""
    if n["class"] == "LOAD":
        svg.shape(f'<path d="M{x - 8:g} {y:g} L{x + 8:g} {y:g} L{x:g} {y + 13:g} Z" fill="{col}"/>')
        return y + 30
    if n["class"] == "SINK":       # leaves the graph unconsumed: hollow, so it never reads as a load
        svg.shape(f'<path d="M{x - 8:g} {y:g} L{x + 8:g} {y:g} L{x:g} {y + 13:g} Z" fill="{PAPER}"'
                  f' stroke="{col}" stroke-width="2"/>')
        return y + 30
    if n["class"] == "SOURCE":
        svg.source(x, y, n["type"], col)
        return y + 40
    svg.shape(f'<rect x="{x - 18:g}" y="{y:g}" width="36" height="22" rx="3" fill="{PAPER}"'
              f' stroke="{col}" stroke-width="2"/>')
    return y + 38


def type_line(n):
    v = n["attrs"].get("nominal_v")
    return f"{n['type'] or '(untyped)'}" + (f" · {kv(v)}" if v is not None else "")


def warnings(lay, c):
    w = []
    if c in lay.multi:
        w.append(f"{len(lay.multi[c])} live parents")
    if lay.gaps[c]:
        w.append("missing " + ", ".join(sorted(lay.gaps[c])))
    if lay.also[c]:
        w.append("also fed by " + ", ".join(sorted(lay.also[c])))
    return w


def labels(svg, lay, c, y, x):
    """Code, name, type under a leaf. Returns the bottom."""
    n = lay.nodes[c]
    svg.text(x, y, n["code"], 12, INK, weight="bold", halo=True)
    svg.text(x, y + 15, short(n["name"]), 10, MUTED, halo=True)
    svg.text(x, y + 30, type_line(n), 10, MUTED, halo=True)
    y += 30
    for w in warnings(lay, c):
        y += 15
        svg.text(x, y, w, 10, WARN, italic=True, halo=True)
    return y


def bar_label(svg, lay, c, y, x, anchor):
    """Two lines above a bar that has children, clear of its feeders and of the bar below."""
    n = lay.nodes[c]
    first = [(n["code"], INK, "bold", False)]
    first += [(" · " + w, WARN, "normal", True) for w in warnings(lay, c)]
    second = [(type_line(n), MUTED, "normal", False)]
    if lay.more(c) > 0:
        second.append((f" · +{lay.more(c)} not shown here", WARN, "normal", True))
    svg.spans(x, y - 20, first, 12, anchor, halo=True)
    svg.spans(x, y - 7, second, 10, anchor, halo=True)


def draw_feeder(svg, lay, m, e, kind, x, top, anchor, has_stub, out_y):
    """One incoming feeder of m, from above down to m's bar or glyph."""
    lv = lay.colour[m]
    y_end = out_y.get(m, anchor)
    if kind == "tree":
        p = lay.parent[m]
        group = [q for q in lay.members[lay.unit[p]] if q in out_y]
        ys = [out_y[q] for q in lay.links[m]]
        if len(group) > 1:
            for q in lay.links[m]:
                svg.dot(x, out_y[q], lay.colour[q])
        svg.text(x + 5, max(out_y[q] for q in group) + 14, e["edge_type"] or "(untyped)", 9, MUTED, "start", halo=True)
        symbols(svg, x, min(ys), anchor, e, lay.nodes[m]["attrs"], lay.colour[p], lv, lay.gaps[m])
    elif kind == "stub":
        y0 = top + STUB - 4
        svg.text(x + 5, top + 10, f"from {e['from']}", 10, MUTED, "start", italic=True, halo=True)
        svg.text(x + 5, y0 + 14, e["edge_type"] or "(untyped)", 9, MUTED, "start", halo=True)
        symbols(svg, x, y0, anchor, e, lay.nodes[m]["attrs"], volt_colour(e["from_attrs"]) or INK, lv,
                lay.gaps[m])
    else:
        gy = top + (STUB if has_stub else 0) + 26     # clear of the bus above: a source hangs from nothing
        yb = svg.source(x, gy, e["from_type"], lv)
        svg.text(x + 24, gy + 10, e["from"], 11, INK, "start", "bold", halo=True)
        svg.text(x + 24, gy + 23, f"{e['from_type']} · {e['edge_type']}", 9, MUTED, "start", halo=True)
        symbols(svg, x, yb, anchor, e, e["from_attrs"] or {}, lv, lv, lay.gaps[e["from"]])
    if y_end > anchor:   # down to a lower bar of a stack, crossing the bars above without a dot
        svg.line(x, anchor, x, y_end, lv, 2, None if e["carries_flow"] else "5 4")


def render(data):
    lay = Layout(data)
    N, D, root = lay.nodes, lay.depth, lay.root
    W = max(MARGIN * 2 + SLOT * lay.slots, 980)
    svg = Svg()
    out_y, label_bottom, conn_y = {}, {}, {}
    y = TOP

    for d in range(D + 1):
        units = lay.levels.get(d, [])
        if not units:
            break
        # a parent that is not a bus: a connector down, and an implicit bus if it has several children
        if d > 0:
            for u in lay.levels[d - 1]:
                for m in lay.members[u]:
                    if N[m]["class"] == "BUS" or not lay.kids[m]:
                        continue
                    col, x = lay.colour[m], lay.ux[u]
                    if len(lay.kids[m]) > 1:
                        xs = [lay.main_x[k] for k in lay.kids[m]]
                        svg.line(x, conn_y[m], x, y, col)
                        svg.bar(min(xs + [x]) - 30, max(xs + [x]) + 30, y, col, 3)
                        if m in lay.implicit:    # a tank also fans out here, but no bus is missing
                            svg.text(min(xs + [x]) - 30, y - 6, f"implicit bus, no node ({m})", 10, col,
                                     "start", italic=True, halo=True)
                        out_y[m] = y
                    else:
                        out_y[m] = conn_y[m]

        feeds = [(u, m, e, k, x) for u in units for (m, e, k), x in zip(lay.feeders[u], lay.fx[u], strict=True)]
        has_stub = any(k == "stub" for *_, k, _ in feeds)
        if not feeds:
            E = 0
        elif any(e["edge_type"] == "TRANSFORMER" for _, _, e, _, _ in feeds):
            E = EDGE_TX
        elif any(k == "inject" for *_, k, _ in feeds):
            E = EDGE_INJ
        else:
            E = EDGE_PLAIN
        E += STUB if has_stub else 0
        anchor = y + E
        bottom = anchor

        bars = {}
        for u in units:
            if N[lay.members[u][0]]["class"] == "BUS":
                for i, m in enumerate(lay.members[u]):
                    bars[m] = out_y[m] = anchor + i * BAR_GAP

        for _u, m, e, k, x in feeds:
            draw_feeder(svg, lay, m, e, k, x, y, anchor, has_stub, out_y)

        for u in units:
            ms = lay.members[u]
            cx = lay.ux[u]
            if ms[0] in bars:
                for m in ms:
                    fxs = [x for (mm, _, _), x in zip(lay.feeders[u], lay.fx[u], strict=True) if mm == m]
                    xs = [lay.main_x[c] for c in lay.linked[m]] + fxs
                    col, by = lay.colour[m], bars[m]
                    if lay.linked[m]:
                        svg.bar(min(xs) - 30, max(xs) + 30, by, col)
                        if fxs:
                            bar_label(svg, lay, m, by, min(fxs) - 12, "end")
                        else:
                            bar_label(svg, lay, m, by, min(xs) - 26, "start")
                        bottom = max(bottom, by + 10)
                    else:
                        xs = xs or [cx]
                        svg.bar(min(xs + [cx]) - 60, max(xs + [cx]) + 60, by, col)
                        label_bottom[m] = labels(svg, lay, m, by + 20, cx)
                        bottom = max(bottom, stub_more(svg, lay, m, cx, label_bottom[m]))
                continue
            m = ms[0]
            if m == root and N[m]["class"] == "SOURCE" and m not in lay.supply:
                conn_y[m] = label_bottom[m] = root_source(svg, lay, m, cx, anchor)
                bottom = max(bottom, conn_y[m] + 10)
                continue
            ly = glyph(svg, N[m], lay.colour[m], cx, anchor)
            label_bottom[m] = labels(svg, lay, m, ly, cx)
            conn_y[m] = label_bottom[m] + 6
            bottom = max(bottom, stub_more(svg, lay, m, cx, label_bottom[m]))
        y = bottom + 30

    H = y + 73
    util = f" · {data['utility']}" if data.get("utility") else ""
    head = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:g}" height="{H:g}" viewBox="0 0 {W:g} {H:g}"'
            ' font-family="Helvetica, Arial, sans-serif">',
            f'<rect width="{W:g}" height="{H:g}" fill="{PAPER}"/>']
    frame = Svg()
    frame.text(MARGIN - 20, 34, f"SLD — {root}, depth {D}", 18, INK, "start", "bold")
    frame.text(MARGIN - 20, 54, f"tenant {data['tenant']} · as_of {data['as_of']}{util} · "
               "source: graph.node / graph.edge (effective window)", 12, MUTED, "start")
    ly = H - 63
    frame.text(MARGIN - 20, ly, "Legend:", 11, INK, "start", "bold")
    frame.line(MARGIN + 35, ly - 4, MARGIN + 60, ly - 4, MV, 4)
    frame.text(MARGIN + 66, ly, "≥ 1 kV", 11, MV, "start")
    frame.line(MARGIN + 115, ly - 4, MARGIN + 140, ly - 4, LV, 4)
    frame.text(MARGIN + 146, ly, "< 1 kV", 11, LV, "start")
    frame.text(MARGIN + 200, ly, "☒ breaker  ·  ▼ load  ·  ▽ sink  ·  ▢ conversion / treatment / storage  ·  "
               "PV / G source  ·  dashed = carries no flow", 11, MUTED, "start")
    frame.text(MARGIN + 35, ly + 18, "feeders above a bar, loads below  ·  ● connected to this bar; a line crossing "
               "a bar without a dot is not", 11, MUTED, "start")
    frame.text(MARGIN + 35, ly + 36, "? / missing = a gap in graph.v_property_gaps  ·  2 live parents = connected to "
               "two bars, which the plant may not be  ·  implicit bus = several children but no bus node", 11, WARN,
               "start")
    return "\n".join(head + frame.svg() + svg.svg() + ["</svg>"])


def stub_more(svg, lay, c, x, y):
    """▼ n more under a node whose children are not drawn. Returns the new bottom."""
    if lay.more(c) <= 0 or lay.linked[c]:
        return y
    svg.line(x, y + 8, x, y + 26, lay.colour[c], 1.5, "4 3")
    svg.text(x, y + 40, f"▼ {lay.more(c)} more", 10, MUTED, italic=True)
    return y + 40


def root_source(svg, lay, m, x, y):
    """A grid incomer or generator at the top: symbol, ratings, main breaker. Returns the bottom."""
    n, col = lay.nodes[m], lay.colour[m]
    a = n["attrs"]
    svg.shape(f'<circle cx="{x:g}" cy="{y + 22:g}" r="22" fill="{PAPER}" stroke="{col}" stroke-width="2"/>')
    svg.shape(f'<path d="M{x - 12:g} {y + 22:g} q6 -10 12 0 t12 0" fill="none" stroke="{col}" stroke-width="2"/>')
    svg.text(x + 34, y + 16, m, 13, INK, "start", "bold")
    svg.text(x + 34, y + 32, f"{n['name']} · {n['type']}", 11, MUTED, "start")
    extra = [kv(a["nominal_v"])] if "nominal_v" in a else []
    extra += [f"contract {a['contract_kva']} kVA"] if "contract_kva" in a else []
    extra += [f"tariff {a['tariff_code']}"] if "tariff_code" in a else []
    if extra:
        svg.text(x + 34, y + 47, " · ".join(extra), 11, MUTED, "start")
    svg.line(x, y + 44, x, y + 80, col)
    b = y + 80
    if a.get("main_breaker_a") is not None:
        b = svg.breaker(x, b, a["main_breaker_a"], col, "main_breaker_a" in lay.gaps[m])
    return b


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("root", nargs="?", help="node_code to start from")
    ap.add_argument("-d", "--depth", type=int, default=1, help="levels below the root (default 1)")
    ap.add_argument("--as-of", default=datetime.date.today().isoformat(), help="effective date (default today)")
    ap.add_argument("--tenant", type=int, default=3)
    ap.add_argument("--utility", help="keep only this utility's edges, e.g. ELECTRICITY")
    ap.add_argument("-e", "--env", default=str(ROOT_DIR / ".env"), help="connection file (default .env)")
    ap.add_argument("-o", "--out", help="SVG path (default logs/<label>/sld_<root>_d<depth>_<as_of>.svg)")
    ap.add_argument("--json", help="render this saved o-mcp/subgraph v1 document instead of querying")
    ap.add_argument("--save-json", help="also write the o-mcp/subgraph v1 document here")
    args = ap.parse_args()

    if args.depth < 1:
        ap.error("--depth must be at least 1")
    datetime.date.fromisoformat(args.as_of)

    if args.json:
        doc, label = json.loads(pathlib.Path(args.json).read_text()), "json"
    else:
        if not args.root:
            ap.error("give a root node_code, or --json")
        conn = load_env(pathlib.Path(args.env))
        doc, label = query(conn, args.tenant, args.root, args.as_of, args.depth, args.utility), conn["LABEL"]
        if args.save_json:
            pathlib.Path(args.save_json).write_text(json.dumps(doc, indent=1) + "\n")
    data = from_v1(doc)

    out = pathlib.Path(args.out) if args.out else (
        ROOT_DIR / "logs" / label / f"sld_{doc['query']['root']}_d{data['depth']}_{data['as_of']}.svg")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(render(data))
    print(out)


if __name__ == "__main__":
    main()
