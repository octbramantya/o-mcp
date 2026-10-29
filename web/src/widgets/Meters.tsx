// Two questions about a node (GET /api/meters), on the range's last day. Meters: the devices reading
// the node or its feeder, when each last reported, and, opened, each device's own quantities. Values
// at this node: what the Value widget can give here, and how.
import { useQuery } from '@tanstack/react-query';
import { Fragment, useState } from 'react';
import { get } from '../api/client';
import type { Meters as M } from '../types/formats/meters';
import { Field, Findings, Hint, NodeName, NodePicker, Pending } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';
import { useHeldView } from './fresh';

interface S {
  node: number | null;
}

type Device = M['devices'][number];

const SOURCE: Record<M['resolvable'][number]['availability'], string> = {
  MEASURED: 'measured', INFERRED: 'solved', INHERITED: 'inherited', DERIVED: 'derived', NOT_AVAILABLE: 'not available',
};

/** An API time in site time as DD/MM/YY - HH:MM. */
function when(s: string | null | undefined): string {
  const m = s && /^\d{2}(\d{2})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(s);
  return m ? `${m[3]}/${m[2]}/${m[1]} - ${m[4]}:${m[5]}` : (s ?? '—');
}

/** One row per quantity the device reported in the lookback or the graph maps it for. */
function quantities(d: Device) {
  const ids = new Set([...d.reported.map((r) => r.quantity_id), ...d.graph_quantities.map((g) => g.quantity_id)]);
  return [...ids].map((id) => {
    const r = d.reported.find((x) => x.quantity_id === id);
    return { id, code: r?.code ?? d.graph_quantities.find((g) => g.quantity_id === id)?.code ?? null, r };
  }).sort((a, b) => (a.code ?? '').localeCompare(b.code ?? '') || a.id - b.id);
}

function DeviceQuantities({ d, days }: { d: Device; days: number }) {
  const qs = quantities(d);
  if (qs.length === 0) return <div className="muted">Nothing reported in the last {days} days.</div>;
  return (
    <table className="grid-table sub">
      <thead><tr><th>Quantity</th><th>Reading</th><th>Last reading</th></tr></thead>
      <tbody>
        {qs.map((q) => (
          <tr key={q.id}>
            <td>{q.code ?? <span className="warn">id {q.id}, not in the vocabulary</span>} {q.r?.unit && <span className="muted">({q.r.unit})</span>}</td>
            <td className="muted">{q.r?.reading?.toLowerCase() ?? ''}</td>
            <td>{q.r ? when(q.r.last_reading) : <span className="warn">not reported in {days} days</span>}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function View({ settings, entity, view: live }: WidgetProps<S>) {
  const node = nodeOf(entity, settings.node);
  const [view, track] = useHeldView(live, [settings, node]);
  const [open, setOpen] = useState<ReadonlySet<number>>(new Set());
  const q = useQuery({
    queryKey: ['plant', view.tenant, 'meters', node, view.asOf, view.tick],
    queryFn: ({ signal }) => get<M>('/api/meters', { node, as_of: view.asOf }, signal),
    enabled: node !== null,
    placeholderData: (prev) => prev,
  });
  track(q.data);
  if (node === null) return <Hint>Choose a node in the widget's settings, or follow a channel.</Hint>;
  const toggle = (id: number) => setOpen((s) => {
    const n = new Set(s);
    if (!n.delete(id)) n.add(id);
    return n;
  });
  return (
    <Pending q={q}>
      {(m) => (
        <div className="scroll">
          <div className="pad"><b>{m.node.code}</b> <span className="muted">{m.node.name} · {m.node.type}</span></div>
          <h4 className="pad-x">Meters</h4>
          {m.devices.length === 0 ? <div className="pad-x muted">No meter on this node or its feeder.</div> : (
            <table className="grid-table clickable">
              <thead><tr><th>Device</th><th>On</th><th>Last reading</th><th>Status</th><th>Quantities</th></tr></thead>
              <tbody>
                {m.devices.map((d) => (
                  <Fragment key={d.device_id}>
                    <tr onClick={() => toggle(d.device_id)} className={open.has(d.device_id) ? 'selected' : undefined}>
                      <td title={d.name ?? undefined}>{open.has(d.device_id) ? '▾' : '▸'} <b>{d.code}</b> <span className="muted">{d.name}</span></td>
                      <td className="muted">{d.attached_to === 'FEEDER' ? `feeder from ${d.feeder_from}` : 'node'}</td>
                      <td>{when(d.last_reading)}</td>
                      <td className={`status ${d.observed}`}>{d.observed.toLowerCase().replace('_', ' ')}</td>
                      <td className="muted">{d.reported.length} reported · {new Set(d.graph_quantities.map((g) => g.quantity_id)).size} in graph</td>
                    </tr>
                    {open.has(d.device_id) && (
                      <tr className="expanded"><td colSpan={5}><DeviceQuantities d={d} days={m.query.lookback_days} /></td></tr>
                    )}
                  </Fragment>
                ))}
              </tbody>
            </table>
          )}
          <h4 className="pad-x">Values at this node</h4>
          <div className="pad-x muted">What the Value widget can give for {m.node.code}, and where it comes from.</div>
          <table className="grid-table">
            <thead><tr><th>Quantity</th><th>Source</th><th>How</th></tr></thead>
            <tbody>
              {m.resolvable.map((r) => (
                <tr key={r.quantity}>
                  <td>{r.quantity} {r.unit && <span className="muted">({r.unit})</span>}</td>
                  <td className={r.availability === 'NOT_AVAILABLE' ? 'muted' : undefined}>{SOURCE[r.availability]}</td>
                  <td className="muted">{r.note}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <Findings findings={m.findings} />
        </div>
      )}
    </Pending>
  );
}

function Settings({ settings, setSettings }: SettingsProps<S>) {
  return (
    <Field label="Node (a channel's node replaces it)">
      {settings.node !== null && <div><NodeName id={settings.node} /></div>}
      <NodePicker onPick={(node) => setSettings({ node })} />
    </Field>
  );
}

export const meters: WidgetType<S> = {
  type: 'meters', label: 'Meters',
  description: 'The meters on a node, when each last reported and what each reports, and which values can be given there.',
  minW: 6, minH: 5, w: 10, h: 9,
  defaults: { node: null },
  View, Settings,
};
