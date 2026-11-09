// A drag handle on a panel's edge (design/frontend.md §4, §5): drag to resize, double-click for the
// initial width. React Aria has no splitter, so this stays hand-written (design/frontend-aria.md);
// it is a `role="separator"`. `edge` is the side of the panel it sits on: on the right edge a drag
// to the right widens the panel, on the left edge a drag to the left does.
import type { PointerEvent as ReactPointerEvent } from 'react';

export function Resizer({ label, edge, width, setWidth, initial }: {
  label: string;
  edge: 'left' | 'right';
  /** The width when a drag starts. */
  width: () => number;
  setWidth: (w: number) => void;
  initial: number;
}) {
  const down = (e: ReactPointerEvent<HTMLDivElement>) => {
    const from = e.clientX;
    const start = width();
    const sign = edge === 'right' ? 1 : -1;
    const el = e.currentTarget;
    el.setPointerCapture(e.pointerId);
    const move = (m: PointerEvent) => setWidth(start + sign * (m.clientX - from));
    const up = () => { el.removeEventListener('pointermove', move); el.removeEventListener('pointerup', up); };
    el.addEventListener('pointermove', move);
    el.addEventListener('pointerup', up);
  };
  return (
    <div className={`resizer at-${edge}`} role="separator" aria-orientation="vertical" aria-label={label}
         title="Drag to resize; double-click to reset" onPointerDown={down} onDoubleClick={() => setWidth(initial)} />
  );
}
