// A single-line diagram of an o-mcp/subgraph v1 document walked down from its root: tools/sld.py's
// layout and drawing, ported line for line so both draw the same SVG (sld.test.ts compares them on
// documents from dev). Read tools/sld.py's docstring for how the layout reads; the comments here
// are its own.
//
// Two additions for the frontend, both off by default so the comparison holds: a palette in place
// of the fixed colours, and data-node on each drawn node's code, so a click can find the node.
import type { Subgraph } from '../types/formats/subgraph';

export interface Palette { ink: string; muted: string; mv: string; lv: string; warn: string; paper: string }
export const PRINT: Palette = { ink: '#1f2937', muted: '#6b7280', mv: '#b91c1c', lv: '#1d4ed8', warn: '#b45309', paper: 'white' };

const SLOT = 160;          // horizontal space per leaf or per feeder
const MARGIN = 60;
const TOP = 80;            // title block
const BAR_GAP = 36;        // between stacked busbars
const [EDGE_TX, EDGE_INJ, EDGE_PLAIN, STUB] = [150, 120, 70, 24];    // feeder section heights
const INJECTION_TYPES = new Set(['PV_INJECTION', 'GENERATOR_INFEED']);

type Attrs = Record<string, unknown>;
type DocNode = Subgraph['nodes'][number];
interface Node extends Omit<DocNode, 'depth'> { depth: number | null; n_children: number; co?: boolean; attrs: Attrs }
interface Edge {
  from: string; to: string; edge_type: string | null; utility: string; carries_flow: boolean;
  from_depth: number | null; from_class: string; from_name: string; from_type: string | null; from_attrs: Attrs;
}
interface Data {
  tenant: number; as_of: string; depth: number; utility: string | null; root: string | null;
  nodes: Node[]; edges: Edge[]; parents: Node[]; up_edges: Edge[]; findings: Subgraph['findings'];
}
type Kind = 'tree' | 'stub' | 'inject';
type Feeder = [string, Edge, Kind];

// -- Python's ways, where JavaScript's differ ---------------------------------------------------------
/** format(x, 'g'): six significant digits, trailing zeros dropped. */
export function g(x: number): string {
  if (x === 0) return Object.is(x, -0) ? '-0' : '0';
  const [m, e] = x.toExponential(5).split('e');
  const exp = Number(e);
  if (exp < -4 || exp >= 6) {
    const mant = m.replace(/\.?0+$/, '');
    return `${mant}e${exp < 0 ? '-' : '+'}${String(Math.abs(exp)).padStart(2, '0')}`;
  }
  const s = x.toFixed(5 - exp);
  return s.includes('.') ? s.replace(/\.?0+$/, '') : s;
}

/** str(v) for what JSON gives: numbers, strings, and None for null. */
function str(v: unknown): string {
  return v === null || v === undefined ? 'None' : String(v);
}

function escape(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#x27;');
}

type Key = (boolean | number | string | null)[];
/** sorted(xs, key=k): tuples compared in order, False before True. */
function sorted<T>(xs: Iterable<T>, key: (x: T) => Key): T[] {
  const cmp = (a: Key, b: Key) => {
    for (let i = 0; i < Math.min(a.length, b.length); i++) {
      const x = typeof a[i] === 'boolean' ? Number(a[i]) : a[i];
      const y = typeof b[i] === 'boolean' ? Number(b[i]) : b[i];
      if (x! < y!) return -1;
      if (x! > y!) return 1;
    }
    return a.length - b.length;
  };
  return [...xs].map((x) => [key(x), x] as const).sort((p, q) => cmp(p[0], q[0])).map((p) => p[1]);
}

function list<K, V>(m: Map<K, V[]>, k: K): V[] {
  return m.get(k) ?? [];
}

function push<K, V>(m: Map<K, V[]>, k: K, v: V) {
  const l = m.get(k);
  if (l) l.push(v); else m.set(k, [v]);
}

function has(attrs: Attrs | null | undefined, k: string): boolean {
  return !!attrs && Object.prototype.hasOwnProperty.call(attrs, k);
}

function get(attrs: Attrs | null | undefined, k: string): unknown {
  return has(attrs, k) ? attrs![k] : null;
}

function nonNull(v: unknown): boolean {
  return v !== null && v !== undefined;
}

// -- data ---------------------------------------------------------------------------------------------
/** Reshape a downward o-mcp/subgraph v1 document for the layout: reached nodes, edges into them,
 * and the unreached parents with their own supply, each edge carrying its parent's details. */
