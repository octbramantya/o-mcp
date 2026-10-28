// Stat: one quantity at one node as a single figure over the range, with its line underneath, as
// Grafana's stat panel. The figure comes from GET /api/aggregate, so it is the Aggregate widget's: a
// counter's total, worked out on the graph where unmetered; for a sampled quantity one meter's last
// reading, average, minimum, 95th percentile or maximum. The line is GET /api/readings at the automatic
// interval: the meter's values, or a counter's consumption summed over the node's meters, or for a
// derived quantity (PF_TRUE) its formula on its two counters' sums per interval.
import { useQuery } from '@tanstack/react-query';
import { get } from '../api/client';
import { useTenant, useVocabulary } from '../api/hooks';
import type { Aggregate } from '../types/formats/aggregate';
import type { Meters } from '../types/formats/meters';
import type { Readings } from '../types/formats/readings';
import { show } from '../time/range';
import type { Point } from './chart';
import { means, ratio, sumPerInterval } from './chart';
import { accentColor, EChart, Field, fmt, Hint, NodeName, NodePicker, Pending } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';
import { useHeldView } from './fresh';
import { OfferedSelect } from './Value';

type Statistic = 'last' | 'mean' | 'min' | 'p95' | 'max';

interface S {
  node: number | null;
  quantity: string;
  /** For a sampled quantity; a counter is always its total. */
  statistic: Statistic;
  /** The meter, for a sampled quantity at a node with several; null for the first. */
  device: number | null;
  sparkline: boolean;
}

const STATISTICS: Record<Statistic, string> = {
  last: 'last', mean: 'average', min: 'minimum', p95: '95th percentile', max: 'maximum',
};

const DATA: Record<string, string> = { minute: '1-minute data', '15min': '15-minute data', day: 'the daily summary' };

/** A counter (or PF_TRUE) is a total; a sampled quantity has a statistic. The line reads the
 * quantity itself, or a derived one's two counters (from). */
function useKind(code: string) {
  const v = useVocabulary().data;
  const q = v?.quantities.find((x) => x.code === code);
  const from = v?.derived_quantities.find((x) => x.code === code)?.from ?? null;
  return { known: !!v, total: !q || q.reading === 'COUNTER', reads: q ? [code] : from ?? [], from };
}

/** The line: one meter's values, a counter's consumption added up over the node's meters, or a
 * derived quantity's ratio. */
function line(r: Readings, total: boolean, device: number | null, from: string[] | null): Point[] {
  if (from) return ratio(r, from);
  if (total) return sumPerInterval(r, r.query.quantities[0]);
  const s = r.series.find((x) => x.device_id === device);
  return s ? means(s) : [];
}

function option(points: Point[], scale: boolean) {
  const color = accentColor();
  return {
    backgroundColor: 'transparent',
    animation: false,
    grid: { left: 0, right: 0, top: 4, bottom: 0 },
    tooltip: { trigger: 'axis', confine: true, valueFormatter: (v: unknown) => fmt(typeof v === 'number' ? v : null) },
    xAxis: { type: 'time', show: false },
    yAxis: { type: 'value', show: false, scale },
    series: [{
      type: 'line', showSymbol: false, data: points,
      lineStyle: { color, width: 1.5 }, itemStyle: { color }, areaStyle: { color, opacity: 0.15 },
    }],
  };
}

