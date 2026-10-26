// The devices reading a node, when each last reported, and what can be resolved there
// (GET /api/meters), on the range's last day.
import { useQuery } from '@tanstack/react-query';
import { get } from '../api/client';
import type { Meters as M } from '../types/formats/meters';
import { show } from '../time/range';
import { Field, Findings, Hint, NodeName, NodePicker, Pending } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';

interface S {
  node: number | null;
}

function View({ settings, entity, view }: WidgetProps<S>) {
  const node = nodeOf(entity, settings.node);
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'meters', node, view.asOf, view.tick],
    queryFn: ({ signal }) => get<M>('/api/meters', { node, as_of: view.asOf }, signal),
    enabled: node !== null,
    placeholderData: (prev) => prev,
  });
  if (node === null) return <Hint>Choose a node in the widget's settings, or follow a channel.</Hint>;
  return (
    <Pending q={q}>
      {(m) => (
        <div className="scroll">
          <div className="pad"><b>{m.node.code}</b> <span className="muted">{m.node.name} · {m.node.type}</span></div>
          <table className="grid-table">
            <thead><tr><th>Device</th><th>On</th><th>Last reading</th><th>Status</th></tr></thead>
            <tbody>
              {m.devices.map((d) => (
                <tr key={d.device_id}>
                  <td title={d.name ?? undefined}><b>{d.code}</b> <span className="muted">{d.name}</span></td>
                  <td className="muted">{d.attached_to === 'FEEDER' ? `feeder from ${d.feeder_from}` : 'node'}</td>
                  <td>{show(d.last_reading)}</td>
                  <td className={`status ${d.observed}`}>{d.observed.toLowerCase().replace('_', ' ')}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <table className="grid-table">
            <thead><tr><th>Quantity</th><th>Available</th></tr></thead>
            <tbody>
              {m.resolvable.map((r) => (
                <tr key={r.quantity}><td>{r.quantity} <span className="muted">({r.unit})</span></td><td title={r.note}>{r.availability.toLowerCase()}</td></tr>
              ))}
            </tbody>
          </table>
          <Findings findings={m.findings} />
        </div>
      )}
    </Pending>
  );
}

function Settings({ settings, setSettings }: SettingsProps<S>) {
  return (
    <Field label="Node (a channel's node replaces it)">
      {settings.node !== null && <div><NodeName id={settings.node} /></div>}
      <NodePicker onPick={(node) => setSettings({ node })} />
    </Field>
  );
}

export const meters: WidgetType<S> = {
  type: 'meters', label: 'Meters',
  description: 'The meters on a node, when each last reported, and which quantities can be worked out there.',
  minW: 6, minH: 5, w: 10, h: 9,
  defaults: { node: null },
  View, Settings,
};
