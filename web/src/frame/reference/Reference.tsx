// The Reference view (design/frontend.md §5): a lookup of the plant today, apart from any dashboard
// and channel. One search finds nodes, devices and quantities in the lists the browser already holds;
// every node, device and quantity on a page opens its own page, and Back and Forward walk the pages
// seen, as in a browser.
import { useState } from 'react';
import { useDevices, useNodes, useVocabulary } from '../../api/hooks';
import type { Stars } from '../Pickers';
import type { Ref } from '../sideBarStore';
import { useSideBar } from '../sideBarStore';
import { DevicePage } from './DevicePage';
import { Go } from './links';
import { NodePage } from './NodePage';
import { QuantityPage } from './QuantityPage';

const SHOWN = 8;

interface Hit { to: Ref; code: string; note: string | null }

function has(t: string, ...fields: (string | number | null | undefined)[]) {
  return fields.some((f) => f !== null && f !== undefined && String(f).toLowerCase().replaceAll('_', ' ').includes(t));
}

/** By code first, then by the other fields. */
function ranked<T>(xs: T[], code: (x: T) => string, t: string) {
  const starts = (x: T) => (code(x).toLowerCase().replaceAll('_', ' ').startsWith(t) ? 0 : has(t, code(x)) ? 1 : 2);
  return [...xs].sort((a, b) => starts(a) - starts(b) || code(a).localeCompare(code(b)));
}

function Group({ title, hits, onPick }: { title: string; hits: Hit[]; onPick: () => void }) {
  const [all, setAll] = useState(false);
  if (hits.length === 0) return null;
  return (
    <section>
      <h4>{title} <span className="muted">{hits.length}</span></h4>
      <ul className="node-list">
        {(all ? hits : hits.slice(0, SHOWN)).map((h) => (
          <li key={`${h.to.kind} ${h.to.id}`} onClick={onPick}>
            <Go to={h.to} title={h.note ?? undefined}><b>{h.code}</b> <span className="muted">{h.note}</span></Go>
          </li>
        ))}
      </ul>
      {hits.length > SHOWN && !all && <button type="button" className="link small" onClick={() => setAll(true)}>{hits.length - SHOWN} more</button>}
    </section>
  );
}

function Results({ text, onPick }: { text: string; onPick: () => void }) {
  const nq = useNodes();
  const dq = useDevices();
  const vq = useVocabulary();
  const nodes = nq.data?.list ?? [];
  const devices = dq.data?.devices ?? [];
  const quantities = vq.data?.quantities ?? [];
  const failed = [nq, dq, vq].find((q) => q.isError)?.error as Error | undefined;
  const loading = !nq.data || !dq.data || !vq.data;
  const t = text.trim().toLowerCase().replaceAll('_', ' ');
  const n = /^\d+$/.test(t) ? Number(t) : null;
  const ns = ranked(nodes.filter((x) => has(t, x.code, x.name)), (x) => x.code, t)
    .map((x): Hit => ({ to: { kind: 'node', id: x.id }, code: x.code, note: x.name }));
  const ds = ranked(devices.filter((x) => has(t, x.code, x.name, x.brand, x.model, x.gateway?.ip_address) || x.slave_id === n), (x) => x.code, t)
    .map((x): Hit => ({ to: { kind: 'device', id: x.device_id }, code: x.code, note: [x.name, x.brand, x.model].filter(Boolean).join(' · ') || null }));
  const qs = ranked(quantities.filter((x) => has(t, x.code, x.description, x.unit) || x.quantity_id === n), (x) => x.code, t)
    .map((x): Hit => ({ to: { kind: 'quantity', id: x.quantity_id }, code: x.code, note: x.unit }));
  if (!ns.length && !ds.length && !qs.length) {
    return failed ? <div className="error pad">{failed.message}</div>
      : <div className="muted pad">{loading ? 'Loading…' : 'Nothing matches.'}</div>;
  }
  return (
    <div className="ref-page">
      <Group key={`n ${t}`} title="Nodes" hits={ns} onPick={onPick} />
      <Group key={`d ${t}`} title="Devices" hits={ds} onPick={onPick} />
      <Group key={`q ${t}`} title="Quantities" hits={qs} onPick={onPick} />
      {failed && <div className="error small">{failed.message}</div>}
      {!failed && loading && <div className="muted small">Still loading: more may match.</div>}
    </div>
  );
}

function Start({ stars }: { stars: Stars }) {
  const nodes = useNodes().data;
  return (
    <div className="ref-page">
      <div className="muted">
        Look up a node, a device or a quantity, as the plant is today: search by code or name, a device's
        brand, model, gateway address or slave ID, or a quantity's description or unit. ⓘ beside a node in
        Find, Categories or Starred opens it here.
      </div>
      {stars.ids.length > 0 && (
        <section>
          <h4>Starred</h4>
          <ul className="node-list">
            {stars.ids.map((id) => {
              const x = nodes?.byId.get(id);
              return x && <li key={id}><Go to={{ kind: 'node', id }}><b>{x.code}</b> <span className="muted">{x.name}</span></Go></li>;
            })}
          </ul>
        </section>
      )}
    </div>
  );
}

export function Reference({ stars }: { stars: Stars }) {
  const history = useSideBar((s) => s.history);
  const at = useSideBar((s) => s.at);
  const go = useSideBar((s) => s.go);
  const [text, setText] = useState('');
  const cur = history[at];
  return (
    <div className="reference">
      <div className="ref-head pad">
        <button type="button" onClick={() => go(-1)} disabled={at <= 0} title="Back" aria-label="Back">‹</button>
        <button type="button" onClick={() => go(1)} disabled={at >= history.length - 1} title="Forward" aria-label="Forward">›</button>
        <input type="search" placeholder="Node, device or quantity" value={text} onChange={(e) => setText(e.target.value)}
               onKeyDown={(e) => { if (e.key === 'Escape') setText(''); }} aria-label="Look up a node, device or quantity" />
      </div>
      {text.trim() ? <Results text={text} onPick={() => setText('')} />
        : !cur ? <Start stars={stars} />
        : cur.kind === 'node' ? <NodePage key={cur.id} id={cur.id} stars={stars} />
        : cur.kind === 'device' ? <DevicePage key={cur.id} id={cur.id} />
        : <QuantityPage key={cur.id} id={cur.id} />}
    </div>
  );
}
