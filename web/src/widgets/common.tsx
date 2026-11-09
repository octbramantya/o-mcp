// Pieces the widgets share: node names and pickers, quantity pickers, findings, loading states, and
// an ECharts host.
import type { UseQueryResult } from '@tanstack/react-query';
import { BarChart, LineChart, SankeyChart } from 'echarts/charts';
import { GridComponent, LegendComponent, TooltipComponent } from 'echarts/components';
import * as echarts from 'echarts/core';
import { CanvasRenderer } from 'echarts/renderers';
import type { ReactNode } from 'react';
import { useEffect, useRef } from 'react';
import { useNodes, useVocabulary } from '../api/hooks';
import type { Finding } from '../api/types';
import { chartMinute } from '../time/range';
import type { Meters } from '../types/formats/meters';
import type { Match } from '../ui/ComboBox';
import { ComboBox } from '../ui/ComboBox';
import { Select } from '../ui/Select';

echarts.use([BarChart, LineChart, SankeyChart, GridComponent, LegendComponent, TooltipComponent, CanvasRenderer]);

/** A figure as shown everywhere: thousands separated, 2 decimals unless a widget asks otherwise. */
export function fmt(v: number | null | undefined, digits = 2): string {
  if (v === null || v === undefined || !Number.isFinite(v)) return '—';
  return v.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

/** A device's data concentrator as address:port, as the device register records it. */
export function gateway(d: Pick<Meters['devices'][number], 'gateway'>) {
  const g = d.gateway;
  if (!g) return <span className="muted">not recorded</span>;
  return <>{g.ip_address}{g.port !== null && `:${g.port}`}</>;
}

/** A stored node id as its current code and name; a node not in the plant today says so (decision 19). */
export function NodeName({ id }: { id: number }) {
  const n = useNodes().data?.byId.get(id);
  if (!n) return <span className="muted">node {id} (not in the plant today)</span>;
  return <span title={n.name ?? undefined}><b>{n.code}</b> {n.name && <span className="muted">{n.name}</span>}</span>;
}

/** Today's nodes by code or name, 12 at most, as you type. */
export function NodePicker({ onPick, placeholder = 'Find a node…' }: { onPick: (id: number) => void; placeholder?: string }) {
  const nodes = useNodes().data;
  const matches = (text: string): Match[] => {
    const t = text.trim().toLowerCase();
    return (nodes?.list ?? [])
      .filter((n) => n.code.toLowerCase().includes(t) || (n.name ?? '').toLowerCase().includes(t)).slice(0, 12)
      .map((n) => ({ id: n.id, text: n.name ? `${n.code} ${n.name}` : n.code, label: <><b>{n.code}</b> <span className="muted">{n.name}</span></> }));
  };
  return <ComboBox matches={matches} onPick={onPick} label="Find a node" placeholder={placeholder} />;
}

export function NodeList({ ids, onChange, max }: { ids: number[]; onChange: (ids: number[]) => void; max: number }) {
  return (
    <div>
      <ul className="chips">
        {ids.map((id) => (
          <li key={id}>
            <NodeName id={id} />
            <button type="button" className="link" onClick={() => onChange(ids.filter((x) => x !== id))}>remove</button>
          </li>
        ))}
      </ul>
      {ids.length < max && <NodePicker onPick={(id) => !ids.includes(id) && onChange([...ids, id])} />}
    </div>
  );
}

/** Quantities: those the solver resolves for a node (`value`), or everything meters report (`reading`). */
export function useQuantities(kind: 'value' | 'reading' | 'flow') {
  const v = useVocabulary().data;
  if (!v) return [];
  if (kind === 'reading') return v.quantities.map((q) => ({ code: q.code, unit: q.unit }));
  const rules = v.quantities.filter((q) => q.node_value).map((q) => ({ code: q.code, unit: q.unit, rule: q.rule }));
  if (kind === 'flow') return rules.filter((q) => q.rule?.conserved && q.rule.network_agg === 'SUM');
  return [...rules, ...v.derived_quantities.map((d) => ({ code: d.code, unit: d.unit, rule: null }))];
}

export function QuantitySelect({ value, onChange, kind }: { value: string; onChange: (q: string) => void; kind: 'value' | 'flow' }) {
  const qs = useQuantities(kind);
  return (
    <Select label="Quantity" value={qs.length ? value : null} placeholder={value} onChange={onChange}
            options={qs.map((q) => ({ id: q.code, label: `${q.code} (${q.unit})` }))} />
  );
}

/** A setting with its name above it. `group` for a control of several parts (a filter and a list), which a `<label>` would turn every click inside into a click on its first field. */
export function Field({ label, children, group }: { label: string; children: ReactNode; group?: boolean }) {
  if (group) return <div className="field" role="group" aria-label={label}><span>{label}</span>{children}</div>;
  return <label className="field"><span>{label}</span>{children}</label>;
}

export function Findings({ findings }: { findings: Finding[] }) {
  if (!findings.length) return null;
  return (
    <ul className="findings">
      {findings.map((f, i) => <li key={i} className={`finding ${f.code}`}><b>{f.code}</b> {f.message}</li>)}
    </ul>
  );
}

/** Loading and error states for a query; children render only with data. The previous answer stays
 * on screen while the next loads, dimmed and marked, so it is never taken for the new one. */
export function Pending<T>({ q, children }: { q: UseQueryResult<T>; children: (data: T) => ReactNode }) {
  if (q.isError) return <div className="error pad">{(q.error as Error).message}</div>;
  if (!q.data) return <div className="muted pad loading">Loading…</div>;
  if (!q.isPlaceholderData) return <>{children(q.data)}</>;
  return (
    <div className="stale stack">
      <span className="badge loading">Loading…</span>
      {children(q.data)}
    </div>
  );
}

export function Hint({ children }: { children: ReactNode }) {
  return <div className="muted pad">{children}</div>;
}

// Shared tooltip: the charts of a group show their tooltips at the time under the mouse in any one of
// them. Matched by time only, so meters with gaps or other intervals still line up; echarts.connect
// places the others' tooltips by the hovered chart's series and point index, and links legends too.
// One dashboard is on screen at a time, so a group needs no dashboard in its name.
const groups = new Map<string, Set<echarts.ECharts>>();
let hovered: echarts.ECharts | null = null;

/** Where a relayed tooltip goes: the middle of the first grid when its place is given in percent (a
 * chart of panels, chart.ts), else the middle of the chart, which in a panel chart can fall between two. */
function tipY(c: echarts.ECharts): number {
  const g = (c.getOption().grid as { top?: unknown; height?: unknown }[] | undefined)?.[0];
  const pct = (v: unknown) => (typeof v === 'string' && v.endsWith('%') ? parseFloat(v) / 100 : null);
  const top = pct(g?.top);
  const height = pct(g?.height);
  return top !== null && height !== null ? c.getHeight() * (top + height / 2) : c.getHeight() / 2;
}

function join(group: string, c: echarts.ECharts): () => void {
  const members = groups.get(group) ?? new Set<echarts.ECharts>();
  groups.set(group, members);
  members.add(c);
  const others = () => [...members].filter((o) => o !== c);
  // As if the mouse left them: hides the pointer line with the tooltip, which hideTip leaves drawn.
  const hide = () => others().forEach((o) => o.dispatchAction({ type: 'updateAxisPointer', currTrigger: 'leave' }));
  const zr = c.getZr();
  const enter = () => { hovered = c; };
  const leave = () => { if (hovered === c) hovered = null; hide(); };
  zr.on('mousemove', enter);
  zr.on('globalout', leave);
  // Only the chart under the mouse relays: the tooltips it shows elsewhere fire this event too.
  c.on('updateAxisPointer', (e) => {
    if (hovered !== c) return;
    const x = (e as { axesInfo?: { axisDim: string; value: number }[] }).axesInfo?.find((a) => a.axisDim === 'x');
    if (!x) { hide(); return; }
    for (const o of others()) {
      const px = o.convertToPixel({ xAxisIndex: 0 }, x.value);
      if (Number.isFinite(px)) o.dispatchAction({ type: 'showTip', x: px, y: tipY(o) });
      else o.dispatchAction({ type: 'updateAxisPointer', currTrigger: 'leave' });
    }
  });
  return () => {
    zr.off('mousemove', enter);
    zr.off('globalout', leave);
    if (hovered === c) hovered = null;
    members.delete(c);
    if (!members.size) groups.delete(group);
  };
}

type Rect = { x: number; y: number; width: number; height: number };

type Grids = { getModel(): { getComponent(type: 'grid', i: number): { coordinateSystem?: { getRect(): Rect } } | undefined } };

/** The plot areas of a chart, one per grid (a panel each in a chart of panels). ECharts has no public
 * call for a grid's place; getModel is typed private but is how its own components read it. */
function plots(c: echarts.ECharts): Rect[] {
  const out: Rect[] = [];
  for (let i = 0; ; i++) {
    const g = (c as unknown as Grids).getModel().getComponent('grid', i);
    if (!g) return out;
    const r = g.coordinateSystem?.getRect();
    if (r) out.push(r);
  }
}

/** Below this many pixels a drag is a click, not a zoom. */
const ZOOM_MIN_PX = 5;

/** Drag to zoom on a time chart (decision 32), as in Grafana: a mouse drag across a plot area shades the
 * span over every panel and, on release, gives its two ends on the time axis, in the axis's milliseconds.
 * A mouse only, so a finger still scrolls the page; Escape while dragging, or a drag under ZOOM_MIN_PX,
 * gives nothing. The tooltip is hidden while dragging, so it doesn't cover the span. */
function zoomable(c: echarts.ECharts, onZoom: (start: number, end: number) => void): () => void {
  const zr = c.getZr();
  let stop: (() => void) | null = null;
  const down = (e: { offsetX: number; offsetY: number; event?: Event }) => {
    const ev = e.event as (MouseEvent & { pointerType?: string }) | undefined;
    if (!ev || !('button' in ev) || ev.button !== 0 || (ev.pointerType && ev.pointerType !== 'mouse')) return;
    const all = plots(c);
    const i = all.findIndex((r) => e.offsetX >= r.x && e.offsetX <= r.x + r.width && e.offsetY >= r.y && e.offsetY <= r.y + r.height);
    if (i < 0) return;
    const plot = all[i];
    const top = Math.min(...all.map((r) => r.y));
    const bottom = Math.max(...all.map((r) => r.y + r.height));
    const origin = c.getDom().getBoundingClientRect();
    const x0 = e.offsetX;
    let x1 = x0;
    let band: InstanceType<typeof echarts.graphic.Rect> | null = null;
    const move = (m: MouseEvent) => {
      x1 = Math.min(plot.x + plot.width, Math.max(plot.x, m.clientX - origin.left));
      if (Math.abs(x1 - x0) < ZOOM_MIN_PX) return;
      if (!band) {
        band = new echarts.graphic.Rect({ silent: true, z: 1000, style: { fill: accentColor(), opacity: 0.18 } });
        zr.add(band);
        c.setOption({ tooltip: { show: false } });
        c.dispatchAction({ type: 'hideTip' });
      }
      band.setShape({ x: Math.min(x0, x1), y: top, width: Math.abs(x1 - x0), height: bottom - top });
    };
    const end = () => {
      window.removeEventListener('mousemove', move);
      window.removeEventListener('mouseup', up);
      window.removeEventListener('keydown', key);
      if (band) {
        zr.remove(band);
        c.setOption({ tooltip: { show: true } });
      }
      stop = null;
    };
    const up = () => {
      const zoomed = band !== null;
      end();
      if (!zoomed) return;
      const [a, b] = [x0, x1].sort((p, q) => p - q);
      onZoom(c.convertFromPixel({ xAxisIndex: i }, a), c.convertFromPixel({ xAxisIndex: i }, b));
    };
    const key = (k: KeyboardEvent) => { if (k.key === 'Escape') end(); };
    ev.preventDefault();        // no text selection while dragging
    window.addEventListener('mousemove', move);
    window.addEventListener('mouseup', up);
    window.addEventListener('keydown', key);
    stop = end;
  };
  zr.on('mousedown', down);
  return () => { zr.off('mousedown', down); stop?.(); };
}

/** An ECharts chart filling its box, resized with it and disposed with the component. Charts given
 *  the same `group` share their tooltip. With `onZoom` (time charts), a mouse drag across the plot
 *  gives the span dragged, in site time to the minute (decision 32). */
export function EChart({ option, onClick, group, onZoom }: {
  option: echarts.EChartsCoreOption; onClick?: (p: echarts.ECElementEvent) => void; group?: string;
  onZoom?: (start: string, end: string) => void;
}) {
  const box = useRef<HTMLDivElement>(null);
  const chart = useRef<echarts.ECharts | null>(null);
  const click = useRef(onClick);
  click.current = onClick;
  const zoom = useRef(onZoom);
  zoom.current = onZoom;
  const zooms = !!onZoom;
  useEffect(() => {
    const c = echarts.init(box.current!, undefined, { renderer: 'canvas' });
    chart.current = c;
    c.on('click', (p) => click.current?.(p));
    const leave = group ? join(group, c) : null;
    const unzoom = zooms ? zoomable(c, (a, b) => {
      const start = chartMinute(a), end = chartMinute(b);
      if (start < end) zoom.current?.(start, end);
    }) : null;
    const ro = new ResizeObserver(() => c.resize());
    ro.observe(box.current!);
    return () => { ro.disconnect(); unzoom?.(); leave?.(); c.dispose(); chart.current = null; };
  }, [group, zooms]);
  useEffect(() => { chart.current?.setOption(option, true); }, [option]);
  return <div ref={box} className="chart" />;
}

export function textColor(): string {
  return getComputedStyle(document.documentElement).getPropertyValue('--text').trim() || '#ddd';
}

export function accentColor(): string {
  return getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#4f8ff0';
}

export function mutedColor(): string {
  return getComputedStyle(document.documentElement).getPropertyValue('--muted').trim() || '#888';
}
