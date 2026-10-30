// Every widget type, by the key a dashboard stores (design/frontend.md §5). A stored type missing
// here is drawn as a placeholder, never dropped.
import { compare } from './Compare';
import type { WidgetType } from './contract';
import { diagnostics } from './Diagnostics';
import { now } from './Now';
import { readings } from './Readings';
import { sankey } from './Sankey';
import { section } from './Section';
import { stat } from './Stat';
import { value } from './Value';

export const WIDGETS: WidgetType<any>[] = [value, stat, readings, compare, now, section, sankey, diagnostics];

export const byType = new Map(WIDGETS.map((w) => [w.type, w]));

/** Types that were retired, with what replaces them, for the placeholder a saved dashboard still shows. */
export const retired = new Map<string, string>([
  ['finder', "The node finder moved to the side bar's Find view. Remove this widget in edit mode."],
  ['meters', "Meters moved to the side bar's Reference view (the book in the Activity Bar), with Node information. Remove this widget in edit mode."],
  ['nodeinfo', "Node information moved to the side bar's Reference view (the book in the Activity Bar), with Meters. Remove this widget in edit mode."],
]);