export function fromV1(doc: Subgraph): Data {
  if (doc.schema !== 'o-mcp/subgraph' || doc.version !== 1) throw new Error(`Expected o-mcp/subgraph version 1.`);
  const q = doc.query;
  if ((q.direction ?? 'down') !== 'down') throw new Error(`Only downward sections are drawn.`);
  const nodes = new Map<string, Node>(doc.nodes.map((n) => [n.code, { ...n, attrs: n.attrs as Attrs, n_children: n.children_total }]));
  const reached = new Set([...nodes].filter(([, n]) => n.scope === 'reached').map(([c]) => c));
  const edge = (e: Subgraph['edges'][number]): Edge => {
    const f = nodes.get(e.from)!;
    return {
      from: e.from, to: e.to, edge_type: e.type, utility: e.utility, carries_flow: e.carries_flow,
      from_depth: f.depth, from_class: f.class, from_name: f.name, from_type: f.type, from_attrs: f.attrs,
    };
  };
  return {
    tenant: q.tenant, as_of: q.as_of, depth: q.depth, utility: q.utility,
    root: reached.has(q.root) ? q.root : null,
    nodes: [...nodes].filter(([c]) => reached.has(c)).map(([, n]) => n),
    edges: doc.edges.filter((e) => reached.has(e.to)).map(edge),
    parents: [...nodes.values()].filter((n) => n.scope === 'parent'),
    up_edges: doc.edges.filter((e) => !reached.has(e.to)).map(edge),
    findings: doc.findings,
  };
}

// -- layout -------------------------------------------------------------------------------------------
function isInjection(e: Edge) {
  return e.from_class === 'SOURCE' && INJECTION_TYPES.has(e.edge_type ?? '');
}

/** A PV plant or generator the walk did not reach: drawn as a feeder of the bus it feeds. */
function unfedSource(e: Edge) {
  return e.from_class === 'SOURCE' && e.from_depth === null;
}

/** The main supply first: a non-injecting parent, a flow edge, then by code. */
function supplyKey(e: Edge): Key {
  return [isInjection(e), !e.carries_flow, e.from];
}

function edgeLabel(e: Edge) {
  return e.from_class === 'SOURCE' ? `${e.from} (${e.edge_type})` : e.from;
}

/** Units, not nodes, are laid out: a unit is one node, or a group of buses that feed the same
 * drawn children (stacked busbars). Each unit is as wide as its children or its feeders. */
class Layout {
  nodes: Map<string, Node>;
  root: string;
  depth: number;
  gaps = new Map<string, Set<string>>();
  multi = new Map<string, string[]>();
  implicit = new Set<string>();
  parent = new Map<string, string>();
  supply = new Map<string, Edge>();
  kind = new Map<string, Kind>();
  inject = new Map<string, Edge[]>();
  links = new Map<string, string[]>();
  also = new Map<string, string[]>();
  rep = new Map<string, string>();
  unit = new Map<string, string>();
  members = new Map<string, string[]>();
  kids = new Map<string, string[]>();
  linked = new Map<string, string[]>();
  feeders = new Map<string, Feeder[]>();
  ukids = new Map<string, string[]>();
  W = new Map<string, number>();
  ux = new Map<string, number>();
  fx = new Map<string, number[]>();
  mainX = new Map<string, number>();
  levels = new Map<number, string[]>();
  slots: number;
  colour = new Map<string, string>();

