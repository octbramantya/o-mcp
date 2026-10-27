import { describe, expect, it } from 'vitest';
import { blank } from './document';
import { parseImport } from './transfer';

const file = (over: object = {}) => JSON.stringify({
  kind: 'o-mcp/dashboard-export', tenant: 3, exported_at: '2026-10-27T00:00:00Z', title: ' Boilers ', format_version: 1, document: blank(), ...over,
});

describe('parseImport', () => {
  it('reads a file from this site', () => {
    expect(parseImport(file(), 3)).toEqual({ title: 'Boilers', document: blank() });
  });
  it('refuses another site, another kind, another format, and what isn\'t JSON', () => {
    expect(() => parseImport(file(), 4)).toThrow(/another site/);
    expect(() => parseImport(file({ kind: 'x' }), 3)).toThrow(/isn't a dashboard/);
    expect(() => parseImport(file({ format_version: 2 }), 3)).toThrow(/format 2/);
    expect(() => parseImport('{', 3)).toThrow(/isn't JSON/);
  });
});
