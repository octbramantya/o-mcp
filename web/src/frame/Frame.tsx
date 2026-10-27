// The frame (design/frontend.md §5): the top bar shows who and where the user is, and lets an admin
// switch site; the left panel holds ways to choose a node; the bottom bar the site's clock and the
// open dashboard's refresh.
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { useEffect, useState } from 'react';
import { Link, Outlet, useMatch, useNavigate } from 'react-router-dom';
import { post } from '../api/client';
import { useMe } from '../api/hooks';
import type { Me } from '../api/types';
import { PasswordPage } from '../auth/LoginPage';
import { useDashboard } from '../dashboards/store';
import { siteNow } from '../time/range';
import { DataHealth } from './DataHealth';
import { LeftPanel } from './LeftPanel';

export function useSwitchTenant() {
  const qc = useQueryClient();
  const navigate = useNavigate();
  return useMutation({
    mutationFn: (id: number) => post<Me>('/api/tenant', { tenant_id: id }),
    onSuccess: (me) => {
      qc.removeQueries({ queryKey: ['plant'] });
      qc.removeQueries({ queryKey: ['dashboards'] });
      qc.removeQueries({ queryKey: ['dashboard'] });
      qc.setQueryData(['me'], me);
      navigate('/');
    },
  });
}

function TopBar({ onPassword }: { onPassword: () => void }) {
  const me = useMe().data!;
  const qc = useQueryClient();
  const switchTenant = useSwitchTenant();
  const logout = useMutation({ mutationFn: () => post('/api/logout'), onSettled: () => { qc.clear(); qc.setQueryData(['me'], null); } });
  return (
    <header className="topbar">
      <Link to="/" className="brand">Plant dashboards</Link>
      {me.user.role === 'user' ? (
        <span className="tenant">{me.tenant?.name}</span>
      ) : (
        <select className="tenant" value={me.tenant?.id ?? ''} onChange={(e) => switchTenant.mutate(Number(e.target.value))}>
          {!me.tenant && <option value="">Choose a site…</option>}
          {me.tenants.map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
        </select>
      )}
      <span className="spacer" />
      {me.user.role === 'super_admin' && <Link to="/accounts">Accounts</Link>}
      <span className="muted who">{me.user.display_name ?? me.user.email} · {me.user.role.replace('_', ' ')}</span>
      <button type="button" className="link" onClick={onPassword}>Password</button>
      <button type="button" className="link" onClick={() => logout.mutate()}>Log out</button>
    </header>
  );
}

function BottomBar() {
  const me = useMe().data!;
  const refresh = useDashboard((s) => s.doc?.refresh);
  const tick = useDashboard((s) => s.tick);
  const open = useDashboard((s) => s.doc !== null);
  const tz = me.tenant?.time_zone;
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 15_000);
    return () => clearInterval(t);
  }, []);
  const clock = (d: Date) => siteNow(tz!, d).toISOString().slice(0, 16).replace('T', ' ');
  return (
    <footer className="bottombar">
      {tz && <span>{me.tenant?.name} {clock(now)} <span className="muted">({tz})</span></span>}
      {tz && <DataHealth />}
      <span className="spacer" />
      {open && tz && <span className="muted">{refresh ? `Refreshing every ${refresh} s` : 'Refresh off'} · loaded {clock(new Date(tick)).slice(11)}</span>}
    </footer>
  );
}

// whether the left panel is collapsed, remembered per browser: a convenience, so storage may fail
const COLLAPSED = 'o-mcp.left-collapsed';

function useCollapsed(): [boolean, () => void] {
  const [collapsed, setCollapsed] = useState(() => {
    try { return localStorage.getItem(COLLAPSED) === '1'; } catch { return false; }
  });
  const toggle = () => setCollapsed((c) => {
    try { localStorage.setItem(COLLAPSED, c ? '0' : '1'); } catch { /* not remembered */ }
    return !c;
  });
  return [collapsed, toggle];
}

export function Frame() {
  const [password, setPassword] = useState(false);
  const [collapsed, toggleLeft] = useCollapsed();
  const onDashboard = useMatch('/dashboards/:id');
  const me = useMe().data!;
  return (
    <div className={`frame${onDashboard ? ' with-left' : ''}${collapsed ? ' left-collapsed' : ''}`}>
      <TopBar onPassword={() => setPassword(true)} />
      {onDashboard && me.tenant && <LeftPanel collapsed={collapsed} onToggle={toggleLeft} />}
      <main>
        {password ? <PasswordPage forced={false} onDone={() => setPassword(false)} /> : <Outlet />}
        {password && <button type="button" className="link pad" onClick={() => setPassword(false)}>Cancel</button>}
      </main>
      <BottomBar />
    </div>
  );
}