  constructor(data: Data, readonly p: Palette) {
    const N = this.nodes = new Map(data.nodes.map((n) => [n.code, { ...n }]));
    const root = data.root;
    if (root === null || !N.has(root)) throw new Error(`No node in the effective window matches the root (as_of ${data.as_of}).`);
    this.root = root;
    this.depth = data.depth;
    for (const f of data.findings) {    // from the document's findings, not worked out here
      if (f.code === 'PROPERTY_GAP') {
        if (!this.gaps.has(f.node)) this.gaps.set(f.node, new Set());
        this.gaps.get(f.node)!.add(f.property);
      } else if (f.code === 'MULTIPLE_LIVE_PARENTS') this.multi.set(f.node, f.parents);
      else if (f.code === 'IMPLICIT_BUS') this.implicit.add(f.node);
    }
    const edges = sorted(data.edges, (e) => [!e.carries_flow, e.from]);
    const parentsInfo = new Map(data.parents.map((p) => [p.code, p]));
    const upEdges = data.up_edges;
    for (const c of N.keys()) this.rep.set(c, c);

    this.incoming(root, sorted(edges.filter((e) => e.to === root), supplyKey));

    // tree edges: each node hangs under one parent, one level up
    const rest: Edge[] = [];
    for (const e of edges) {
      const t = e.to;
      if (t === root) continue;
      if (!this.parent.has(t) && e.from_depth !== null && e.from_depth === N.get(t)!.depth! - 1) {
        this.parent.set(t, e.from);
        this.supply.set(t, e);
        this.kind.set(t, 'tree');
        push(this.links, t, e.from);
      } else rest.push(e);
    }

    // every other in-edge: an injecting source becomes a feeder above the bus; a second board at
    // the parent's level joins the parent's group; anything else is named, not drawn
    for (const e of rest) {
      const [f, t] = [e.from, e.to];
      const pp = this.parent.get(t);
      if (f === pp) continue;
      if (unfedSource(e) && N.get(t)!.class === 'BUS') push(this.inject, t, e);
      else if (e.from_class === 'BUS' && pp && N.get(pp)!.class === 'BUS'
               && (e.from_depth === N.get(pp)!.depth || (e.from_depth === null && parentsInfo.has(f)))) {
        if (!N.has(f)) {
          N.set(f, { ...parentsInfo.get(f)!, depth: N.get(pp)!.depth, co: true });
          this.rep.set(f, f);
        }
        this.union(f, pp);
        push(this.links, t, f);
      } else push(this.also, t, edgeLabel(e));
    }

    for (const c of [...N].filter(([, n]) => n.co).map(([c]) => c)) {   // a second board's own supply
      this.incoming(c, sorted(upEdges.filter((e) => e.to === c), supplyKey));
    }

    // units
    for (const c of N.keys()) this.unit.set(c, this.find(c));
    for (const c of sorted(N.keys(), (c) => [c !== root, !!N.get(c)!.co, c])) push(this.members, this.unit.get(c)!, c);
    for (const c of sorted(this.parent.keys(), (c) => [!this.supply.get(c)!.carries_flow, c])) push(this.kids, this.parent.get(c)!, c);
    for (const [c, ps] of this.links) for (const p of ps) push(this.linked, p, c);   // every drawn child hanging from a bar

    for (const [u, ms] of this.members) {
      const fs: Feeder[] = [];
      for (const m of ms) {
        if (this.supply.has(m)) fs.push([m, this.supply.get(m)!, this.kind.get(m)!]);
        for (const e of list(this.inject, m)) fs.push([m, e, 'inject']);
      }
      this.feeders.set(u, fs);
    }

    for (const [u, ms] of this.members) {
      for (const m of ms) {
        for (const k of list(this.kids, m)) {
          const ku = this.unit.get(k)!;
          if (this.uparent(ku) === u && !list(this.ukids, u).includes(ku)) push(this.ukids, u, ku);
        }
      }
    }

    const ru = this.unit.get(root)!;
    this.width(ru);
    this.place(ru, 0);
    this.slots = this.W.get(ru)!;
    this.colourAll();
  }

  private incoming(c: string, es: Edge[]) {
    if (!es.length) return;
    const first = es[0];
    this.supply.set(c, first);
    this.kind.set(c, unfedSource(first) && isInjection(first) ? 'inject' : 'stub');
    for (const e of es.slice(1)) {
      if (unfedSource(e) && this.nodes.get(c)!.class === 'BUS') push(this.inject, c, e);
      else push(this.also, c, edgeLabel(e));
    }
  }

  private find(c: string): string {
    while (this.rep.get(c) !== c) {
      this.rep.set(c, this.rep.get(this.rep.get(c)!)!);
      c = this.rep.get(c)!;
    }
    return c;
  }

  private union(a: string, b: string) {
    const [ra, rb] = [this.find(a), this.find(b)];
    if (ra !== rb) this.rep.set(ra, rb);
  }

  private uparent(u: string): string | null {
    for (const m of list(this.members, u)) {
      if (this.parent.has(m)) return this.unit.get(this.parent.get(m)!)!;
    }
    return null;
  }

  private width(u: string): number {
    const w = list(this.ukids, u).reduce((a, k) => a + this.width(k), 0);
    this.W.set(u, Math.max(w, this.feeders.get(u)!.length, 1));
    return this.W.get(u)!;
  }

  private place(u: string, left: number) {
    push(this.levels, this.nodes.get(this.members.get(u)![0])!.depth!, u);
    const W = this.W.get(u)!;
    const cx = MARGIN + (left + W / 2) * SLOT;
    this.ux.set(u, cx);
    const fs = this.feeders.get(u)!;
    this.fx.set(u, fs.map((_, i) => cx + (i - (fs.length - 1) / 2) * SLOT));
    fs.forEach(([m, e], i) => {
      if (!this.mainX.has(m) && e === this.supply.get(m)) this.mainX.set(m, this.fx.get(u)![i]);
    });
    for (const m of this.members.get(u)!) if (!this.mainX.has(m)) this.mainX.set(m, cx);
    let pos = left + (W - list(this.ukids, u).reduce((a, k) => a + this.W.get(k)!, 0)) / 2;
    for (const k of list(this.ukids, u)) {
      this.place(k, pos);
      pos += this.W.get(k)!;
    }
  }

