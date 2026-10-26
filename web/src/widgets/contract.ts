// What a widget gets from the shell, and what the shell needs to know about a widget type
// (design/frontend.md §4, §5). The shell owns the box, the channel and saving; the widget owns
// its data and its settings, which nothing else reads.
import type { ComponentType } from 'react';
import type { Entity } from '../dashboards/document';

/** The dashboard's window, resolved at the last refresh tick, in site time. */
export interface View {
  start: string;
  end: string;
  /** The range's last day: topology is drawn on it (decision 20). */
  asOf: string;
  tick: number;
  tz: string;
  tenant: number;
}

export interface WidgetProps<S> {
  settings: S;
  setSettings: (s: S) => void;
  /** The channel's entity, when the widget follows a channel and the channel holds one. */
  entity: Entity | undefined;
  /** Puts an entity on the widget's channel; false when the widget follows none. */
  select: ((e: Entity) => void) | null;
  view: View;
  editing: boolean;
}

export interface SettingsProps<S> {
  settings: S;
  setSettings: (s: S) => void;
}

export interface WidgetType<S = never> {
  type: string;
  label: string;
  description: string;
  /** Minimum and default size in grid columns and rows; the minimum applies when drawn (§4). */
  minW: number;
  minH: number;
  w: number;
  h: number;
  defaults: S;
  View: ComponentType<WidgetProps<S>>;
  Settings?: ComponentType<SettingsProps<S>>;
}

/** The node a widget shows: the channel's, when it holds a node, else the widget's own. */
export function nodeOf(entity: Entity | undefined, own: number | null): number | null {
  return entity?.kind === 'node' && typeof entity.id === 'number' ? entity.id : own;
}
