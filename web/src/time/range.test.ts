import { describe, expect, it } from 'vitest';
import { isValid, resolveInstant, resolveRange, siteNow } from './range';

// Wednesday 2026-10-21 14:37:20 site time, as a site date (UTC fields hold the wall clock)
const NOW = new Date(Date.UTC(2026, 9, 21, 14, 37, 20));
const at = (s: string, edge: 'from' | 'to' = 'from') => resolveInstant(s, edge, NOW).toISOString().slice(0, 16);

describe('relative instants', () => {
  it('truncates now to the minute', () => expect(at('now')).toBe('2026-10-21T14:37'));
  it('goes back by minutes, hours, days, weeks', () => {
    expect(at('now-30m')).toBe('2026-10-21T14:07');
    expect(at('now-24h')).toBe('2026-10-20T14:37');
    expect(at('now-7d')).toBe('2026-10-14T14:37');
    expect(at('now-2w')).toBe('2026-10-07T14:37');
  });
  it('rounds to the start of the unit, or as `to` to its end', () => {
    expect(at('now/d')).toBe('2026-10-21T00:00');
    expect(at('now/d', 'to')).toBe('2026-10-22T00:00');
    expect(at('now-1d/d')).toBe('2026-10-20T00:00');
    expect(at('now-1d/d', 'to')).toBe('2026-10-21T00:00');
  });
  it('starts weeks on Monday', () => {
    expect(at('now/w')).toBe('2026-10-19T00:00');
    expect(at('now/w', 'to')).toBe('2026-10-26T00:00');
  });
  it('takes months and years whole, across a year end', () => {
    expect(at('now/M')).toBe('2026-10-01T00:00');
    expect(at('now/M', 'to')).toBe('2026-11-01T00:00');
    expect(at('now-1M/M')).toBe('2026-09-01T00:00');
    expect(at('now/y', 'to')).toBe('2027-01-01T00:00');
    const dec = new Date(Date.UTC(2026, 11, 31, 23, 0));
    expect(resolveInstant('now/M', 'to', dec).toISOString().slice(0, 10)).toBe('2027-01-01');
  });
});

describe('absolute instants', () => {
  it('reads a date as its midnight and a minute as is, whichever end', () => {
    expect(at('2026-09-01')).toBe('2026-09-01T00:00');
    expect(at('2026-10-01', 'to')).toBe('2026-10-01T00:00');
    expect(at('2026-10-21T10:15', 'to')).toBe('2026-10-21T10:15');
  });
  it('accepts only what the dashboard format allows', () => {
    for (const s of ['now', 'now-6h', 'now/d', 'now-1M/M', '2026-10-21', '2026-10-21T10:15']) expect(isValid(s)).toBe(true);
    for (const s of ['yesterday', 'now+1d', 'now/h', '2026-10-21 10:15', '21/10/2026', '']) expect(isValid(s)).toBe(false);
  });
});

describe('ranges', () => {
  it('takes the last day before the end as as_of, so a range ending at midnight is drawn on its last day', () => {
    const t = new Date(Date.UTC(2026, 9, 21, 7, 37));          // 14:37 in Jakarta
    expect(resolveRange({ from: 'now-1d/d', to: 'now-1d/d' }, 'Asia/Jakarta', t))
      .toEqual({ start: '2026-10-20T00:00', end: '2026-10-21T00:00', asOf: '2026-10-20' });
    expect(resolveRange({ from: 'now-6h', to: 'now' }, 'Asia/Jakarta', t))
      .toEqual({ start: '2026-10-21T08:37', end: '2026-10-21T14:37', asOf: '2026-10-21' });
  });
  it('reads the wall clock in the site zone, not the browser\'s', () => {
    const t = new Date(Date.UTC(2026, 9, 21, 20, 0));          // 03:00 the next day in Jakarta
    expect(siteNow('Asia/Jakarta', t).toISOString().slice(0, 16)).toBe('2026-10-22T03:00');
    expect(siteNow('Europe/London', t).toISOString().slice(0, 16)).toBe('2026-10-21T21:00');
  });
});