  private colourAll() {
    const N = this.nodes;
    const rs = this.supply.get(this.root);
    for (const c of sorted(N.keys(), (c) => [N.get(c)!.depth, !!N.get(c)!.co])) {
      const own = voltColour(N.get(c)!.attrs, this.p);
      if (own) this.colour.set(c, own);
      else if (this.parent.has(c)) this.colour.set(c, this.colour.get(this.parent.get(c)!) ?? this.p.ink);
      else if (c === this.root && rs) this.colour.set(c, voltColour(rs.from_attrs, this.p) ?? this.p.ink);
      else this.colour.set(c, this.colour.get(this.members.get(this.unit.get(c)!)![0]) ?? this.p.ink);
    }
  }

  /** Children of c that are not drawn hanging from c. */
  more(c: string) {
    return this.nodes.get(c)!.n_children - list(this.linked, c).length;
  }
}

function voltColour(attrs: Attrs | null, p: Palette): string | null {
  const v = get(attrs, 'nominal_v');
  if (v === null || v === undefined) return null;
  return (v as number) >= 1000 ? p.mv : p.lv;
}

function kv(v: unknown) {
  if (v === null || v === undefined) return '? V';
  const n = v as number;
  return n >= 1000 ? `${g(n / 1000)} kV` : `${g(n)} V`;
}

function short(s: string, n = 24) {
  const cs = Array.from(s);
  return cs.length <= n ? s : cs.slice(0, n - 1).join('') + '…';
}

// -- drawing ------------------------------------------------------------------------------------------
type Span = [string, string, string, boolean];

/** Three layers so that symbols sit on lines and text sits on both. */
class Svg {
  l: string[] = [];
  s: string[] = [];
  t: string[] = [];

  constructor(readonly p: Palette, readonly links: boolean) {}

  svg() {
    return [...this.l, ...this.s, ...this.t];
  }

  text(x: number, y: number, s: string, size = 11, fill = this.p.ink, anchor = 'middle', weight = 'normal', italic = false,
       halo = false, node?: string) {
    this.spans(x, y, [[s, fill, weight, italic]], size, anchor, halo, node);
  }

  spans(x: number, y: number, parts: Span[], size = 11, anchor = 'middle', halo = false, node?: string) {
    const extra = halo ? ` stroke="${this.p.paper}" stroke-width="4" stroke-linejoin="round" paint-order="stroke"` : '';
    const link = this.links && node !== undefined ? ` data-node="${escape(node)}"` : '';
    const body = parts.map(([s, fill, weight, it]) =>
      `<tspan fill="${fill}" font-weight="${weight}"${it ? ' font-style="italic"' : ''}>${escape(s)}</tspan>`).join('');
    this.t.push(`<text x="${g(x)}" y="${g(y)}" font-size="${size}" text-anchor="${anchor}"${extra}${link}>${body}</text>`);
  }

  line(x1: number, y1: number, x2: number, y2: number, stroke = this.p.ink, w = 2, dash: string | null = null, layer: 'l' | 's' = 'l') {
    const d = dash ? ` stroke-dasharray="${dash}"` : '';
    this[layer].push(`<line x1="${g(x1)}" y1="${g(y1)}" x2="${g(x2)}" y2="${g(y2)}" stroke="${stroke}" stroke-width="${w}"${d}/>`);
  }

  shape(s: string) {
    this.s.push(s);
  }

  bar(x0: number, x1: number, y: number, col: string, w = 5) {
    this.line(x0, y, x1, y, col, w, null, 's');
  }

  dot(x: number, y: number, col: string) {
    this.shape(`<circle cx="${g(x)}" cy="${g(y)}" r="4" fill="${col}"/>`);
  }

  /** IEC circuit breaker, a square with an X; y is the top. Returns the bottom. An unknown rating
   * reads "? A" only when it is a reported property gap; a deliberate blank shows nothing. */
  breaker(x: number, y: number, amps: unknown, stroke: string, gap = false) {
    const s = 16;
    this.shape(`<rect x="${g(x - s / 2)}" y="${g(y)}" width="${s}" height="${s}" fill="${this.p.paper}" stroke="${stroke}" stroke-width="2"/>`);
    this.line(x - s / 2, y, x + s / 2, y + s, stroke, 1.5, null, 's');
    this.line(x + s / 2, y, x - s / 2, y + s, stroke, 1.5, null, 's');
    if (nonNull(amps)) this.text(x + 14, y + 12, `${str(amps)} A`, 11, this.p.muted, 'start');
    else if (gap) this.text(x + 14, y + 12, '? A', 11, this.p.warn, 'start');
    return y + s;
  }

