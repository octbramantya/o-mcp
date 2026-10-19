-- Migration: 055_sippa_under_wwtp.sql
-- Description: SIPPA is fed from the WWTP panel, not directly from FINISHING_22 (documentation
--              correction); WWTP retyped PUMP -> SUB_BOARD so it can feed.
-- Author: Claude
-- Date: 2026-10-19
-- Design: design/graph-sankey.md §10 (054 diagnostics: FINISHING_22 NEGATIVE_RESIDUAL)
-- Requires: 054_graph_sankey.sql
--
-- WHY
-- ---
-- graph.sankey_diagnostics returned FINISHING_22 as a NEGATIVE_RESIDUAL of -9,641 kWh in September
-- 2026: its meter (5) read 76,848 and SIPPA (138) + WWTP (139) below it 86,489. The 15-minute data
-- on dev showed SIPPA's load inside meter 139: over the 31 times SIPPA stepped by more than 10 kW,
-- 139 stepped by 0.95 x SIPPA's step in the same interval (r = 0.85), and the per-phase currents
-- rose by the same 45-52 A. The residual was negative only on days SIPPA ran. The user's SLD
-- (2026-10-19) agrees: FINISHING_22 feeds GARUK and WWTP, and WWTP feeds SIPPA. The graph had
-- SIPPA fed from FINISHING_22 (edge FINISHING_22 -> SIPPA).
--
-- The plant did not change; the drawing was wrong. So the old edge gets effective_to = '-infinity'
-- and WWTP -> SIPPA starts at '-infinity', as in 052.
--
-- WWTP was typed PUMP (class LOAD), and SUPPLY_LV only leaves a board, so the new edge needs WWTP
-- to be a board. On the SLD it feeds SIPPA through a 630 A main breaker: it is a panel. It becomes
-- SUB_BOARD (class BUS), like FINISHING_22, decided by the user on 2026-10-19. SUB_BOARD requires
-- main_breaker_a (already 630) and nominal_v: set to 400, as on FINISHING_22; meter 139 reads
-- 226 V line-to-neutral. Node types have no history, so the retype is in place (as 047 did for
-- labels). WWTP keeps its id, meter 139 and its explicit GARUK category row.
--
-- Effect: no metered value changes. WWTP's own value becomes 139 - 138 (the WWTP plant's load,
-- 59,003 in September) and FINISHING_22's becomes 5 - 139 (+4,102, GARUK and the rest). Garuk is
-- drawn at 76,848 = meter 5 instead of 86,489. Section 2.3 solves September before and after and
-- aborts if any node value moves, or any own value other than FINISHING_22's and WWTP's.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 FINISHING_22 and WWTP children, today ==='
SELECT f.node_code AS parent, string_agg(t.node_code, ', ' ORDER BY t.node_code) AS children
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active AND e.effective_from <= CURRENT_DATE
  AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)
  AND f.node_code IN ('FINISHING_22', 'WWTP')
GROUP BY 1 ORDER BY 1;
-- expect FINISHING_22: GARUK, SIPPA, WWTP (and nothing under WWTP)

\echo ''
\echo '=== 1.2 WWTP ==='
SELECT node_code, node_class, node_type, attrs FROM graph.node WHERE tenant_id = 3 AND node_code = 'WWTP';
-- expect LOAD, PUMP, {"main_breaker_a": 630}


-- ============================================================================
-- 2. The change
-- ============================================================================

BEGIN;

CREATE TEMP TABLE _sippa ON COMMIT DROP AS
SELECT e.*
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id AND f.node_code = 'FINISHING_22'
JOIN graph.node t ON t.id = e.to_node_id   AND t.node_code = 'SIPPA'
WHERE e.tenant_id = 3 AND e.is_active;

DO $$
BEGIN
    IF (SELECT count(*) FROM _sippa) <> 1
       OR NOT EXISTS (SELECT 1 FROM _sippa WHERE effective_from = '-infinity' AND effective_to IS NULL
                                             AND edge_type = 'SUPPLY_LV' AND utility_code = 'ELECTRICITY') THEN
        RAISE EXCEPTION '055: expected one open SUPPLY_LV edge FINISHING_22 -> SIPPA from -infinity';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM graph.node WHERE tenant_id = 3 AND node_code = 'WWTP'
                   AND node_class = 'LOAD' AND node_type = 'PUMP'
                   AND attrs = '{"main_breaker_a": 630}'::jsonb) THEN
        RAISE EXCEPTION '055: WWTP is not the PUMP node with main_breaker_a 630 this migration expects';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.edge e JOIN graph.node f ON f.id = e.from_node_id
               WHERE f.tenant_id = 3 AND f.node_code = 'WWTP') THEN
        RAISE EXCEPTION '055: WWTP already has out-edges';
    END IF;
    IF EXISTS (SELECT 1 FROM graph.measurement m JOIN _sippa s ON s.id = m.edge_id) THEN
        RAISE EXCEPTION '055: the edge being retired carries a meter; move it explicitly';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 2.1 Capture September before
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _res (ver text, q int, kind text, code text, value numeric) ON COMMIT DROP;

