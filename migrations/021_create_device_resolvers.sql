-- Migration: 021_create_device_resolvers.sql
-- Description: Resolve a device to its graph node by devices.id or by
--              (data-concentrator ip_address, slave_id); correct and normalise
--              devices.metadata->'data_concentrator'
-- Author: Claude
-- Date: 2026-08-28
-- Phase: 0 -- additive in graph, corrective in public.devices.
--
-- Requires 008 (graph.node/edge/measurement) and 016 (the topology primitives
-- this exists to feed). Apply any time after 016.
--
-- ROLE: sections 1-2 UPDATE public.devices (owner: postgres) and sections 3-5
-- CREATE in schema graph. Neither is available to grafReader, which is what
-- ../prs_diags/scripts/.env holds -- run this as `postgres`, the same way
-- ../prs_diags/scripts/migrate_device54_to_161.sql does. The verification block at the foot
-- is read-only and does run as grafReader.
--
-- ---------------------------------------------------------------------------
-- WHY THIS EXISTS
--
-- 016 keys every traversal on node_code, and that is correct: node_code is the
-- graph's identity. But engineers do not carry node codes around. They carry
-- devices.id, or the pair an instrument is addressed by on the plant floor --
-- the data concentrator's IP and the device's Modbus slave address. Asking
-- them to translate by hand is how a diagnosis gets run against the wrong
-- branch.
--
-- So this file adds a resolver layer, not a second traversal API. Nothing in
-- 016 changes. The composition is:
--
--     SELECT * FROM graph.ancestors(3, graph.node_code_of_device(3, 158), 'ELECTRICITY');
--     SELECT * FROM graph.siblings (3, graph.node_code_of_dc(3, '192.168.20.17', 53));
--
-- Three primitives times two keys, with no wrapper explosion and nothing new to
-- learn. Deliberately NOT done as overloads of graph.descendants: an INTEGER
-- second parameter alongside the existing VARCHAR one makes descendants(3,
-- 'AHU_4_7') ambiguous to the function resolver on an unknown-type literal.
--
-- ---------------------------------------------------------------------------
-- WHY THE RESOLVERS RAISE INSTEAD OF RETURNING NO ROWS
--
-- The failure this layer must not have is the silent empty result. On tenant 3
-- one active power meter is attached to nothing, and all 43 of tenant 4's
-- devices are attached to nothing, because no graph has been authored for that
-- tenant. A resolver that returns NULL for those feeds NULL into
-- graph.descendants, which returns zero rows -- indistinguishable from a node
-- that genuinely has no descendants. An engineer cannot tell "this device is
-- unmetered" from "this breaker feeds nothing", and the second reading is the
-- dangerous one.
--
-- The resolvers therefore RAISE, with three distinct messages: the device does
-- not exist, the device exists but is not attached as of that date, or the
-- device resolves to more than one node. graph.v_device_attachment is the
-- non-raising counterpart for browsing -- it lists unattached devices with a
-- NULL node_code rather than omitting them.
--
-- ---------------------------------------------------------------------------
-- EDGE-ATTACHED DEVICES RESOLVE TO to_node_id
--
-- graph.measurement is node_id XOR edge_id (§4.4). A flow meter tapped into a
-- pipe reads the pipe, so it has no single node and one has to be chosen.
--
-- Measured on live valkyrie: all 6 of tenant 3's Flow Meter devices are
-- edge-attached, all 98 attached Power Meters are node-attached, and no device
-- is attached to both, to two nodes, to two edges, or to two utilities. Every
-- one of the six flow meters is named after the DOWNSTREAM node of its edge:
--
--     FLO-02  Clarifier WTP 1        WTP1_RAW -> WTP1_CLR
--     FLO-03  Clarifier WTP 2        WTP2_RAW -> WTP2_CLR
--     FLO-01  Flow Meter Softener 1  WTP1_CLR -> WTP1_SOFT_1
--     FLO-04  Tank Softener-3        WTP2_CLR -> WTP2_SOFT_3
--     FLO-05  Tank Softener-4        WTP2_CLR -> WTP2_SOFT_4
--     FLO-06  Tank Softener-5        WTP2_CLR -> WTP2_SOFT_5
--
-- Six out of six. Whoever named these thinks of a flow meter as "the meter for
-- the thing downstream", so to_node_id is the convention already in use, not a
-- convention imposed here.
--
-- This does NOT resolve the open question in §10.2 rule 4 -- whether a meter
-- physically sits on a vessel's inlet or outlet pipe is in the P&ID and not in
-- this database, and it changes which node owns the loss between them. The
-- resolver's choice is about which node to hand to a traversal, not about where
-- the instrument is welded. v_device_attachment exposes edge_id,
-- from_node_code and to_node_code so a caller that cares can decide otherwise.
--
-- ---------------------------------------------------------------------------
-- THE (ip_address, slave_id) KEY NEEDS NORMALISING ON BOTH SIDES
--
-- As found on live valkyrie, that pair is not usable as typed:
--
--   * 90 of tenant 3's 105 active devices store the IP with a /32 suffix and 15
--     without -- and BOTH spellings exist for the same physical gateway.
--     192.168.20.13 (2 devices) and 192.168.20.13/32 (12 devices) are one data
--     concentrator. Same for .14, .15, .16, .17, .19 and .20. Tenant 4 uses no
--     suffix at all. An engineer typing 192.168.20.13 finds 2 of the 14 devices
--     on that gateway and no error.
--   * slave_id is a JSON number on 146 devices and a JSON string on 2 (140,
--     141), which also carry `port` as a string.
--
-- Section 2 normalises the stored values; section 4 normalises the lookup
-- anyway. Both are needed and neither is redundant: `wages_sync export` writes
-- dc_ip_address back out to CSV, and /32 is how a gateway presents itself in
-- its own configuration, so the drift returns on the next hand-edited sync.
-- The third leg -- a normalising coercer at ingest -- is in ../prs_diags/scripts/wages_sync.py.
--
-- Rewriting these values is safe because nothing reads them: wages_sync writes
-- metadata, the taxonomy CSV exports display it, and migrate_device54_to_161
-- rewrites it. No query in this repository joins or filters on it. NOT verified
-- from here: the Modbus collector is outside this repository. If it reads
-- devices.metadata for its poll targets then section 1 redirects a poll; if it
-- does not, section 1 corrects the record only.

