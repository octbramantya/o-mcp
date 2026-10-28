import { describe, expect, it } from 'vitest';
import type { Readings } from '../types/formats/readings';
import type { Line } from './chart';
import { layout, panelBox, panelTip, ratio, sumPerInterval, timeOption, unitOf } from './chart';
import { nodeLines } from './Compare';

const window = { start: '2026-10-28T00:00:00+07:00', end: '2026-10-28T06:00:00+07:00' };
const colors = { text: '#000', muted: '#888' };
const line = (name: string, unit: string, bar = false): Line => ({ name, unit, bar, data: [[window.start, 1]] });

type Series = Readings['series'][number];
function series(device: string, quantity: string, reading: 'COUNTER' | 'SAMPLE', values: [string, number][]): Series {
  return {
    device_id: device.length, device, device_name: null, quantity, unit: null, reading, decoded: false,
    points: values.map(([start, v]) => ({
      start, consumption: reading === 'COUNTER' ? v : null, mean: reading === 'SAMPLE' ? v : null,
      min: null, max: null, p95: null, samples: 1, rejected: 0,
    })),
  };
}
function readings(quantities: string[], s: Series[]): Readings {
  return {
    schema: 'o-mcp/readings', version: 1,
    query: { tenant: 3, node: 'N', node_id: 1, as_of: '2026-10-28', interval: '15min', window, quantities, device: null },
    series: s, findings: [],
  };
}

describe('layout', () => {
  it('draws one unit on one axis, two on a dual axis, three or more in panels', () => {
    expect(layout(1, 'auto')).toBe('single');
    expect(layout(2, 'auto')).toBe('dual');
    expect(layout(3, 'auto')).toBe('panels');
  });
  it('draws panels from two units when asked', () => {
    expect(layout(1, 'panels')).toBe('single');
    expect(layout(2, 'panels')).toBe('panels');
  });
});

describe('unitOf', () => {
  it('gives decoded power factor and unitless quantities a unit of their own', () => {
    expect(unitOf({ unit: 'V', decoded: false })).toBe('V');
    expect(unitOf({ unit: null, decoded: true })).toBe('0..1');
    expect(unitOf({ unit: null, decoded: false })).toBe('no unit');
  });
});

describe('timeOption', () => {
  it('puts the second unit on the right and says so in the legend', () => {
    const o = timeOption([line('a V', 'V'), line('a I', 'A')], 'auto', window, colors);
    expect((o.yAxis as unknown as { position: string; name: string }[]).map((y) => [y.position, y.name])).toEqual([['left', 'V'], ['right', 'A']]);
    expect(o.series.map((s) => [s.name, s.yAxisIndex])).toEqual([['a V', 0], ['a I (right)', 1]]);
  });
  it('gives each of three units a panel, lines of one unit sharing it, on one time span', () => {
    const o = timeOption([line('V1', 'V'), line('I', 'A'), line('V2', 'V'), line('THD', '%')], 'auto', window, colors);
    expect((o.grid as unknown[]).length).toBe(3);
    expect(o.series.map((s) => s.yAxisIndex)).toEqual([0, 1, 0, 2]);
    const xs = o.xAxis as { min: number; max: number; axisLabel: { show: boolean } }[];
    expect(new Set(xs.map((x) => `${x.min}-${x.max}`)).size).toBe(1);
    expect(xs.map((x) => x.axisLabel.show)).toEqual([false, false, true]);
  });
  it('starts a counter\'s axis at zero and fits a sampled one', () => {
    const o = timeOption([line('E', 'kWh', true), line('V', 'V')], 'auto', window, colors);
    expect((o.yAxis as { scale: boolean }[]).map((y) => y.scale)).toEqual([false, true]);
  });
});

describe('panelBox', () => {
  it('fits the panels between the legend and the time labels without overlap', () => {
    const boxes = [0, 1, 2].map((i) => panelBox(i, 3));
    for (let i = 1; i < 3; i++) expect(boxes[i].top).toBeGreaterThan(boxes[i - 1].top + boxes[i - 1].height);
    expect(boxes[2].top + boxes[2].height).toBeLessThanOrEqual(100);
  });
});

describe('per-interval sums', () => {
  const t1 = '2026-10-28T00:00:00+07:00';
  const t2 = '2026-10-28T00:15:00+07:00';
  it('adds a counter over the node\'s meters', () => {
    const r = readings(['E'], [series('M1', 'E', 'COUNTER', [[t1, 1], [t2, 2]]), series('M2', 'E', 'COUNTER', [[t2, 3]])]);
    expect(sumPerInterval(r, 'E')).toEqual([[t1, 1], [t2, 5]]);
  });
  it('works out P / sqrt(P² + Q²) on the sums', () => {
    const r = readings(['P', 'Q'], [series('M1', 'P', 'COUNTER', [[t1, 3]]), series('M1', 'Q', 'COUNTER', [[t1, 4]])]);
    expect(ratio(r, ['P', 'Q'])).toEqual([[t1, 0.6]]);
  });
});

describe('nodeLines', () => {
  const t = '2026-10-28T00:00:00+07:00';
  it('draws a counter as one line per node, from zero', () => {
    const r = readings(['E'], [series('M1', 'E', 'COUNTER', [[t, 1]]), series('M2', 'E', 'COUNTER', [[t, 2]])]);
    expect(nodeLines('LVMDB_A1', r, { counter: true, from: null, unit: 'kWh' }))
      .toEqual([{ name: 'LVMDB_A1', unit: 'kWh', bar: false, zero: true, data: [[t, 3]] }]);
  });
  it('draws a sampled quantity per meter, naming the meter only where there are several', () => {
    const one = readings(['V'], [series('M1', 'V', 'SAMPLE', [[t, 230]])]);
    expect(nodeLines('A', one, { counter: false, from: null, unit: 'V' }).map((l) => l.name)).toEqual(['A']);
    const two = readings(['V'], [series('M1', 'V', 'SAMPLE', [[t, 230]]), series('M2', 'V', 'SAMPLE', [[t, 231]])]);
    expect(nodeLines('A', two, { counter: false, from: null, unit: 'V' }).map((l) => l.name)).toEqual(['A M1', 'A M2']);
  });
});

describe('panelTip', () => {
  it('lists every panel\'s series once, under one time, in the legend\'s order', () => {
    const p = (i: number, name: string, v: number) => ({ seriesIndex: i, seriesName: name, marker: '', axisValueLabel: 'T', value: [window.start, v] as [string, number] });
    const html = panelTip([p(1, 'P', 2), p(0, 'I <A>', 1000)]);
    expect(html.match(/T/g)?.length).toBe(1);
    expect(html.indexOf('I &#60;A&#62;')).toBeLessThan(html.indexOf('P'));
    expect(html).toContain('1,000.00');
  });
});
