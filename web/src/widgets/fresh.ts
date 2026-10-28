// A widget's window, held across refresh ticks while its data can't have changed (design/frontend.md
// §6). Each plant answer says when its data can next move (X-Fresh-Until); until then a tick that only
// moves a relative range on keeps the widget's last window, so its query keys stay and nothing is
// asked. A new range, a forced refresh, other settings, or an answer that doesn't say all take the
// new window at once.
import { useRef } from 'react';
import { freshUntil } from '../api/client';
import type { View } from './contract';

export interface Held {
  view: View;
  deps: string;
  /** When the held answers can first change; null when unknown, which holds nothing. */
  until: number | null;
}

export function hold(prev: Held | null, view: View, deps: string, now: number): Held {
  if (prev && prev.view === view && prev.deps === deps) return prev;
  const keep = prev !== null && prev.until !== null && now < prev.until && prev.deps === deps
    && prev.view.range === view.range && prev.view.forced === view.forced
    && prev.view.tenant === view.tenant && prev.view.tz === view.tz;
  return keep ? prev : { view, deps, until: null };
}

/** The earliest time any of the answers can change; null if one doesn't say. Answers not there yet
 * (a query not enabled) don't count. */
export function earliest(answers: unknown[]): number | null {
  const got = answers.filter((a) => a !== undefined && a !== null).map(freshUntil);
  return got.length && got.every((u) => u !== null) ? Math.min(...(got as number[])) : null;
}

/** The view a widget's tick-bound queries use, and `track`, called with those queries' answers after
 * them in the same render. deps: whatever else the queries depend on (settings, the node). */
export function useHeldView(view: View, deps: unknown): [View, (...answers: unknown[]) => void] {
  const ref = useRef<Held | null>(null);
  const held = hold(ref.current, view, JSON.stringify(deps), Date.now());
  ref.current = held;
  const track = (...answers: unknown[]) => { held.until = earliest(answers); };
  return [held.view, track];
}