BEGIN;

-- ============================================================================
-- 1. Data corrections
--
-- Devices 53 and 158 are the same physical meter across a May 2026
-- repositioning, the same shape as the 54 -> 161 relocation. Both rows claim
-- 192.168.20.15 slave 53, which is the only duplicate of that pair anywhere in
-- the table once the /32 spelling is normalised away.
--
--   53  COMP-04  Compressor Turbo 300HP  created 2025-08-20, attached to nothing
--   158 MC303-2  MC303 Baru              created 2026-05-21, attached to MC303_BARU
--
-- 53 is superseded and becomes OFFLINE -- the first non-ONLINE row in the
-- table; all 148 devices are ONLINE today, so this column has never been
-- maintained and nothing reads it.
--
-- 158 keeps ONLINE. It is the current, correctly installed device. Its Modbus
-- poll is failing at the time of writing, but reachability is a collector-layer
-- fact and this column is the device record, not a liveness signal.
--
-- 158's gateway is wrong: the slave address 53 is correct, the concentrator is
-- 192.168.20.17 and not .15. Gateway .17 currently holds slaves 52, 66, 67, 68,
-- 69 and 97 -- no 53 -- so the correction collides with nothing and dissolves
-- the .15/53 duplicate in the same statement.
--
-- Both UPDATEs match on device_code as well as id, so a stale id cannot
-- silently rewrite some other device, and both are no-ops on a re-run.
-- ============================================================================

UPDATE public.devices
   SET status = 'OFFLINE'
 WHERE id = 53 AND tenant_id = 3 AND device_code = 'COMP-04'
   AND status IS DISTINCT FROM 'OFFLINE';

UPDATE public.devices
   SET metadata = jsonb_set(metadata, '{data_concentrator,ip_address}',
                            to_jsonb('192.168.20.17'::text))
 WHERE id = 158 AND tenant_id = 3 AND device_code = 'MC303-2'
   AND metadata->'data_concentrator'->>'ip_address' IS DISTINCT FROM '192.168.20.17';

-- ============================================================================
-- 2. Normalisation of devices.metadata->'data_concentrator'
--
-- (i)   ip_address: drop the CIDR-style suffix. 90 rows on tenant 3.
-- (ii)  slave_id:   JSON string -> JSON number. 2 rows (140, 141).
-- (iii) port:       JSON string -> JSON number. Same 2 rows.
--
-- (ii) and (iii) are guarded by a digits-only regexp, so a value that is not a
-- plain integer is left alone rather than failing the migration. Every one of
-- these is idempotent: a second run matches no rows.
-- ============================================================================

