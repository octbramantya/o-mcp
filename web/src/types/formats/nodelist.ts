// Generated from design/nodelist-v1.schema.json by scripts/gen-types.mjs. Don't edit; run npm run types.

/**
 * Nodes in effect on query.as_of that match every filter in query, ordered by code. Returned by plant_find. A list, not a subgraph: for how the nodes connect, ask plant_section. Unknown fields may appear in later version-1 documents; ignore them.
 */
export interface NodeList {
  /**
   * Names the format. Check it, and version, before reading anything else.
   */
  schema: "o-mcp/nodelist";
  /**
   * Format version. Adding fields keeps it at 1; removing, renaming or changing the meaning of a field makes 2.
   */
  version: 1;
  /**
   * What was asked for. Filters that were not given are absent.
   */
  query: {
    /**
     * Tenant (site) id.
     */
    tenant: number;
    /**
     * The day the plant is described as of, YYYY-MM-DD, site time.
     */
    as_of: string;
    /**
     * Most rows returned.
     */
    limit: number;
    /**
     * Part of a code or name, matched ignoring case.
     */
    text?: string;
    /**
     * Node type; its subtypes matched too.
     */
    type?: string;
    /**
     * Node class.
     */
    class?: string;
    /**
     * Only nodes with an edge of this utility.
     */
    utility?: string;
    /**
     * Whether a meter is on the node or its feeder.
     */
    metered?: boolean;
    /**
     * Declared status; none means nothing declared.
     */
    site_status?: string;
  };
  /**
   * How many nodes match. Above returned means the list was cut at limit.
   */
  total: number;
  /**
   * How many nodes are in nodes.
   */
  returned: number;
  /**
   * The matching nodes, by code.
   */
  nodes: {
    /**
     * The node's graph.node.id, which stays when its code changes (design/frontend.md §5). The frontend stores it.
     */
    id: number;
    /**
     * The node's code; other tools take it.
     */
    code: string;
    /**
     * Human-readable name, as the site calls it.
     */
    name: string;
    /**
     * Node class, the broad role.
     */
    class: string;
    /**
     * Node type; null if not yet typed.
     */
    type: string | null;
    /**
     * Utilities of the live edges at this node.
     */
    utilities: string[];
    /**
     * True when a meter is on the node itself or on an edge into it. False: its values are inferred by the solver from its neighbours.
     */
    metered: boolean;
    /**
     * Live edges into the node that carry flow. More than one on a board or load is an open question for the site, unless one is a PV plant or generator.
     */
    feeders: number;
    /**
     * Status the site declared (normal or inactive); null when nothing is declared, which is not the same as normal.
     */
    site_status: string | null;
    /**
     * The day the status was declared, YYYY-MM-DD.
     */
    site_status_as_of: string | null;
  }[];
}