  /** Two overlapping circles, primary above secondary; y is the top. Returns the bottom. */
  transformer(x: number, y: number, attrs: Attrs, hv: string, lv: string, gaps: Set<string>) {
    const r = 17;
    this.shape(`<circle cx="${g(x)}" cy="${g(y + r)}" r="${r}" fill="none" stroke="${hv}" stroke-width="2"/>`);
    this.shape(`<circle cx="${g(x)}" cy="${g(y + r * 2.3)}" r="${r}" fill="none" stroke="${lv}" stroke-width="2"/>`);
    if (has(attrs, 'rated_kva')) this.text(x + 24, y + 22, `${str(attrs.rated_kva)} kVA`, 11, this.p.ink, 'start', 'bold');
    else if (gaps.has('rated_kva')) this.text(x + 24, y + 22, '? kVA', 11, this.p.warn, 'start', 'bold');
    const [p, s] = [get(attrs, 'tx_primary_v') as number | null, get(attrs, 'nominal_v') as number | null];
    this.text(x + 24, y + 37, p && s ? `${g(p / 1000)}/${g(s / 1000)} kV` : '? kV', 11, this.p.muted, 'start');
    if (get(attrs, 'tx_equipment_code')) this.text(x + 24, y + 51, str(attrs.tx_equipment_code), 9, this.p.muted, 'start');
    return y + r * 3.3;
  }

  /** PV plant: a box marked PV. Generator: a circle marked G. Other sources: a circle with ~. */
  source(x: number, y: number, nodeType: string | null, col: string) {
    const t = nodeType || '';
    const mark = t.startsWith('PV') ? 'PV' : t.includes('GEN') ? 'G' : '~';
    if (mark === 'PV') {
      this.shape(`<rect x="${g(x - 18)}" y="${g(y)}" width="36" height="24" fill="${this.p.paper}" stroke="${col}" stroke-width="2"/>`);
    } else {
      this.shape(`<circle cx="${g(x)}" cy="${g(y + 12)}" r="12" fill="${this.p.paper}" stroke="${col}" stroke-width="2"/>`);
    }
    this.text(x, y + 16, mark, mark === 'PV' ? 11 : 12, col, 'middle', 'bold');
    return y + 24;
  }
}

/** The equipment on one feeder, bottom-aligned at y1: transformer and LV main, or a breaker. */
function symbols(svg: Svg, x: number, y0: number, y1: number, e: Edge, attrs: Attrs, hv: string, lv: string, gaps: Set<string>) {
  const dash = e.carries_flow ? null : '5 4';
  if (e.edge_type === 'TRANSFORMER') {
    const top = y1 - EDGE_TX + 25;
    svg.line(x, y0, x, top, hv, 2, dash);
    let y = svg.transformer(x, top, attrs, hv, lv, gaps);
    svg.line(x, y, x, y + 20, lv);
    y = svg.breaker(x, y + 20, get(attrs, 'main_breaker_a'), lv, gaps.has('main_breaker_a'));
    svg.line(x, y, x, y1, lv);
  } else if (nonNull(get(attrs, 'main_breaker_a')) || gaps.has('main_breaker_a')) {
    const b = y1 - 36;
    svg.line(x, y0, x, b, lv, 2, dash);
    const y = svg.breaker(x, b, get(attrs, 'main_breaker_a'), lv, gaps.has('main_breaker_a'));
    svg.line(x, y, x, y1, lv, 2, dash);
  } else {
    svg.line(x, y0, x, y1, lv, 2, dash);
  }
}

/** A node that is not a bar. Returns the y where its labels start. */
function glyph(svg: Svg, n: Node, col: string, x: number, y: number) {
  if (n.class === 'LOAD') {
    svg.shape(`<path d="M${g(x - 8)} ${g(y)} L${g(x + 8)} ${g(y)} L${g(x)} ${g(y + 13)} Z" fill="${col}"/>`);
    return y + 30;
  }
  if (n.class === 'SINK') {       // leaves the graph unconsumed: hollow, so it never reads as a load
    svg.shape(`<path d="M${g(x - 8)} ${g(y)} L${g(x + 8)} ${g(y)} L${g(x)} ${g(y + 13)} Z" fill="${svg.p.paper}" stroke="${col}" stroke-width="2"/>`);
    return y + 30;
  }
  if (n.class === 'SOURCE') {
    svg.source(x, y, n.type, col);
    return y + 40;
  }
  svg.shape(`<rect x="${g(x - 18)}" y="${g(y)}" width="36" height="22" rx="3" fill="${svg.p.paper}" stroke="${col}" stroke-width="2"/>`);
  return y + 38;
}