UPDATE public.devices
   SET metadata = jsonb_set(metadata, '{data_concentrator,ip_address}',
                            to_jsonb(split_part(metadata->'data_concentrator'->>'ip_address', '/', 1)))
 WHERE metadata->'data_concentrator'->>'ip_address' LIKE '%/%';

UPDATE public.devices
   SET metadata = jsonb_set(metadata, '{data_concentrator,slave_id}',
                            to_jsonb((metadata->'data_concentrator'->>'slave_id')::integer))
 WHERE jsonb_typeof(metadata->'data_concentrator'->'slave_id') = 'string'
   AND metadata->'data_concentrator'->>'slave_id' ~ '^[0-9]+$';

UPDATE public.devices
   SET metadata = jsonb_set(metadata, '{data_concentrator,port}',
                            to_jsonb((metadata->'data_concentrator'->>'port')::integer))
 WHERE jsonb_typeof(metadata->'data_concentrator'->'port') = 'string'
   AND metadata->'data_concentrator'->>'port' ~ '^[0-9]+$';

-- ============================================================================
-- 3. graph.v_device_attachment -- where is this device, including "nowhere"
--
-- One row per active device per distinct attachment. LEFT JOIN, so a device
-- with no measurement still appears, with attachment and node_code NULL: the
-- point of the view is that "device 53 is attached to nothing" is an ANSWER,
-- not an empty result set.
--
-- graph.measurement holds one row per quantity -- 888 rows across 104 devices,
-- ~9 per device from the quantity_rule fan-out -- so the DISTINCT in `att` is
-- what collapses that to attachment grain. Without it every device would appear
-- nine times.
--
-- node_code is the RESOLVED node: the node itself when node-attached, the edge's
-- to_node when edge-attached. Section 4 reads this column, so the view and the
-- resolvers cannot drift apart -- the rule is written once, here.
--
-- dc_ip_address and dc_slave_id are lifted out of the JSONB and normalised, so
-- `WHERE dc_ip_address = '192.168.20.13'` behaves after section 2 and would
-- still behave if a /32 crept back in.
--
-- DROP first: CREATE OR REPLACE VIEW cannot change a column list, so a re-run
-- against an earlier definition of this view would otherwise fail.
-- ============================================================================

DROP VIEW IF EXISTS graph.v_device_attachment;
CREATE VIEW graph.v_device_attachment AS
WITH att AS (
    SELECT DISTINCT m.tenant_id, m.device_id, m.node_id, m.edge_id,
           m.utility_code, m.effective_from, m.effective_to
    FROM graph.measurement m
    WHERE m.is_active
)
SELECT d.tenant_id,
       d.id                AS device_id,
       d.device_code,
       d.device_name,
       d.device_type,
       d.status,
       split_part(d.metadata->'data_concentrator'->>'ip_address', '/', 1) AS dc_ip_address,
       btrim(d.metadata->'data_concentrator'->>'slave_id')                AS dc_slave_id,
       CASE WHEN a.node_id IS NOT NULL THEN 'NODE'
            WHEN a.edge_id IS NOT NULL THEN 'EDGE'
       END                 AS attachment,
       COALESCE(n.node_code,  nt.node_code)  AS node_code,
       COALESCE(n.node_name,  nt.node_name)  AS node_name,
       COALESCE(n.node_class, nt.node_class) AS node_class,
       a.edge_id,
       e.edge_class,
       nf.node_code        AS from_node_code,
       nt.node_code        AS to_node_code,
       a.utility_code,
       a.effective_from,
       a.effective_to
FROM public.devices d
LEFT JOIN att a
       ON a.device_id = d.id AND a.tenant_id = d.tenant_id
LEFT JOIN graph.node n
       ON n.id = a.node_id AND n.is_active
LEFT JOIN graph.edge e
       ON e.id = a.edge_id AND e.is_active
LEFT JOIN graph.node nf
       ON nf.id = e.from_node_id AND nf.is_active
LEFT JOIN graph.node nt
       ON nt.id = e.to_node_id AND nt.is_active
WHERE d.is_active;

