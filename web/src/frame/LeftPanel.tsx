// The left panel (design/frontend.md §5): ways to choose a node, by text and filters, by the sankey's category
// tree, or from the account's starred list. A click puts the node on the channel chosen at the top
// (A unless changed) of the open dashboard; the star keeps it in the starred list, on every browser.
import { useState } from 'react';
import { useCategories, useNodes, useStars, useVocabulary } from '../api/hooks';
import type { PlantNode } from '../api/hooks';
import type { Categories } from '../api/types';
import type { ChannelId } from '../dashboards/document';
import { CHANNELS } from '../dashboards/document';
import { useDashboard } from '../dashboards/store';

type Tab = 'find' | 'categories' | 'starred';
const TABS: [Tab, string][] = [['find', 'Find'], ['categories', 'Categories'], ['starred', 'Starred']];

type Stars = ReturnType<typeof useStars>;

function NodeRow({ id, stars, target, note, showMetered }: { id: number; stars: Stars; target: ChannelId; note?: string; showMetered?: boolean }) {
  const n = useNodes().data?.byId.get(id);
  const setChannel = useDashboard((s) => s.setChannel);
  const selected = useDashboard((s) => s.doc?.channels[target]);
  const on = stars.has(id);
  return (
    <li className={selected?.kind === 'node' && selected.id === id ? 'selected' : undefined}>
      {n ? (
        <button type="button" className="pick" onClick={() => setChannel(target, { kind: 'node', id })} title={n.name ?? undefined}>
          {showMetered && <span className={`metered${n.metered ? ' on' : ''}`} title={n.metered ? 'Metered' : 'Not metered: solved from its neighbours'} />}
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

interface Filters { type: string; utility: string; metered: boolean }

/** Today's nodes by code or name, utility (those with a node), type (its subtypes too) and metered, grouped by type: the
 * group heading carries the type, which a 240 px panel has no room for as a column. Filtered here,
 * on the list the panel already holds. */
function Find({ stars, target }: { stars: Stars; target: ChannelId }) {
  const nodes = useNodes().data;
  const vocab = useVocabulary().data;
  const [text, setText] = useState('');
  const [f, setF] = useState<Filters>({ type: '', utility: '', metered: false });
  const parent = new Map((vocab?.node_types ?? []).map((t) => [t.code, t.parent]));
  const isA = (type: string | null, want: string) => {
    for (let x = type; x; x = parent.get(x) ?? null) if (x === want) return true;
    return false;
  };
  const list = nodes?.list ?? [];
  const used = new Set(list.flatMap((n) => {
    const up: string[] = [];
    for (let x = n.type; x; x = parent.get(x) ?? null) up.push(x);
    return up;
  }));
  const utilities = new Set(list.flatMap((n) => n.utilities));
  const t = text.trim().toLowerCase();
  const hits = list.filter((n) => (!t || n.code.toLowerCase().includes(t) || (n.name ?? '').toLowerCase().includes(t))
    && (!f.utility || n.utilities.includes(f.utility))
    && (!f.type || isA(n.type, f.type))
    && (!f.metered || n.metered));
  const groups = new Map<string, PlantNode[]>();
  for (const n of hits) groups.set(n.type ?? 'Untyped', [...(groups.get(n.type ?? 'Untyped') ?? []), n]);
  const open = t !== '' || f.type !== '' || groups.size === 1;
  return (
    <>
      <div className="pad find-filters">
        <input placeholder="Find a node" value={text} onChange={(e) => setText(e.target.value)} />
        <div className="utilities" role="group" aria-label="Utility">
          {vocab?.utilities.filter((u) => utilities.has(u.code)).map((u) => (
            <button key={u.code} type="button" aria-pressed={f.utility === u.code} className={f.utility === u.code ? 'on' : undefined}
                    title={u.name} onClick={() => setF({ ...f, utility: f.utility === u.code ? '' : u.code })}>
              {u.name}
            </button>
          ))}
        </div>
        <div className="row">
          <select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })} aria-label="Type">
            <option value="">Any type</option>
            {vocab?.node_types.filter((x) => used.has(x.code)).map((x) => <option key={x.code} value={x.code}>{x.code}</option>)}
          </select>
          <label className="small"><input type="checkbox" checked={f.metered} onChange={(e) => setF({ ...f, metered: e.target.checked })} /> metered</label>
        </div>
      </div>
      <div className="category-tree">
        {[...groups.keys()].sort().map((g) => (
          <details key={g} open={open}>
            <summary>{g} <span className="muted">{groups.get(g)!.length}</span></summary>
            <ul className="node-list">{groups.get(g)!.map((n) => <NodeRow key={n.id} id={n.id} stars={stars} target={target} showMetered />)}</ul>
          </details>
        ))}
        {nodes && hits.length === 0 && <div className="muted pad">No node matches.</div>}
      </div>
    </>
  );
}

type Member = Categories['nodes'][number];

function share(m: Member) {
  return m.weight < 1 ? `${Math.round(m.weight * 100)}%` : undefined;
}

function CategoryBranch({ id, data, kids, members, stars, target }: {
  id: number; data: Categories; stars: Stars; target: ChannelId; kids: Map<number | null, Categories['categories']>; members: Map<number | null, Member[]>;
}) {
  const c = data.categories.find((x) => x.id === id)!;
  const sub = kids.get(id) ?? [];
  const own = members.get(id) ?? [];
  const count = (cid: number): number => (members.get(cid)?.length ?? 0) + (kids.get(cid) ?? []).reduce((a, k) => a + count(k.id), 0);
  return (
    <details open={c.parent_id === null}>
      <summary><span className="dot" style={{ background: c.color ?? 'var(--muted)' }} />{c.name} <span className="muted">{count(id)}</span></summary>
      {sub.map((k) => <CategoryBranch key={k.id} id={k.id} data={data} kids={kids} members={members} stars={stars} target={target} />)}
      {own.length > 0 && <ul className="node-list">{own.map((m) => <NodeRow key={m.node_id} id={m.node_id} stars={stars} target={target} note={share(m)} />)}</ul>}
    </details>
  );
}

function CategoryTree({ stars, target }: { stars: Stars; target: ChannelId }) {
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
      {(kids.get(null) ?? []).map((c) => <CategoryBranch key={c.id} id={c.id} data={data} kids={kids} members={members} stars={stars} target={target} />)}
      {unassigned.length > 0 && (
        <details>
          <summary><span className="dot" style={{ background: 'var(--muted)' }} />Unassigned <span className="muted">{unassigned.length}</span></summary>
          <ul className="node-list">{unassigned.map((m) => <NodeRow key={m.node_id} id={m.node_id} stars={stars} target={target} />)}</ul>
        </details>
      )}
    </div>
  );
}

