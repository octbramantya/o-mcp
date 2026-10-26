// The dashboard's time range (design/frontend.md §3), resolved in the tenant's time zone. The API
// takes and returns site time without an offset, so this works on site wall-clock time: a "site
// date" is a Date whose UTC fields hold the wall clock in the tenant's zone. Windows are half-open.
import type { Dashboard } from '../types/formats/dashboard';

export type TimeRange = Dashboard['time'];

const RELATIVE = /^now(?:-(\d{1,4})([mhdwMy]))?(?:\/([dwMy]))?$/;
const ABSOLUTE = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?$/;

export const PRESETS: { label: string; from: string; to: string }[] = [
  { label: 'Last 30 minutes', from: 'now-30m', to: 'now' },
  { label: 'Last 1 hour', from: 'now-1h', to: 'now' },
  { label: 'Last 6 hours', from: 'now-6h', to: 'now' },
  { label: 'Last 24 hours', from: 'now-24h', to: 'now' },
  { label: 'Last 7 days', from: 'now-7d', to: 'now' },
  { label: 'Last 30 days', from: 'now-30d', to: 'now' },
  { label: 'Today so far', from: 'now/d', to: 'now' },
  { label: 'Today', from: 'now/d', to: 'now/d' },
  { label: 'Yesterday', from: 'now-1d/d', to: 'now-1d/d' },
  { label: 'This week', from: 'now/w', to: 'now/w' },
  { label: 'This month', from: 'now/M', to: 'now/M' },
  { label: 'Last month', from: 'now-1M/M', to: 'now-1M/M' },
];

export function siteNow(tz: string, now: Date = new Date()): Date {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
  }).formatToParts(now);
  const n = (t: string) => Number(parts.find((p) => p.type === t)?.value);
  return new Date(Date.UTC(n('year'), n('month') - 1, n('day'), n('hour'), n('minute'), n('second')));
}

function shift(d: Date, n: number, unit: string): Date {
  const r = new Date(d);
  switch (unit) {
    case 'm': r.setUTCMinutes(r.getUTCMinutes() + n); break;
    case 'h': r.setUTCHours(r.getUTCHours() + n); break;
    case 'd': r.setUTCDate(r.getUTCDate() + n); break;
    case 'w': r.setUTCDate(r.getUTCDate() + 7 * n); break;
    case 'M': r.setUTCMonth(r.getUTCMonth() + n); break;
    case 'y': r.setUTCFullYear(r.getUTCFullYear() + n); break;
  }
  return r;
}

function startOf(d: Date, unit: string): Date {
  const r = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  if (unit === 'w') r.setUTCDate(r.getUTCDate() - ((r.getUTCDay() + 6) % 7));   // weeks start on Monday
  if (unit === 'M') r.setUTCDate(1);
  if (unit === 'y') r.setUTCMonth(0, 1);
  return r;
}

export function isValid(s: string): boolean {
  return RELATIVE.test(s) || ABSOLUTE.test(s);
}

/** One end of the range as a site date. A rounded `to` is the end of its unit, so now/d to now/d is today. */
export function resolveInstant(s: string, edge: 'from' | 'to', now: Date): Date {
  const a = ABSOLUTE.exec(s);
  if (a) return new Date(Date.UTC(+a[1], +a[2] - 1, +a[3], +(a[4] ?? 0), +(a[5] ?? 0)));
  const r = RELATIVE.exec(s);
  if (!r) throw new Error(`Not a time: ${s}`);
  let d = new Date(Math.floor(now.getTime() / 60000) * 60000);
  if (r[1]) d = shift(d, -Number(r[1]), r[2]);
  if (r[3]) {
    d = startOf(d, r[3]);
    if (edge === 'to') d = shift(d, 1, r[3]);
  }
  return d;
}

/** A site date as the API takes it: YYYY-MM-DDTHH:MM, no offset. */
export function param(d: Date): string {
  return d.toISOString().slice(0, 16);
}

export interface Window {
  start: string;
  end: string;
  /** The range's last day, YYYY-MM-DD: topology is drawn on it (decision 20, A). */
  asOf: string;
}

export function resolveRange(t: TimeRange, tz: string, at: Date = new Date()): Window {
  const now = siteNow(tz, at);
  const start = resolveInstant(t.from, 'from', now);
  const end = resolveInstant(t.to, 'to', now);
  return { start: param(start), end: param(end), asOf: new Date(end.getTime() - 60000).toISOString().slice(0, 10) };
}

export function describe(t: TimeRange): string {
  const p = PRESETS.find((x) => x.from === t.from && x.to === t.to);
  return p ? p.label : `${t.from.replace('T', ' ')} to ${t.to.replace('T', ' ')}`;
}

/** An API time (site time with offset, or without) for people: 21 Oct 2026 14:00. */
export function show(s: string | null | undefined): string {
  if (!s) return '—';
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}))?/.exec(s);
  if (!m) return s;
  const month = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][+m[2] - 1];
  return `${+m[3]} ${month} ${m[1]}${m[4] ? ` ${m[4]}:${m[5]}` : ''}`;
}

/** A moment with its own offset (a save time) as site time for people. */
export function stamp(iso: string, tz: string): string {
  return new Date(iso).toLocaleString('en-GB', { timeZone: tz, day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}