COMMENT ON VIEW graph.v_device_attachment IS
  'Every active device and where it sits in the graph. Unattached devices are '
  'listed with attachment and node_code NULL. node_code resolves an '
  'edge-attached device to the edge''s to_node; from_node_code/to_node_code '
  'expose both endpoints. dc_ip_address/dc_slave_id are normalised.';

-- ============================================================================
-- 4. The resolvers
--
-- STABLE and plpgsql -- plpgsql only because RAISE is the whole point. No temp
-- tables, so like the 016 primitives these are safe to call from a read-only
-- role in a read-only transaction.
--
-- p_utility_code narrows a device attached across two networks. No device on
-- tenant 3 is, today; the parameter is what the ambiguity message tells the
-- caller to reach for when one eventually is.
--
-- p_as_of filters the measurement's effective window, so the answer reflects
-- what was attached on that date. All 888 measurement rows currently run
-- -infinity..NULL, so this is inert today and correct the day it is not.
-- ============================================================================

CREATE OR REPLACE FUNCTION graph.node_code_of_device(
    p_tenant_id    INTEGER,
    p_device_id    INTEGER,
    p_utility_code VARCHAR DEFAULT NULL,
    p_as_of        DATE    DEFAULT CURRENT_DATE
) RETURNS VARCHAR LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_dev    RECORD;
    v_codes  VARCHAR[];
    -- Folded into a variable because plpgsql reads two adjacent %% as one
    -- escaped literal percent, so the date and this note cannot sit side by side.
    v_util   TEXT := CASE WHEN p_utility_code IS NULL THEN ''
                          ELSE ' on utility ' || p_utility_code END;
BEGIN
    SELECT d.device_code, d.device_name INTO v_dev
    FROM public.devices d
    WHERE d.id = p_device_id AND d.tenant_id = p_tenant_id AND d.is_active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'device id % is not an active device of tenant %',
                        p_device_id, p_tenant_id
              USING HINT = 'SELECT * FROM graph.v_device_attachment WHERE tenant_id = '
                           || p_tenant_id;
    END IF;

    SELECT array_agg(DISTINCT v.node_code) INTO v_codes
    FROM graph.v_device_attachment v
    WHERE v.tenant_id = p_tenant_id
      AND v.device_id = p_device_id
      AND v.node_code IS NOT NULL
      AND (p_utility_code IS NULL OR v.utility_code = p_utility_code)
      AND v.effective_from <= p_as_of
      AND (v.effective_to IS NULL OR v.effective_to >= p_as_of);

    IF v_codes IS NULL THEN
        RAISE EXCEPTION 'device % (% / %) is not attached to the graph% as of %',
                        p_device_id, v_dev.device_code, v_dev.device_name,
                        v_util, p_as_of
              USING HINT = 'The device exists but has no active graph.measurement row. '
                           'This is not the same as a node with no neighbours.';
    END IF;

    IF array_length(v_codes, 1) > 1 THEN
        RAISE EXCEPTION 'device % (%) resolves to % nodes: %',
                        p_device_id, v_dev.device_code,
                        array_length(v_codes, 1), array_to_string(v_codes, ', ')
              USING HINT = 'Pass p_utility_code if the attachments are on different '
                           'networks; otherwise inspect '
                           'graph.v_device_attachment and pick a node explicitly.';
    END IF;

    RETURN v_codes[1];
END;
$$;

COMMENT ON FUNCTION graph.node_code_of_device(INTEGER, INTEGER, VARCHAR, DATE) IS
  'The node_code a device is attached to, for feeding graph.descendants/'
  'ancestors/siblings. Edge-attached devices resolve to the edge''s to_node. '
  'Raises rather than returning NULL when the device is missing, unattached, '
  'or ambiguous.';

CREATE OR REPLACE FUNCTION graph.node_code_of_dc(
    p_tenant_id    INTEGER,
    p_ip_address   VARCHAR,
    p_slave_id     INTEGER,
    p_utility_code VARCHAR DEFAULT NULL,
    p_as_of        DATE    DEFAULT CURRENT_DATE
) RETURNS VARCHAR LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ip     VARCHAR := split_part(btrim(p_ip_address), '/', 1);
    v_ids    INTEGER[];
    v_codes  VARCHAR[];