function Starred({ stars, target }: { stars: Stars; target: ChannelId }) {
  return (
    <>
      {stars.ids.length === 0 && <div className="muted pad">No starred nodes yet: ☆ beside a node stars it.</div>}
      <ul className="node-list">{stars.ids.map((id) => <NodeRow key={id} id={id} stars={stars} target={target} />)}</ul>
    </>
  );
}

export function LeftPanel({ collapsed, onToggle }: { collapsed: boolean; onToggle: () => void }) {
  const [tab, setTab] = useState<Tab>('find');
  const [target, setTarget] = useState<ChannelId>('A');
  const stars = useStars();
  if (collapsed) {
    return (
      <aside className="left collapsed">
        <button type="button" className="collapse" onClick={onToggle} title="Show the left panel" aria-label="Show the left panel" aria-expanded={false}>»</button>
      </aside>
    );
  }
  return (
    <aside className="left">
      <div className="tabs" role="tablist">
        {TABS.map(([t, label]) => (
          <button key={t} type="button" role="tab" aria-selected={tab === t} className={tab === t ? 'on' : undefined} onClick={() => setTab(t)}>
            {label}{t === 'starred' && stars.ids.length > 0 && <span className="muted"> {stars.ids.length}</span>}
          </button>
        ))}
        <button type="button" className="collapse" onClick={onToggle} title="Hide the left panel" aria-label="Hide the left panel" aria-expanded>«</button>
      </div>
      <div className="channel-target muted small pad" role="radiogroup" aria-label="Channel a click fills">
        A click puts a node on channel
        {CHANNELS.map((c) => (
          <button key={c.id} type="button" role="radio" aria-checked={target === c.id} className={target === c.id ? 'on' : undefined}
                  style={{ borderColor: c.color, ...(target === c.id ? { background: c.color } : {}) }} onClick={() => setTarget(c.id)}>
            {c.id}
          </button>
        ))}
      </div>
      {stars.error && <div className="error pad small">{(stars.error as Error).message}</div>}
      {tab === 'find' && <Find stars={stars} target={target} />}
      {tab === 'categories' && <CategoryTree stars={stars} target={target} />}
      {tab === 'starred' && <Starred stars={stars} target={target} />}
    </aside>
  );
}
