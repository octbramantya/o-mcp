// Generated from design/vocabulary-v1.schema.json by scripts/gen-types.mjs. Don't edit; run npm run types.

/**
 * The terms the plant tools use: node and edge classes and types, properties, utilities and quantities, each with its definition from the database. Returned by plant_vocabulary; a section left empty was not asked for. Unknown fields may appear in later version-1 documents; ignore them.
 */
export interface Vocabulary {
  /**
   * Names the format. Check it, and version, before reading anything else.
   */
  schema: "o-mcp/vocabulary";
  /**
   * Format version. Adding fields keeps it at 1; removing, renaming or changing the meaning of a field makes 2.
   */
  version: 1;
  /**
   * The broad roles a node can have (graph.node_class).
   */
  node_classes: {
    /**
     * Class code, such as BUS or LOAD.
     */
    code: string;
    /**
     * What the class means.
     */
    description: string;
  }[];
  /**
   * Specific node types (graph.node_type), each in one class.
   */
  node_types: {
    /**
     * Type code, such as SUB_BOARD.
     */
    code: string;
    /**
     * The node class every node of this type has.
     */
    class: string;
    /**
     * The type this one specialises, or null. A filter on the parent includes this type.
     */
    parent: string | null;
    /**
     * True for a type that only groups its subtypes and is never assigned to a node (SWITCHBOARD, WATER_TREATMENT).
     */
    abstract: boolean;
    /**
     * Human-readable name.
     */
    name: string;
    /**
     * What the type covers, how its nodes sit in the graph, and what may not be inferred from it.
     */
    description: string | null;
    /**
     * The properties a node of this type may carry, including those inherited from its parent types.
     */
    properties: {
      /**
       * Property key, as it appears in a node's attrs.
       */
      key: string;
      /**
       * REQUIRED (a named reader needs it; its absence is a PROPERTY_GAP finding) or OPTIONAL.
       */
      requirement: string;
      /**
       * The report or program that needs it.
       */
      used_by: string | null;
      /**
       * The type the rule is set on: this type, or a parent it inherits from.
       */
      defined_on: string;
    }[];
  }[];
  /**
   * The broad kinds of connection (graph.edge_class).
   */
  edge_classes: {
    /**
     * Class code: FEEDER, PIPE or COMPENSATION.
     */
    code: string;
    /**
     * What the class means.
     */
    description: string;
  }[];
  /**
   * Specific edge types (graph.edge_type) and which nodes each may join.
   */
  edge_types: {
    /**
     * Edge type code, such as SUPPLY_LV or PV_INJECTION.
     */
    code: string;
    /**
     * The edge class.
     */
    class: string;
    /**
     * The utility it carries.
     */
    utility: string | null;
    /**
     * False for a connection that moves no energy (a capacitor bank on its board). Such edges stay out of flow totals.
     */
    carries_flow: boolean;
    /**
     * True when the edge changes voltage level (a transformer).
     */
    is_transform: boolean;
    /**
     * What the edge type means and where its meter, if any, is tapped.
     */
    description: string;
    /**
     * The allowed (from, to) pairs. Each end names a node type or a whole node class.
     */
    endpoints: {
      /**
       * Node type or class the edge may start at.
       */
      from: string;
      /**
       * Whether from names a node type or a node class.
       */
      from_is: "type" | "class" | "unknown";
      /**
       * Node type or class the edge may end at.
       */
      to: string;
      /**
       * Whether to names a node type or a node class.
       */
      to_is: "type" | "class" | "unknown";
    }[];
  }[];
  /**
   * Node properties (graph.property): what each attrs key holds and its allowed values.
   */
  properties: {
    /**
     * The attrs key, such as main_breaker_a.
     */
    key: string;
    /**
     * number, integer, text, date, enum or number[].
     */
    datatype: string;
    /**
     * Unit of the value, also in the key's suffix.
     */
    unit: string | null;
    /**
     * Smallest allowed value.
     */
    min: number | null;
    /**
     * Largest allowed value.
     */
    max: number | null;
    /**
     * The allowed values of an enum property.
     */
    enum_values: string[] | null;
    /**
     * Where the value comes from: NAMEPLATE (read off the equipment), DESIGN, RECORD or SITE_STATUS.
     */
    kind: string;
    /**
     * What the property means, and which value is the rating where several could be.
     */
    description: string;
  }[];
  /**
   * What flows through the networks (graph.utility).
   */
  utilities: {
    /**
     * Utility code, such as ELECTRICITY.
     */
    code: string;
    /**
     * Human-readable name.
     */
    name: string;
    /**
     * The unit its flows are totalled in.
     */
    base_unit: string;
  }[];
  /**
   * The quantities meters report (graph.quantity_term), with the network model's rule where it resolves the quantity for every node.
   */
  quantities: {
    /**
     * Quantity code, as the readings and values tools take it.
     */
    code: string;
    /**
     * The id telemetry stores it under.
     */
    quantity_id: number;
    /**
     * Unit; null for a dimensionless value such as power factor.
     */
    unit: string | null;
    /**
     * COUNTER: a register that only grows; what matters is its difference over an interval. SAMPLE: a value at an instant.
     */
    reading: "COUNTER" | "SAMPLE";
    /**
     * What it measures, and how it is encoded where that matters.
     */
    description: string;
    /**
     * How the network model resolves it at every node, or null when it does not.
     */
    rule: {
      /**
       * The utility network it is solved over.
       */
      utility: string;
      /**
       * How a meter's readings over a window become one number: DELTA (counter difference), AVG, P95 or SUM.
       */
      time_agg: string;
      /**
       * How it reaches unmetered nodes: SUM (flow balance), INHERIT (from the feeder) or NONE (metered nodes only).
       */
      network_agg: string;
      /**
       * True for a flow that balances at every bus (energy, water, air).
       */
      conserved: boolean;
    } | null;
    /**
     * True when node_value serves it.
     */
    node_value: boolean;
  }[];
  /**
   * Quantities computed from two others at every node (graph.derived_quantity), such as PF_TRUE.
   */
  derived_quantities: {
    /**
     * Derived quantity code.
     */
    code: string;
    /**
     * The utility network it is computed over.
     */
    utility: string;
    /**
     * Unit; null when dimensionless.
     */
    unit: string | null;
    /**
     * What it is, how it is computed, and when to prefer it.
     */
    description: string;
    /**
     * The two quantity codes it is computed from.
     */
    from: string[];
    /**
     * True when node_value serves it.
     */
    node_value: boolean;
  }[];
}
