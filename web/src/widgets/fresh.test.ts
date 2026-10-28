import { describe, expect, it } from 'vitest';
import type { View } from './contract';
import { earliest, hold } from './fresh';

const view = (tick: number, over: Partial<View> = {}): View => ({
  start: `t${tick}`, end: `t${tick}`, asOf: '2026-10-28', tick, range: 'now-24h now', forced: 0,
  tz: 'Asia/Jakarta', tenant: 3, ...over,
});

describe('hold', () => {
  const first = hold(null, view(1), 'deps', 0);
  const fresh = { ...first, until: 1000 };

  it('takes the first view, and holds nothing while its answers say nothing', () => {
    expect(first.view.tick).toBe(1);
    expect(hold(first, view(2), 'deps', 10).view.tick).toBe(2);
  });

  it('keeps the window on a tick before the data can change, and moves on after', () => {
    expect(hold(fresh, view(2), 'deps', 999)).toBe(fresh);
    expect(hold(fresh, view(2), 'deps', 1000).view.tick).toBe(2);
  });

  it('never holds across a new range, a forced refresh, a tenant or new settings', () => {
    expect(hold(fresh, view(2, { range: 'now-7d now' }), 'deps', 10).view.tick).toBe(2);
    expect(hold(fresh, view(2, { forced: 1 }), 'deps', 10).view.tick).toBe(2);
    expect(hold(fresh, view(2, { tenant: 4 }), 'deps', 10).view.tick).toBe(2);
    expect(hold(fresh, view(2), 'other', 10).view.tick).toBe(2);
  });
});

describe('earliest', () => {
  it('is unknown when an answer there carries no time, and ignores answers not there', () => {
    expect(earliest([undefined])).toBeNull();
    expect(earliest([{}])).toBeNull();
  });
});
