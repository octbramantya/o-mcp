// Aggregate (was Value; design/frontend.md §1 decision 21, §5): one quantity across several nodes over the
// dashboard's range (GET /api/aggregate). A counter is one total per node, worked out on the graph where
// unmetered; a sampled quantity the minimum, average, 95th percentile and maximum of each meter's
// readings. A channel's node comes first, before the nodes chosen in the settings. The type stays
// `value` in saved dashboards.
import { useQueries, useQuery } from '@tanstack/react-query';
import { get } from '../api/client';
import { useTenant, useVocabulary } from '../api/hooks';
import type { Aggregate } from '../types/formats/aggregate';
import type { Meters } from '../types/formats/meters';
import { show } from '../time/range';
import { Field, Findings, fmt, Hint, NodeList, Pending } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';

interface S {
  quantity: string;
  nodes: number[];
}

const ORIGIN: Record<string, string> = {
  MEASURED: 'measured', ROLLUP: 'from its children', IN_EDGES: 'from its feeders', OUT_EDGES: 'from what it feeds',
  CHILDREN: 'from its children', INHERITED: "its feeder's", DERIVED: 'derived', NONE: 'no value', NO_METER: 'no meter',
};

// quadrant-encoded power factor registers: not offered (api/aggregate.py); PF_TRUE is a total
const PF_ENCODED = new Set(['PF_TOTAL', 'PF_A', 'PF_B', 'PF_C', 'DPF_TOTAL', 'DPF_A', 'DPF_B', 'DPF_C']);

const DATA: Record<string, Record<string, string>> = {
  TOTAL: { minute: 'from 1-minute readings', '15min': 'from 15-minute data', day: 'from the daily summary' },
  SPREAD: { minute: 'from 1-minute readings', '15min': 'from 15-minute readings (the last reading in each 15 minutes)' },
};

function View({ settings, entity, view }: WidgetProps<S>) {
  const linked = nodeOf(entity, null);
  const nodes = [...new Set(linked !== null ? [linked, ...settings.nodes] : settings.nodes)];
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'aggregate', settings.quantity, nodes, view.start, view.end, view.tick],
    queryFn: ({ signal }) => get<Aggregate>('/api/aggregate', {
      quantity: settings.quantity, nodes: nodes.join(','), start: view.start, end: view.end,
    }, signal),
    enabled: nodes.length > 0,
    placeholderData: (prev) => prev,
  });
  if (!nodes.length) return <Hint>Choose nodes in the widget's settings, or follow a channel.</Hint>;
  return (
    <Pending q={q}>
      {(r) => {
        const unit = r.quantity.unit ? ` (${r.quantity.unit})` : '';
        const node = (x: Aggregate['rows'][number]) => (
          <td title={x.name ?? undefined}>
            {x.node_id === linked && <span className="dot channel-row" title="The channel's node" />}
            <b>{x.code}</b> <span className="muted">{x.name}</span>
          </td>
        );
        return (
          <div className="scroll">
            <table className="grid-table">
              {r.statistic === 'TOTAL' ? (
                <>
                  <thead><tr><th>Node</th><th className="num">Total{unit}</th><th>How</th></tr></thead>
                  <tbody>
                    {r.rows.map((x) => (
                      <tr key={x.node_id}>
                        {node(x)}
                        <td className="num big">{fmt(x.total, 3)}</td>
                        <td className="muted">{ORIGIN[x.origin] ?? x.origin}</td>
                      </tr>
                    ))}
                  </tbody>
                </>
              ) : (
                <>
                  <thead>
                    <tr>
                      <th>Node</th><th>Meter</th><th className="num">Min{unit}</th><th className="num">Avg</th>
                      <th className="num" title="95th percentile: the value the readings stayed at or below 95% of the time">P95</th>
                      <th className="num">Max</th><th className="num" title="Readings the figures rest on, of those expected">Readings</th>
                    </tr>
                  </thead>
                  <tbody>
                    {r.rows.map((x) => (
                      <tr key={`${x.node_id}-${x.device_id ?? 'none'}`}>
                        {node(x)}
                        {x.device_id === null ? (
                          <td className="muted" colSpan={6}>no meter</td>
                        ) : (
                          <>
                            <td title={x.device_name ?? undefined}>{x.device}</td>
                            <td className="num">{fmt(x.min, 3)}</td>
                            <td className="num">{fmt(x.mean, 3)}</td>
                            <td className="num big">{fmt(x.p95, 3)}</td>
                            <td className="num">{fmt(x.max, 3)}</td>
                            <td className={`num${(x.samples ?? 0) < 0.9 * (x.expected ?? 0) ? ' warn' : ' muted'}`}>
                              {x.samples} of {x.expected}
                            </td>
                          </>
                        )}
                      </tr>
                    ))}
                  </tbody>
                </>
              )}
            </table>
            <div className="foot muted">
              {r.quantity.code}, {DATA[r.statistic][r.resolution] ?? r.resolution}, {show(r.window.start)} to {show(r.window.end)}
              {r.data_until && ` · data until ${show(r.data_until)}`}
            </div>
            <Findings findings={r.findings} />
          </div>
        );
      }}
    </Pending>
  );
}

