// One node and what it feeds, or what feeds it (GET /api/section), on the range's last day
// (decision 20): what it feeds as a single-line diagram (sld.ts, tools/sld.py's drawing) or an
// indented tree, what feeds it as the tree. Clicking a node puts it on the widget's channel.
//
// The diagram can carry one total per node over the range (GET /api/aggregate) and up to three
// readings at the range's end (GET /api/now/nodes), each meter's where it sits: on its node, or on the
// feeder into it (design/frontend.md §5, "The single-line diagram with values"). The drawing leaves
// value rows and says where; the figures are a second SVG over it in the same coordinates, so a refresh
// redraws only them. Feeders get rows only when a drawn feeder has a meter.
import { useQueries, useQuery } from '@tanstack/react-query';
import type { MouseEvent } from 'react';
import { useMemo, useState } from 'react';
import { get } from '../api/client';
import { useVocabulary } from '../api/hooks';
import type { NowNodes } from '../api/types';
import type { Aggregate } from '../types/formats/aggregate';
import type { Subgraph } from '../types/formats/subgraph';
import { show } from '../time/range';
import { Select } from '../ui/Select';
import { Field, Findings, Hint, NodeName, NodePicker, Pending } from './common';
import type { Anchor, Figure, Options, Palette } from './sld';
import { draw, PRINT, withFigures } from './sld';
import type { SettingsProps, View as Window, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';
import { useHeldView } from './fresh';
import { quantityLabel, useOffered } from './Value';
import { Tip } from '../ui/Tip';
import { NumberField } from '../ui/NumberField';

interface S {
  node: number | null;
  depth: number;
  direction: 'down' | 'up';
  view: 'diagram' | 'tree';
  /** A total to show at each node of the diagram (a counter the solver resolves, or derived); null for none.
   * Absent in dashboards saved before 2026-11-02. */
  quantity?: string | null;
  /** Up to three sampled quantities read at the range's end. Absent before 2026-11-02. */
  live?: string[];
}

const BATCH = 50;    // /api/aggregate's limit on node ids
const LIVE_BATCH = 300;    // /api/now/nodes's
const MAX_LIVE = 3;

/** Where a total came from, for its tooltip; Aggregate's words. */
const ORIGIN: Record<string, string> = {
  MEASURED: 'measured', ROLLUP: 'from its children', IN_EDGES: 'from its feeders', OUT_EDGES: 'from what it feeds',
  CHILDREN: 'from its children', INHERITED: "its feeder's", DERIVED: 'derived', NONE: 'no value', NO_METER: 'no meter',
};

/** A figure short enough for a diagram: whole numbers from 100 up, else two significant decimals. */
function figure(v: number | null | undefined): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return '—';
  const digits = Math.abs(v) >= 100 ? 0 : Math.abs(v) >= 10 ? 1 : 2;
  return v.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

type N = Subgraph['nodes'][number];

/** The reached nodes in walk order: each under the node it was reached from. */
function tree(doc: Subgraph, direction: S['direction']) {
  const byCode = new Map(doc.nodes.map((n) => [n.code, n]));
  const next = new Map<string, string[]>();
  for (const e of doc.edges) {
    const [a, b] = direction === 'down' ? [e.from, e.to] : [e.to, e.from];
    if (!next.has(a)) next.set(a, []);
    next.get(a)!.push(b);
  }
  const out: { node: N; level: number }[] = [];
  const seen = new Set<string>();
  const walk = (n: N, level: number) => {
    if (seen.has(n.code)) return;
    seen.add(n.code);
    out.push({ node: n, level });
    for (const c of (next.get(n.code) ?? []).sort()) {
      const m = byCode.get(c);
      if (m?.scope === 'reached' && m.depth === (n.depth ?? 0) + 1) walk(m, level + 1);
    }
  };
  const root = doc.nodes.find((n) => n.depth === 0);
  if (root) walk(root, 0);
  return out;
}

function palette(): Palette {
  const css = getComputedStyle(document.documentElement);
  const v = (name: string) => css.getPropertyValue(name).trim();
  return { ink: v('--text'), muted: v('--muted'), mv: v('--sld-mv'), lv: v('--sld-lv'), warn: v('--warn'), paper: v('--panel') };
}

/** The totals of one quantity at the drawn nodes over the window, in batches of BATCH node ids. */
function useTotals(quantity: string | null, ids: number[], live: Window) {
  const [view, track] = useHeldView(live, [quantity, ids]);
  const batches: number[][] = [];
  for (let i = 0; i < ids.length; i += BATCH) batches.push(ids.slice(i, i + BATCH));
  const qs = useQueries({
    queries: batches.map((nodes) => ({
      queryKey: ['plant', view.tenant, 'aggregate', quantity, nodes, view.start, view.end, view.tick],
      queryFn: ({ signal }: { signal: AbortSignal }) => get<Aggregate>('/api/aggregate', {
        quantity, nodes: nodes.join(','), start: view.start, end: view.end,
      }, signal),
      enabled: quantity !== null,
      placeholderData: (prev: Aggregate | undefined) => prev,
    })),
  });
  track(...qs.map((q) => q.data));
  if (quantity === null) return null;
  const done = qs.filter((q) => q.data).map((q) => q.data!);
  const all = [...new Map(done.flatMap((r) => r.findings).map((f) => [`${f.code} ${f.node_id} ${f.message}`, f])).values()];
  // a finding about one node goes with its figure; the rest (the window's) are listed under the drawing
  const about = new Map<number, string[]>();
  for (const f of all) if (f.node_id !== undefined) about.set(f.node_id, [...(about.get(f.node_id) ?? []), f.message]);
  return {
    rows: new Map(done.flatMap((r) => r.rows).map((r) => [r.node_id, r])),
    first: done[0] ?? null,
    about,
    findings: all.filter((f) => f.node_id === undefined),
    error: qs.find((q) => q.isError)?.error as Error | undefined,
    loading: qs.some((q) => !q.data || q.isPlaceholderData),
  };
}

type Totals = NonNullable<ReturnType<typeof useTotals>>;

type Device = NowNodes['devices'][number];

/** The last readings of codes at the range's end from every meter of the nodes ids, by where each sits. */
function useLive(codes: string[], ids: number[], live: Window) {
  const [view, track] = useHeldView(live, [codes, ids]);
  const batches: number[][] = [];
  for (let i = 0; i < ids.length; i += LIVE_BATCH) batches.push(ids.slice(i, i + LIVE_BATCH));
  const qs = useQueries({
    queries: batches.map((nodes) => ({
      queryKey: ['plant', view.tenant, 'now-nodes', codes, nodes, view.end, view.tick],
      queryFn: ({ signal }: { signal: AbortSignal }) => get<NowNodes>('/api/now/nodes', {
        nodes: nodes.join(','), quantities: codes.join(','), at: view.end,
      }, signal),
      enabled: codes.length > 0,
      placeholderData: (prev: NowNodes | undefined) => prev,
    })),
  });
  track(...qs.map((q) => q.data));
  if (!codes.length) return null;
  const done = qs.filter((q) => q.data).map((q) => q.data!);
  const devices = [...new Map(done.flatMap((r) => r.devices).map((d) => [d.device_id, d])).values()];
  const onNode = new Map<string, Device[]>();
  const onFeeder = new Map<string, Device[]>();
  for (const d of devices) {
    for (const p of d.on) {
      const [m, k] = p.kind === 'node' ? [onNode, p.node] : [onFeeder, `${p.from}>${p.to}`];
      m.set(k, [...(m.get(k) ?? []), d]);
    }
  }
  const notes = new Map<number, string[]>();
  for (const f of done.flatMap((r) => r.findings)) notes.set(f.device_id, [...(notes.get(f.device_id) ?? []), f.message]);
  return {
    codes, onNode, onFeeder, notes, devices,
    at: done[0]?.at ?? null,
    units: new Map((done[0]?.quantities ?? []).map((q) => [q.code, q.unit])),
    error: qs.find((q) => q.isError)?.error as Error | undefined,
    loading: qs.some((q) => !q.data || q.isPlaceholderData),
  };
}

type Live = NonNullable<ReturnType<typeof useLive>>;

/** One quantity's readings from the meters at one place: each meter's value, or — when it has none. */
function liveText(live: Live, devices: Device[], code: string) {
  const unit = live.units.get(code) ? ` ${live.units.get(code)}` : '';
  const got = devices.map((d) => [d, d.readings.find((r) => r.quantity === code)] as const);
  const text = got.every(([, r]) => !r) ? '—' : got.map(([, r]) => (r ? figure(r.value) : '—')).join(' · ') + unit;
  const title = [code, ...got.map(([d, r]) => `${d.code}: ${r ? `${figure(r.value)}${unit} at ${show(r.at)}` : 'no reading'}`),
    ...devices.flatMap((d) => live.notes.get(d.device_id) ?? [])].join('\n');
  return { text, title, none: text === '—' };
}

type Placed = Figure & { node: string; feeder?: string };

/** Every figure of the drawing, where its anchor says. A node's rows are its total (if asked for), then
 * its readings; a feeder's rows its readings. The overlay and the exported file both draw these. */
function figures(anchors: Anchor[], ids: Map<string, number>, totals: Totals | null, live: Live | null): Placed[] {
  const unit = totals?.first?.quantity.unit ? ` ${totals.first.quantity.unit}` : '';
  const rows: (string | null)[] = [...(totals ? [null] : []), ...(live?.codes ?? [])];   // null: the total
  const out: Placed[] = [];
  for (const a of anchors) {
    const at = { x: a.x, y: a.y, anchor: a.anchor };
    if (a.kind === 'node' && rows[a.row] === null) {
      const id = ids.get(a.node);
      const r = id === undefined || !totals ? undefined : totals.rows.get(id);
      if (!r) continue;
      const has = r.total !== null && r.total !== undefined;
      const how = ORIGIN[r.origin] ?? r.origin;
      out.push({ ...at, node: a.node, kind: !has ? 'none' : r.origin === 'MEASURED' ? 'measured' : 'solved',
        text: has ? `${figure(r.total)}${unit}` : '—',
        title: [`${a.node}: ${has ? `${figure(r.total)}${unit}, ${how}` : how}`, ...(totals!.about.get(r.node_id) ?? [])].join('\n') });
      continue;
    }
    const code = a.kind === 'node' ? rows[a.row] : live?.codes[a.row];
    const devices = !live || !code ? undefined
      : a.kind === 'node' ? live.onNode.get(a.node) : live.onFeeder.get(`${a.from}>${a.to}`);
    if (!devices?.length || !code) continue;
    const t = liveText(live!, devices, code);
    out.push({ ...at, node: a.kind === 'node' ? a.node : a.to, feeder: a.kind === 'feeder' ? `${a.from}>${a.to}` : undefined,
      kind: t.none ? 'none' : 'live', text: t.text, title: t.title });
  }
  return out;
}

/** The figures over the drawing, in its coordinates; each says more in its tooltip. */
function Values({ figs, width, height }: { figs: Placed[]; width: number; height: number }) {
  return (
    <svg className="sld-values" viewBox={`0 0 ${width} ${height}`}>
      {figs.map((f, i) => (
        <text key={i} x={f.x} y={f.y} textAnchor={f.anchor} data-node={f.node} data-feeder={f.feeder} className={f.kind}>
          <title>{f.title}</title>
          {f.text}
        </text>
      ))}
    </svg>
  );
}

/** Downloads the drawing with its figures and legend as one SVG, in tools/sld.py's print colours and
 * named as it names its files; the caption says when the figures are from. */
function download(doc: Subgraph, opts: Options, figs: Placed[], caption: string) {
  const d = draw(doc, { ...opts, palette: PRINT, links: false, legend: true });
  const url = URL.createObjectURL(new Blob([withFigures(d.svg, figs, caption)], { type: 'image/svg+xml' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = `sld_${doc.query.root}_d${doc.query.depth}_${doc.query.as_of}.svg`;
  a.click();
  URL.revokeObjectURL(url);
}

/** How many drawn nodes have no figure; each says why in its tooltip. */
function Missing({ totals }: { totals: Totals }) {
  const n = [...totals.rows.values()].filter((r) => r.total === null || r.total === undefined).length;
  return n ? <> · <Tip tip="Hover a node's — for why">{n} without a figure</Tip></> : null;
}

/** What the drawing's symbols mean, as tools/sld.py's legend says it, outside the drawing. */
function Legend({ values }: { values: boolean }) {
  return (
    <div className="sld-legend muted">
      <span><i className="swatch mv" /> ≥ 1 kV</span> <span><i className="swatch lv" /> &lt; 1 kV</span>
      <span>☒ breaker · ▼ load · ▽ sink · ▢ conversion, treatment or storage · PV / G source · dashed = carries no flow</span>
      <span>feeders above a bar, loads below · ● connected to this bar; a line crossing a bar without a dot is not</span>
      <span className="warn">? or missing = a property not yet recorded · 2 live parents = connected to two bars,
        which the plant may not be · implicit bus = several children but no bus node</span>
      {values && <span><b>bold</b> = a total measured · <i>italic</i> = a total worked out on the graph · upright = a meter's
        reading at the range's end, on the feeder when the meter is there · — = no figure (hover for why)</span>}
    </div>
  );
}

/** The drawing at its own size, or fitted to the widget's width; a click on a node's code picks it. */
function Diagram({ doc, select, quantity, codes, view }: {
  doc: Subgraph; select: WidgetProps<S>['select']; quantity: string | null; codes: string[]; view: Window;
}) {
  const [fit, setFit] = useState(true);
  const [legend, setLegend] = useState(false);
  const ids = useMemo(() => new Map(doc.nodes.map((n) => [n.code, n.id])), [doc]);
  // every node that can be drawn: reached, and the parents drawn beside them (a second board, a PV plant)
  const asked = useMemo(() => doc.nodes.filter((n) => n.scope !== 'context').map((n) => n.id), [doc]);
  const reached = useMemo(() => new Set(doc.nodes.filter((n) => n.scope === 'reached').map((n) => n.code)), [doc]);
  const live = useLive(codes, asked, view);
  const feeders = !!live?.devices.some((m) => m.on.some((p) => p.kind === 'feeder' && reached.has(p.to)));
  const opts = useMemo(() => ({ rows: (quantity ? 1 : 0) + codes.length, feederRows: feeders ? codes.length : 0 }),
    [quantity, codes, feeders]);
  const d = useMemo(() => draw(doc, { ...opts, palette: palette(), links: true, legend: false }), [doc, opts]);
  const offFeeders = useMemo(() => {
    if (!live) return 0;
    const drawn = new Set(d.anchors.flatMap((a) => (a.kind === 'feeder' ? [`${a.from}>${a.to}`] : [])));
    return [...live.onFeeder].filter(([k]) => !drawn.has(k)).reduce((n, [, ms]) => n + ms.length, 0);
  }, [d, live]);
  const drawn = useMemo(() => [...new Set(d.anchors.flatMap((a) => (a.kind === 'node' && ids.has(a.node) ? [ids.get(a.node)!] : [])))],
    [d, ids]);
  const totals = useTotals(quantity, drawn, view);
  const figs = useMemo(() => figures(d.anchors, ids, totals, live), [d, ids, totals, live]);
  const caption = [
    `As of ${doc.query.as_of}`,
    ...(totals?.first ? [`${totals.first.quantity.code} ${show(totals.first.window.start)} to ${show(totals.first.window.end)}`] : []),
    ...(live?.at ? [`${live.codes.join(', ')} at ${show(live.at)}`] : []),
  ].join(' · ');
  const pick = (e: MouseEvent) => {
    const code = (e.target as Element).closest('[data-node]')?.getAttribute('data-node');
    const id = code ? ids.get(code) : undefined;
    if (id !== undefined) select?.({ kind: 'node', id });
  };
  return (
    <>
      <div className={`scroll sld${fit ? ' fit' : ''}${select ? ' linked' : ''}`} onClick={pick}>
        <div className="sld-stage">
          <div dangerouslySetInnerHTML={{ __html: d.svg }} />
          {figs.length > 0 && <Values figs={figs} width={d.width} height={d.height} />}
        </div>
      </div>
      {legend && <Legend values={totals !== null || live !== null} />}
      <div className="foot muted">
        As of {doc.query.as_of}
        {totals?.first && <> · {totals.first.quantity.code} {show(totals.first.window.start)} to {show(totals.first.window.end)}</>}
        {totals && !totals.loading && <Missing totals={totals} />}
        {totals?.loading && !totals.error && <> · <span className="loading">loading figures…</span></>}
        {totals?.error && <> · <span className="error">figures: {totals.error.message}</span></>}
        {live?.at && <> · readings at {show(live.at)}</>}
        {offFeeders > 0 && <> · {offFeeders} meter(s) on a feeder not drawn here</>}
        {live?.loading && !live.error && <> · <span className="loading">loading readings…</span></>}
        {live?.error && <> · <span className="error">readings: {live.error.message}</span></>}
        {' · '}<button type="button" className="link" onClick={() => setFit(!fit)}>{fit ? 'Actual size' : 'Fit to width'}</button>
        {' · '}<button type="button" className="link" onClick={() => setLegend(!legend)}>{legend ? 'Hide legend' : 'Legend'}</button>
        {' · '}<button type="button" className="link" disabled={!!(totals?.loading || live?.loading)}
                        title="The drawing with its figures and legend, as an SVG file"
                        onClick={() => download(doc, opts, figs, caption)}>Export SVG</button>
        {select && ' · click a node to put it on the channel'}
      </div>
      {totals && <Findings findings={totals.findings.map((f) => ({ code: f.code, message: f.message }))} />}
    </>
  );
}

const NONE: string[] = [];

function View({ settings, entity, select, view }: WidgetProps<S>) {
  const node = nodeOf(entity, settings.node);
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'section', node, settings.depth, settings.direction, view.asOf],
    queryFn: ({ signal }) => get<Subgraph>('/api/section', {
      node, depth: settings.depth, direction: settings.direction, as_of: view.asOf,
    }, signal),
    enabled: node !== null,
    placeholderData: (prev) => prev,
  });
  if (node === null) return <Hint>Choose a node in the widget's settings, or follow a channel.</Hint>;
  if (settings.view === 'diagram' && settings.direction === 'down') {
    return (
      <Pending q={q}>
        {(doc) => (
          <div className="stack">
            <Diagram doc={doc} select={select} quantity={settings.quantity ?? null} codes={settings.live ?? NONE} view={view} />
            <Findings findings={doc.findings.filter((f) => f.code !== 'PROPERTY_GAP').map((f) => ({ code: f.code, message: f.message }))} />
          </div>
        )}
      </Pending>
    );
  }
  return (
    <Pending q={q}>
      {(doc) => (
        <div className="scroll">
          <ul className="tree">
            {tree(doc, settings.direction).map(({ node: n, level }) => (
              <li key={n.code} style={{ paddingLeft: `${level * 1.2}rem` }} className={n.id === node ? 'selected' : undefined}>
                <button type="button" className="link" onClick={() => select?.({ kind: 'node', id: n.id })}>
                  <b>{n.code}</b>
                </button>{' '}
                <span className="muted">{n.name} · {n.type}</span>
                {n.children_not_included > 0 && <span className="muted"> · {n.children_not_included} more below</span>}
              </li>
            ))}
          </ul>
          <div className="foot muted">
            {settings.direction === 'down' ? 'What it feeds' : 'What feeds it'}, {settings.depth} level(s), as of {doc.query.as_of}
          </div>
          <Findings findings={doc.findings.map((f) => ({ code: f.code, message: f.message }))} />
        </div>
      )}
    </Pending>
  );
}

function Settings({ settings, setSettings }: SettingsProps<S>) {
  return (
    <>
      <Field label="Node (a channel's node replaces it)">
        {settings.node !== null && <div><NodeName id={settings.node} /></div>}
        <NodePicker onPick={(node) => setSettings({ ...settings, node })} />
      </Field>
      <Field label="Drawn as">
        <Select<S['view']> label="Drawn as" value={settings.view} onChange={(view) => setSettings({ ...settings, view })}
                           options={[{ id: 'diagram', label: 'A single-line diagram (what it feeds only)' },
                                     { id: 'tree', label: 'An indented list' }]} />
      </Field>
      <Field label="Direction">
        <Select<S['direction']> label="Direction" value={settings.direction} onChange={(direction) => setSettings({ ...settings, direction })}
                                options={[{ id: 'down', label: 'What it feeds' }, { id: 'up', label: 'What feeds it, back to the sources' }]} />
      </Field>
      {settings.view === 'diagram' && settings.direction === 'down' && (
        <Field label="Figures on the diagram, over the range">
          <TotalSelect value={settings.quantity ?? null} onChange={(quantity) => setSettings({ ...settings, quantity })} />
        </Field>
      )}
      {settings.view === 'diagram' && settings.direction === 'down' && (
        <Field label={`Readings at the range's end, on each meter's node or feeder (up to ${MAX_LIVE})`}>
          <LiveSelect value={settings.live ?? []} onChange={(live) => setSettings({ ...settings, live })} />
        </Field>
      )}
      <Field label="Levels" group>
        <NumberField label="Levels" min={1} max={12} value={settings.depth} onChange={(depth) => setSettings({ ...settings, depth })} />
      </Field>
    </>
  );
}

/** The totals the solver gives every node: counters with a rule, and the derived quantities. */
function TotalSelect({ value, onChange }: { value: string | null; onChange: (q: string | null) => void }) {
  const v = useVocabulary().data;
  const totals = v ? [
    ...v.quantities.filter((q) => q.node_value && q.reading === 'COUNTER').map((q) => ({ code: q.code, unit: q.unit })),
    ...v.derived_quantities.map((q) => ({ code: q.code, unit: q.unit })),
  ] : [];
  return (
    <Select label="Figures" value={value ?? 'none'} onChange={(q) => onChange(q === 'none' ? null : q)}
            options={[{ id: 'none', label: 'None' },
                      ...(!v && value ? [{ id: value, label: value }] : []),
                      ...totals.map((q) => ({ id: q.code, label: quantityLabel(q.code, q.unit) }))]} />
  );
}

/** Up to MAX_LIVE sampled quantities, each picked from the same grouped list as Aggregate's. */
function LiveSelect({ value, onChange }: { value: string[]; onChange: (codes: string[]) => void }) {
  const groups = useOffered([], '').map(([g, qs]) => [g, qs.filter((q) => !q.total)] as const).filter(([, qs]) => qs.length);
  const slots = [...value, ...(value.length < MAX_LIVE ? [''] : [])];
  const set = (i: number, code: string) => onChange([...new Set(slots.map((c, j) => (j === i ? code : c)).filter(Boolean))]);
  return (
    <div className="stack">
      {slots.map((c, i) => (
        <Select key={i} label={`Reading ${i + 1}`} value={c || 'none'} onChange={(code) => set(i, code === 'none' ? '' : code)}
                options={[{ id: 'none', label: c ? 'None' : 'Add a reading…' }, ...(!groups.length && c ? [{ id: c, label: c }] : [])]}
                groups={groups.map(([g, qs]) => ({ title: g, options: qs.map((q) => ({ id: q.code, label: quantityLabel(q.code, q.unit) })) }))} />
      ))}
    </div>
  );
}

export const section: WidgetType<S> = {
  type: 'section', label: 'Plant section',
  description: 'A node and what it feeds, as a single-line diagram, or the path back to its sources, on the range\'s last day.',
  minW: 5, minH: 5, w: 8, h: 10,
  defaults: { node: null, depth: 2, direction: 'down', view: 'diagram', quantity: null, live: [] },
  View, Settings,
};