CREATE FUNCTION pg_temp.capture(p_ver text) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE q int;
BEGIN
    FOREACH q IN ARRAY ARRAY[124, 89] LOOP
        PERFORM graph.solve_flow(3, 'ELECTRICITY', '2026-09-01', '2026-09-30', q, false,
                                 ARRAY['SHIFT1','SHIFT2','SHIFT3'], '2026-09-30');
        INSERT INTO _res SELECT p_ver, q, 'node', n.node_code, n.value FROM _gn n;
        INSERT INTO _res SELECT DISTINCT p_ver, q, 'own', s.node_code, s.own
        FROM graph.sankey_nodes(3, '2026-09-01', '2026-09-30', p_quantity_id => q) s;
    END LOOP;
END $f$;

SELECT pg_temp.capture('before');

-- ---------------------------------------------------------------------------
-- 2.2 Retype WWTP, retire the old feed, add the right one
-- ---------------------------------------------------------------------------
UPDATE graph.node SET node_class = 'BUS', node_type = 'SUB_BOARD',
                      attrs = attrs || '{"nominal_v": 400}'::jsonb
WHERE tenant_id = 3 AND node_code = 'WWTP';

UPDATE graph.edge e SET effective_to = '-infinity' FROM _sippa s WHERE e.id = s.id;

INSERT INTO graph.edge (tenant_id, from_node_id, to_node_id, utility_code, edge_class, edge_type,
                        attrs, is_active, effective_from, effective_to)
SELECT 3, p.id, c.id, 'ELECTRICITY', 'FEEDER', 'SUPPLY_LV', '{}'::jsonb, TRUE, '-infinity', NULL
FROM graph.node p, graph.node c
WHERE p.tenant_id = 3 AND p.node_code = 'WWTP'
  AND c.tenant_id = 3 AND c.node_code = 'SIPPA';

-- ---------------------------------------------------------------------------
-- 2.3 Post-condition: node values unchanged; own values move only on FINISHING_22 and WWTP
-- ---------------------------------------------------------------------------
SELECT pg_temp.capture('after');

DO $$
DECLARE
    n INT;
BEGIN
    IF (SELECT count(*) FROM _res WHERE ver = 'before') <> (SELECT count(*) FROM _res WHERE ver = 'after') THEN
        RAISE EXCEPTION '055: the solver returned a different set of rows';
    END IF;
    SELECT count(*) INTO n
    FROM _res b JOIN _res a ON a.ver = 'after' AND a.q = b.q AND a.kind = b.kind AND a.code = b.code
    WHERE b.ver = 'before' AND abs(a.value - b.value) >= 0.5
      AND (b.kind = 'node' OR b.code NOT IN ('FINISHING_22', 'WWTP'));
    IF n <> 0 THEN
        RAISE EXCEPTION '055: % values changed outside FINISHING_22''s and WWTP''s own values', n;
    END IF;
    IF EXISTS (SELECT 1 FROM _res WHERE ver = 'after' AND q = 124 AND kind = 'own'
               AND code IN ('FINISHING_22', 'WWTP') AND value < -0.5) THEN
        RAISE EXCEPTION '055: FINISHING_22 or WWTP still has a negative own value';
    END IF;
    IF (SELECT count(*) FROM graph.v_edge_gaps) <> 0 THEN
        RAISE EXCEPTION '055: graph.v_edge_gaps is not empty';
    END IF;
END
$$;

\echo ''
\echo '=== 2.3 What moved (September 2026) ==='
SELECT b.q, b.kind, b.code, round(b.value) AS before, round(a.value) AS after
FROM _res b JOIN _res a ON a.ver = 'after' AND a.q = b.q AND a.kind = b.kind AND a.code = b.code
WHERE b.ver = 'before' AND abs(a.value - b.value) >= 0.5
ORDER BY 1, 2, 3;
-- on dev, 124: FINISHING_22 own -9,641 -> 4,102; WWTP own 72,746 -> 59,003

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 FINISHING_22 and WWTP children, after ==='
SELECT f.node_code AS parent, string_agg(t.node_code, ', ' ORDER BY t.node_code) AS children
FROM graph.edge e
JOIN graph.node f ON f.id = e.from_node_id
JOIN graph.node t ON t.id = e.to_node_id
WHERE e.tenant_id = 3 AND e.is_active AND e.effective_from <= CURRENT_DATE
  AND (e.effective_to IS NULL OR e.effective_to >= CURRENT_DATE)
  AND f.node_code IN ('FINISHING_22', 'WWTP')
GROUP BY 1 ORDER BY 1;
-- expect FINISHING_22: GARUK, WWTP
--        WWTP: SIPPA

\echo ''
\echo '=== 3.2 Property gaps on WWTP ==='
SELECT attr_key, status FROM graph.v_property_gaps WHERE node_code = 'WWTP';
-- expect no MISSING row


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- DELETE FROM graph.edge e USING graph.node p, graph.node c
--  WHERE p.id = e.from_node_id AND c.id = e.to_node_id AND e.tenant_id = 3
--    AND p.node_code = 'WWTP' AND c.node_code = 'SIPPA';
-- UPDATE graph.edge e SET effective_to = NULL FROM graph.node p, graph.node c
--  WHERE p.id = e.from_node_id AND c.id = e.to_node_id AND e.tenant_id = 3
--    AND p.node_code = 'FINISHING_22' AND c.node_code = 'SIPPA' AND e.effective_to = '-infinity';
-- UPDATE graph.node SET node_class = 'LOAD', node_type = 'PUMP', attrs = attrs - 'nominal_v'
--  WHERE tenant_id = 3 AND node_code = 'WWTP';
-- COMMIT;