function typeLine(n: Node) {
  const v = get(n.attrs, 'nominal_v');
  return `${n.type || '(untyped)'}` + (nonNull(v) ? ` · ${kv(v)}` : '');
}

function warnings(lay: Layout, c: string) {
  const w: string[] = [];
  if (lay.multi.has(c)) w.push(`${lay.multi.get(c)!.length} live parents`);
  if (lay.gaps.get(c)?.size) w.push('missing ' + [...lay.gaps.get(c)!].sort().join(', '));
  if (list(lay.also, c).length) w.push('also fed by ' + [...list(lay.also, c)].sort().join(', '));
  return w;
}

/** Code, name, type under a leaf. Returns the bottom. */
function labels(svg: Svg, lay: Layout, c: string, y: number, x: number) {
  const n = lay.nodes.get(c)!;
  const p = svg.p;
  svg.text(x, y, n.code, 12, p.ink, 'middle', 'bold', false, true, n.code);
  svg.text(x, y + 15, short(n.name), 10, p.muted, 'middle', 'normal', false, true);
  svg.text(x, y + 30, typeLine(n), 10, p.muted, 'middle', 'normal', false, true);
  y += 30;
  for (const w of warnings(lay, c)) {
    y += 15;
    svg.text(x, y, w, 10, p.warn, 'middle', 'normal', true, true);
  }
  return y;
}

/** Two lines above a bar that has children, clear of its feeders and of the bar below. */
function barLabel(svg: Svg, lay: Layout, c: string, y: number, x: number, anchor: string) {
  const n = lay.nodes.get(c)!;
  const p = svg.p;
  const first: Span[] = [[n.code, p.ink, 'bold', false], ...warnings(lay, c).map((w): Span => [' · ' + w, p.warn, 'normal', true])];
  const second: Span[] = [[typeLine(n), p.muted, 'normal', false]];
  if (lay.more(c) > 0) second.push([` · +${lay.more(c)} not shown here`, p.warn, 'normal', true]);
  svg.spans(x, y - 20, first, 12, anchor, true, n.code);
  svg.spans(x, y - 7, second, 10, anchor, true);
}

/** One incoming feeder of m, from above down to m's bar or glyph. */
function drawFeeder(svg: Svg, lay: Layout, m: string, e: Edge, kind: Kind, x: number, top: number, anchor: number,
                    hasStub: boolean, outY: Map<string, number>) {
  const p = svg.p;
  const lv = lay.colour.get(m)!;
  const yEnd = outY.get(m) ?? anchor;
  if (kind === 'tree') {
    const par = lay.parent.get(m)!;
    const group = lay.members.get(lay.unit.get(par)!)!.filter((q) => outY.has(q));
    const ys = list(lay.links, m).map((q) => outY.get(q)!);
    if (group.length > 1) for (const q of list(lay.links, m)) svg.dot(x, outY.get(q)!, lay.colour.get(q)!);
    svg.text(x + 5, Math.max(...group.map((q) => outY.get(q)!)) + 14, e.edge_type || '(untyped)', 9, p.muted, 'start', 'normal', false, true);
    symbols(svg, x, Math.min(...ys), anchor, e, lay.nodes.get(m)!.attrs, lay.colour.get(par)!, lv, lay.gaps.get(m) ?? new Set());
  } else if (kind === 'stub') {
    const y0 = top + STUB - 4;
    svg.text(x + 5, top + 10, `from ${e.from}`, 10, p.muted, 'start', 'normal', true, true, e.from);
    svg.text(x + 5, y0 + 14, e.edge_type || '(untyped)', 9, p.muted, 'start', 'normal', false, true);
    symbols(svg, x, y0, anchor, e, lay.nodes.get(m)!.attrs, voltColour(e.from_attrs, p) ?? p.ink, lv, lay.gaps.get(m) ?? new Set());
  } else {
    const gy = top + (hasStub ? STUB : 0) + 26;     // clear of the bus above: a source hangs from nothing
    const yb = svg.source(x, gy, e.from_type, lv);
    svg.text(x + 24, gy + 10, e.from, 11, p.ink, 'start', 'bold', false, true, e.from);
    svg.text(x + 24, gy + 23, `${str(e.from_type)} · ${str(e.edge_type)}`, 9, p.muted, 'start', 'normal', false, true);
    symbols(svg, x, yb, anchor, e, e.from_attrs ?? {}, lv, lv, lay.gaps.get(e.from) ?? new Set());
  }
  if (yEnd > anchor) {   // down to a lower bar of a stack, crossing the bars above without a dot
    svg.line(x, anchor, x, yEnd, lv, 2, e.carries_flow ? null : '5 4');
  }
}

