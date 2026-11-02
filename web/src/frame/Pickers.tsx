// The side bar's three ways to choose a node (design/frontend.md §5): by text and filters, by the
// sankey's category tree, or from the account's starred list. On a dashboard a click puts the node on
// the channel chosen at the top (A unless changed) and ⓘ looks it up in the Reference view; elsewhere,
// with no channel to fill, a click looks it up. The star keeps it in the starred list, on every browser.
import { useState } from 'react';
import { useCategories, useNodes, useStars, useVocabulary } from '../api/hooks';
import type { PlantNode } from '../api/hooks';
import type { Categories } from '../api/types';
import type { ChannelId } from '../dashboards/document';
import { CHANNELS } from '../dashboards/document';
import { useDashboard } from '../dashboards/store';
import { Check, Choices, Star, Toggle, ToggleGroup } from '../ui/toggles';
import { useSideBar } from './sideBarStore';
import { Select } from '../ui/Select';
import { SearchField } from '../ui/search';
import { Fold } from '../ui/Fold';

export type Stars = ReturnType<typeof useStars>;

/** The channel a click fills, or null where there is no dashboard open. */
export type Target = ChannelId | null;

function NodeRow({ id, stars, target, note, showMetered }: { id: number; stars: Stars; target: Target; note?: string; showMetered?: boolean }) {
  const n = useNodes().data?.byId.get(id);
  const setChannel = useDashboard((s) => s.setChannel);
  const selected = useDashboard((s) => (target ? s.doc?.channels[target] : undefined));
  const inspect = useSideBar((s) => s.inspect);
  const lookUp = () => inspect({ kind: 'node', id });
  const on = stars.has(id);
  return (
    <li className={selected?.kind === 'node' && selected.id === id ? 'selected' : undefined}>
      {n ? (
        <button type="button" className="pick" onClick={target ? () => setChannel(target, { kind: 'node', id }) : lookUp} title={n.name ?? undefined}>
          {showMetered && <span className={`metered${n.metered ? ' on' : ''}`} title={n.metered ? 'Metered' : 'Not metered: solved from its neighbours'} />}
          <b>{n.code}</b> <span className="muted">{n.name}{note && ` · ${note}`}</span>
        </button>
      ) : (
        <span className="pick muted">node {id} (not in the plant today)</span>
      )}
      {n && target && (
        <button type="button" className="inspect" onClick={lookUp} title={`Look ${n.code} up in Reference`} aria-label={`Look ${n.code} up in Reference`}>ⓘ</button>
      )}
      <Star on={on} onToggle={() => stars.toggle(id)} />
    </li>
  );
}

interface Filters { type: string; utility: string; metered: boolean }

/** Today's nodes by code or name, utility (those with a node), type (its subtypes too) and metered, grouped by type: the
 * group heading carries the type, which a narrow side bar has no room for as a column. Filtered here,
 * on the list the side bar already holds. */
export function Find({ stars, target }: { stars: Stars; target: Target }) {
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
        <SearchField label="Find a node" placeholder="Find a node" value={text} onChange={setText} />
        <ToggleGroup className="utilities" label="Utility" value={f.utility || null} onChange={(u) => setF({ ...f, utility: u ?? '' })}>
          {vocab?.utilities.filter((u) => utilities.has(u.code)).map((u) => <Toggle key={u.code} id={u.code}>{u.name}</Toggle>)}
        </ToggleGroup>
        <div className="row">
          <Select label="Type" value={f.type || 'any'} onChange={(type) => setF({ ...f, type: type === 'any' ? '' : type })}
                  options={[{ id: 'any', label: 'Any type' },
                            ...(vocab?.node_types.filter((x) => used.has(x.code)).map((x) => ({ id: x.code, label: x.code })) ?? [])]} />
          <Check className="small" checked={f.metered} onChange={(metered) => setF({ ...f, metered })}>metered</Check>
        </div>
      </div>
      <div className="category-tree">
        {[...groups.keys()].sort().map((g) => (
          // remounted when a search or type opens every group, or clearing them folds them again
          <Fold key={`${g} ${open}`} defaultOpen={open} title={<>{g} <span className="muted">{groups.get(g)!.length}</span></>}>
            <ul className="node-list">{groups.get(g)!.map((n) => <NodeRow key={n.id} id={n.id} stars={stars} target={target} showMetered />)}</ul>
          </Fold>
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
  id: number; data: Categories; stars: Stars; target: Target; kids: Map<number | null, Categories['categories']>; members: Map<number | null, Member[]>;
}) {
  const c = data.categories.find((x) => x.id === id)!;
  const sub = kids.get(id) ?? [];
  const own = members.get(id) ?? [];
  const count = (cid: number): number => (members.get(cid)?.length ?? 0) + (kids.get(cid) ?? []).reduce((a, k) => a + count(k.id), 0);
  return (
    <Fold defaultOpen={c.parent_id === null}
          title={<><span className="dot" style={{ background: c.color ?? 'var(--muted)' }} />{c.name} <span className="muted">{count(id)}</span></>}>
      {sub.map((k) => <CategoryBranch key={k.id} id={k.id} data={data} kids={kids} members={members} stars={stars} target={target} />)}
      {own.length > 0 && <ul className="node-list">{own.map((m) => <NodeRow key={m.node_id} id={m.node_id} stars={stars} target={target} note={share(m)} />)}</ul>}
    </Fold>
  );
}

export function CategoryTree({ stars, target }: { stars: Stars; target: Target }) {
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
        <Fold title={<><span className="dot" style={{ background: 'var(--muted)' }} />Unassigned <span className="muted">{unassigned.length}</span></>}>
          <ul className="node-list">{unassigned.map((m) => <NodeRow key={m.node_id} id={m.node_id} stars={stars} target={target} />)}</ul>
        </Fold>
      )}
    </div>
  );
}

export function Starred({ stars, target }: { stars: Stars; target: Target }) {
  return (
    <>
      {stars.ids.length === 0 && <div className="muted pad">No starred nodes yet: ☆ beside a node stars it.</div>}
      <ul className="node-list">{stars.ids.map((id) => <NodeRow key={id} id={id} stars={stars} target={target} />)}</ul>
    </>
  );
}

/** Which channel a click fills, at the top of the three views on a dashboard; not saved with it. */
export function ChannelTarget({ value, onChange }: { value: ChannelId; onChange: (c: ChannelId) => void }) {
  return (
    <Choices className="channel-target muted small pad" label="A click puts a node on channel" value={value} onChange={onChange}
             options={CHANNELS.map((c) => ({ id: c.id, label: c.id, style: (on) => ({ borderColor: c.color, ...(on ? { background: c.color } : {}) }) }))} />
  );
}
