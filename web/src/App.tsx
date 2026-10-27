// The routes, behind the session: log-in, then the forced password change, then (for an admin) a
// site, then the dashboards.
import { createBrowserRouter, Navigate, RouterProvider } from 'react-router-dom';
import { AccountsPage } from './admin/AccountsPage';
import { useMe } from './api/hooks';
import { LoginPage, PasswordPage } from './auth/LoginPage';
import { DashboardPage } from './dashboards/DashboardPage';
import { ListPage } from './dashboards/ListPage';
import { Frame } from './frame/Frame';

function Gate({ children }: { children: React.ReactNode }) {
  const me = useMe();
  if (me.isPending) return <div className="muted pad">Loading…</div>;
  if (!me.data) return <LoginPage />;
  if (me.data.must_change_password) return <PasswordPage forced />;
  return <>{children}</>;
}

function Home() {
  const me = useMe().data!;
  if (!me.tenant) return <div className="page"><h2>Choose a site</h2><p className="muted">Pick one in the top bar to see its dashboards.</p></div>;
  return <ListPage />;
}

function Sited({ children }: { children: React.ReactNode }) {
  return useMe().data?.tenant ? <>{children}</> : <Navigate to="/" replace />;
}

function SuperAdmin({ children }: { children: React.ReactNode }) {
  return useMe().data?.user.role === 'super_admin' ? <>{children}</> : <Navigate to="/" replace />;
}

const router = createBrowserRouter([{
  path: '/',
  element: <Gate><Frame /></Gate>,
  children: [
    { index: true, element: <Home /> },
    { path: 'dashboards/:id', element: <Sited><DashboardPage /></Sited> },
    { path: 'accounts', element: <SuperAdmin><AccountsPage /></SuperAdmin> },
    { path: '*', element: <Navigate to="/" replace /> },
  ],
}]);

export function App() {
  return <RouterProvider router={router} />;
}
