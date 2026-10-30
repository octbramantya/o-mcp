// A node in the Reference view, today: what it is, what feeds it and what it feeds (GET /api/section,
// one level down, which also lists every edge into it), its devices with the register's details, on
// the node or a feeder (GET /api/meters), and which values can be given for it and how.
import { useNodeMeters, useNodes, useNodeSection } from '../../api/hooks';
import type { Meters } from '../../types/formats/meters';
import type { Subgraph } from '../../types/formats/subgraph';
import { Findings, gateway, Pending } from '../../widgets/common';
import type { Stars } from '../Pickers';
import { Facts, Go, NodeLink, QuantityCode, words } from './links';

type Edge = Subgraph['edges'][number];
type Device = Meters['devices'][number];

const SOURCE: Record<Meters['resolvable'][number]['availability'], string> = {
  MEASURED: 'measured', INFERRED: 'solved', INHERITED: 'inherited', DERIVED: 'derived', NOT_AVAILABLE: 'not available',
};

function Neighbours({ title, edges, doc, far, devices }: {
  title: string; edges: Edge[]; doc: Subgraph; far: (e: Edge) => string;
  /** This node's devices, for the meters on the edges into it; a child's are on the child's own page. */
  devices: Device[] | null;
}) {
  const byCode = new Map(doc.nodes.map((n) => [n.code, n]));
  return (
    <section>
      <h4>{title} <span className="muted">{edges.length}</span></h4>
      {edges.length === 0 ? <div className="muted">Nothing.</div> : (
        <ul className="ref-list">
          {edges.map((e) => {
            const n = byCode.get(far(e));
            const on = devices?.filter((d) => d.graph_quantities.some((q) => q.edge === e.id)) ?? [];
            return (
              <li key={e.id}>
                <div><NodeLink code={far(e)} /> <span className="muted">{n?.name}</span></div>
                <div className="muted small">
                  {n?.type ? words(n.type) : 'untyped'} · {e.type ? words(e.type) : 'untyped edge'}, {words(e.utility)}{e.carries_flow ? '' : ', no flow'}
                  {on.length > 0 && <> · meter {on.map((d, i) => <span key={d.device_id}>{i > 0 && ', '}<Go to={{ kind: 'device', id: d.device_id }}>{d.code}</Go></span>)}</>}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

function Devices({ devices }: { devices: Device[] }) {
  return (
    <section>
      <h4>Devices <span className="muted">{devices.length}</span></h4>
      {devices.length === 0 ? <div className="muted">No device on the node or its feeder: its values are solved from its neighbours.</div> : (
        <ul className="ref-list">
          {devices.map((d) => {
            const where = [...new Set(d.graph_quantities.map((q) => (q.attached_to === 'FEEDER' ? `feeder from ${d.feeder_from}` : 'node')))]
              .sort((a, b) => Number(a !== 'node') - Number(b !== 'node'));
            return (
              <li key={d.device_id}>
                <div>
                  <Go to={{ kind: 'device', id: d.device_id }}><b>{d.code}</b></Go> <span className="muted">{d.name}</span>
                  <span className={`status ${d.observed}`}> · {words(d.observed)}</span>
                </div>
                <div className="muted small">on the {where.join(' and the ')} · {d.brand ?? 'brand not recorded'}{d.model && ` ${d.model}`}</div>
                <div className="muted small">gateway {gateway(d)} · slave ID {d.slave_id ?? 'not recorded'}</div>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

export function NodePage({ id, stars }: { id: number; stars: Stars }) {
  const nodes = useNodes().data;
  const known = nodes?.byId.get(id);
  const s = useNodeSection(id);
  const m = useNodeMeters(id);
  const on = stars.has(id);
  if (nodes && !known) return <div className="muted pad">Node {id} isn't in the plant today.</div>;
  return (
    <div className="ref-page">
      <div className="ref-title">
        <span className="kind">node</span> <b>{known?.code ?? id}</b>
        <button type="button" className={`star${on ? ' on' : ''}`} onClick={() => stars.toggle(id)}
                title={on ? 'Unstar' : 'Star'} aria-label={on ? 'Unstar' : 'Star'} aria-pressed={on}>{on ? '★' : '☆'}</button>
      </div>
      {known?.name && <div className="muted">{known.name}</div>}
      <Pending q={m}>
        {(meters) => {
          const n = meters.node;
          return (
            <>
              <Facts rows={[
                ['Class', words(n.class)],
                ['Type', n.type ? words(n.type) : 'untyped'],
                ['Utilities', n.utilities.map(words).join(', ') || '—'],
                ...(n.site_status ? [['Site status', `${n.site_status} since ${n.site_status_as_of}`] as [string, string]] : []),
              ]} />
              <Pending q={s}>
                {(doc) => {
                  const by = (a: Edge, b: Edge) => a.from.localeCompare(b.from) || a.to.localeCompare(b.to);
                  return (
                    <>
                      <Neighbours title="Fed by" doc={doc} devices={meters.devices} far={(e) => e.from}
                                  edges={doc.edges.filter((e) => e.to === n.code).sort(by)} />
                      <Neighbours title="Feeds" doc={doc} devices={null} far={(e) => e.to}
                                  edges={doc.edges.filter((e) => e.from === n.code).sort(by)} />
                    </>
                  );
                }}
              </Pending>
              <Devices devices={meters.devices} />
              <section>
                <h4>Values at this node</h4>
                <ul className="ref-list">
                  {meters.resolvable.map((r) => (
                    <li key={r.quantity}>
                      <div><QuantityCode code={r.quantity} /> {r.unit && <span className="muted">({r.unit})</span>}{' '}
                        <span className={r.availability === 'NOT_AVAILABLE' ? 'muted' : undefined}>· {SOURCE[r.availability]}</span></div>
                      <div className="muted small">{r.note}</div>
                    </li>
                  ))}
                </ul>
              </section>
              <Findings findings={meters.findings.filter((f) => f.code !== 'NO_METER')} />
              <div className="muted small">Today, as the graph and the device register record it.</div>
            </>
          );
        }}
      </Pending>
    </div>
  );
}
