// Generated from design/dashboard-v1.schema.json by scripts/gen-types.mjs. Don't edit; run npm run types.

export type Instant = string;

/**
 * A saved dashboard's document (frontend.dashboard.document, format_version 1): its time range, refresh, channels, and each widget's place and own settings (design/frontend.md §3-§5, §8). Written by web/, checked by the API on every save. The shell reads everything but `settings`, which belongs to the widget type and is never read by anything else. Version 1 may gain optional fields; a reader ignores fields it doesn't know. Removing or renaming a field, or changing what one means, makes version 2, and web/ migrates older documents when it reads them.
 */
export interface Dashboard {
  /**
   * The dashboard's one time range (decision 1), in the tenant's time zone, half-open. Relative ends follow Grafana: `now`, `now-30m`, `now-24h`, `now-7d`; `/d`, `/w`, `/M` or `/y` rounds to the start of that unit, or as `to` its end, so `now/d` to `now/d` is today. Absolute ends are site dates or minutes.
   */
  time: {
    from: Instant;
    to: Instant;
  };
  /**
   * Seconds between refreshes, or null for off, the default (decision 2). The API answers faster polls from its 30 s cache.
   */
  refresh: number | null;
  /**
   * The entity each channel holds (§5): widgets on a channel show it and follow when it changes. Channels A to D; an empty channel is left out.
   */
  channels: {
    [k: string]: Entity | undefined;
  };
  /**
   * @maxItems 60
   */
  widgets: {
    /**
     * Unique within the dashboard.
     */
    id: string;
    /**
     * The widget registry's key. An unknown type is drawn as a placeholder, never dropped.
     */
    type: string;
    /**
     * Shown in the header; null for the type's default.
     */
    title?: string | null;
    /**
     * Column, of 24 (§4), as a Grafana panel's gridPos.
     */
    x: number;
    /**
     * Row.
     */
    y: number;
    /**
     * Width in columns. The registry's minimum applies when drawn, not when saved.
     */
    w: number;
    /**
     * Height in rows.
     */
    h: number;
    /**
     * The channel the widget follows, or null for its own settings only.
     */
    channel: "A" | "B" | "C" | "D" | null;
    /**
     * The widget type's own settings. Nodes are graph.node ids (decision 19).
     */
    settings: {};
  }[];
}
/**
 * What a channel carries: its kind as well as its id, so a node widget ignores a device (§5).
 */
export interface Entity {
  kind: "node" | "device" | "category";
  /**
   * graph.node.id, public.devices.id, or a graph category code.
   */
  id: number | string;
}
