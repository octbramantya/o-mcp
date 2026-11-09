// The open dashboard: its document as edited, whether that differs from the saved one, the refresh
// tick that relative ranges are resolved at, and the ranges a zoom on a chart came from (decision 32).
// One dashboard is open at a time.
import { create } from 'zustand';
import type { DashboardFull } from '../api/types';
import type { ChannelId, Dashboard, Entity, Widget } from './document';
import type { TimeRange } from '../time/range';
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
  /** Counts forced refreshes (the Refresh button), which no widget may skip. */
  forced: number;
  /** The ranges zooms came from, the latest last: ↶ steps back through them. For this visit only. */
  zoomedFrom: TimeRange[];
  open: (d: DashboardFull) => void;
  saved: (d: DashboardFull) => void;
  close: () => void;
  setEditing: (on: boolean) => void;
  setTitle: (t: string) => void;
  change: (f: (d: Dashboard) => Dashboard) => void;
  /** The range from the time picker: a range chosen there forgets the zooms. */
  setTime: (t: TimeRange) => void;
  /** The range dragged on a chart, remembering the one it replaces. */
  zoom: (t: TimeRange) => void;
  /** Back to the range before the last zoom. */
  unzoom: () => void;
  /** A channel's entity changes while viewing too: it is what the user looks at, saved with the rest. */
  setChannel: (c: ChannelId, e: Entity | undefined) => void;
  addWidget: (type: string, w: number, h: number, settings: object) => void;
  updateWidget: (id: string, patch: Partial<Widget>) => void;
  removeWidget: (id: string) => void;
  refresh: (force?: boolean) => void;
}

export const useDashboard = create<State>((set) => ({
  id: null, title: '', updatedAt: '', readOnly: false, owner: null, doc: null, dirty: false, editing: false,
  tick: Date.now(), forced: 0, zoomedFrom: [],
  open: (d) => set({
    id: d.id, title: d.title, updatedAt: d.updated_at, readOnly: d.read_only, owner: d.owner,
    doc: migrate(d.document, d.format_version), dirty: false, editing: false, tick: Date.now(), zoomedFrom: [],
  }),
  saved: (d) => set({ title: d.title, updatedAt: d.updated_at, dirty: false }),
  close: () => set({ id: null, doc: null, dirty: false, editing: false, zoomedFrom: [] }),
  setEditing: (on) => set({ editing: on }),
  setTitle: (t) => set({ title: t, dirty: true }),
  // a read-only dashboard can still be looked at another way (range, refresh), but is never saved
  change: (f) => set((s) => (s.doc ? { doc: f(s.doc), dirty: !s.readOnly } : {})),
  setTime: (time) => set((s) => (s.doc ? { doc: { ...s.doc, time }, dirty: !s.readOnly, zoomedFrom: [] } : {})),
  zoom: (time) => set((s) => (s.doc ? {
    doc: { ...s.doc, time }, dirty: !s.readOnly, zoomedFrom: [...s.zoomedFrom, s.doc.time],
  } : {})),
  unzoom: () => set((s) => (s.doc && s.zoomedFrom.length ? {
    doc: { ...s.doc, time: s.zoomedFrom[s.zoomedFrom.length - 1] }, dirty: !s.readOnly, zoomedFrom: s.zoomedFrom.slice(0, -1),
  } : {})),
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
  refresh: (force) => set((s) => ({ tick: Date.now(), forced: s.forced + (force ? 1 : 0) })),
}));
