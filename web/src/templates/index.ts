// Static dashboards a new one can start from (design/frontend.md §8, decision 13): a copy is the
// user's own, and changing a template later doesn't touch the copies. Per tenant where they name
// nodes; node ids are graph.node ids (decision 19).
import type { Dashboard } from '../dashboards/document';
import tenant3Energy from './tenant-3-energy.json';

export interface Template {
  key: string;
  title: string;
  description: string;
  document: Dashboard;
}

const BY_TENANT: Record<number, Template[]> = {
  3: [{ key: 'tenant-3/energy', title: 'Energy overview', description: 'Where the energy goes, what the sankey can\'t show, and a node to look into.', document: tenant3Energy as Dashboard }],
};

export function templatesFor(tenant: number): Template[] {
  return BY_TENANT[tenant] ?? [];
}
