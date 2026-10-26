// Pieces the widgets share: node names and pickers, quantity pickers, findings, loading states, and
// an ECharts host.
import type { UseQueryResult } from '@tanstack/react-query';
import { BarChart, LineChart, SankeyChart } from 'echarts/charts';
import { GridComponent, LegendComponent, TooltipComponent } from 'echarts/components';
import * as echarts from 'echarts/core';
import { CanvasRenderer } from 'echarts/renderers';
import type { ReactNode } from 'react';
import { useEffect, useRef, useState } from 'react';
import { useNodes, useVocabulary } from '../api/hooks';
import type { Finding } from '../api/types';

echarts.use([BarChart, LineChart, SankeyChart, GridComponent, LegendComponent, TooltipComponent, CanvasRenderer]);

export function fmt(v: number | null | undefined, digits = 1): string {
  if (v === null || v === undefined) return '—';
  return v.toLocaleString('en-US', { maximumFractionDigits: Math.abs(v) >= 100 ? 0 : digits });
}

/** A stored node id as its current code and name; a node not in the plant today says so (decision 19). */
export function NodeName({ id }: { id: number }) {
  const n = useNodes().data?.byId.get(id);
  if (!n) return <span className="muted">node {id} (not in the plant today)</span>;
  return <span title={n.name ?? undefined}><b>{n.code}</b> {n.name && <span className="muted">{n.name}</span>}</span>;
}

export function NodePicker({ onPick, placeholder = 'Find a node…' }: { onPick: (id: number) => void; placeholder?: string }) {
  const nodes = useNodes().data;
  const [text, setText] = useState('');
  const t = text.trim().toLowerCase();
  const hits = t && nodes
    ? nodes.list.filter((n) => n.code.toLowerCase().includes(t) || (n.name ?? '').toLowerCase().includes(t)).slice(0, 12)
    : [];
  return (
    <div className="picker">
      <input value={text} placeholder={placeholder} onChange={(e) => setText(e.target.value)} />
      {hits.length > 0 && (
        <ul className="picker-list">
          {hits.map((n) => (
            <li key={n.id}>
              <button type="button" onClick={() => { onPick(n.id); setText(''); }}>
                <b>{n.code}</b> <span className="muted">{n.name}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
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
    <select value={value} onChange={(e) => onChange(e.target.value)}>
      {qs.map((q) => <option key={q.code} value={q.code}>{q.code} ({q.unit})</option>)}
    </select>
  );
}

export function Field({ label, children }: { label: string; children: ReactNode }) {
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

/** An ECharts chart filling its box, resized with it and disposed with the component. */
export function EChart({ option, onClick }: { option: echarts.EChartsCoreOption; onClick?: (p: echarts.ECElementEvent) => void }) {
  const box = useRef<HTMLDivElement>(null);
  const chart = useRef<echarts.ECharts | null>(null);
  const click = useRef(onClick);
  click.current = onClick;
  useEffect(() => {
    const c = echarts.init(box.current!, undefined, { renderer: 'canvas' });
    chart.current = c;
    c.on('click', (p) => click.current?.(p));
    const ro = new ResizeObserver(() => c.resize());
    ro.observe(box.current!);
    return () => { ro.disconnect(); c.dispose(); chart.current = null; };
  }, []);
  useEffect(() => { chart.current?.setOption(option, true); }, [option]);
  return <div ref={box} className="chart" />;
}

export function textColor(): string {
  return getComputedStyle(document.documentElement).getPropertyValue('--text').trim() || '#ddd';
}

export function mutedColor(): string {
  return getComputedStyle(document.documentElement).getPropertyValue('--muted').trim() || '#888';
}
