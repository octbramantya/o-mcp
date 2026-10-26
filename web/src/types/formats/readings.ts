// Generated from design/readings-v1.schema.json by scripts/gen-types.mjs. Don't edit; run npm run types.

/**
 * What one node's meters read over a window, one series per device and quantity, one point per interval. Returned by meter_readings. Times are site time with their offset; the window is half-open (end excluded). A COUNTER point is consumption over the interval; a SAMPLE point the mean, min and max of its 15-minute values; power factor is decoded to 0..1 first. Unknown fields may appear in later version-1 documents; ignore them.
 */
export interface Readings {
  /**
   * Names the format. Check it, and version, before reading anything else.
   */
  schema: "o-mcp/readings";
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
     * Code of the node the server resolved the request to.
     */
    node: string;
    /**
     * That node's graph.node.id.
     */
    node_id: number;
    /**
     * Which devices were on the node: as on this day.
     */
    as_of: string;
    /**
     * Point size; window is one point for the whole window. hour and day follow site time. minute reads minute telemetry; only the frontend's API gives it, for windows of 6 hours or less.
     */
    interval: "minute" | "15min" | "hour" | "day" | "window";
    /**
     * The window, start included, end excluded.
     */
    window: {
      /**
       * Start, site time with offset.
       */
      start: string;
      /**
       * End, excluded.
       */
      end: string;
    };
    /**
     * Quantity codes asked for.
     */
    quantities: string[];
    /**
     * The one device asked for, or null for all on the node.
     */
    device: string | null;
  };
  /**
   * One per device and quantity, by device code.
   */
  series: {
    /**
     * The device's public.devices id.
     */
    device_id: number;
    /**
     * Device code.
     */
    device: string;
    /**
     * Device name.
     */
    device_name: string | null;
    /**
     * Quantity code.
     */
    quantity: string;
    /**
     * Unit of consumption, or of mean, min and max.
     */
    unit: string | null;
    /**
     * COUNTER: points carry consumption. SAMPLE: points carry mean, min and max.
     */
    reading: "COUNTER" | "SAMPLE";
    /**
     * True for power factor: the meter's quadrant encoding (-2..2) was decoded to 0..1 before any statistic, so leading and lagging are no longer told apart.
     */
    decoded: boolean;
    /**
     * One per interval that has data, in time order. A missing interval had no readings.
     */
    points: {
      /**
       * Start of the interval, site time with offset.
       */
      start: string;
      /**
       * COUNTER only: the register's increase over the interval. Consumption across a gap in readings lands in the first interval after it.
       */
      consumption: number | null;
      /**
       * SAMPLE only: mean of the 15-minute values.
       */
      mean: number | null;
      /**
       * SAMPLE only: smallest 15-minute value (a 15-minute mean, not an instantaneous minimum).
       */
      min: number | null;
      /**
       * SAMPLE only: largest 15-minute value.
       */
      max: number | null;
      /**
       * Values in the interval: 15-minute values (4 per full hour), or minute values at interval minute.
       */
      samples: number;
      /**
       * COUNTER only: steps where the register went backwards or jumped implausibly, counted as zero.
       */
      rejected: number;
    }[];
  }[];
  /**
   * What the server noticed. Show message as is.
   */
  findings: {
    /**
     * NO_READINGS: a device has no values of a quantity in the window. COUNTER_RESET: some steps were rejected, so consumption is a lower bound.
     */
    code: "NO_READINGS" | "COUNTER_RESET";
    /**
     * Device code.
     */
    device: string;
    /**
     * Quantity code.
     */
    quantity: string;
    /**
     * One sentence for a person.
     */
    message: string;
  }[];
}
