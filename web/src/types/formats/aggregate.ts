// Generated from design/aggregate-v1.schema.json by scripts/gen-types.mjs. Don't edit; run npm run types.

/**
 * One quantity across several nodes over a window. A counter (energy, volume) or a derived quantity is one total per node, worked out on the network model as the values format does, metered or not. A sampled quantity (voltage, current, power, THD) is the minimum, mean, 95th percentile and maximum of each meter's readings: a row per meter, since two meters' readings aren't merged. Returned by GET /api/aggregate. Times are site time with their offset; windows are half-open (end excluded). Unknown fields may appear in later version-1 documents; ignore them.
 */
export interface Aggregate {
  /**
   * Names the format. Check it, and version, before reading anything else.
   */
  schema: "o-mcp/aggregate";
  /**
   * Format version. Adding fields keeps it at 1; removing, renaming or changing the meaning of a field makes 2.
   */
  version: 1;
  /**
   * What was asked for.
   */
  query: {
    /**
     * Tenant (site) id.
     */
    tenant: number;
    /**
     * Quantity code.
     */
    quantity: string;
    /**
     * Node ids (graph.node.id), in the order asked, duplicates removed.
     */
    nodes: number[];
    requested: Window;
  };
  /**
   * The quantity, from the vocabulary.
   */
  quantity: {
    /**
     * Quantity code.
     */
    code: string;
    /**
     * Unit of every figure in rows.
     */
    unit: string | null;
    /**
     * What the quantity is.
     */
    description: string | null;
    /**
     * COUNTER: a running register; SAMPLE: an instantaneous value; DERIVED: computed from two counters (PF_TRUE).
     */
    reading: "COUNTER" | "SAMPLE" | "DERIVED";
  };
  /**
   * TOTAL: each row's total holds the figure, and min, mean, p95 and max are null. SPREAD: the other way round.
   */
  statistic: "TOTAL" | "SPREAD";
  /**
   * The data the figures come from. minute: minute readings (a window of 6 hours or less within the minute data kept). 15min: 15-minute values; for a SPREAD each is the last reading in its 15 minutes, so a shorter dip or spike between two of them doesn't show. day: the daily summary, for a TOTAL over whole site days.
   */
  resolution: "minute" | "15min" | "day";
  window: Window1;
  /**
   * The table read: telemetry_data, telemetry_15min_agg or daily_energy_cost_summary, or for a TOTAL that read several, the one whose data stops first.
   */
  source: string;
  /**
   * Where the data read stops, site time with offset; null when there was none. Short of window.end, findings has DATA_INCOMPLETE.
   */
  data_until: string | null;
  /**
   * TOTAL only (empty for a SPREAD): the parts the window was worked out in, each on the network of its own last day. One piece unless the plant changed inside the window (finding PLANT_CHANGED).
   */
  pieces: {
    /**
     * Start, site time with offset.
     */
    start: string;
    /**
     * End, excluded.
     */
    end: string;
    /**
     * The network the piece was worked out on.
     */
    as_of: string;
  }[];
  /**
   * TOTAL: one per node, in the order asked. SPREAD: one per meter on each node (on the node or its feeder edge, on the window's last day), nodes in the order asked and meters by code; a node with no meter has one row with origin NO_METER. A node not in the plant on the window's last day has no row (finding NOT_IN_PLANT).
   */
  rows: {
    /**
     * Node id.
     */
    node_id: number;
    /**
     * Node code on the window's last day.
     */
    code: string;
    /**
     * Node name.
     */
    name: string | null;
    /**
     * SPREAD: the meter's device id; null for NO_METER and for a TOTAL.
     */
    device_id: number | null;
    /**
     * SPREAD: the meter's device code.
     */
    device: string | null;
    /**
     * SPREAD: the meter's name.
     */
    device_name: string | null;
    /**
     * TOTAL: the node's total over the window; null when it has none (finding NO_VALUE or NOT_IN_NETWORK), which is not zero.
     */
    total: number | null;
    /**
     * How the figure was found; new values may appear. MEASURED: from a meter (always so for a SPREAD row with a meter). The others are the solver's, for a TOTAL: ROLLUP and CHILDREN from what the node feeds, IN_EDGES from its feeders, OUT_EDGES from its out-edges, INHERITED its feeder's, DERIVED computed from two quantities, NONE no value. NO_METER: a SPREAD row for a node with no meter.
     */
    origin: string;
    /**
     * SPREAD: the smallest reading; null when the meter had none.
     */
    min: number | null;
    /**
     * SPREAD: the mean of the readings.
     */
    mean: number | null;
    /**
     * SPREAD: the 95th percentile of the readings (continuous).
     */
    p95: number | null;
    /**
     * SPREAD: the largest reading.
     */
    max: number | null;
    /**
     * SPREAD: readings the statistics rest on. null for a TOTAL.
     */
    samples: number | null;
    /**
     * SPREAD: readings a meter reporting every minute (resolution minute) or every 15 minutes gives in the window. samples well short of it means gaps.
     */
    expected: number | null;
    /**
     * SPREAD: start of the meter's last reading in the window, site time with offset.
     */
    last_reading: string | null;
  }[];
  /**
   * What the server noticed. Show message as is.
   */
  findings: {
    /**
     * NO_VALUE, NOT_IN_NETWORK, PLANT_CHANGED, DATA_INCOMPLETE, NO_METER, NO_READINGS, NOT_IN_PLANT; new codes may appear.
     */
    code: string;
    /**
     * The node it is about, when one.
     */
    node_id?: number;
    /**
     * The meter it is about, when one.
     */
    device?: string;
    /**
     * A sentence for the reader.
     */
    message: string;
  }[];
}
/**
 * The window asked for.
 */
export interface Window {
  /**
   * Start, site time with offset.
   */
  start: string;
  /**
   * End, excluded.
   */
  end: string;
}
/**
 * The window the figures cover. For a TOTAL, the requested window snapped outwards to its resolution; for a SPREAD, the requested window.
 */
export interface Window1 {
  /**
   * Start, site time with offset.
   */
  start: string;
  /**
   * End, excluded.
   */
  end: string;
}
