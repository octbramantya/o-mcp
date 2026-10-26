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
