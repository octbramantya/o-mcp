// The caller's dashboards in the current site: open, copy, delete, and start a new one from a blank
// canvas or a template. An admin also sees the site's users' dashboards, to open read-only (§2).
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Link, useNavigate } from 'react-router-dom';
import { get, post } from '../api/client';
import { useMe, useTenant } from '../api/hooks';
import type { DashboardFull, DashboardSummary } from '../api/types';
import { templatesFor } from '../templates';
import { stamp } from '../time/range';
import type { Dashboard } from './document';
import { blank, FORMAT_VERSION } from './document';

export function ListPage() {
  const me = useMe().data!;
  const tenant = useTenant();
  const admin = me.user.role !== 'user';
  const qc = useQueryClient();
  const navigate = useNavigate();
  const mine = useQuery({
    queryKey: ['dashboards', tenant.id, 'mine'],
    queryFn: ({ signal }) => get<{ dashboards: DashboardSummary[] }>('/api/dashboards', undefined, signal),
  });
  const theirs = useQuery({
    queryKey: ['dashboards', tenant.id, 'users'],
    queryFn: ({ signal }) => get<{ dashboards: DashboardSummary[] }>('/api/admin/dashboards', undefined, signal),
    enabled: admin,
  });
  const done = () => qc.invalidateQueries({ queryKey: ['dashboards'] });
  const create = useMutation({
    mutationFn: (t: { title: string; document: Dashboard; from_template?: string }) =>
      post<DashboardFull>('/api/dashboards', { ...t, format_version: FORMAT_VERSION }),
    onSuccess: (d) => { done(); navigate(`/dashboards/${d.id}`); },
  });
  const copy = useMutation({ mutationFn: (id: number) => post<DashboardFull>(`/api/dashboards/${id}/copy`), onSuccess: done });
  const remove = useMutation({ mutationFn: (id: number) => post(`/api/dashboards/${id}/delete`), onSuccess: done });
  const failed = create.error ?? copy.error ?? remove.error;

  return (
    <div className="page">
      <h2>Dashboards · {tenant.name}</h2>
      <section className="new">
        <button type="button" className="primary" onClick={() => create.mutate({ title: 'New dashboard', document: blank() })}>
          New blank dashboard
        </button>
        {templatesFor(tenant.id).map((t) => (
          <button key={t.key} type="button" title={t.description}
                  onClick={() => create.mutate({ title: t.title, document: t.document, from_template: t.key })}>
            New from “{t.title}”
          </button>
        ))}
      </section>
      {failed && <div className="error">{(failed as Error).message}</div>}
      <List tz={tenant.time_zone} q={mine.data?.dashboards} empty="No dashboards yet." render={(d) => (
        <>
          <button type="button" className="link" onClick={() => copy.mutate(d.id)}>Copy</button>
          <button type="button" className="link" onClick={() => window.confirm(`Delete “${d.title}”?`) && remove.mutate(d.id)}>Delete</button>
        </>
      )} />
      {admin && (
        <>
          <h3>Users' dashboards <span className="muted">(read-only; opening one is logged)</span></h3>
          <List tz={tenant.time_zone} q={theirs.data?.dashboards} empty="No user in this site has a dashboard." owner render={() => null} />
        </>
      )}
    </div>
  );
}

function List({ tz, q, empty, owner, render }: {
  tz: string; q: DashboardSummary[] | undefined; empty: string; owner?: boolean; render: (d: DashboardSummary) => React.ReactNode;
}) {
  if (!q) return <div className="muted">Loading…</div>;
  if (!q.length) return <div className="muted">{empty}</div>;
  return (
    <table className="grid-table list">
      <thead><tr><th>Title</th>{owner && <th>Owner</th>}<th>Saved</th><th /></tr></thead>
      <tbody>
        {q.map((d) => (
          <tr key={d.id}>
            <td><Link to={`/dashboards/${d.id}`}>{d.title}</Link>{d.from_template && <span className="muted"> · from a template</span>}</td>
            {owner && <td>{d.owner.email}</td>}
            <td className="muted">{stamp(d.updated_at, tz)}</td>
            <td className="actions">{render(d)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
