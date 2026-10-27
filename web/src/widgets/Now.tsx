// The last reading of each of a node's meters (GET /api/now): at the range's end, which for a range
// running to now is now. Instantaneous values by default; a reading older than 15 minutes is not
// "now", and the meter says it has none.
import { useQuery } from '@tanstack/react-query';
import { get } from '../api/client';
import type { Now as N } from '../api/types';
import { show } from '../time/range';
import { Field, Findings, fmt, Hint, NodeName, NodePicker, Pending, useQuantities } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';

interface S {
  node: number | null;
  quantities: string[];
}

function View({ settings, entity, view }: WidgetProps<S>) {
  const node = nodeOf(entity, settings.node);
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'now', node, settings.quantities, view.end, view.tick],
    queryFn: ({ signal }) => get<N>('/api/now', { node, at: view.end, quantities: settings.quantities.join(',') }, signal),
    enabled: node !== null,
    placeholderData: (prev) => prev,
  });
  if (node === null) return <Hint>Choose a node in the widget's settings, or follow a channel.</Hint>;
  return (
    <Pending q={q}>
      {(r) => (
        <div className="scroll">
          {r.devices.map((d) => (
            <div key={d.device_id}>
              <div className="pad"><b>{d.code}</b> <span className="muted">{d.name}</span></div>
              {d.readings.length > 0 && (
                <table className="grid-table">
                  <tbody>
                    {d.readings.map((x) => (
                      <tr key={x.quantity}>
                        <td>{x.quantity}</td>
                        <td className="num big">{fmt(x.value, 3)}</td>
                        <td className="muted">{x.unit}</td>
                        <td className="muted">{x.at.slice(11, 16)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          ))}
          <div className="foot muted"><NodeName id={node} /> · last readings up to {show(r.at)}</div>
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
      <Field label="Quantities (none chosen: every instantaneous value)">
        <select multiple size={10} value={settings.quantities}
                onChange={(e) => setSettings({ ...settings, quantities: [...e.target.selectedOptions].map((o) => o.value) })}>
          {all.map((q) => <option key={q.code} value={q.code}>{q.code} ({q.unit})</option>)}
        </select>
      </Field>
    </>
  );
}

export const now: WidgetType<S> = {
  type: 'now', label: 'Now',
  description: "The last reading of a node's meters at the range's end: power, current, voltage, power factor.",
  minW: 4, minH: 4, w: 6, h: 9,
  defaults: { node: null, quantities: [] },
  View, Settings,
};
