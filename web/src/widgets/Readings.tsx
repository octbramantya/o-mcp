// What a node's meters read over the range (GET /api/readings), one line per device and quantity.
// The API chooses minutes for short ranges (design/frontend.md §3); the chart says which it drew.
// Each unit reads on a scale of its own: one axis, a dual axis for two units, panels from three
// (chart.ts; §5, "Readings' units"). Every Readings chart on the dashboard shares its tooltip with the
// others, matched by time.
import { useQuery } from '@tanstack/react-query';
import { get } from '../api/client';
import type { Readings as R } from '../types/formats/readings';
import { show } from '../time/range';
import type { Axes, Line, Point } from './chart';
import { means, timeOption, unitOf } from './chart';
import { EChart, Field, Findings, Hint, mutedColor, NodeName, NodePicker, Pending, textColor, useQuantities } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';
import { useHeldView } from './fresh';

interface S {
  node: number | null;
  quantities: string[];
  interval: 'auto' | '15min' | 'hour' | 'day';
  /** auto: one axis, or two for two units, panels from three; panels: a panel per unit from two. */
  axes: Axes;
}

function lines(r: R): Line[] {
  return r.series.map((s) => ({
    name: `${s.device} ${s.quantity}`,
    unit: unitOf(s),
    bar: s.reading === 'COUNTER',
    data: s.reading === 'COUNTER'
      ? s.points.filter((p) => p.consumption !== null).map((p): Point => [p.start, p.consumption as number])
      : means(s),
  }));
}

function View({ settings, entity, view: live }: WidgetProps<S>) {
  const node = nodeOf(entity, settings.node);
  const [view, track] = useHeldView(live, [settings, node]);
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'readings', node, settings.quantities, settings.interval, view.start, view.end, view.tick],
    queryFn: ({ signal }) => get<R>('/api/readings', {
      node, quantities: settings.quantities.join(','), interval: settings.interval, start: view.start, end: view.end,
    }, signal),
    enabled: node !== null && settings.quantities.length > 0,
    placeholderData: (prev) => prev,
  });
  track(q.data);
  if (node === null) return <Hint>Choose a node in the widget's settings, or follow a channel.</Hint>;
  if (!settings.quantities.length) return <Hint>Choose quantities in the widget's settings.</Hint>;
  return (
    <Pending q={q}>
      {(r) => (
        <div className="stack">
          <EChart option={timeOption(lines(r), settings.axes, r.query.window, { text: textColor(), muted: mutedColor() })} group="readings" />
          <div className="foot muted"><NodeName id={node} /> · {r.query.interval} points from {show(r.query.window.start)}</div>
          <Findings findings={r.findings} />
        </div>
      )}
    </Pending>
  );
}

function Settings({ settings, setSettings }: SettingsProps<S>) {
  const all = useQuantities('reading');
  return (
    <>
      <Field label="Node (a channel's node replaces it)">
        {settings.node !== null && <div><NodeName id={settings.node} /></div>}
        <NodePicker onPick={(node) => setSettings({ ...settings, node })} />
      </Field>
      <Field label="Quantities (up to 8)">
        <select multiple size={8} value={settings.quantities}
                onChange={(e) => setSettings({ ...settings, quantities: [...e.target.selectedOptions].map((o) => o.value).slice(0, 8) })}>
          {all.map((q) => <option key={q.code} value={q.code}>{q.code} ({q.unit})</option>)}
        </select>
      </Field>
      <Field label="Interval">
        <select value={settings.interval} onChange={(e) => setSettings({ ...settings, interval: e.target.value as S['interval'] })}>
          <option value="auto">Automatic (minutes for 6 hours or less)</option>
          <option value="15min">15 minutes</option>
          <option value="hour">Hour</option>
          <option value="day">Day</option>
        </select>
      </Field>
      <Field label="Axes">
        <select value={settings.axes} onChange={(e) => setSettings({ ...settings, axes: e.target.value as Axes })}>
          <option value="auto">Automatic (two units on a dual axis, panels from three)</option>
          <option value="panels">One panel per unit</option>
        </select>
      </Field>
    </>
  );
}

export const readings: WidgetType<S> = {
  type: 'readings', label: 'Readings',
  description: "A node's meters over the range: consumption per interval, or the mean of instantaneous values, each unit on a scale of its own.",
  minW: 6, minH: 5, w: 12, h: 9,
  defaults: { node: null, quantities: ['ACTIVE_ENERGY_DELIVERED'], interval: 'auto', axes: 'auto' },
  View, Settings,
};
