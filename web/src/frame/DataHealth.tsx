// The bottom bar's data health (design/frontend.md §5): where minute data, 15-minute data and the
// daily summary stop, and which meters have gone silent, polled every minute while the tab is visible.
import { useQuery } from '@tanstack/react-query';
import { useState } from 'react';
import { get } from '../api/client';
import { useTenant } from '../api/hooks';
import type { Status } from '../api/types';
import { useDashboard } from '../dashboards/store';

const POLL = 60_000;

/** Minutes from an API time (with its offset) to now. */
function age(s: string | null): number | null {
  return s ? (Date.now() - new Date(s).getTime()) / 60_000 : null;
}

/** How far a source reaches, coloured by its age: amber after `ok` minutes, red after `warn` or with none. */
function Since({ label, at, ok, warn, hours }: { label: string; at: string | null; ok: number; warn: number; hours: number }) {
  const a = age(at);
  const level = a === null || a > warn ? 'bad' : a > ok ? 'warn' : 'ok';
  return (
    <span className={`health ${level}`} title={at ?? undefined}>
      {label}{at ? ` ${at.slice(11, 16)}` : `: none in the last ${hours} h`}{a !== null && a > 90 ? ` (${a > 2880 ? `${Math.round(a / 1440)} d` : `${Math.round(a / 60)} h`} ago)` : ''}
    </span>
  );
}

export function DataHealth() {
  const tenant = useTenant();
  const [open, setOpen] = useState(false);
  const setChannel = useDashboard((s) => s.setChannel);
  const dashboardOpen = useDashboard((s) => s.doc !== null);
  const q = useQuery({
    queryKey: ['plant', tenant.id, 'status'],
    queryFn: ({ signal }) => get<Status>('/api/status', undefined, signal),
    refetchInterval: POLL,
  });
  if (q.isError) return <span className="health bad">Data status unavailable: {(q.error as Error).message}</span>;
  const s = q.data;
  if (!s) return null;
  const unexplained = s.silent.filter((m) => !m.declared);
  const declared = s.silent.length - unexplained.length;
  return (
    <span className="health-bar">
      <Since label="Minute data" at={s.latest_minute} ok={10} warn={60} hours={s.lookback_hours} />
      <Since label="15-min data" at={s.latest_quarter} ok={45} warn={120} hours={s.lookback_hours} />
      <Since label="Daily summary refreshed" at={s.summary_refreshed} ok={45} warn={120} hours={72} />
      <span className="popover-anchor up">
        <button type="button" className={`link health ${unexplained.length ? 'warn' : 'ok'}`} onClick={() => setOpen(!open)}>
          {unexplained.length} of {s.meters} meters silent{declared ? ` (+${declared} turned off)` : ''}
        </button>
        {open && (
          <div className="popover silent-list">
            <p className="muted">No 15-minute data for over 2 hours (the last {s.lookback_hours} h are read).
              {dashboardOpen && ' A node puts it on channel A.'}</p>
            <table className="grid-table">
              <thead><tr><th>Meter</th><th>Last reading</th><th>Nodes</th></tr></thead>
              <tbody>
                {s.silent.map((m) => (
                  <tr key={m.device_id} className={m.declared ? 'muted' : undefined}>
                    <td title={m.name}><b>{m.code}</b>{m.declared && ' (turned off)'}</td>
                    <td>{m.last_reading ? m.last_reading.slice(0, 16).replace('T', ' ') : `over ${s.lookback_hours} h ago`}</td>
                    <td>{m.nodes.map((code, i) => (
                      <button key={code} type="button" className="link" disabled={!dashboardOpen}
                              onClick={() => setChannel('A', { kind: 'node', id: m.node_ids[i] })}>{code}</button>
                    ))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </span>
    </span>
  );
}