/** ▼ n more under a node whose children are not drawn. Returns the new bottom. */
function stubMore(svg: Svg, lay: Layout, c: string, x: number, y: number) {
  if (lay.more(c) <= 0 || list(lay.linked, c).length) return y;
  svg.line(x, y + 8, x, y + 26, lay.colour.get(c)!, 1.5, '4 3');
  svg.text(x, y + 40, `▼ ${lay.more(c)} more`, 10, svg.p.muted, 'middle', 'normal', true);
  return y + 40;
}

/** A grid incomer or generator at the top: symbol, ratings, main breaker. Returns the bottom. */
function rootSource(svg: Svg, lay: Layout, m: string, x: number, y: number) {
  const n = lay.nodes.get(m)!;
  const col = lay.colour.get(m)!;
  const a = n.attrs;
  const p = svg.p;
  svg.shape(`<circle cx="${g(x)}" cy="${g(y + 22)}" r="22" fill="${p.paper}" stroke="${col}" stroke-width="2"/>`);
  svg.shape(`<path d="M${g(x - 12)} ${g(y + 22)} q6 -10 12 0 t12 0" fill="none" stroke="${col}" stroke-width="2"/>`);
  svg.text(x + 34, y + 16, m, 13, p.ink, 'start', 'bold', false, false, m);
  svg.text(x + 34, y + 32, `${n.name} · ${str(n.type)}`, 11, p.muted, 'start');
  const extra = [
    ...(has(a, 'nominal_v') ? [kv(a.nominal_v)] : []),
    ...(has(a, 'contract_kva') ? [`contract ${str(a.contract_kva)} kVA`] : []),
    ...(has(a, 'tariff_code') ? [`tariff ${str(a.tariff_code)}`] : []),
  ];
  if (extra.length) svg.text(x + 34, y + 47, extra.join(' · '), 11, p.muted, 'start');
  svg.line(x, y + 44, x, y + 80, col);
  let b = y + 80;
  if (nonNull(get(a, 'main_breaker_a'))) b = svg.breaker(x, b, a.main_breaker_a, col, lay.gaps.get(m)?.has('main_breaker_a') ?? false);
  return b;
}

export interface Options {
  palette?: Palette;
  /** data-node="CODE" on each node's code, for clicks. */
  links?: boolean;
}

