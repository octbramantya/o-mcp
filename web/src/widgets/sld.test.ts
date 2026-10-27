// The port draws what tools/sld.py draws: each saved document (o-mcp/subgraph v1, from dev, as of
// 2026-10-21) is rendered by both, and the SVGs must be the same text. Needs uv, as the repository's
// Python does.
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type { Subgraph } from '../types/formats/subgraph';
import { g, render } from './sld';

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
  }
});
