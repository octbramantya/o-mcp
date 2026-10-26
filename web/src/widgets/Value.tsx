// One resolved quantity for nodes over the dashboard's range (GET /api/values), with how each value
// was found. Following a channel, it shows the channel's node.
import { useQuery } from '@tanstack/react-query';
import { get } from '../api/client';
import type { Values } from '../api/types';
import { show } from '../time/range';
import { Field, Findings, fmt, Hint, NodeList, Pending, QuantitySelect } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';

interface S {
  quantity: string;
  nodes: number[];
}

const ORIGIN: Record<string, string> = {
  MEASURED: 'measured', ROLLUP: 'from its children', IN_EDGES: 'from its feeders', OUT_EDGES: 'from what it feeds',
  CHILDREN: 'from its children', INHERITED: "its feeder's", DERIVED: 'derived', NONE: 'no value',
};

function View({ settings, entity, view }: WidgetProps<S>) {
  const linked = nodeOf(entity, null);
  const nodes = linked !== null ? [linked] : settings.nodes;
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'values', settings.quantity, nodes, view.start, view.end, view.tick],
    queryFn: ({ signal }) => get<Values>('/api/values', {
      quantity: settings.quantity, nodes: nodes.join(','), start: view.start, end: view.end,
    }, signal),
    enabled: nodes.length > 0,
    placeholderData: (prev) => prev,
  });
  if (!nodes.length) return <Hint>Choose nodes in the widget's settings, or follow a channel.</Hint>;
  return (
    <Pending q={q}>
      {(r) => (
        <div className="scroll">
          <table className="grid-table">
            <thead><tr><th>Node</th><th className="num">{r.quantity.code} ({r.quantity.unit})</th><th>How</th></tr></thead>
            <tbody>
              {r.values.map((v) => (
                <tr key={v.node_id}>
                  <td title={v.name}><b>{v.code}</b> <span className="muted">{v.name}</span></td>
                  <td className="num big">{fmt(v.value, 3)}</td>
                  <td className="muted">{ORIGIN[v.origin] ?? v.origin}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="foot muted">
            {r.resolution} data, {show(r.window.start)} to {show(r.window.end)} · {r.source} until {show(r.data_until)}
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
        <QuantitySelect kind="value" value={settings.quantity} onChange={(quantity) => setSettings({ ...settings, quantity })} />
      </Field>
      <Field label="Nodes (a channel's node replaces them)">
        <NodeList ids={settings.nodes} max={50} onChange={(nodes) => setSettings({ ...settings, nodes })} />
      </Field>
    </>
  );
}

export const value: WidgetType<S> = {
  type: 'value', label: 'Value',
  description: 'One quantity for one or more nodes over the range, worked out on the graph where unmetered.',
  minW: 4, minH: 3, w: 8, h: 6,
  defaults: { quantity: 'ACTIVE_ENERGY_DELIVERED', nodes: [] },
  View, Settings,
};