/** The diagram as SVG text, as tools/sld.py draws it. Every string in it is escaped. */
export function render(doc: Subgraph, { palette = PRINT, links = false }: Options = {}): string {
  const data = fromV1(doc);
  const p = palette;
  const lay = new Layout(data, p);
  const [N, D, root] = [lay.nodes, lay.depth, lay.root];
  const W = Math.max(MARGIN * 2 + SLOT * lay.slots, 980);
  const svg = new Svg(p, links);
  const outY = new Map<string, number>();
  const labelBottom = new Map<string, number>();
  const connY = new Map<string, number>();
  let y = TOP;

  for (let d = 0; d <= D; d++) {
    const units = lay.levels.get(d) ?? [];
    if (!units.length) break;
    // a parent that is not a bus: a connector down, and an implicit bus if it has several children
    if (d > 0) {
      for (const u of list(lay.levels, d - 1)) {
        for (const m of lay.members.get(u)!) {
          if (N.get(m)!.class === 'BUS' || !list(lay.kids, m).length) continue;
          const [col, x] = [lay.colour.get(m)!, lay.ux.get(u)!];
          if (list(lay.kids, m).length > 1) {
            const xs = [...list(lay.kids, m).map((k) => lay.mainX.get(k)!), x];
            svg.line(x, connY.get(m)!, x, y, col);
            svg.bar(Math.min(...xs) - 30, Math.max(...xs) + 30, y, col, 3);
            if (lay.implicit.has(m)) {    // a tank also fans out here, but no bus is missing
              svg.text(Math.min(...xs) - 30, y - 6, `implicit bus, no node (${m})`, 10, col, 'start', 'normal', true, true);
            }
            outY.set(m, y);
          } else {
            outY.set(m, connY.get(m)!);
          }
        }
      }
    }

    const feeds: [string, string, Edge, Kind, number][] = [];
    for (const u of units) lay.feeders.get(u)!.forEach(([m, e, k], i) => feeds.push([u, m, e, k, lay.fx.get(u)![i]]));
    const hasStub = feeds.some(([, , , k]) => k === 'stub');
    let E: number;
    if (!feeds.length) E = 0;
    else if (feeds.some(([, , e]) => e.edge_type === 'TRANSFORMER')) E = EDGE_TX;
    else if (feeds.some(([, , , k]) => k === 'inject')) E = EDGE_INJ;
    else E = EDGE_PLAIN;
    E += hasStub ? STUB : 0;
    const anchor = y + E;
    let bottom = anchor;

    const bars = new Map<string, number>();
    for (const u of units) {
      if (N.get(lay.members.get(u)![0])!.class === 'BUS') {
        lay.members.get(u)!.forEach((m, i) => {
          bars.set(m, anchor + i * BAR_GAP);
          outY.set(m, anchor + i * BAR_GAP);
        });
      }
    }

    for (const [, m, e, k, x] of feeds) drawFeeder(svg, lay, m, e, k, x, y, anchor, hasStub, outY);

    for (const u of units) {
      const ms = lay.members.get(u)!;
      const cx = lay.ux.get(u)!;
      if (bars.has(ms[0])) {
        for (const m of ms) {
          const fxs = lay.feeders.get(u)!.map(([mm], i) => [mm, lay.fx.get(u)![i]] as const).filter(([mm]) => mm === m).map(([, x]) => x);
          let xs = [...list(lay.linked, m).map((c) => lay.mainX.get(c)!), ...fxs];
          const [col, by] = [lay.colour.get(m)!, bars.get(m)!];
          if (list(lay.linked, m).length) {
            svg.bar(Math.min(...xs) - 30, Math.max(...xs) + 30, by, col);
            if (fxs.length) barLabel(svg, lay, m, by, Math.min(...fxs) - 12, 'end');
            else barLabel(svg, lay, m, by, Math.min(...xs) - 26, 'start');
            bottom = Math.max(bottom, by + 10);
          } else {
            xs = xs.length ? xs : [cx];
            svg.bar(Math.min(...xs, cx) - 60, Math.max(...xs, cx) + 60, by, col);
            labelBottom.set(m, labels(svg, lay, m, by + 20, cx));
            bottom = Math.max(bottom, stubMore(svg, lay, m, cx, labelBottom.get(m)!));
          }
        }
        continue;
      }
      const m = ms[0];
      if (m === root && N.get(m)!.class === 'SOURCE' && !lay.supply.has(m)) {
        const b = rootSource(svg, lay, m, cx, anchor);
        connY.set(m, b);
        labelBottom.set(m, b);
        bottom = Math.max(bottom, b + 10);
        continue;
      }
      const ly = glyph(svg, N.get(m)!, lay.colour.get(m)!, cx, anchor);
      labelBottom.set(m, labels(svg, lay, m, ly, cx));
      connY.set(m, labelBottom.get(m)! + 6);
      bottom = Math.max(bottom, stubMore(svg, lay, m, cx, labelBottom.get(m)!));
    }
    y = bottom + 30;
  }

  const H = y + 73;
  const util = data.utility ? ` · ${data.utility}` : '';
  const head = [`<svg xmlns="http://www.w3.org/2000/svg" width="${g(W)}" height="${g(H)}" viewBox="0 0 ${g(W)} ${g(H)}"`
    + ' font-family="Helvetica, Arial, sans-serif">', `<rect width="${g(W)}" height="${g(H)}" fill="${p.paper}"/>`];
  const frame = new Svg(p, false);
  frame.text(MARGIN - 20, 34, `SLD — ${root}, depth ${D}`, 18, p.ink, 'start', 'bold');
  frame.text(MARGIN - 20, 54, `tenant ${data.tenant} · as_of ${data.as_of}${util} · `
    + 'source: graph.node / graph.edge (effective window)', 12, p.muted, 'start');
  const ly = H - 63;
  frame.text(MARGIN - 20, ly, 'Legend:', 11, p.ink, 'start', 'bold');
  frame.line(MARGIN + 35, ly - 4, MARGIN + 60, ly - 4, p.mv, 4);
  frame.text(MARGIN + 66, ly, '≥ 1 kV', 11, p.mv, 'start');
  frame.line(MARGIN + 115, ly - 4, MARGIN + 140, ly - 4, p.lv, 4);
  frame.text(MARGIN + 146, ly, '< 1 kV', 11, p.lv, 'start');
  frame.text(MARGIN + 200, ly, '☒ breaker  ·  ▼ load  ·  ▽ sink  ·  ▢ conversion / treatment / storage  ·  '
    + 'PV / G source  ·  dashed = carries no flow', 11, p.muted, 'start');
  frame.text(MARGIN + 35, ly + 18, 'feeders above a bar, loads below  ·  ● connected to this bar; a line crossing '
    + 'a bar without a dot is not', 11, p.muted, 'start');
  frame.text(MARGIN + 35, ly + 36, '? / missing = a gap in graph.v_property_gaps  ·  2 live parents = connected to '
    + 'two bars, which the plant may not be  ·  implicit bus = several children but no bus node', 11, p.warn, 'start');
  return [...head, ...frame.svg(), ...svg.svg(), '</svg>'].join('\n');
}
