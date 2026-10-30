// Links between the Reference view's pages: each one opens a page after the one shown, so Back
// returns to it.
import type { ReactNode } from 'react';
import { useNodes, useVocabulary } from '../../api/hooks';
import type { Ref } from '../sideBarStore';
import { useSideBar } from '../sideBarStore';

export function Go({ to, children, title }: { to: Ref; children: ReactNode; title?: string }) {
  const inspect = useSideBar((s) => s.inspect);
  return <button type="button" className="ref-link" title={title} onClick={() => inspect(to)}>{children}</button>;
}

/** A node by its code, linked when it is in the plant today. */
export function NodeLink({ code }: { code: string }) {
  const n = useNodes().data?.list.find((x) => x.code === code);
  if (!n) return <b>{code}</b>;
  return <Go to={{ kind: 'node', id: n.id }} title={n.name ?? undefined}><b>{n.code}</b></Go>;
}

/** A quantity by its id, linked; one with no vocabulary entry says so. */
export function QuantityLink({ id, code }: { id: number; code?: string | null }) {
  const q = useVocabulary().data?.quantities.find((x) => x.quantity_id === id);
  const label = q?.code ?? code;
  return (
    <Go to={{ kind: 'quantity', id }} title={q ? `${q.unit ?? 'no unit'} · ${q.reading.toLowerCase()}` : undefined}>
      {label ?? <span className="warn">id {id}</span>}
    </Go>
  );
}

/** A quantity by its code, linked when the vocabulary has it (a derived quantity has no id). */
export function QuantityCode({ code }: { code: string }) {
  const q = useVocabulary().data?.quantities.find((x) => x.code === code);
  return q ? <QuantityLink id={q.quantity_id} /> : <span>{code}</span>;
}

export function words(s: string) {
  return s.toLowerCase().replaceAll('_', ' ');
}

/** Label and value rows. */
export function Facts({ rows }: { rows: [string, ReactNode][] }) {
  return (
    <dl className="facts">
      {rows.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}
    </dl>
  );
}
