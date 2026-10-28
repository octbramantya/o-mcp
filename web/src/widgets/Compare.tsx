// Compare: one quantity at several nodes over the range, Readings turned round (design/frontend.md §1
// decision 26, §5 "Compare"). GET /api/readings once per node with the one quantity: a counter is one
// line per node, its consumption added over the node's meters (raw registers, as Stat's line); a sampled
// quantity a line per meter; PF_TRUE Stat's formula per interval. Nodes without a meter on the range's
// last day (GET /api/meters) are listed under the chart. A channel's node comes first; at most 10.
import { useQueries } from '@tanstack/react-query';
import { get } from '../api/client';
import { useNodes, useVocabulary } from '../api/hooks';
import type { Meters } from '../types/formats/meters';
import type { Readings } from '../types/formats/readings';
import { show } from '../time/range';
import type { Line } from './chart';
import { means, ratio, sumPerInterval, timeOption, unitOf } from './chart';
import { EChart, Field, Findings, Hint, mutedColor, NodeList, textColor } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';
import { useHeldView } from './fresh';
import { OfferedSelect, PF_ENCODED } from './Value';

export const MAX_NODES = 10;

interface S {
  quantity: string;
  nodes: number[];
  interval: 'auto' | '15min' | 'hour' | 'day';
}

/** What the quantity is drawn from: itself, or a derived quantity's two counters (from). */
function useKind(code: string) {
  const v = useVocabulary().data;
  const q = v?.quantities.find((x) => x.code === code);
  const d = v?.derived_quantities.find((x) => x.code === code);
  return {
    known: !!v,
    counter: q?.reading === 'COUNTER',
    reads: q ? [code] : d?.from ?? [],
    from: d?.from ?? null,
    unit: q ? unitOf({ unit: q.unit, decoded: PF_ENCODED.has(code) }) : d?.unit ?? '0..1',
  };
}

/** A node's lines: one for a counter or PF_TRUE, one per meter for a sampled quantity, the meter
 * named only where there are several. */
export function nodeLines(code: string, r: Readings, kind: { counter: boolean; from: string[] | null; unit: string }): Line[] {
  if (kind.from) return [{ name: code, unit: kind.unit, bar: false, data: ratio(r, kind.from) }];
  if (kind.counter) return [{ name: code, unit: kind.unit, bar: false, zero: true, data: sumPerInterval(r, r.query.quantities[0]) }];
  return r.series.map((s) => ({
    name: r.series.length > 1 ? `${code} ${s.device}` : code, unit: kind.unit, bar: false, data: means(s),
  }));
}

function View({ settings, entity, view: live }: WidgetProps<S>) {
  const linked = nodeOf(entity, null);
  const chosen = [...new Set(linked !== null ? [linked, ...settings.nodes] : settings.nodes)];
  const nodes = chosen.slice(0, MAX_NODES);
  const [view, track] = useHeldView(live, [settings, nodes]);
  const kind = useKind(settings.quantity);
  const byId = useNodes().data?.byId;
  const meters = useQueries({
    queries: nodes.map((node) => ({
      queryKey: ['plant', view.tenant, 'meters', node, view.asOf, view.tick],
      queryFn: ({ signal }: { signal: AbortSignal }) => get<Meters>('/api/meters', { node, as_of: view.asOf }, signal),
      placeholderData: (prev: Meters | undefined) => prev,
    })),
  });
  const readings = useQueries({
    queries: nodes.map((node, i) => ({
      queryKey: ['plant', view.tenant, 'readings', node, kind.reads, settings.interval, view.start, view.end, view.tick],
      queryFn: ({ signal }: { signal: AbortSignal }) => get<Readings>('/api/readings', {
        node, quantities: kind.reads.join(','), interval: settings.interval, start: view.start, end: view.end,
      }, signal),
      enabled: kind.known && kind.reads.length > 0 && (meters[i].data?.devices.length ?? 0) > 0,
      placeholderData: (prev: Readings | undefined) => prev,
    })),
  });
  track(...meters.map((q) => q.data), ...readings.map((q) => q.data));
  if (!nodes.length) return <Hint>Choose nodes in the widget's settings, or follow a channel.</Hint>;

  const code = (id: number) => byId?.get(id)?.code ?? `node ${id}`;
  const answers = readings.map((q) => q.data).filter((r): r is Readings => !!r);
  const lines = nodes.flatMap((id, i) => (readings[i].data ? nodeLines(code(id), readings[i].data!, kind) : []));
  const unmetered = nodes.filter((_, i) => meters[i].data?.devices.length === 0);
  const errors = nodes.flatMap((id, i) => {
    const e = meters[i].error ?? readings[i].error;
    return e ? [`${code(id)}: ${(e as Error).message}`] : [];
  });
  const loading = [...meters, ...readings].some((q) => q.isFetching && (!q.data || q.isPlaceholderData));
  const first = answers[0];
  return (
    <div className={`stack${loading && answers.length ? ' stale' : ''}`}>
      {loading && <span className="badge loading">Loading…</span>}
      {first && lines.length > 0
        ? <EChart option={timeOption(lines, 'auto', first.query.window, { text: textColor(), muted: mutedColor() })} group="readings" />
        : !loading && !errors.length && <Hint>No readings for these nodes.</Hint>}
      <div className="foot muted">
        {settings.quantity}
        {first && `, ${first.query.interval} points from ${show(first.query.window.start)}`}
        {PF_ENCODED.has(settings.quantity) && ' · decoded to 0..1, leading and lagging alike'}
        {kind.counter && ' · added over each node\'s meters, as they read'}
        {chosen.length > MAX_NODES && ` · the first ${MAX_NODES} of ${chosen.length} nodes`}
      </div>
      {unmetered.length > 0 && <div className="foot muted">no meter: {unmetered.map(code).join(', ')}</div>}
      {errors.map((e) => <div key={e} className="error">{e}</div>)}
      <Findings findings={answers.flatMap((r) => r.findings)} />
    </div>
  );
}

function Settings({ settings, setSettings }: SettingsProps<S>) {
  return (
    <>
      <Field label="Quantity">
        <OfferedSelect nodes={settings.nodes} value={settings.quantity} onChange={(quantity) => setSettings({ ...settings, quantity })} />
      </Field>
      <Field label={`Nodes (up to ${MAX_NODES}; a channel's node comes first)`}>
        <NodeList ids={settings.nodes} max={MAX_NODES} onChange={(nodes) => setSettings({ ...settings, nodes })} />
      </Field>
      <Field label="Interval">
        <select value={settings.interval} onChange={(e) => setSettings({ ...settings, interval: e.target.value as S['interval'] })}>
          <option value="auto">Automatic (minutes for 6 hours or less)</option>
          <option value="15min">15 minutes</option>
          <option value="hour">Hour</option>
          <option value="day">Day</option>
        </select>
      </Field>
    </>
  );
}

export const compare: WidgetType<S> = {
  type: 'compare', label: 'Compare',
  description: "One quantity at several nodes over the range, a line each: a counter's consumption per node, or a sampled quantity per meter.",
  minW: 6, minH: 5, w: 12, h: 9,
  defaults: { quantity: 'ACTIVE_ENERGY_DELIVERED', nodes: [], interval: 'auto' },
  View, Settings,
};
