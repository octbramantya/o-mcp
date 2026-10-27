// The super admin's accounts (design/frontend.md §2, decision 16): nobody signs up. Create an account
// with a temporary password, shown once; reset it; disable or enable; set role and site together.
// The API refuses all of these on one's own account.
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { FormEvent } from 'react';
import { useState } from 'react';
import { get, post } from '../api/client';
import { useMe } from '../api/hooks';
import type { Account, Role, Tenant } from '../api/types';
import { stamp } from '../time/range';

const ROLES: { role: Role; label: string }[] = [
  { role: 'user', label: 'User (one site)' },
  { role: 'admin', label: 'Admin (every site)' },
  { role: 'super_admin', label: 'Super admin (also accounts)' },
];

function RoleSite({ role, tenant, tenants, onChange }: {
  role: Role; tenant: number | null; tenants: Tenant[]; onChange: (role: Role, tenant: number | null) => void;
}) {
  return (
    <>
      <select value={role} onChange={(e) => {
        const r = e.target.value as Role;
        onChange(r, r === 'user' ? tenant ?? tenants[0]?.id ?? null : null);
      }}>
        {ROLES.map((r) => <option key={r.role} value={r.role}>{r.label}</option>)}
      </select>
      {role === 'user' && (
        <select value={tenant ?? ''} onChange={(e) => onChange(role, Number(e.target.value))}>
          {tenants.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
        </select>
      )}
    </>
  );
}

export function AccountsPage() {
  const me = useMe().data!;
  const qc = useQueryClient();
  const tenants = me.tenants;
  const [shown, setShown] = useState<{ email: string; password: string; reset: boolean } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const q = useQuery({ queryKey: ['accounts'], queryFn: ({ signal }) => get<{ users: Account[] }>('/api/admin/users', undefined, signal) });
  const done = () => { setError(null); qc.invalidateQueries({ queryKey: ['accounts'] }); };
  const failed = (e: Error) => setError(e.message);

  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  const [role, setRole] = useState<Role>('user');
  const [tenant, setTenant] = useState<number | null>(tenants[0]?.id ?? null);
  const create = useMutation({
    mutationFn: () => post<{ user: Account; temporary_password: string }>('/api/admin/users', {
      email, display_name: name || null, role, ...(role === 'user' ? { tenant_id: tenant } : {}),
    }),
    onSuccess: (r) => { setShown({ email: r.user.email, password: r.temporary_password, reset: false }); setEmail(''); setName(''); done(); },
    onError: failed,
  });
  const reset = useMutation({
    mutationFn: (u: Account) => post<{ temporary_password: string }>(`/api/admin/users/${u.id}/reset-password`)
      .then((r) => ({ email: u.email, password: r.temporary_password, reset: true })),
    onSuccess: (r) => { setShown(r); done(); },
    onError: failed,
  });
  const toggle = useMutation({
    mutationFn: (u: Account) => post(`/api/admin/users/${u.id}/${u.disabled_at ? 'enable' : 'disable'}`),
    onSuccess: done, onError: failed,
  });
  const assign = useMutation({
    mutationFn: ({ u, role, tenant }: { u: Account; role: Role; tenant: number | null }) =>
      post(`/api/admin/users/${u.id}/assign`, { role, ...(role === 'user' ? { tenant_id: tenant } : {}) }),
    onSuccess: done, onError: failed,
  });
  const siteName = (id: number | null) => tenants.find((t) => t.id === id)?.name ?? (id === null ? '' : `site ${id}`);
  const submit = (e: FormEvent) => { e.preventDefault(); create.mutate(); };

  return (
    <div className="page">
      <h2>Accounts</h2>
      {shown && (
        <div className="card notice">
          Temporary password for <b>{shown.email}</b>, shown once: <code className="secret">{shown.password}</code>{' '}
          <button type="button" onClick={() => navigator.clipboard.writeText(shown.password)}>Copy</button>{' '}
          <button type="button" className="link" onClick={() => setShown(null)}>Done</button>
          <div className="muted">They choose their own at the next log-in.{shown.reset && ' Their open sessions have ended.'}</div>
        </div>
      )}
      {error && <div className="error">{error}</div>}
      <form className="new-account" onSubmit={submit}>
        <input type="email" placeholder="Email" value={email} onChange={(e) => setEmail(e.target.value)} required />
        <input placeholder="Name (optional)" value={name} onChange={(e) => setName(e.target.value)} />
        <RoleSite role={role} tenant={tenant} tenants={tenants} onChange={(r, t) => { setRole(r); setTenant(t); }} />
        <button type="submit" className="primary" disabled={create.isPending}>Create account</button>
      </form>
      {!q.data ? <div className="muted">Loading…</div> : (
        <table className="grid-table list">
          <thead><tr><th>Email</th><th>Role and site</th><th>Last log-in</th><th>State</th><th /></tr></thead>
          <tbody>
            {q.data.users.map((u) => (
              <tr key={u.id} className={u.disabled_at ? 'muted' : undefined}>
                <td><b>{u.email}</b>{u.display_name && <div className="muted">{u.display_name}</div>}</td>
                <td>
                  {u.id === me.user.id ? <>{u.role.replace('_', ' ')} <span className="muted">(you)</span></> : (
                    <RoleSite role={u.role} tenant={u.tenant_id} tenants={tenants}
                              onChange={(role, tenant) => window.confirm(`Make ${u.email} ${role.replace('_', ' ')}${role === 'user' ? ` of ${siteName(tenant)}` : ''}? Their sessions end.`)
                                && assign.mutate({ u, role, tenant })} />
                  )}
                </td>
                <td className="muted">{u.last_login_at ? stamp(u.last_login_at, me.tenant?.time_zone) : 'never'}</td>
                <td>{u.disabled_at ? 'disabled' : u.must_change_password ? 'temporary password' : 'active'}</td>
                <td className="actions">
                  {u.id !== me.user.id && (
                    <>
                      <button type="button" className="link" onClick={() => window.confirm(`Reset ${u.email}'s password? Their sessions end.`) && reset.mutate(u)}>Reset password</button>
                      <button type="button" className="link" onClick={() => toggle.mutate(u)}>{u.disabled_at ? 'Enable' : 'Disable'}</button>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
