// The port draws what tools/sld.py draws: each saved document (o-mcp/subgraph v1, from dev, as of
// 2026-10-21) is rendered by both, as drawn by default and without the legend but with value rows, and
// the SVGs must be the same text and the value rows' anchors the same. Needs uv, as the repository's
// Python does.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { Subgraph } from '../types/formats/subgraph';
import { draw, g, render, withFigures } from './sld';

const ROOT = resolve(__dirname, '../../..');
const FIXTURES = join(__dirname, 'sld-fixtures');

function hasUv() {
  try {
    execFileSync('uv', ['--version']);
    return true;
  } catch {
    return false;
  }
}

describe('g, as Python formats with :g', () => {
  it('drops trailing zeros and keeps six significant digits', () => {
    expect([160, 0.4, 20, 39.099999999999994, 1234567, 0.00001, -2.5, 0].map(g))
      .toEqual(['160', '0.4', '20', '39.1', '1.23457e+06', '1e-05', '-2.5', '0']);
  });
});

describe.skipIf(!hasUv())('render, against tools/sld.py', () => {
  const out = mkdtempSync(join(tmpdir(), 'sld-'));
  for (const f of readdirSync(FIXTURES).filter((f) => f.endsWith('.json'))) {
    it(f, () => {
      const svg = join(out, f.replace('.json', '.svg'));
      execFileSync('uv', ['run', '--no-project', 'python', join(ROOT, 'tools/sld.py'), '--json', join(FIXTURES, f), '-o', svg]);
      const doc = JSON.parse(readFileSync(join(FIXTURES, f), 'utf8')) as Subgraph;
      expect(render(doc)).toBe(readFileSync(svg, 'utf8'));
    });
    it(`${f}, without the legend, with value rows and their anchors`, () => {
      const svg = join(out, f.replace('.json', '.rows.svg'));
      const anchors = join(out, f.replace('.json', '.anchors.json'));
      execFileSync('uv', ['run', '--no-project', 'python', join(ROOT, 'tools/sld.py'), '--json', join(FIXTURES, f), '-o', svg,
        '--no-legend', '--rows', '2', '--feeder-rows', '1', '--anchors', anchors]);
      const doc = JSON.parse(readFileSync(join(FIXTURES, f), 'utf8')) as Subgraph;
      const d = draw(doc, { legend: false, rows: 2, feederRows: 1 });
      expect(d.svg).toBe(readFileSync(svg, 'utf8'));
      expect(d.anchors).toEqual(JSON.parse(readFileSync(anchors, 'utf8')));
      expect(d.anchors.length).toBeGreaterThan(0);
    });
  }
});

describe('withFigures', () => {
  it('writes each figure and the caption into the drawing, escaped, inside its frame', () => {
    const doc = JSON.parse(readFileSync(join(FIXTURES, 'GAS_ENGINE_d1.json'), 'utf8')) as Subgraph;
    const d = draw(doc, { legend: true, rows: 1 });
    const a = d.anchors[0];
    const out = withFigures(d.svg, [{ x: a.x, y: a.y, anchor: a.anchor, text: '1,234 kWh', title: 'A & B', kind: 'measured' }],
      'As of 2026-10-21 <x>');
    expect(out.startsWith(d.svg.slice(0, -'</svg>'.length))).toBe(true);
    expect(out.endsWith('</svg>')).toBe(true);
    expect(out).toContain(`<text x="${g(a.x)}" y="${g(a.y)}" font-size="11" text-anchor="${a.anchor}" fill="#1f2937" font-weight="bold"`);
    expect(out).toContain('<title>A &amp; B</title>1,234 kWh</text>');
    expect(out).toContain(`y="${g(d.height - 9)}"`);
    expect(out).toContain('As of 2026-10-21 &lt;x&gt;</text>');
  });

  it('finds the figures where the widget, drawn without the legend, put them', () => {
    for (const f of readdirSync(FIXTURES).filter((f) => f.endsWith('.json'))) {
      const doc = JSON.parse(readFileSync(join(FIXTURES, f), 'utf8')) as Subgraph;
      const opts = { rows: 2, feederRows: 1 };
      expect(draw(doc, { ...opts, legend: true }).anchors).toEqual(draw(doc, { ...opts, legend: false }).anchors);
    }
  });
});
