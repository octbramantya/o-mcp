// The answers that have no format in design/ (the generated ones are in ../types/formats).
import type { Dashboard } from '../types/formats/dashboard';

export interface Tenant {
  id: number;
  name: string;
  time_zone: string;
}

export interface Me {
  user: { id: number; email: string; display_name: string | null; role: 'user' | 'admin' | 'super_admin' };
  must_change_password: boolean;
  tenant: Tenant | null;
  tenants: Tenant[];
}

export interface DashboardSummary {
  id: number;
  title: string;
  format_version: number;
  from_template: string | null;
  created_at: string;
  updated_at: string;
  owner: { id: number; email: string; display_name: string | null };
  read_only: boolean;
}

export interface DashboardFull extends DashboardSummary {
  document: Dashboard;
}

export interface Finding {
  code: string;
  message: string;
  node_id?: number;
}

export interface Values {
  quantity: { code: string; utility: string; unit: string; kind: string };
  requested: { start: string; end: string };
  window: { start: string; end: string };
  resolution: 'minute' | '15min' | 'day';
  source: string;
  data_until: string | null;
  pieces: { start: string; end: string; as_of: string }[];
  values: {
    node_id: number;
    code: string;
    name: string;
    value: number | null;
    origin: string;
    parts: Record<string, number | null> | null;
  }[];
  findings: Finding[];
}

interface FlowHead {
  quantity: { code: string; utility: string; unit: string };
  window: { start: string; end: string };
  requested: { start: string; end: string };
  as_of: string;
  source: string;
  data_until: string | null;
  findings: Finding[];
}

export interface Sankey extends FlowHead {
  node_detail: boolean;
  links: { source: string; target: string; value: number; color: string | null; link_kind: string; is_ambiguous: boolean }[];
}

export interface Diagnostics extends FlowHead {
  diagnostics: { kind: string; node_code: string | null; node_id: number | null; value: number | null; detail: string | null }[];
  property_gaps: {
    node_code: string;
    node_id: number | null;
    node_name: string;
    node_type: string;
    property: string;
    kind: string;
    status: string;
    used_by: string | null;
    detail: string | null;
  }[];
}

export interface Status {
  at: string;
  latest_minute: string | null;
  latest_quarter: string | null;
  summary_refreshed: string | null;
  lookback_hours: number;
  meters: number;
  silent: { device_id: number; code: string; name: string; last_reading: string | null; nodes: string[]; node_ids: number[]; declared: boolean }[];
}

export interface Now {
  node: { id: number; code: string; name: string };
  at: string;
  lookback_minutes: number;
  devices: { device_id: number; code: string; name: string; readings: { quantity: string; unit: string; value: number | null; at: string }[] }[];
  findings: Finding[];
}

export interface Categories {
  tenant: number;
  as_of: string;
  quantity: { code: string; utility: string };
  categories: { id: number; code: string; name: string; parent_id: number | null; color: string | null }[];
  nodes: { node_id: number; code: string; category_id: number | null; how: string; weight: number }[];
}

export type Role = 'user' | 'admin' | 'super_admin';

export interface Account {
  id: number;
  email: string;
  display_name: string | null;
  role: Role;
  tenant_id: number | null;
  must_change_password: boolean;
  created_at: string;
  password_changed_at: string | null;
  last_login_at: string | null;
  disabled_at: string | null;
}
