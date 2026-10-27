// Every widget type, by the key a dashboard stores (design/frontend.md §5). A stored type missing
// here is drawn as a placeholder, never dropped.
import type { WidgetType } from './contract';
import { diagnostics } from './Diagnostics';
import { finder } from './Finder';
import { meters } from './Meters';
import { now } from './Now';
import { readings } from './Readings';
import { sankey } from './Sankey';
import { section } from './Section';
import { value } from './Value';

export const WIDGETS: WidgetType<any>[] = [value, readings, now, finder, section, meters, sankey, diagnostics];

export const byType = new Map(WIDGETS.map((w) => [w.type, w]));