function View({ settings, entity, view: live }: WidgetProps<S>) {
  const node = nodeOf(entity, settings.node);
  const [view, track] = useHeldView(live, [settings, node]);
  const kind = useKind(settings.quantity);
  const agg = useQuery({
    queryKey: ['plant', view.tenant, 'aggregate', settings.quantity, [node], view.start, view.end, view.tick],
    queryFn: ({ signal }) => get<Aggregate>('/api/aggregate', {
      quantity: settings.quantity, nodes: String(node), start: view.start, end: view.end,
    }, signal),
    enabled: node !== null,
    placeholderData: (prev) => prev,
  });
  const last = !kind.total && settings.statistic === 'last';
  const rd = useQuery({
    queryKey: ['plant', view.tenant, 'readings', node, kind.reads, 'auto', view.start, view.end, view.tick],
    queryFn: ({ signal }) => get<Readings>('/api/readings', {
      node, quantities: kind.reads.join(','), interval: 'auto', start: view.start, end: view.end,
    }, signal),
    enabled: node !== null && kind.known && kind.reads.length > 0 && (settings.sparkline || last),
    placeholderData: (prev) => prev,
  });
  track(agg.data, rd.data);
  if (node === null) return <Hint>Choose a node in the widget's settings, or follow a channel.</Hint>;
  return (
    <Pending q={agg}>
      {(a) => {
        const metered = a.rows.filter((x) => x.device_id !== null);
        const row = a.statistic === 'TOTAL'
          ? a.rows[0]
          : metered.find((x) => x.device_id === settings.device) ?? metered[0];
        const device = row?.device_id ?? null;
        const points = rd.data ? line(rd.data, a.statistic === 'TOTAL', device, kind.from) : [];
        let figure: number | null | undefined;
        let what: string;
        if (a.statistic === 'TOTAL') {
          figure = row?.total;
          what = kind.from ? 'over the range' : 'total';
        } else if (last) {
          figure = points.length ? points[points.length - 1][1] : null;
          what = points.length ? `last, ${show(points[points.length - 1][0])} (${rd.data?.query.interval})` : 'last';
        } else {
          figure = row?.[settings.statistic as Exclude<Statistic, 'last'>];
          what = STATISTICS[settings.statistic];
        }
        const warn = [...a.findings, ...(rd.data?.findings ?? [])].map((f) => f.message);
        return (
          <div className="stat" title={`${a.quantity.code}, ${what}, from ${DATA[a.resolution] ?? a.resolution}`
                                         + (a.quantity.decoded ? ', decoded to 0..1, leading and lagging alike' : '')
                                         + `\n${show(a.window.start)} to ${show(a.window.end)}`
                                         + (warn.length ? `\n\n${warn.join('\n')}` : '')}>
            <div className="stat-head">
              <div className="stat-figure">
                {a.statistic === 'SPREAD' && !metered.length ? <span className="muted">no meter</span> : fmt(figure)}
                {a.quantity.unit && <span className="stat-unit">{a.quantity.unit}</span>}
              </div>
              <div className="stat-caption muted">
                <NodeName id={node} /> · {a.quantity.code} · {what}
                {a.statistic === 'SPREAD' && metered.length > 1 && row && ` · ${row.device}`}
                {warn.length > 0 && <span className="warn" title={warn.join('\n')}> · ⚠ {warn.length}</span>}
              </div>
            </div>
            {settings.sparkline && points.length > 1 && <EChart option={option(points, a.statistic !== 'TOTAL' || !!kind.from)} />}
          </div>
        );
      }}
    </Pending>
  );
}

function Settings({ settings, setSettings }: SettingsProps<S>) {
  const kind = useKind(settings.quantity);
  const tenant = useTenant().id;
  const meters = useQuery({
    queryKey: ['plant', tenant, 'meters-reported', settings.node],
    queryFn: ({ signal }) => get<Meters>('/api/meters', { node: settings.node }, signal),
    enabled: settings.node !== null && !kind.total,
    staleTime: 5 * 60_000,
  });
  const devices = meters.data?.devices ?? [];
  return (
    <>
      <Field label="Node (a channel's node replaces it)">
        {settings.node !== null && <div><NodeName id={settings.node} /></div>}
        <NodePicker onPick={(node) => setSettings({ ...settings, node, device: null })} />
      </Field>
      <Field label="Quantity">
        <OfferedSelect nodes={settings.node !== null ? [settings.node] : []} value={settings.quantity}
                       onChange={(quantity) => setSettings({ ...settings, quantity })} />
      </Field>
      {kind.total ? (
        <div className="muted">A total over the range, worked out on the graph where the node has no meter.</div>
      ) : (
        <>
          <Field label="Figure">
            <select value={settings.statistic} onChange={(e) => setSettings({ ...settings, statistic: e.target.value as Statistic })}>
              {Object.entries(STATISTICS).map(([k, label]) => <option key={k} value={k}>{label}</option>)}
            </select>
          </Field>
          {devices.length > 1 && (
            <Field label="Meter">
              <select value={settings.device ?? ''}
                      onChange={(e) => setSettings({ ...settings, device: e.target.value ? Number(e.target.value) : null })}>
                <option value="">The first listed</option>
                {devices.map((d) => <option key={d.device_id} value={d.device_id}>{d.code} {d.name}</option>)}
              </select>
            </Field>
          )}
        </>
      )}
      <Field label="Line">
        <select value={settings.sparkline ? 'yes' : 'no'} onChange={(e) => setSettings({ ...settings, sparkline: e.target.value === 'yes' })}>
          <option value="yes">Over the range, under the figure</option>
          <option value="no">None</option>
        </select>
      </Field>
    </>
  );
}

export const stat: WidgetType<S> = {
  type: 'stat', label: 'Stat',
  description: "One quantity at one node as a single figure over the range, with its line: an energy or volume total, or a meter's last reading, average, minimum, 95th percentile or maximum.",
  minW: 3, minH: 3, w: 5, h: 5,
  defaults: { node: null, quantity: 'ACTIVE_ENERGY_DELIVERED', statistic: 'last', device: null, sparkline: true },
  View, Settings,
};
