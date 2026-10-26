// The dashboard document, o-mcp/dashboard v1 (design/dashboard-v1.schema.json). The API checks every
// save against the schema; a later version is migrated here, when read.
import type { Dashboard, Entity } from '../types/formats/dashboard';

export type { Dashboard, Entity };
export type Widget = Dashboard['widgets'][number];
export type ChannelId = 'A' | 'B' | 'C' | 'D';

export const FORMAT_VERSION = 1;
export const CHANNELS: { id: ChannelId; color: string }[] = [
  { id: 'A', color: '#e8a33d' },
  { id: 'B', color: '#4f9ee8' },
  { id: 'C', color: '#5fbf77' },
  { id: 'D', color: '#c86fd6' },
];
export const COLUMNS = 24;
export const ROW_HEIGHT = 30;

export function blank(): Dashboard {
  return { time: { from: 'now-24h', to: 'now' }, refresh: null, channels: {}, widgets: [] };
}

/** A stored document as the current version. Version 1 is the only one so far. */
export function migrate(doc: unknown, version: number): Dashboard {
  if (version !== FORMAT_VERSION) throw new Error(`This dashboard is format ${version}; this frontend reads ${FORMAT_VERSION}.`);
  return doc as Dashboard;
}

export function newId(): string {
  return crypto.randomUUID().slice(0, 8);
}

/** Below every widget, so adding never moves one. */
export function nextRow(doc: Dashboard): number {
  return doc.widgets.reduce((y, w) => Math.max(y, w.y + w.h), 0);
}