BEGIN
    SELECT array_agg(DISTINCT v.device_id) INTO v_ids
    FROM graph.v_device_attachment v
    WHERE v.tenant_id = p_tenant_id
      AND v.dc_ip_address = v_ip
      AND v.dc_slave_id   = p_slave_id::text;

    IF v_ids IS NULL THEN
        RAISE EXCEPTION 'no active device of tenant % at % slave %',
                        p_tenant_id, v_ip, p_slave_id
              USING HINT = 'The IP is matched with any /prefix stripped. '
                           'SELECT dc_ip_address, dc_slave_id, device_code FROM '
                           'graph.v_device_attachment WHERE tenant_id = '
                           || p_tenant_id || ' ORDER BY 1, 2';
    END IF;

    IF array_length(v_ids, 1) > 1 THEN
        RAISE EXCEPTION '% slave % maps to % devices: %',
                        v_ip, p_slave_id, array_length(v_ids, 1),
                        array_to_string(v_ids, ', ')
              USING HINT = 'Two device rows claim one physical instrument. '
                           'Resolve the duplicate, or call '
                           'graph.node_code_of_device with the intended id.';
    END IF;

    -- Delegates, so the missing/unattached/ambiguous messages are written once.
    RETURN graph.node_code_of_device(p_tenant_id, v_ids[1], p_utility_code, p_as_of);
END;
$$;

COMMENT ON FUNCTION graph.node_code_of_dc(INTEGER, VARCHAR, INTEGER, VARCHAR, DATE) IS
  'The node_code for the device at a data concentrator IP and Modbus slave '
  'address. The IP is matched with any /prefix stripped. Raises rather than '
  'returning NULL.';

-- ============================================================================
-- 5. Grants. Same guard as 016: 010 already sets ALTER DEFAULT PRIVILEGES for
-- this schema, so this only matters when 021 is applied by a different role
-- than 010 was, and it must not fail on a cluster with no grafReader.
-- ============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafReader') THEN
        EXECUTE 'GRANT SELECT ON graph.v_device_attachment TO "grafReader"';
        EXECUTE 'GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA graph TO "grafReader"';
    END IF;
END $$;

COMMIT;

-- ============================================================================
-- Verification -- all read-only, all runnable as grafReader.
-- ============================================================================
--
-- Sections 1-2 took effect:
--   SELECT id, device_code, status, metadata->'data_concentrator' AS dc
--     FROM public.devices WHERE id IN (53, 158) ORDER BY id;
--   -- expect 53 OFFLINE; 158 ONLINE at 192.168.20.17 slave 53
--
--   SELECT count(*) FROM public.devices
--    WHERE metadata->'data_concentrator'->>'ip_address' LIKE '%/%';   -- expect 0
--   SELECT count(*) FROM public.devices
--    WHERE jsonb_typeof(metadata->'data_concentrator'->'slave_id') = 'string'; -- expect 0
--
-- The (ip, slave) key is now unique per tenant:
--   SELECT tenant_id, dc_ip_address, dc_slave_id, count(DISTINCT device_id) n
--     FROM graph.v_device_attachment
--    GROUP BY 1, 2, 3 HAVING count(DISTINCT device_id) > 1;           -- expect 0 rows
--
-- Attachment shape (expect: Flow Meter 6 EDGE, Power Meter 98 NODE + 1 NULL on
-- tenant 3; 43 NULL on tenant 4):
--   SELECT tenant_id, device_type, attachment, count(DISTINCT device_id)
--     FROM graph.v_device_attachment GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
--
-- Round trip through both resolvers and into 016:
--   SELECT graph.node_code_of_device(3, 158);                 -- MC303_BARU
--   SELECT graph.node_code_of_dc(3, '192.168.20.17', 53);     -- MC303_BARU
--   SELECT graph.node_code_of_dc(3, '192.168.20.17/32', 53);  -- MC303_BARU (suffix ignored)
--   SELECT graph.node_code_of_device(3, 95);                  -- WTP1_CLR (edge -> to_node)
--   SELECT * FROM graph.ancestors(3, graph.node_code_of_device(3, 158), 'ELECTRICITY')
--    ORDER BY depth;
--
-- The three raises, each of which SHOULD error:
--   SELECT graph.node_code_of_device(3, 53);      -- exists, attached to nothing
--   SELECT graph.node_code_of_device(3, 99999);   -- no such device
--   SELECT graph.node_code_of_dc(3, '10.0.0.1', 1);
