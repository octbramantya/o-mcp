// The open dashboard: its document as edited, whether that differs from the saved one, and the
// refresh tick that relative ranges are resolved at. One dashboard is open at a time.
import { create } from 'zustand';
import type { DashboardFull } from '../api/types';
import type { ChannelId, Dashboard, Entity, Widget } from './document';
import { migrate, newId, nextRow } from './document';

interface State {
  id: number | null;
  title: string;
  updatedAt: string;
  readOnly: boolean;
  owner: DashboardFull['owner'] | null;
  doc: Dashboard | null;
  dirty: boolean;
  editing: boolean;
  /** When the range was last resolved: relative ranges move on with it. */
  tick: number;
  open: (d: DashboardFull) => void;
  saved: (d: DashboardFull) => void;
  close: () => void;
  setEditing: (on: boolean) => void;
  setTitle: (t: string) => void;
  change: (f: (d: Dashboard) => Dashboard) => void;
  /** A channel's entity changes while viewing too: it is what the user looks at, saved with the rest. */
  setChannel: (c: ChannelId, e: Entity | undefined) => void;
  addWidget: (type: string, w: number, h: number, settings: object) => void;
  updateWidget: (id: string, patch: Partial<Widget>) => void;
  removeWidget: (id: string) => void;
  refresh: () => void;
}

export const useDashboard = create<State>((set) => ({
  id: null, title: '', updatedAt: '', readOnly: false, owner: null, doc: null, dirty: false, editing: false,
  tick: Date.now(),
  open: (d) => set({
    id: d.id, title: d.title, updatedAt: d.updated_at, readOnly: d.read_only, owner: d.owner,
    doc: migrate(d.document, d.format_version), dirty: false, editing: false, tick: Date.now(),
  }),
  saved: (d) => set({ title: d.title, updatedAt: d.updated_at, dirty: false }),
  close: () => set({ id: null, doc: null, dirty: false, editing: false }),
  setEditing: (on) => set({ editing: on }),
  setTitle: (t) => set({ title: t, dirty: true }),
  // a read-only dashboard can still be looked at another way (range, refresh), but is never saved
  change: (f) => set((s) => (s.doc ? { doc: f(s.doc), dirty: !s.readOnly } : {})),
  setChannel: (c, e) => set((s) => {
    if (!s.doc) return {};
    const channels = { ...s.doc.channels };
    if (e) channels[c] = e; else delete channels[c];
    return { doc: { ...s.doc, channels }, dirty: !s.readOnly };
  }),
  addWidget: (type, w, h, settings) => set((s) => s.doc ? {
    dirty: true,
    doc: { ...s.doc, widgets: [...s.doc.widgets, { id: newId(), type, title: null, x: 0, y: nextRow(s.doc), w, h, channel: null, settings }] },
  } : {}),
  updateWidget: (id, patch) => set((s) => s.doc ? {
    dirty: true, doc: { ...s.doc, widgets: s.doc.widgets.map((w) => (w.id === id ? { ...w, ...patch } : w)) },
  } : {}),
  removeWidget: (id) => set((s) => s.doc ? {
    dirty: true, doc: { ...s.doc, widgets: s.doc.widgets.filter((w) => w.id !== id) },
  } : {}),
  refresh: () => set({ tick: Date.now() }),
}));
