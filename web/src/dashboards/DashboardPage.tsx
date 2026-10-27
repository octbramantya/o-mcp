// One dashboard: its toolbar (title, time range, refresh, edit, save) and its canvas. Relative
// ranges are resolved at each refresh tick; with refresh on, the tick moves every interval while
// the tab is visible (design/frontend.md §3).
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useEffect, useMemo, useState } from 'react';
import { useBlocker, useNavigate, useParams } from 'react-router-dom';
import { get, post } from '../api/client';
import { useTenant } from '../api/hooks';
import type { DashboardFull } from '../api/types';
import { resolveRange } from '../time/range';
import { RefreshPicker, TimePicker } from '../time/TimePicker';
import { NodeName } from '../widgets/common';
import type { View } from '../widgets/contract';
import { WIDGETS } from '../widgets/registry';
import { Canvas } from './Canvas';
import type { ChannelId } from './document';
import { CHANNELS, FORMAT_VERSION } from './document';
import { useDashboard } from './store';
import { exportFile } from './transfer';

export function DashboardPage() {
  const id = Number(useParams().id);
  const tenant = useTenant();
  const q = useQuery({
    queryKey: ['dashboard', tenant.id, id],
    queryFn: ({ signal }) => get<DashboardFull>(`/api/dashboards/${id}`, undefined, signal),
    staleTime: Infinity, refetchOnWindowFocus: false,
  });
  const open = useDashboard((s) => s.open);
  const close = useDashboard((s) => s.close);
  const loaded = useDashboard((s) => s.id === id && s.doc !== null);
  useEffect(() => { if (q.data) open(q.data); }, [q.data, open]);
  useEffect(() => close, [close]);
  if (q.isError) return <div className="error pad">{(q.error as Error).message}</div>;
  if (!loaded) return <div className="muted pad">Loading…</div>;
  // the saved copy, reopened: a refetch that returns what the cache holds keeps the same object, so
  // the effect above wouldn't run and the edits would stay
  const reload = async () => {
    const r = await q.refetch();
    if (r.data) open(r.data);
  };
  return <Opened tz={tenant.time_zone} tenant={tenant.id} reload={reload} />;
}

function Opened({ tz, tenant, reload }: { tz: string; tenant: number; reload: () => void }) {
  const s = useDashboard();
  const doc = s.doc!;
  const navigate = useNavigate();
  const qc = useQueryClient();
  const [error, setError] = useState<string | null>(null);

  // refresh: every interval while the tab is visible, and on coming back to a hidden tab
  const { refresh } = s;
  useEffect(() => {
    if (!doc.refresh) return;
    const timer = setInterval(() => { if (document.visibilityState === 'visible') refresh(); }, doc.refresh * 1000);
    const back = () => { if (document.visibilityState === 'visible') refresh(); };
    document.addEventListener('visibilitychange', back);
    return () => { clearInterval(timer); document.removeEventListener('visibilitychange', back); };
  }, [doc.refresh, refresh]);

  const view: View = useMemo(() => ({ ...resolveRange(doc.time, tz, new Date(s.tick)), tick: s.tick, tz, tenant }),
    [doc.time, tz, s.tick, tenant]);

  const blocker = useBlocker(({ currentLocation, nextLocation }) => s.dirty && currentLocation.pathname !== nextLocation.pathname);
  useEffect(() => {
    if (blocker.state === 'blocked') {
      if (window.confirm('This dashboard has unsaved changes. Leave without saving?')) blocker.proceed(); else blocker.reset();
    }
  }, [blocker]);
  useEffect(() => {
    const warn = (e: BeforeUnloadEvent) => { if (useDashboard.getState().dirty) e.preventDefault(); };
    window.addEventListener('beforeunload', warn);
    return () => window.removeEventListener('beforeunload', warn);
  }, []);

  const save = useMutation({
    mutationFn: () => post<DashboardFull>(`/api/dashboards/${s.id}`, {
      title: s.title, document: doc, format_version: FORMAT_VERSION, updated_at: s.updatedAt,
    }),
    onSuccess: (d) => { s.saved(d); qc.setQueryData(['dashboard', tenant, d.id], d); qc.invalidateQueries({ queryKey: ['dashboards'] }); setError(null); },
    onError: (e: Error) => setError(e.message),
  });
  const copy = useMutation({
    mutationFn: () => post<DashboardFull>(`/api/dashboards/${s.id}/copy`),
    onSuccess: (d) => { qc.invalidateQueries({ queryKey: ['dashboards'] }); navigate(`/dashboards/${d.id}`); },
    onError: (e: Error) => setError(e.message),
  });

  return (
    <div className="dashboard">
      <div className="toolbar">
        {s.editing ? (
          <input className="title-input big" value={s.title} onChange={(e) => s.setTitle(e.target.value)} />
        ) : (
          <h2>{s.title}{s.readOnly && <span className="muted"> · {s.owner?.email}'s, read-only</span>}</h2>
        )}
        <span className="spacer" />
        <Channels />
        <TimePicker value={doc.time} onChange={(time) => s.change((d) => ({ ...d, time }))} />
        <RefreshPicker value={doc.refresh} onChange={(refresh) => s.change((d) => ({ ...d, refresh }))} />
        <button type="button" onClick={refresh} title="Resolve the range again and reload every widget">Refresh</button>
        {s.readOnly ? (
          <button type="button" onClick={() => copy.mutate()}>Copy to my dashboards</button>
        ) : (
          <>
            {s.editing && <AddWidget />}
            <button type="button" onClick={() => s.setEditing(!s.editing)}>{s.editing ? 'Done editing' : 'Edit'}</button>
            <button type="button" className="primary" disabled={!s.dirty || save.isPending} onClick={() => save.mutate()}>
              {save.isPending ? 'Saving…' : s.dirty ? 'Save' : 'Saved'}
            </button>
            {s.dirty && <button type="button" onClick={reload}>Discard</button>}
            <button type="button" onClick={() => exportFile(s.title, doc, tenant)} title="Download this dashboard, as edited, as a JSON file">Export</button>
          </>
        )}
      </div>
      {error && <div className="error pad">{error} {error.includes('reload') && <button type="button" onClick={reload}>Reload</button>}</div>}
      <Canvas doc={doc} view={view} />
    </div>
  );
}

function Channels() {
  const channels = useDashboard((s) => s.doc?.channels ?? {});
  const setChannel = useDashboard((s) => s.setChannel);
  const used = CHANNELS.filter((c) => channels[c.id]);
  if (!used.length) return null;
  return (
    <span className="channels">
      {used.map((c) => {
        const e = channels[c.id]!;
        return (
          <span key={c.id} className="channel" style={{ borderColor: c.color }}>
            <span className="dot" style={{ background: c.color }} />{c.id}:{' '}
            {e.kind === 'node' && typeof e.id === 'number' ? <NodeName id={e.id} /> : `${e.kind} ${e.id}`}
            <button type="button" className="link" title="Clear the channel" onClick={() => setChannel(c.id as ChannelId, undefined)}>×</button>
          </span>
        );
      })}
    </span>
  );
}

function AddWidget() {
  const addWidget = useDashboard((s) => s.addWidget);
  return (
    <select value="" onChange={(e) => {
      const t = WIDGETS.find((w) => w.type === e.target.value);
      if (t) addWidget(t.type, t.w, t.h, t.defaults);
    }}>
      <option value="">Add a widget…</option>
      {WIDGETS.map((w) => <option key={w.type} value={w.type} title={w.description}>{w.label}</option>)}
    </select>
  );
}
