// The time charts of Readings and Compare (design/frontend.md §5, "Readings' units"): every unit on a
// scale of its own, one axis for one unit, a dual axis for two, and from three one panel per unit on one
// shared time axis. Also the per-interval sums Stat and Compare draw from a readings answer.
import type { Readings } from '../types/formats/readings';
import { fmt } from './common';

export type Point = [string, number];

/** One line (or a counter's bars) of a time chart. */
export interface Line {
  name: string;
  /** The axis it reads on: lines with the same key share one (unitOf). */
  unit: string;
  bar: boolean;
  /** Its axis starts at zero, as a counter's does, drawn as bars or not. */
  zero?: boolean;
  data: Point[];
}

export type Axes = 'auto' | 'panels';
export type Layout = 'single' | 'dual' | 'panels';

/** The scale a series reads on: its unit; a decoded power factor (0..1, no unit) is a unit of its own. */
export function unitOf(s: { unit: string | null; decoded: boolean }): string {
  return s.decoded ? '0..1' : s.unit ?? 'no unit';
}

/** The units in the order their first line comes, which is the order they were picked in. */
export function units(lines: Line[]): string[] {
  return [...new Set(lines.map((l) => l.unit))];
}

export function layout(n: number, axes: Axes): Layout {
  if (n <= 1) return 'single';
  return n === 2 && axes === 'auto' ? 'dual' : 'panels';
}

const sorted = (m: Map<string, number>): Point[] => [...m].sort(([a], [b]) => (a < b ? -1 : 1));

/** A counter's consumption per interval added up over every series of `quantity` (each a meter). */
export function sumPerInterval(r: Readings, quantity: string): Point[] {
  const sum = new Map<string, number>();
  for (const s of r.series) {
    if (s.quantity !== quantity) continue;
    for (const p of s.points) sum.set(p.start, (sum.get(p.start) ?? 0) + (p.consumption ?? 0));
  }
  return sorted(sum);
}

/** P / sqrt(P² + Q²) per interval, P and Q each added up over the node's meters, as PF_TRUE is
 * worked out over the range (graph.derived_quantity); no point where both are zero. */
export function ratio(r: Readings, [p, q]: string[]): Point[] {
  const sum = new Map<string, [number, number]>();
  for (const s of r.series) {
    if (s.quantity !== p && s.quantity !== q) continue;
    for (const x of s.points) {
      const pq = sum.get(x.start) ?? [0, 0];
      pq[s.quantity === p ? 0 : 1] += x.consumption ?? 0;
      sum.set(x.start, pq);
    }
  }
  return [...sum].filter(([, [a, b]]) => a || b).map(([t, [a, b]]): Point => [t, a / Math.hypot(a, b)])
    .sort(([a], [b]) => (a < b ? -1 : 1));
}

/** A sampled series' means as points, intervals without one left out. */
export function means(s: Readings['series'][number]): Point[] {
  return s.points.filter((p) => p.mean !== null).map((p) => [p.start, p.mean as number]);
}

// Panels share the box between a legend on top and the time labels under the last; percentages,
// since the option is made before the chart knows its height.
const TOP = 12;
const BOTTOM = 8;
const GAP = 4;

/** Where panel i of n sits, in percent of the chart's height. */
export function panelBox(i: number, n: number): { top: number; height: number } {
  const height = (100 - TOP - BOTTOM - GAP * (n - 1)) / n;
  return { top: TOP + i * (height + GAP), height };
}

interface TipParam { seriesIndex: number; seriesName: string; marker: string; axisValueLabel: string; value: [string, number] }

const esc = (t: string) => t.replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`);

/** A panel chart's tooltip: the time once, then every series at it in the legend's order. */
export function panelTip(params: TipParam | TipParam[]): string {
  const ps = (Array.isArray(params) ? params : [params]).slice().sort((a, b) => a.seriesIndex - b.seriesIndex);
  if (!ps.length) return '';
  const rows = ps.map((p) => `<div style="display:flex;gap:16px;justify-content:space-between">`
    + `<span>${p.marker}${esc(p.seriesName)}</span><b>${fmt(p.value?.[1] ?? null)}</b></div>`);
  return [`<div>${esc(ps[0].axisValueLabel)}</div>`, ...rows].join('');
}

/** The ECharts option for lines on their units' scales over the window, which every time axis spans so
 * panels line up. A counter's axis starts at zero; a sampled quantity's fits its data. */
export function timeOption(lines: Line[], axes: Axes, window: { start: string; end: string },
                           colors: { text: string; muted: string }) {
  const span = { min: Date.parse(window.start), max: Date.parse(window.end) };
  const us = units(lines);
  const mode = layout(us.length, axes);
  const zero = (u: string) => lines.some((l) => l.unit === u && (l.bar || l.zero));
  const yAxis = (u: string, i: number, extra: object) => ({
    type: 'value', scale: !zero(u), name: u, nameLocation: 'middle', nameGap: 44, nameRotate: 90,
    nameTextStyle: { color: colors.muted }, axisLabel: { color: colors.muted, hideOverlap: true },
    splitLine: { show: i === 0 || mode === 'panels', lineStyle: { opacity: 0.2 } }, ...extra,
  });
  const name = (l: Line) => (mode === 'dual' && l.unit === us[1] ? `${l.name} (right)` : l.name);
  const series = lines.map((l) => {
    const i = us.indexOf(l.unit);
    return {
      name: name(l), type: l.bar ? 'bar' : 'line', showSymbol: false, data: l.data,
      ...(mode === 'panels' ? { xAxisIndex: i, yAxisIndex: i } : { yAxisIndex: mode === 'dual' ? i : 0 }),
    };
  });
  const base = {
    backgroundColor: 'transparent',
    animation: false,
    tooltip: { trigger: 'axis', confine: true, valueFormatter: (v: unknown) => fmt(typeof v === 'number' ? v : null) },
    legend: { type: 'scroll', top: 0, textStyle: { color: colors.text } },
    series,
  };
  if (mode !== 'panels') {
    return {
      ...base,
      grid: { left: 64, right: mode === 'dual' ? 64 : 16, top: 30, bottom: 28 },
      xAxis: { type: 'time', ...span, axisLabel: { color: colors.muted } },
      yAxis: mode === 'dual'
        ? us.map((u, i) => yAxis(u, i, { position: i ? 'right' : 'left' }))
        : yAxis(us[0] ?? '', 0, {}),
    };
  }
  return {
    ...base,
    // one list in the order of the legend, not a block per panel each repeating the time
    tooltip: { ...base.tooltip, formatter: panelTip },
    axisPointer: { link: [{ xAxisIndex: 'all' }] },
    grid: us.map((_, i) => {
      const b = panelBox(i, us.length);
      return { left: 64, right: 16, top: `${b.top}%`, height: `${b.height}%` };
    }),
    xAxis: us.map((_, i) => ({
      type: 'time', gridIndex: i, ...span, axisLabel: { show: i === us.length - 1, color: colors.muted },
    })),
    yAxis: us.map((u, i) => yAxis(u, i, { gridIndex: i })),
  };
}
