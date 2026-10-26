// What the sankey can't show over the range (negative residuals, silent meters, reverse energy,
// unassigned energy) and the properties the site still has to supply (GET /api/diagnostics).
// Diagnosed meter faults are shown, never hidden (design/frontend.md §5).
import { useQuery } from '@tanstack/react-query';
import { get } from '../api/client';
import type { Diagnostics as D } from '../api/types';
import { Field, Findings, fmt, Pending, QuantitySelect } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';

interface S {
  quantity: string;
}

function View({ settings, select, view }: WidgetProps<S>) {
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'diagnostics', settings.quantity, view.start, view.end, view.tick],
    queryFn: ({ signal }) => get<D>('/api/diagnostics', { quantity: settings.quantity, start: view.start, end: view.end }, signal),
    placeholderData: (prev) => prev,
  });
  const pick = (id: number | null) => id !== null && select?.({ kind: 'node', id });
  return (
    <Pending q={q}>
      {(r) => (
        <div className="scroll">
          <Findings findings={r.findings} />
          <table className="grid-table clickable">
            <thead><tr><th>Kind</th><th>Node</th><th className="num">{r.quantity.unit}</th><th>Detail</th></tr></thead>
            <tbody>
              {r.diagnostics.map((d, i) => (
                <tr key={i} onClick={() => pick(d.node_id)}>
                  <td className={`kind ${d.kind}`}>{d.kind}</td><td><b>{d.node_code}</b></td>
                  <td className="num">{fmt(d.value, 0)}</td><td className="muted">{d.detail}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <h4 className="pad">Properties the site still has to supply ({r.property_gaps.length})</h4>
          <table className="grid-table clickable">
            <thead><tr><th>Node</th><th>Property</th><th>Needed by</th></tr></thead>
            <tbody>
              {r.property_gaps.map((g) => (
                <tr key={`${g.node_code}.${g.property}`} onClick={() => pick(g.node_id)}>
                  <td><b>{g.node_code}</b> <span className="muted">{g.node_type}</span></td>
                  <td>{g.property}</td><td className="muted">{g.used_by}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Pending>
  );
}

function Settings({ settings, setSettings }: SettingsProps<S>) {
  return (
    <Field label="Quantity">
      <QuantitySelect kind="flow" value={settings.quantity} onChange={(quantity) => setSettings({ quantity })} />
    </Field>
  );
}

export const diagnostics: WidgetType<S> = {
  type: 'diagnostics', label: 'Diagnostics',
  description: "What the sankey can't show: negative residuals, silent meters, reverse energy; and missing properties.",
  minW: 8, minH: 6, w: 12, h: 12,
  defaults: { quantity: 'ACTIVE_ENERGY_DELIVERED' },
  View, Settings,
};
