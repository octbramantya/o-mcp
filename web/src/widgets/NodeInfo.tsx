// One node at a glance, on the range's last day (decision 20): what feeds it and what it feeds
// (GET /api/section, one level down, which also lists every edge into the node), and its devices
// with their brand, model, gateway and Modbus address, on the node or on a feeder (GET /api/meters).
// For checking a device's details without the site's worksheet. Clicking a neighbour puts it on the
// widget's channel.
import { useQuery } from '@tanstack/react-query';
import { get } from '../api/client';
import type { Meters as M } from '../types/formats/meters';
import type { Subgraph } from '../types/formats/subgraph';
import { Field, Findings, gateway, Hint, NodeName, NodePicker, Pending } from './common';
import type { SettingsProps, WidgetProps, WidgetType } from './contract';
import { nodeOf } from './contract';
import { useHeldView } from './fresh';

interface S {
  node: number | null;
}

type Device = M['devices'][number];
type Edge = Subgraph['edges'][number];

function words(s: string) {
  return s.toLowerCase().replaceAll('_', ' ');
}

/** Where the model reads the device: the node, and each edge into it, with its quantities. */
function places(d: Device, edges: Edge[]) {
  const from = new Map(edges.map((e) => [e.id, e.from]));
  const at = new Map<string, string[]>();
  for (const q of d.graph_quantities) {
    const where = q.attached_to === 'FEEDER' && q.edge !== null ? `edge from ${from.get(q.edge) ?? d.feeder_from}` : 'node';
    at.set(where, [...(at.get(where) ?? []), q.code ?? String(q.quantity_id)]);
  }
  return [...at].map(([where, qs]) => (
    <div key={where} title={qs.join(', ')}>{where}{at.size > 1 && <span className="muted"> ({qs.length})</span>}</div>
  ));
}

function Neighbours({ title, edges, doc, far, devices, select }: {
  title: string; edges: Edge[]; doc: Subgraph; far: (e: Edge) => string;
  /** This node's devices, for the edges into it; a child's feeder meter is in the child's own answer. */
  devices: Device[] | null;
  select: WidgetProps<S>['select'];
}) {
  const byCode = new Map(doc.nodes.map((n) => [n.code, n]));
  return (
    <>
      <h4 className="pad-x">{title}</h4>
      {edges.length === 0 ? <div className="muted pad-x">Nothing.</div> : (
        <table className="grid-table">
          <thead><tr><th>Node</th><th>Type</th><th>Through</th>{devices && <th>Meter on the edge</th>}</tr></thead>
          <tbody>
            {edges.map((e) => {
              const n = byCode.get(far(e));
              const on = devices?.filter((d) => d.graph_quantities.some((q) => q.edge === e.id)) ?? [];
              return (
                <tr key={e.id}>
                  <td title={n?.name ?? undefined}>
                    {n && select
                      ? <button type="button" className="link" onClick={() => select({ kind: 'node', id: n.id })}><b>{n.code}</b></button>
                      : <b>{far(e)}</b>}{' '}
                    <span className="muted">{n?.name}</span>
                  </td>
                  <td className="muted">{n?.type ? words(n.type) : '—'}</td>
                  <td>{e.type ? words(e.type) : 'untyped'} <span className="muted">· {words(e.utility)}{e.carries_flow ? '' : ', no flow'}</span></td>
                  {devices && <td>{on.length ? on.map((d) => d.code).join(', ') : <span className="muted">—</span>}</td>}
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </>
  );
}

function Devices({ devices, edges }: { devices: Device[]; edges: Edge[] }) {
  return (
    <>
      <h4 className="pad-x">Devices</h4>
      {devices.length === 0 ? <div className="muted pad-x">No device on the node or its feeder.</div> : (
        <table className="grid-table">
          <thead><tr><th>Device</th><th>On</th><th>Brand / model</th><th>Type</th><th>Gateway</th><th>Slave ID</th><th>Status</th></tr></thead>
          <tbody>
            {devices.map((d) => (
              <tr key={d.device_id}>
                <td title={d.name ?? undefined}><b>{d.code}</b> <span className="muted">{d.name}</span></td>
                <td>{places(d, edges)}</td>
                <td>{d.brand ?? '—'} <span className="muted">{d.model}</span></td>
                <td>{d.type ?? '—'}</td>
                <td title={d.protocol ?? undefined}>{gateway(d)}</td>
                <td className="num">{d.slave_id ?? '—'}</td>
                <td className={`status ${d.observed}`}>{words(d.observed)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}

function View({ settings, entity, select, view: live }: WidgetProps<S>) {
  const node = nodeOf(entity, settings.node);
  const [view, track] = useHeldView(live, [settings, node]);
  // The same keys as the Plant section and Meters widgets, so a dashboard with both asks once.
  const s = useQuery({
    queryKey: ['plant', view.tenant, 'section', node, 1, 'down', view.asOf],
    queryFn: ({ signal }) => get<Subgraph>('/api/section', { node, depth: 1, direction: 'down', as_of: view.asOf }, signal),
    enabled: node !== null,
    placeholderData: (prev) => prev,
  });
  const m = useQuery({
    queryKey: ['plant', view.tenant, 'meters', node, view.asOf, view.tick],
    queryFn: ({ signal }) => get<M>('/api/meters', { node, as_of: view.asOf }, signal),
    enabled: node !== null,
    placeholderData: (prev) => prev,
  });
  track(m.data);
  if (node === null) return <Hint>Choose a node in the widget's settings, or follow a channel.</Hint>;
  return (
    <Pending q={s}>
      {(doc) => (
        <Pending q={m}>
          {(meters) => {
            const n = meters.node;
            const by = (a: Edge, b: Edge) => a.from.localeCompare(b.from) || a.to.localeCompare(b.to);
            return (
              <div className="scroll">
                <div className="pad">
                  <b>{n.code}</b> <span className="muted">{n.name} · {words(n.class)}{n.type ? ` · ${words(n.type)}` : ''}</span>
                  {n.site_status && <span className="muted"> · {n.site_status} since {n.site_status_as_of}</span>}
                </div>
                <Neighbours title="Fed by" doc={doc} devices={meters.devices} select={select}
                            edges={doc.edges.filter((e) => e.to === n.code).sort(by)} far={(e) => e.from} />
                <Neighbours title="Feeds" doc={doc} devices={null} select={select}
                            edges={doc.edges.filter((e) => e.from === n.code).sort(by)} far={(e) => e.to} />
                <Devices devices={meters.devices} edges={doc.edges} />
                <div className="foot muted">As of {doc.query.as_of}, as the device register records it.</div>
                <Findings findings={meters.findings.filter((f) => f.code !== 'NO_METER')} />
              </div>
            );
          }}
        </Pending>
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

export const nodeinfo: WidgetType<S> = {
  type: 'nodeinfo', label: 'Node information',
  description: 'What feeds a node and what it feeds, and its devices: brand, model, type, gateway and Modbus slave address, on the node or on an edge.',
  minW: 8, minH: 6, w: 14, h: 10,
  defaults: { node: null },
  View, Settings,
};
