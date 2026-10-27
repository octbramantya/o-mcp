// The left panel (design/frontend.md §5): ways to choose a node, by text, by the sankey's category
// tree, or from the account's starred list. A click puts the node on channel A of the open
// dashboard; the star keeps it in the starred list, on every browser.
import { useState } from 'react';
import { useCategories, useNodes, useStars } from '../api/hooks';
import type { Categories } from '../api/types';
import { CHANNELS } from '../dashboards/document';
import { useDashboard } from '../dashboards/store';

type Tab = 'find' | 'categories' | 'starred';
const TABS: [Tab, string][] = [['find', 'Find'], ['categories', 'Categories'], ['starred', 'Starred']];

type Stars = ReturnType<typeof useStars>;

function NodeRow({ id, stars, note }: { id: number; stars: Stars; note?: string }) {
  const n = useNodes().data?.byId.get(id);
  const setChannel = useDashboard((s) => s.setChannel);
  const selected = useDashboard((s) => s.doc?.channels.A);
  const on = stars.has(id);
  return (
    <li className={selected?.kind === 'node' && selected.id === id ? 'selected' : undefined}>
      {n ? (
        <button type="button" className="pick" onClick={() => setChannel('A', { kind: 'node', id })} title={n.name ?? undefined}>
          <b>{n.code}</b> <span className="muted">{n.name}{note && ` · ${note}`}</span>
        </button>
      ) : (
        <span className="pick muted">node {id} (not in the plant today)</span>
      )}
      <button type="button" className={`star${on ? ' on' : ''}`} onClick={() => stars.toggle(id)}
              title={on ? 'Unstar' : 'Star'} aria-label={on ? 'Unstar' : 'Star'} aria-pressed={on}>
        {on ? '★' : '☆'}
      </button>
    </li>
  );
}

function Find({ stars }: { stars: Stars }) {
  const nodes = useNodes().data;
  const [text, setText] = useState('');
  const t = text.trim().toLowerCase();
  const hits = (nodes?.list ?? []).filter((n) => !t || n.code.toLowerCase().includes(t) || (n.name ?? '').toLowerCase().includes(t));
  return (
    <>
      <div className="pad"><input placeholder="Find a node" value={text} onChange={(e) => setText(e.target.value)} /></div>
      <ul className="node-list">{hits.slice(0, 300).map((n) => <NodeRow key={n.id} id={n.id} stars={stars} />)}</ul>
    </>
  );
}

type Member = Categories['nodes'][number];

function share(m: Member) {
  return m.weight < 1 ? `${Math.round(m.weight * 100)}%` : undefined;
}

function CategoryBranch({ id, data, kids, members, stars }: {
  id: number; data: Categories; stars: Stars; kids: Map<number | null, Categories['categories']>; members: Map<number | null, Member[]>;
}) {
  const c = data.categories.find((x) => x.id === id)!;
  const sub = kids.get(id) ?? [];
  const own = members.get(id) ?? [];
  const count = (cid: number): number => (members.get(cid)?.length ?? 0) + (kids.get(cid) ?? []).reduce((a, k) => a + count(k.id), 0);
  return (
    <details open={c.parent_id === null}>
      <summary><span className="dot" style={{ background: c.color ?? 'var(--muted)' }} />{c.name} <span className="muted">{count(id)}</span></summary>
      {sub.map((k) => <CategoryBranch key={k.id} id={k.id} data={data} kids={kids} members={members} stars={stars} />)}
      {own.length > 0 && <ul className="node-list">{own.map((m) => <NodeRow key={m.node_id} id={m.node_id} stars={stars} note={share(m)} />)}</ul>}
    </details>
  );
}

function CategoryTree({ stars }: { stars: Stars }) {
  const q = useCategories();
  if (q.isError) return <div className="error pad">{(q.error as Error).message}</div>;
  if (!q.data) return <div className="muted pad">Loading…</div>;
  const data = q.data;
  const kids = new Map<number | null, Categories['categories']>();
  for (const c of data.categories) kids.set(c.parent_id, [...(kids.get(c.parent_id) ?? []), c]);
  const members = new Map<number | null, Member[]>();
  for (const m of data.nodes) members.set(m.category_id, [...(members.get(m.category_id) ?? []), m]);
  const unassigned = members.get(null) ?? [];
  return (
    <div className="category-tree">
      <div className="muted small pad">{data.quantity.utility.toLowerCase()} nodes, by the sankey's categories</div>
      {(kids.get(null) ?? []).map((c) => <CategoryBranch key={c.id} id={c.id} data={data} kids={kids} members={members} stars={stars} />)}
      {unassigned.length > 0 && (
        <details>
          <summary><span className="dot" style={{ background: 'var(--muted)' }} />Unassigned <span className="muted">{unassigned.length}</span></summary>
          <ul className="node-list">{unassigned.map((m) => <NodeRow key={m.node_id} id={m.node_id} stars={stars} />)}</ul>
        </details>
      )}
    </div>
  );
}

function Starred({ stars }: { stars: Stars }) {
  return (
    <>
      {stars.ids.length === 0 && <div className="muted pad">No starred nodes yet: ☆ beside a node stars it.</div>}
      <ul className="node-list">{stars.ids.map((id) => <NodeRow key={id} id={id} stars={stars} />)}</ul>
    </>
  );
}

export function LeftPanel() {
  const [tab, setTab] = useState<Tab>('find');
  const stars = useStars();
  return (
    <aside className="left">
      <div className="tabs" role="tablist">
        {TABS.map(([t, label]) => (
          <button key={t} type="button" role="tab" aria-selected={tab === t} className={tab === t ? 'on' : undefined} onClick={() => setTab(t)}>
            {label}{t === 'starred' && stars.ids.length > 0 && <span className="muted"> {stars.ids.length}</span>}
          </button>
        ))}
      </div>
      <div className="muted small pad">A click puts a node on channel <span className="dot" style={{ background: CHANNELS[0].color }} /> A</div>
      {stars.error && <div className="error pad small">{(stars.error as Error).message}</div>}
      {tab === 'find' && <Find stars={stars} />}
      {tab === 'categories' && <CategoryTree stars={stars} />}
      {tab === 'starred' && <Starred stars={stars} />}
    </aside>
  );
}
