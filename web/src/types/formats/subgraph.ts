// Generated from design/subgraph-v1.schema.json by scripts/gen-types.mjs. Don't edit; run npm run types.

/**
 * Part of a plant's energy and water network as of one date: a root node, everything below it down to a depth, and the parents that feed into that part from outside it. Edges point the way energy or water flows. Only rows in effect on query.as_of are included. Explained further in design/subgraph-format.md. Unknown fields may appear in later version-1 documents; ignore them.
 */
export interface Subgraph {
  /**
   * Names the format. Check it, and version, before reading anything else.
   */
  schema: "o-mcp/subgraph";
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
     * The node code asked for. If no node with this code is in effect on as_of, nodes is empty.
     */
    root: string;
    /**
     * The day the plant is described as of, YYYY-MM-DD.
     */
    as_of: string;
    /**
     * How many levels from the root were followed: below it, or above it when direction is up.
     */
    depth: number;
    /**
     * When set, only edges of this utility (ELECTRICITY, WATER, AIR, GAS, STEAM) were followed and returned. Null means all utilities.
     */
    utility: string | null;
    /**
     * Which way the walk went. down: from the root to what it feeds. up: from the root back towards its sources, along edges that carry flow, so reached nodes are its feeders and theirs, and depth counts levels above the root. Absent in documents written before 2026-10-12, which are all down.
     */
    direction?: "down" | "up";
  };
  /**
   * Every node in the document, each once. Ordered by scope (reached, parent, context), then depth, then code.
   */
  nodes: {
    /**
     * The node's graph.node.id, which stays when its code changes (design/frontend.md §5). The frontend stores it.
     */
    id: number;
    /**
     * The node's code, unique within the tenant. Edges and findings refer to nodes by this code.
     */
    code: string;
    /**
     * Human-readable name, as the site calls it.
     */
    name: string;
    /**
     * Broad role. SOURCE: brings energy or water in (grid incomer, PV plant, generator, well). BUS: a point where flow is shared out (switchboard, header); a main board and a sub-board are both BUS, told apart by type (MAIN_LV_BOARD, SUB_BOARD). CONVERSION: takes energy in one utility and delivers a different one (an air compressor takes electricity and delivers compressed air; a boiler, steam). TREATMENT: the same utility passes through, changed in quality and with some lost (clarifier, softener, RO unit, air dryer); inflow minus outflow is a real loss, and any electricity it draws is auxiliary. STORAGE: holds or compensates (tank, capacitor bank). LOAD: uses the utility (machine, lighting, a process area using water); on water it may return spent water to a tank. SINK: where the utility leaves the graph unconsumed, an outfall or overflow, or a recycle cut that re-enters at the node in attrs.reenters_at; keep SINK out of consumption totals.
     */
    class: "SOURCE" | "BUS" | "CONVERSION" | "TREATMENT" | "STORAGE" | "LOAD" | "SINK";
    /**
     * Specific node type from the ontology, such as MAIN_LV_BOARD, PV_PLANT or AIR_COMPRESSOR. Null if not yet typed.
     */
    type: string | null;
    /**
     * The node's recorded properties. A missing key means not recorded; that is a problem only if a PROPERTY_GAP finding names it. The unit is in the key: nominal_v and tx_primary_v in volts, rated_kva in kVA, rated_kw in kW, rated_kvar in kvar, main_breaker_a in amperes. On a board fed by a transformer, rated_kva, tx_primary_v and tx_equipment_code describe that transformer.
     */
    attrs: {};
    /**
     * Why the node is here. reached: part of the asked-for section, found walking from the root (down, or up when query.direction is up). parent: not part of it, but feeds a reached node from outside (a second board, a PV plant, a generator). context: feeds a parent node; present only so that edge has both ends.
     */
    scope: "reached" | "parent" | "context";
    /**
     * For reached nodes, the fewest edges from the root in the walk's direction (the root is 0; a node reachable two ways gets the shorter). Not a voltage level or a rank. Null for parent and context nodes.
     */
    depth: number | null;
    /**
     * How many nodes this node feeds, in or out of the document.
     */
    children_total: number;
    /**
     * Of those, how many are not in the document. Above zero means the section stops here; it does not mean the node feeds nothing.
     */
    children_not_included: number;
  }[];
  /**
   * Every edge into a reached or parent node, so each reached node's full set of parents is present. Both ends of every edge are in nodes. Ordered by from, to, id.
   */
  edges: {
    /**
     * The edge's database id.
     */
    id: number;
    /**
     * Code of the node the flow comes from.
     */
    from: string;
    /**
     * Code of the node the flow goes to.
     */
    to: string;
    /**
     * Specific edge type from the ontology, such as TRANSFORMER (a 20/0.4 kV transformer between the two nodes), SUPPLY_LV (a low-voltage feeder), PV_INJECTION or PF_COMPENSATION. Null if not yet typed.
     */
    type: string | null;
    /**
     * Broad edge class, the conveyance. FEEDER: an electrical connection (what kind is in type). PIPE: a pipe carrying the utility. COMPENSATION: a capacitor bank's connection, which moves no energy.
     */
    class: "FEEDER" | "PIPE" | "COMPENSATION";
    /**
     * What flows along it: ELECTRICITY, WATER, AIR, GAS or STEAM.
     */
    utility: string;
    /**
     * False for a connection that moves no energy or water, such as a capacitor bank on a board. Do not add such edges into flow totals.
     */
    carries_flow: boolean;
    /**
     * When this edge became true, YYYY-MM-DD, or "-infinity" for since before records began.
     */
    effective_from: string;
    /**
     * Last day this edge is true, YYYY-MM-DD, or null while it still is.
     */
    effective_to: string | null;
  }[];
  /**
   * What the server noticed about these nodes and edges. Computed by the server; display them, do not work them out again. Each has a code and a message to show a person as is. Ordered by code, then subject.
   */
  findings: (
    | {
        code: "MULTIPLE_LIVE_PARENTS";
        /**
         * Code of the node.
         */
        node: string;
        /**
         * Codes of its parents, alphabetical.
         */
        parents: string[];
        /**
         * One sentence for a person.
         */
        message: string;
      }
    | {
        code: "IMPLICIT_BUS";
        /**
         * Code of the node.
         */
        node: string;
        /**
         * How many nodes it feeds directly, counting only edges that carry flow.
         */
        children: number;
        /**
         * One sentence for a person.
         */
        message: string;
      }
    | {
        code: "PROPERTY_GAP";
        /**
         * Code of the node.
         */
        node: string;
        /**
         * The missing key, as it would appear in attrs.
         */
        property: string;
        /**
         * Where the value would come from, such as NAMEPLATE (read off the equipment) or DESIGN.
         */
        kind: string;
        /**
         * What is wrong, such as MISSING.
         */
        status: string;
        /**
         * The report or program that needs it.
         */
        used_by: string | null;
        /**
         * Extra detail, when there is any.
         */
        detail: string | null;
        /**
         * One sentence for a person.
         */
        message: string;
      }
    | {
        code: "EDGE_GAP";
        /**
         * Id of the edge.
         */
        edge: number;
        /**
         * Code of the node it comes from.
         */
        from: string;
        /**
         * Code of the node it goes to.
         */
        to: string;
        /**
         * UNTYPED (no edge type), ENDPOINT_UNTYPED (an end has no node type) or ILLEGAL_ENDPOINT (its edge type does not allow these node types).
         */
        status: string;
        /**
         * One sentence for a person.
         */
        message: string;
      }
  )[];
}
