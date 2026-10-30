// Generated from design/devicelist-v1.schema.json by scripts/gen-types.mjs. Don't edit; run npm run types.

/**
 * Every device in the site's device register as of a date: what the register records about it, where the network model reads it (a node, or the edge into one), and which quantities it reported in the last day. Returned by GET /api/devices, the index of the frontend's Reference view; o-mcp/meters gives one node's devices in detail. Times are site time with their offset. Unknown fields may appear in later version-1 documents; ignore them.
 */
export interface DeviceList {
  /**
   * Names the format. Check it, and version, before reading anything else.
   */
  schema: "o-mcp/devicelist";
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
     * Where the model reads each device as of this day, YYYY-MM-DD, site time.
     */
    as_of: string;
    /**
     * The instant reporting is judged at: now for today, else the end of the as_of day.
     */
    observed_at: string;
    /**
     * Days before observed_at that reported and last_reading cover.
     */
    reported_days: number;
  };
  /**
   * Every device in the register, by code, whether or not the model reads it.
   */
  devices: {
    /**
     * The device's database id.
     */
    device_id: number;
    /**
     * Device code.
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
     * The device register's status. It is not maintained: a silent device can still read ONLINE. Judge by reporting.
     */
    declared_status: string | null;
    /**
     * Whether the register holds the device as active.
     */
    active: boolean;
    /**
     * Manufacturer, as the device register records it. Null if not recorded.
     */
    brand: string | null;
    /**
     * Model, as recorded. Null if not recorded.
     */
    model: string | null;
    /**
     * How the device is read, as recorded, such as Modbus TCP. Null if not recorded.
     */
    protocol: string | null;
    /**
     * The gateway (data concentrator) the device is polled through, identified by its address, as recorded; null if none is.
     */
    gateway: {
      /**
       * The gateway's IP address on the plant network.
       */
      ip_address: string;
      /**
       * The gateway's TCP port.
       */
      port: number | null;
    } | null;
    /**
     * The device's Modbus slave address behind its gateway, as recorded. Null if not recorded.
     */
    slave_id: number | null;
    /**
     * Every quantity the network model reads from this device on as_of, and where, by node. Empty: the model doesn't read the device.
     */
    graph: {
      /**
       * Quantity id.
       */
      quantity_id: number;
      /**
       * Quantity code; null when the quantity is not in the vocabulary.
       */
      code: string | null;
      /**
       * TOTAL, SUBMETER or CHECK.
       */
      role: string;
      /**
       * Factor applied to the reading (a CT ratio, a sign).
       */
      multiplier: number;
      /**
       * NODE: read on the node. FEEDER: read on the edge into the node, from feeder_from.
       */
      attached_to: "NODE" | "FEEDER";
      /**
       * The node's graph.node.id: the node itself, or for FEEDER the node the edge goes into, whose meters list the device.
       */
      node_id: number;
      /**
       * That node's code.
       */
      node: string;
      /**
       * Id of the edge, for FEEDER.
       */
      edge: number | null;
      /**
       * Code of the node the edge comes from, for FEEDER.
       */
      feeder_from: string | null;
    }[];
    /**
     * Its latest 15-minute value in the reported_days before observed_at; null if none.
     */
    last_reading: string | null;
    /**
     * True when it read within 2 hours of observed_at.
     */
    reporting: boolean;
    /**
     * Every quantity it reported in the reported_days before observed_at, by id.
     */
    reported: {
      /**
       * Quantity id.
       */
      quantity_id: number;
      /**
       * Quantity code; null when the quantity is not in the vocabulary.
       */
      code: string | null;
    }[];
  }[];
}
