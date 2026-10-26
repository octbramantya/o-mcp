// One node and what it feeds, or what feeds it (GET /api/section), drawn on the range's last day
// (decision 20) as an indented tree. Clicking a node puts it on the widget's channel.
import { useQuery } from '@tanstack/react-query';
import { get } from '../api/client';
import type { Subgraph } from '../types/formats/subgraph';
import { Field, Findings, Hint, NodeName, NodePicker, Pending } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';

interface S {
  node: number | null;
  depth: number;
  direction: 'down' | 'up';
}

type N = Subgraph['nodes'][number];

/** The reached nodes in walk order: each under the node it was reached from. */
function tree(doc: Subgraph, direction: S['direction']) {
  const byCode = new Map(doc.nodes.map((n) => [n.code, n]));
  const next = new Map<string, string[]>();
  for (const e of doc.edges) {
    const [a, b] = direction === 'down' ? [e.from, e.to] : [e.to, e.from];
    if (!next.has(a)) next.set(a, []);
    next.get(a)!.push(b);
  }
  const out: { node: N; level: number }[] = [];
  const seen = new Set<string>();
  const walk = (n: N, level: number) => {
    if (seen.has(n.code)) return;
    seen.add(n.code);
    out.push({ node: n, level });
    for (const c of (next.get(n.code) ?? []).sort()) {
      const m = byCode.get(c);
      if (m?.scope === 'reached' && m.depth === (n.depth ?? 0) + 1) walk(m, level + 1);
    }
  };
  const root = doc.nodes.find((n) => n.depth === 0);
  if (root) walk(root, 0);
  return out;
}

function View({ settings, entity, select, view }: WidgetProps<S>) {
  const node = nodeOf(entity, settings.node);
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'section', node, settings.depth, settings.direction, view.asOf],
    queryFn: ({ signal }) => get<Subgraph>('/api/section', {
      node, depth: settings.depth, direction: settings.direction, as_of: view.asOf,
    }, signal),
    enabled: node !== null,
    placeholderData: (prev) => prev,
  });
  if (node === null) return <Hint>Choose a node in the widget's settings, or follow a channel.</Hint>;
  return (
    <Pending q={q}>
      {(doc) => (
        <div className="scroll">
          <ul className="tree">
            {tree(doc, settings.direction).map(({ node: n, level }) => (
              <li key={n.code} style={{ paddingLeft: `${level * 1.2}rem` }} className={n.id === node ? 'selected' : undefined}>
                <button type="button" className="link" onClick={() => select?.({ kind: 'node', id: n.id })}>
                  <b>{n.code}</b>
                </button>{' '}
                <span className="muted">{n.name} · {n.type}</span>
                {n.children_not_included > 0 && <span className="muted"> · {n.children_not_included} more below</span>}
              </li>
            ))}
          </ul>
          <div className="foot muted">
            {settings.direction === 'down' ? 'What it feeds' : 'What feeds it'}, {settings.depth} level(s), as of {doc.query.as_of}
          </div>
          <Findings findings={doc.findings.map((f) => ({ code: f.code, message: f.message }))} />
        </div>
      )}
    </Pending>
  );
}

function Settings({ settings, setSettings }: SettingsProps<S>) {
  return (
    <>
      <Field label="Node (a channel's node replaces it)">
        {settings.node !== null && <div><NodeName id={settings.node} /></div>}
        <NodePicker onPick={(node) => setSettings({ ...settings, node })} />
      </Field>
      <Field label="Direction">
        <select value={settings.direction} onChange={(e) => setSettings({ ...settings, direction: e.target.value as S['direction'] })}>
          <option value="down">What it feeds</option>
          <option value="up">What feeds it, back to the sources</option>
        </select>
      </Field>
      <Field label="Levels">
        <input type="number" min={1} max={12} value={settings.depth}
               onChange={(e) => setSettings({ ...settings, depth: Math.min(12, Math.max(1, Number(e.target.value) || 1)) })} />
      </Field>
    </>
  );
}

export const section: WidgetType<S> = {
  type: 'section', label: 'Plant section',
  description: 'A node and what it feeds, or the path back to its sources, on the range\'s last day.',
  minW: 5, minH: 5, w: 8, h: 10,
  defaults: { node: null, depth: 2, direction: 'down' },
  View, Settings,
};
