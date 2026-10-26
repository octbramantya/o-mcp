// Generated from design/meters-v1.schema.json by scripts/gen-types.mjs. Don't edit; run npm run types.

/**
 * The instruments at one node as of a date: each device on the node or its feeder, what it reports and when it last did, and which quantities node_value can give for the node and how. Returned by node_meters. Times are site time with their offset. Unknown fields may appear in later version-1 documents; ignore them.
 */
export interface Meters {
  /**
   * Names the format. Check it, and version, before reading anything else.
   */
  schema: "o-mcp/meters";
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
     * Attachments as of this day, YYYY-MM-DD, site time.
     */
    as_of: string;
    /**
     * The instant reporting is judged at: now for today, else the end of the as_of day.
     */
    observed_at: string;
    /**
     * Days before observed_at that the reported quantities cover.
     */
    lookback_days: number;
  };
  /**
   * The node.
   */
  node: {
    /**
     * The node's graph.node.id, which stays when its code changes (design/frontend.md §5). The frontend stores it.
     */
    id: number;
    /**
     * The node's code.
     */
    code: string;
    /**
     * Human-readable name.
     */
    name: string;
    /**
     * Node class.
     */
    class: string;
    /**
     * Node type.
     */
    type: string | null;
    /**
     * Utilities of the live edges at the node.
     */
    utilities: string[];
    /**
     * Status the site declared (normal or inactive); null when nothing is declared, or when as_of is before the declaration.
     */
    site_status: string | null;
    /**
     * The day the status was declared.
     */
    site_status_as_of: string | null;
  };
  /**
   * Every device on the node or on an edge into it, by code.
   */
  devices: {
    /**
     * The device's database id.
     */
    device_id: number;
    /**
     * Device code; meter_readings takes it as device.
     */
    code: string;
    /**
     * Device name.
     */
    name: string | null;
    /**
     * Device type, such as Power Meter or Flow Meter.
     */
    type: string | null;
    /**
     * The device register's status. It is not maintained: a silent device can still read ONLINE. Judge by observed.
     */
    declared_status: string | null;
    /**
     * NODE: the meter reads the node. FEEDER: it sits on the edge into the node, from feeder_from.
     */
    attached_to: "NODE" | "FEEDER";
    /**
     * Id of the edge it sits on, for FEEDER.
     */
    edge: number | null;
    /**
     * Code of the node at the other end of that edge, for FEEDER.
     */
    feeder_from: string | null;
    /**
     * The quantities the network model reads from this device for this node.
     */
    graph_quantities: {
      /**
       * Quantity code.
       */
      code: string | null;
      /**
       * Quantity id.
       */
      quantity_id: number;
      /**
       * TOTAL, SUBMETER or CHECK.
       */
      role: string;
      /**
       * Factor applied to the reading (a CT ratio, a sign).
       */
      multiplier: number;
    }[];
    /**
     * Its latest reading at or before observed_at, within 90 days; null if none.
     */
    last_reading: string | null;
    /**
     * REPORTING: read within 2 hours of observed_at. SILENT: last read earlier. NO_DATA: nothing in 90 days.
     */
    observed: "REPORTING" | "SILENT" | "NO_DATA";
    /**
     * Every quantity it reported in the lookback, by id.
     */
    reported: {
      /**
       * Quantity code; null when the quantity is not in the vocabulary (an UNKNOWN_QUANTITY finding says so).
       */
      code: string | null;
      /**
       * Quantity id.
       */
      quantity_id: number;
      /**
       * Unit.
       */
      unit: string | null;
      /**
       * COUNTER or SAMPLE.
       */
      reading: string | null;
      /**
       * Its latest 15-minute value in the lookback.
       */
      last_reading: string;
      /**
       * How many 15-minute values it has in the lookback.
       */
      readings: number;
    }[];
  }[];
  /**
   * What node_value can give for this node, per quantity of the node's utilities.
   */
  resolvable: {
    /**
     * Quantity code node_value takes.
     */
    quantity: string;
    /**
     * Unit.
     */
    unit: string | null;
    /**
     * Utility network.
     */
    utility: string;
    /**
     * MEASURED: a meter on the node or its feeder reports it. INFERRED: worked out from neighbouring meters by flow balance. INHERITED: taken from the feeder. DERIVED: computed from two other quantities. NOT_AVAILABLE: only a meter here could give it.
     */
    availability: "MEASURED" | "INFERRED" | "INHERITED" | "DERIVED" | "NOT_AVAILABLE";
    /**
     * The same in a sentence.
     */
    note: string;
  }[];
  /**
   * What the server noticed. Show message as is.
   */
  findings: {
    /**
     * NO_METER: no device on the node or its feeder. METER_SILENT: silent with nothing on record to explain it. SILENT_AS_DECLARED: silent, as the site's inactive status explains. STATUS_OUT_OF_DATE: declared inactive but reporting. UNKNOWN_QUANTITY: a reported quantity id with no vocabulary entry.
     */
    code: "NO_METER" | "METER_SILENT" | "SILENT_AS_DECLARED" | "STATUS_OUT_OF_DATE" | "UNKNOWN_QUANTITY";
    /**
     * Code of the node.
     */
    node: string;
    /**
     * Code of the device, when the finding is about one.
     */
    device?: string;
    /**
     * The unknown quantity id, for UNKNOWN_QUANTITY.
     */
    quantity_id?: number;
    /**
     * One sentence for a person.
     */
    message: string;
  }[];
}
