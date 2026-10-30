// Generates src/types/formats/*.ts from the formats in design/ (design/frontend.md §5): the API
// answers in them, so a format change shows up here as a type error. Run after changing a schema:
//   npm run types
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { compile } from 'json-schema-to-typescript';

const FORMATS = {
  dashboard: 'Dashboard', nodelist: 'NodeList', subgraph: 'Subgraph', meters: 'Meters',
  readings: 'Readings', vocabulary: 'Vocabulary', aggregate: 'Aggregate', devicelist: 'DeviceList',
};
const design = new URL('../../design/', import.meta.url);
const out = new URL('../src/types/formats/', import.meta.url);
await mkdir(out, { recursive: true });
for (const [name, type] of Object.entries(FORMATS)) {
  const schema = JSON.parse(await readFile(new URL(`${name}-v1.schema.json`, design), 'utf8'));
  schema.title = type;
  const ts = await compile(schema, type, {
    bannerComment: `// Generated from design/${name}-v1.schema.json by scripts/gen-types.mjs. Don't edit; run npm run types.`,
    additionalProperties: false, unknownAny: true, format: true, strictIndexSignatures: true,
  });
  await writeFile(new URL(`${name}.ts`, out), ts);
}
