// A device in the Reference view, from the device list (GET /api/devices): the register's details,
// where the network model reads it today, by node, and the quantities it reported in the last day
// beside those the model reads. No reading times: a 15-minute bucket's time reads as the last reading.
import { useDevices } from '../../api/hooks';
import type { Device } from '../../api/hooks';
import { gateway, Pending } from '../../widgets/common';
import { Facts, NodeLink, QuantityLink, words } from './links';

function status(d: Device, days: number) {
  if (d.reporting) return <span className="status REPORTING">reporting</span>;
  if (d.last_reading) return <span className="status SILENT">silent: nothing in the last 2 hours</span>;
  return <span className="status NO_DATA">nothing in the last {days === 1 ? 'day' : `${days} days`}</span>;
}

/** The model's readings of the device, by the node they belong to and where on it. */
function Places({ d }: { d: Device }) {
  const at = new Map<string, Device['graph']>();
  for (const g of d.graph) {
    const k = `${g.node_id} ${g.edge ?? ''}`;
    at.set(k, [...(at.get(k) ?? []), g]);
  }
  if (at.size === 0) return <div className="muted">The network model doesn't read this device.</div>;
  return (
    <ul className="ref-list">
      {[...at.values()].map((gs) => {
        const g = gs[0];
        return (
          <li key={`${g.node_id} ${g.edge}`}>
            <div><NodeLink code={g.node} />{g.attached_to === 'FEEDER' && <span className="muted"> on its feeder from </span>}
              {g.attached_to === 'FEEDER' && g.feeder_from && <NodeLink code={g.feeder_from} />}</div>
            <div className="inline-list small">
              {gs.map((q) => (
                <span key={q.quantity_id}>
                  <QuantityLink id={q.quantity_id} code={q.code} />
                  {(q.role !== 'TOTAL' || q.multiplier !== 1) && (
                    <span className="muted"> ({[q.role !== 'TOTAL' && words(q.role), q.multiplier !== 1 && `× ${q.multiplier}`].filter(Boolean).join(', ')})</span>
                  )}
                </span>
              ))}
            </div>
          </li>
        );
      })}
    </ul>
  );
}

export function DevicePage({ id }: { id: number }) {
  const q = useDevices();
  return (
    <Pending q={q}>
      {(list) => {
        const d = list.byId.get(id);
        if (!d) return <div className="muted pad">No device {id} in this site's register.</div>;
        const days = list.query.reported_days;
        const mapped = new Set(d.graph.map((g) => g.quantity_id));
        const heard = new Set(d.reported.map((r) => r.quantity_id));
        const silentMapped = [...mapped].filter((x) => !heard.has(x));
        return (
          <div className="ref-page">
            <div className="ref-title"><span className="kind">device</span> <b>{d.code}</b></div>
            {d.name && <div className="muted">{d.name}</div>}
            <Facts rows={[
              ['Status', status(d, days)],
              ['Type', d.type ?? '—'],
              ['Brand / model', <>{d.brand ?? 'not recorded'} <span className="muted">{d.model}</span></>],
              ['Protocol', d.protocol ?? 'not recorded'],
              ['Gateway', gateway(d)],
              ['Slave ID', d.slave_id ?? 'not recorded'],
              ['Register', <>{d.declared_status ?? 'no status'}{!d.active && <span className="warn"> · not active</span>}</>],
            ]} />
            <section>
              <h4>Where the model reads it</h4>
              <Places d={d} />
            </section>
            <section>
              <h4>Reported in the last {days === 1 ? 'day' : `${days} days`} <span className="muted">{d.reported.length}</span></h4>
              {d.reported.length === 0 ? <div className="muted">Nothing.</div> : (
                <div className="inline-list">
                  {d.reported.map((r) => (
                    <span key={r.quantity_id} className={mapped.has(r.quantity_id) ? 'mapped' : undefined}
                          title={mapped.has(r.quantity_id) ? 'The model reads it' : undefined}>
                      <QuantityLink id={r.quantity_id} code={r.code} />
                    </span>
                  ))}
                </div>
              )}
              {silentMapped.length > 0 && (
                <div className="small"><span className="warn">The model reads, but it didn't report: </span>
                  <span className="inline-list">{silentMapped.map((x) => <QuantityLink key={x} id={x} />)}</span>
                </div>
              )}
              {d.reported.length > 0 && <div className="muted small">Underlined: the model reads it.</div>}
            </section>
          </div>
        );
      }}
    </Pending>
  );
}
