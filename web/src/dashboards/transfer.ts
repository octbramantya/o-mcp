// A dashboard as a JSON file, to keep or to hand to someone in the same site: its title and its
// o-mcp/dashboard document, with the site it names nodes in. Node ids are a site's own, so a file
// is imported only into the site it came from. The API checks the document as on every save.
import type { Dashboard } from './document';
import { FORMAT_VERSION, migrate } from './document';

const KIND = 'o-mcp/dashboard-export';

export interface Exported {
  kind: typeof KIND;
  tenant: number;
  exported_at: string;
  title: string;
  format_version: number;
  document: Dashboard;
}

export function exportFile(title: string, doc: Dashboard, tenant: number) {
  const body: Exported = { kind: KIND, tenant, exported_at: new Date().toISOString(), title, format_version: FORMAT_VERSION, document: doc };
  const url = URL.createObjectURL(new Blob([JSON.stringify(body, null, 1) + '\n'], { type: 'application/json' }));
  const a = document.createElement('a');
  a.href = url;
  a.download = `${title.replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '').toLowerCase() || 'dashboard'}.json`;
  a.click();
  URL.revokeObjectURL(url);
}

/** A file's title and document for this site, or an Error that says what is wrong with it. */
export function parseImport(text: string, tenant: number): { title: string; document: Dashboard } {
  let f: Partial<Exported>;
  try {
    f = JSON.parse(text);
  } catch {
    throw new Error('The file isn\'t JSON.');
  }
  if (!f || f.kind !== KIND || typeof f.format_version !== 'number' || typeof f.document !== 'object') {
    throw new Error('The file isn\'t a dashboard exported from here.');
  }
  if (f.tenant !== tenant) throw new Error('The file is from another site; its nodes are that site\'s.');
  const title = typeof f.title === 'string' && f.title.trim() ? f.title.trim() : 'Imported dashboard';
  return { title, document: migrate(f.document, f.format_version) };
}
