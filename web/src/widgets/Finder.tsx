// Nodes by text, type, class, utility and metered (GET /api/nodes), as of the range's last day.
// Clicking one puts it on the widget's channel, for the widgets that follow it.
import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { get } from '../api/client';
import { useVocabulary } from '../api/hooks';
import type { NodeList } from '../types/formats/nodelist';
import { Hint, Pending } from './common';
import type { WidgetProps, WidgetType } from './contract';

interface S {
  type: string;
  utility: string;
  metered: '' | 'true' | 'false';
}

function View({ settings, entity, select, view }: WidgetProps<S>) {
  const [text, setText] = useState('');
  const [f, setF] = useState(settings);   // filters are the user's while looking; the saved ones are the defaults
  const vocab = useVocabulary().data;
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'nodes', text, f, view.asOf],
    queryFn: ({ signal }) => get<NodeList>('/api/nodes', {
      text, type: f.type, utility: f.utility, metered: f.metered, as_of: view.asOf, limit: 200,
    }, signal),
    placeholderData: (prev) => prev,
  });
  const set = (k: keyof S, v: string) => setF({ ...f, [k]: v });
  return (
    <div className="stack">
      <div className="filters">
        <input placeholder="Code or name" value={text} onChange={(e) => setText(e.target.value)} />
        <select value={f.type} onChange={(e) => set('type', e.target.value)}>
          <option value="">Any type</option>
          {vocab?.node_types.map((t) => <option key={t.code} value={t.code}>{t.code}</option>)}
        </select>
        <select value={f.utility} onChange={(e) => set('utility', e.target.value)}>
          <option value="">Any utility</option>
          {vocab?.utilities.map((u) => <option key={u.code} value={u.code}>{u.code}</option>)}
        </select>
        <select value={f.metered} onChange={(e) => set('metered', e.target.value)}>
          <option value="">Metered or not</option>
          <option value="true">Metered</option>
          <option value="false">Not metered</option>
        </select>
      </div>
      {!select && <Hint>Choose a channel in the header to send the node you click to other widgets.</Hint>}
      <Pending q={q}>
        {(r) => (
          <div className="scroll">
            <table className="grid-table clickable">
              <thead><tr><th>Code</th><th>Name</th><th>Type</th><th>Metered</th></tr></thead>
              <tbody>
                {r.nodes.map((n) => (
                  <tr key={n.id} className={entity?.kind === 'node' && entity.id === n.id ? 'selected' : undefined}
                      onClick={() => select?.({ kind: 'node', id: n.id })}>
                    <td><b>{n.code}</b></td><td>{n.name}</td><td className="muted">{n.type}</td>
                    <td>{n.metered ? 'yes' : <span className="muted">no</span>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="foot muted">{r.total > r.returned ? `${r.returned} of ${r.total}` : r.total} nodes as of {view.asOf}</div>
          </div>
        )}
      </Pending>
    </div>
  );
}

export const finder: WidgetType<S> = {
  type: 'finder', label: 'Node finder',
  description: 'Find nodes by code, name, type or utility; a click selects one for the widgets on its channel.',
  minW: 5, minH: 5, w: 8, h: 10,
  defaults: { type: '', utility: '', metered: '' },
  View,
};
