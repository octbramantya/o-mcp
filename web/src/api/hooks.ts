// Queries shared by the frame and the widgets. Plant queries are keyed by tenant under 'plant', so
// switching tenant drops them all (frame/TopBar.tsx).
import { useQuery } from '@tanstack/react-query';
import type { NodeList } from '../types/formats/nodelist';
import type { Vocabulary } from '../types/formats/vocabulary';
import { get } from './client';
import type { Me } from './types';

export function useMe() {
  return useQuery({ queryKey: ['me'], queryFn: ({ signal }) => get<Me>('/api/me', undefined, signal), retry: false });
}

/** The current tenant; widgets render only inside a session with one. */
export function useTenant() {
  const me = useMe().data;
  if (!me?.tenant) throw new Error('No site chosen');
  return me.tenant;
}

export function useVocabulary() {
  const t = useTenant();
  return useQuery({
    queryKey: ['plant', t.id, 'vocabulary'],
    queryFn: ({ signal }) => get<Vocabulary>('/api/vocabulary', undefined, signal),
    staleTime: Infinity,
  });
}

export type PlantNode = NodeList['nodes'][number];

/** Every node in effect today, by id: how a stored id is shown as its current code (decision 19). */
export function useNodes() {
  const t = useTenant();
  return useQuery({
    queryKey: ['plant', t.id, 'nodes-today'],
    queryFn: async ({ signal }) => {
      const r = await get<NodeList>('/api/nodes', { limit: 500 }, signal);
      return { list: r.nodes, byId: new Map(r.nodes.map((n) => [n.id, n])), complete: r.total === r.returned };
    },
    staleTime: 10 * 60_000,
  });
}
