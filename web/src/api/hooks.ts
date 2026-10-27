// Queries shared by the frame and the widgets. Plant queries are keyed by tenant under 'plant', so
// switching tenant drops them all (frame/TopBar.tsx).
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import type { NodeList } from '../types/formats/nodelist';
import type { Vocabulary } from '../types/formats/vocabulary';
import { get, post } from './client';
import type { Categories, Me } from './types';

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

/** The sankey's categories and the nodes in each, today: the left panel's category tree. */
export function useCategories() {
  const t = useTenant();
  return useQuery({
    queryKey: ['plant', t.id, 'categories-today'],
    queryFn: ({ signal }) => get<Categories>('/api/categories', undefined, signal),
    staleTime: 10 * 60_000,
  });
}

type Stars = { nodes: number[] };

/** The account's starred nodes in this site, kept by the API so they follow the person (064). A
 * toggle shows at once and is put right if the API refuses it. */
export function useStars() {
  const t = useTenant();
  const qc = useQueryClient();
  const key = ['stars', t.id];
  const q = useQuery({ queryKey: key, queryFn: ({ signal }) => get<Stars>('/api/stars', undefined, signal), staleTime: Infinity });
  const m = useMutation({
    mutationFn: (v: { id: number; starred: boolean }) => post<Stars>('/api/stars', { node_id: v.id, starred: v.starred }),
    onMutate: ({ id, starred }) => {
      const before = qc.getQueryData<Stars>(key);
      const nodes = (before?.nodes ?? []).filter((n) => n !== id);
      qc.setQueryData<Stars>(key, { nodes: starred ? [...nodes, id] : nodes });
      return before;
    },
    onError: (_e, _v, before) => qc.setQueryData(key, before),
    onSuccess: (r) => qc.setQueryData(key, r),
  });
  const ids = q.data?.nodes ?? [];
  return {
    ids,
    error: m.error ?? q.error,
    has: (id: number) => ids.includes(id),
    toggle: (id: number) => m.mutate({ id, starred: !ids.includes(id) }),
  };
}
