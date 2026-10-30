// The side bar's state (design/frontend.md §5): which view the Activity Bar shows, whether it is open,
// its width, and the Reference view's history. The first three are remembered per browser, a
// convenience, so storage may fail; the history lasts the session and is dropped on a site switch.
import { create } from 'zustand';
import type { ChannelId } from '../dashboards/document';

export type ViewId = 'find' | 'categories' | 'starred' | 'reference';

/** What the Reference view shows: a node by graph.node.id, a device by its id, a quantity by its id. */
export type Ref = { kind: 'node' | 'device' | 'quantity'; id: number };

export const WIDTH = { min: 200, max: 640, initial: 300 };
const KEY = 'o-mcp.side-bar';

interface Stored { view: ViewId; open: boolean; width: number }

function load(): Stored {
  const d: Stored = { view: 'find', open: true, width: WIDTH.initial };
  try {
    const s = JSON.parse(localStorage.getItem(KEY) ?? '{}');
    return {
      view: ['find', 'categories', 'starred', 'reference'].includes(s.view) ? s.view : d.view,
      // on a phone the bar lies over the page, so each visit starts with it closed
      open: (typeof s.open === 'boolean' ? s.open : d.open) && window.innerWidth >= 768,
      width: typeof s.width === 'number' ? clamp(s.width) : d.width,
    };
  } catch {
    return d;
  }
}

function keep(s: Stored) {
  try { localStorage.setItem(KEY, JSON.stringify(s)); } catch { /* not remembered */ }
}

export function clamp(w: number) {
  const max = Math.min(WIDTH.max, Math.max(WIDTH.min, Math.round(window.innerWidth / 2)));
  return Math.round(Math.min(max, Math.max(WIDTH.min, w)));
}

interface SideBar extends Stored {
  /** The channel Find, Categories and Starred fill on a dashboard; not saved with it. */
  channel: ChannelId;
  setChannel: (c: ChannelId) => void;
  tenant: number | null;
  history: Ref[];
  at: number;
  /** Opens a view; on the view already open, closes the side bar, as an Activity Bar does. */
  press: (v: ViewId) => void;
  setWidth: (w: number) => void;
  /** Opens the Reference view on r, after the entry shown now; the entries ahead of it are dropped. */
  inspect: (r: Ref) => void;
  go: (step: -1 | 1) => void;
  /** Drops the history when the site changes: its ids are another site's. */
  forTenant: (t: number) => void;
}

const stored = load();

export const useSideBar = create<SideBar>((set, get) => ({
  ...stored,
  channel: 'A', setChannel: (channel) => set({ channel }),
  tenant: null, history: [], at: -1,
  press: (v) => {
    const s = get();
    const next = { view: v, open: !(s.open && s.view === v), width: s.width };
    keep(next);
    set(next);
  },
  setWidth: (w) => {
    const s = get();
    const width = clamp(w);
    keep({ view: s.view, open: s.open, width });
    set({ width });
  },
  inspect: (r) => {
    const s = get();
    const cur = s.history[s.at];
    const history = cur && cur.kind === r.kind && cur.id === r.id ? s.history : [...s.history.slice(0, s.at + 1), r];
    keep({ view: 'reference', open: true, width: s.width });
    set({ view: 'reference', open: true, history, at: history.length - 1 });
  },
  go: (step) => set((s) => ({ at: Math.min(s.history.length - 1, Math.max(0, s.at + step)) })),
  forTenant: (t) => { if (get().tenant !== t) set({ tenant: t, history: [], at: -1 }); },
}));
