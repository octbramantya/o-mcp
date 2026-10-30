// A quantity in the Reference view: its vocabulary entry (GET /api/vocabulary), and the devices that
// carry it, from the device list: those the network model reads it from today, at which node, and
// those that reported it in the last day without the model reading it.
import type { ReactNode } from 'react';
import { useDevices, useVocabulary } from '../../api/hooks';
import type { Device } from '../../api/hooks';
import { Pending } from '../../widgets/common';
import { Facts, Go, NodeLink, words } from './links';

function DeviceRow({ d, children }: { d: Device; children?: ReactNode }) {
  return (
    <li>
      <div><Go to={{ kind: 'device', id: d.device_id }}><b>{d.code}</b></Go> <span className="muted">{d.name}</span>
        {!d.reporting && <span className="status SILENT"> · not reporting</span>}</div>
      {children && <div className="muted small">{children}</div>}
    </li>
  );
}

export function QuantityPage({ id }: { id: number }) {
  const vocab = useVocabulary().data;
  const q = vocab?.quantities.find((x) => x.quantity_id === id);
  const devices = useDevices();
  const derived = vocab?.derived_quantities.filter((x) => q && x.from.includes(q.code)) ?? [];
  return (
    <div className="ref-page">
      <div className="ref-title"><span className="kind">quantity</span> <b>{q?.code ?? `id ${id}`}</b></div>
      {vocab && !q && <div className="warn">Quantity id {id} has no entry in the vocabulary, so what it measures is not known.</div>}
      {q && (
        <>
          <div className="muted">{q.description}</div>
          <Facts rows={[
            ['Unit', q.unit ?? 'none'],
            ['Reading', q.reading === 'COUNTER' ? 'counter: what matters is its difference over an interval' : 'sample: a value at an instant'],
            ['Solved', q.rule ? `for every node of the ${words(q.rule.utility)} network (${words(q.rule.network_agg)})` : 'no: only where a meter reads it'],
            ...(derived.length ? [['Derives', derived.map((x) => x.code).join(', ')] as [string, string]] : []),
            ['Id', q.quantity_id],
          ]} />
        </>
      )}
      <Pending q={devices}>
        {(list) => {
          const read = list.devices.filter((d) => d.graph.some((g) => g.quantity_id === id));
          const only = list.devices.filter((d) => !read.includes(d) && d.reported.some((r) => r.quantity_id === id));
          const days = list.query.reported_days;
          return (
            <>
              <section>
                <h4>Read by the model <span className="muted">{read.length}</span></h4>
                {read.length === 0 ? <div className="muted">No device: the model doesn't read it anywhere today.</div> : (
                  <ul className="ref-list">
                    {read.map((d) => (
                      <DeviceRow key={d.device_id} d={d}>
                        {d.graph.filter((g) => g.quantity_id === id).map((g, i) => (
                          <span key={i}>{i > 0 && '; '}at <NodeLink code={g.node} />
                            {g.attached_to === 'FEEDER' && <> on its feeder from {g.feeder_from && <NodeLink code={g.feeder_from} />}</>}
                            {g.role !== 'TOTAL' && ` (${words(g.role)})`}</span>
                        ))}
                      </DeviceRow>
                    ))}
                  </ul>
                )}
              </section>
              <section>
                <h4>Also reported in the last {days === 1 ? 'day' : `${days} days`}, where the model doesn't read it <span className="muted">{only.length}</span></h4>
                {only.length === 0 ? <div className="muted">None.</div> : (
                  <ul className="ref-list">
                    {only.map((d) => {
                      const at = [...new Set(d.graph.map((g) => g.node))];
                      return (
                        <DeviceRow key={d.device_id} d={d}>
                          {at.length ? <>its meter at {at.map((c, i) => <span key={c}>{i > 0 && ', '}<NodeLink code={c} /></span>)}</> : 'not in the model'}
                        </DeviceRow>
                      );
                    })}
                  </ul>
                )}
              </section>
            </>
          );
        }}
      </Pending>
    </div>
  );
}
