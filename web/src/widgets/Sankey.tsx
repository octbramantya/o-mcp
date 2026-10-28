// Where energy, water or air goes, by category (GET /api/sankey), in whole site days drawn on the
// range's last day. The drawing follows the Grafana panel (grafana/graph-sankey/sankey.js): colours,
// labels and order all come from the rows, so a node added to the graph appears unchanged here.
import { useQuery } from '@tanstack/react-query';
import { get } from '../api/client';
import type { Sankey as S_ } from '../api/types';
import { show } from '../time/range';
import { EChart, Field, Findings, fmt, Pending, QuantitySelect, textColor } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { useHeldView } from './fresh';

interface S {
  quantity: string;
  node_detail: boolean;
}

function option(r: S_) {
  const links = r.links.filter((l) => l.value > 0);
  const order: string[] = [];
  const seen = new Set<string>();
  const colorOf: Record<string, string> = {};
  const inflow: Record<string, number> = {};
  const children: Record<string, string[]> = {};
  for (const l of links) {
    for (const n of [l.source, l.target]) if (!seen.has(n)) { seen.add(n); order.push(n); }
    if (l.color) { colorOf[l.target] = l.color; colorOf[l.source] ??= l.color; }
    inflow[l.target] = (inflow[l.target] ?? 0) + l.value;
    (children[l.source] ??= []).push(l.target);
  }
  // a walk of the tree from the sources, children in row order, so branches never cross
  const walked: string[] = [];
  const done = new Set<string>();
  const walk = (n: string) => { if (done.has(n)) return; done.add(n); walked.push(n); (children[n] ?? []).forEach(walk); };
  order.filter((n) => !inflow[n]).forEach(walk);
  order.forEach(walk);
  const supply = links.filter((l) => l.link_kind === 'SUPPLY').reduce((s, l) => s + l.value, 0);
  const unit = r.quantity.unit;
  return {
    backgroundColor: 'transparent',
    tooltip: {
      trigger: 'item', confine: true,
      formatter: (p: { dataType: string; data: { source: string; target: string; value: number; ambiguous?: boolean }; name: string; value: number }) =>
        p.dataType === 'edge'
          ? `<b>${p.data.source} → ${p.data.target}</b><br/>${fmt(p.data.value)} ${unit}`
            + (supply > 0 ? ` (${fmt(100 * p.data.value / supply)}% of supply)` : '')
            + (p.data.ambiguous ? '<br/>solved, not metered' : '')
          : `<b>${p.name}</b><br/>${fmt(p.value)} ${unit}`,
    },
    series: [{
      type: 'sankey', left: 8, right: 120, top: 8, bottom: 8, nodeAlign: 'left', layoutIterations: 0,
      emphasis: { focus: 'adjacency' },
      label: { color: textColor(), fontSize: 11 },
      lineStyle: { color: 'gradient', curveness: 0.5, opacity: 0.35 },
      data: walked.map((name) => ({
        name,
        itemStyle: { color: colorOf[name] ?? '#9E9E9E', borderColor: colorOf[name] ?? '#9E9E9E' },
        label: { show: supply > 0 && (inflow[name] ?? supply) / supply >= 0.001 },
      })),
      links: links.map((l) => ({
        source: l.source, target: l.target, value: l.value, ambiguous: l.is_ambiguous,
        lineStyle: l.is_ambiguous ? { opacity: 0.12 } : undefined,
      })),
    }],
  };
}

function View({ settings, view: live }: WidgetProps<S>) {
  const [view, track] = useHeldView(live, settings);
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'sankey', settings, view.start, view.end, view.tick],
    queryFn: ({ signal }) => get<S_>('/api/sankey', {
      quantity: settings.quantity, node_detail: settings.node_detail, start: view.start, end: view.end,
    }, signal),
    placeholderData: (prev) => prev,
  });
  track(q.data);
  return (
    <Pending q={q}>
      {(r) => (
        <div className="stack">
          {r.links.length ? <EChart option={option(r)} /> : <div className="muted pad">No flow in this range.</div>}
          <div className="foot muted">
            {r.quantity.code}, whole days {show(r.window.start)} to {show(r.window.end)}, plant as of {r.as_of}
          </div>
          <Findings findings={r.findings} />
        </div>
      )}
    </Pending>
  );
}

function Settings({ settings, setSettings }: SettingsProps<S>) {
  return (
    <>
      <Field label="Quantity">
        <QuantitySelect kind="flow" value={settings.quantity} onChange={(quantity) => setSettings({ ...settings, quantity })} />
      </Field>
      <Field label="Nodes">
        <select value={String(settings.node_detail)} onChange={(e) => setSettings({ ...settings, node_detail: e.target.value === 'true' })}>
          <option value="true">Every node under its category</option>
          <option value="false">Categories only, where they have subcategories</option>
        </select>
      </Field>
    </>
  );
}

export const sankey: WidgetType<S> = {
  type: 'sankey', label: 'Sankey',
  description: 'Where energy, water or air goes, by category, in whole days.',
  minW: 10, minH: 8, w: 16, h: 14,
  defaults: { quantity: 'ACTIVE_ENERGY_DELIVERED', node_detail: true },
  View, Settings,
};