/** The kind of quantity, for grouping the picker. */
function group(q: { code: string; unit: string | null; total: boolean }): string {
  if (q.total) return 'Totals';
  if (q.unit === 'V') return 'Voltage';
  if (q.unit === 'A') return 'Current';
  if (q.unit === 'kW' || q.unit === 'kVAr' || q.unit === 'kVA') return 'Power';
  if (q.unit === 'Hz') return 'Frequency';
  if (q.code.includes('UNBALANCE')) return 'Unbalance';
  if (q.code.startsWith('THD_') || /^H\d+_/.test(q.code)) return 'Harmonics';
  return 'Other';
}
const GROUPS = ['Totals', 'Voltage', 'Current', 'Power', 'Frequency', 'Harmonics', 'Unbalance', 'Other'];

/** What the widget offers: counters with a solver rule and PF_TRUE (totals), and every sampled
 * quantity but the encoded power factor; sampled ones narrowed to what the chosen nodes' meters
 * reported in the last week, once there are chosen nodes. */
function useOffered(nodes: number[], keep: string) {
  const v = useVocabulary().data;
  const tenant = useTenant().id;
  const meters = useQueries({
    queries: nodes.map((id) => ({
      queryKey: ['plant', tenant, 'meters-reported', id],
      queryFn: ({ signal }: { signal: AbortSignal }) => get<Meters>('/api/meters', { node: id }, signal),
      staleTime: 5 * 60_000,
    })),
  });
  if (!v) return [];
  const reported = new Set(meters.flatMap((m) => m.data?.devices.flatMap((d) => d.reported.map((x) => x.code)) ?? []));
  const narrow = nodes.length > 0 && meters.every((m) => m.data);
  const all = [
    ...v.quantities.filter((q) => q.node_value && q.reading === 'COUNTER').map((q) => ({ code: q.code, unit: q.unit, total: true })),
    ...v.derived_quantities.map((d) => ({ code: d.code, unit: d.unit, total: true })),
    ...v.quantities.filter((q) => q.reading === 'SAMPLE' && !PF_ENCODED.has(q.code)
                               && (!narrow || reported.has(q.code) || q.code === keep))
      .map((q) => ({ code: q.code, unit: q.unit, total: false })),
  ];
  return GROUPS.map((g) => [g, all.filter((q) => group(q) === g)] as const).filter(([, qs]) => qs.length);
}

function Settings({ settings, setSettings }: SettingsProps<S>) {
  const groups = useOffered(settings.nodes, settings.quantity);
  return (
    <>
      <Field label="Quantity">
        <select value={settings.quantity} onChange={(e) => setSettings({ ...settings, quantity: e.target.value })}>
          {!groups.length && <option value={settings.quantity}>Loading quantities…</option>}
          {groups.map(([g, qs]) => (
            <optgroup key={g} label={g}>
              {qs.map((q) => <option key={q.code} value={q.code}>{q.code}{q.unit ? ` (${q.unit})` : ''}</option>)}
            </optgroup>
          ))}
        </select>
      </Field>
      <Field label="Nodes (a channel's node comes first)">
        <NodeList ids={settings.nodes} max={50} onChange={(nodes) => setSettings({ ...settings, nodes })} />
      </Field>
    </>
  );
}

export const value: WidgetType<S> = {
  type: 'value', label: 'Aggregate',
  description: 'One quantity across several nodes over the range: a total for energy and volume, worked out on the graph where unmetered; minimum, average, 95th percentile and maximum per meter for voltage, current, power and the rest.',
  minW: 4, minH: 3, w: 8, h: 6,
  defaults: { quantity: 'ACTIVE_ENERGY_DELIVERED', nodes: [] },
  View, Settings,
};
