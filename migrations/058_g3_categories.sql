-- Migration: 058_g3_categories.sql
-- Description: Category rows for the G3 worklist: every node still Unassigned after 056, except
--              meter 94's unaccounted remainder.
-- Author: Claude
-- Date: 2026-10-22
-- Design: design/graph-sankey.md §10 (G3 worklist), §4 (CHILDREN rule)
-- Requires: 057_sld_devices.sql
--
-- WHY
-- ---
-- After 056, graph.sankey drew 390,413 kWh of September 2026 as Unassigned: meter 94 beyond its
-- six feeds (200,472, a meter question, G10) and seven nodes with no category. The user decided
-- them on 2026-10-19 and 2026-10-22, from the SLD and the client's two broad classes (Production,
-- Utilities):
--
--   LVMDB_A1          FABRIC      every load on A1 is production (WJL, PKN); losses only below it
--   HEATER_5, _6, _11 HEATER      like every other heater on HEATER_TOTAL; the panel follows
--                                 HEATER_5/6 through the CHILDREN rule
--   MC_MOTOR_5        MC_MOTOR    a metered machine missing its row; MC_MOTOR_1-4, 7-12 have it
--   MC_MOTOR_6        MC_MOTOR    the same, unmetered
--   MC_SP_A, _B, _C   SPINNING    part of the spinning process
--   LVMDP_SPINNING_2  SPINNING    MC_SP_A/B/C sit under the unmetered LVSDP_SP2_1/2, and the
--                                 CHILDREN rule looks one level down, so the board needs a row
--   OFFICE_2          PRODUCTION  unmetered office feed, Production for now (as FLR_124, 056)
--   LVMDB_TF630       PRODUCTION  TWIST_PANEL, an unmetered child with no category, blocks the
--                                 CHILDREN rule, so OFFICE_2's row alone would not reach the board
--   LVMDB_B2          FABRIC      its unmetered remainder is Production / Fabric; the boiler,
--                                 Finishing 2.1, compressor and WTP_2 keep their Utilities rows
--   LABKNIT           FABRIC      Lab Knitting, Production / Fabric
--   LVMDB_TEXTURE_2   YARN        LABKNIT (Fabric) and MC_MOTOR_6 (MC Motor) disagree, so the
--                                 board's own residual takes Yarn, the Texture board's division
--
-- A row on a panel does not recolour its children: a child's own row or type default wins over
-- inheritance. Each board row classifies only the board's residual and its uncategorised nodes.
--
-- Effect (September 2026, dev): Unassigned 390,413 -> 200,472, meter 94's remainder alone;
-- Production 1,303,661 -> 1,493,602. Utilities does not move. Section 2 checks this.

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE _rows (node_code text, category_code text) ON COMMIT DROP;
INSERT INTO _rows VALUES
    ('LVMDB_A1', 'FABRIC'),
    ('HEATER_5', 'HEATER'), ('HEATER_6', 'HEATER'), ('HEATER_11', 'HEATER'),
    ('MC_MOTOR_5', 'MC_MOTOR'), ('MC_MOTOR_6', 'MC_MOTOR'),
    ('MC_SP_A', 'SPINNING'), ('MC_SP_B', 'SPINNING'), ('MC_SP_C', 'SPINNING'),
    ('LVMDP_SPINNING_2', 'SPINNING'),
    ('OFFICE_2', 'PRODUCTION'), ('LVMDB_TF630', 'PRODUCTION'),
    ('LVMDB_B2', 'FABRIC'),
    ('LABKNIT', 'FABRIC'),
    ('LVMDB_TEXTURE_2', 'YARN');

DO $$
DECLARE
    n INT;
BEGIN
    SELECT count(*) INTO n
    FROM _rows r
    JOIN graph.node n ON n.tenant_id = 3 AND n.node_code = r.node_code
                     AND n.is_active AND n.effective_from <= CURRENT_DATE
                     AND (n.effective_to IS NULL OR n.effective_to >= CURRENT_DATE)
    JOIN graph.category c ON c.tenant_id = 3 AND c.taxonomy_code = 'FUNCTIONAL'
                         AND c.category_code = r.category_code;
    IF n <> 15 THEN
        RAISE EXCEPTION '058: expected 15 nodes in effect with their categories, found %', n;
    END IF;
    IF EXISTS (SELECT 1 FROM graph.node_category nc JOIN graph.node n ON n.id = nc.node_id
               JOIN _rows r ON r.node_code = n.node_code WHERE n.tenant_id = 3) THEN
        RAISE EXCEPTION '058: a node in this migration already has a node_category row';
    END IF;
END
$$;

CREATE TEMP TABLE _res (ver text, category text, value numeric) ON COMMIT DROP;
INSERT INTO _res
SELECT 'before', target, value FROM graph.sankey(3, '2026-09-01', '2026-09-30', p_node_detail => FALSE)
WHERE link_kind = 'CATEGORY';

INSERT INTO graph.node_category (tenant_id, node_id, category_id, weight, effective_from)
SELECT 3, n.id, c.id, 1.0, '1900-01-01'
FROM _rows r
JOIN graph.node n ON n.tenant_id = 3 AND n.node_code = r.node_code
JOIN graph.category c ON c.tenant_id = 3 AND c.taxonomy_code = 'FUNCTIONAL' AND c.category_code = r.category_code;

INSERT INTO _res
SELECT 'after', target, value FROM graph.sankey(3, '2026-09-01', '2026-09-30', p_node_detail => FALSE)
WHERE link_kind = 'CATEGORY';

-- Post-conditions: Utilities and its categories don't move; Production gains what Unassigned
-- loses; the only Unassigned value left is a SOURCE's unaccounted remainder (meter 94)
DO $$
DECLARE
    n INT;
    d_prod NUMERIC;
    d_unas NUMERIC;
BEGIN
    SELECT count(*) INTO n
    FROM (SELECT category, value FROM _res WHERE ver = 'before') b
    FULL JOIN (SELECT category, value FROM _res WHERE ver = 'after') a ON a.category = b.category
    JOIN graph.v_category_tree t ON t.tenant_id = 3 AND t.taxonomy_code = 'FUNCTIONAL'
                                AND t.category_name = COALESCE(b.category, a.category)
    WHERE t.path LIKE 'SUPPLY/UTILITIES%'
      AND (a.category IS NULL OR b.category IS NULL OR abs(a.value - b.value) >= 0.5);
    IF n <> 0 THEN
        RAISE EXCEPTION '058: % Utilities categories moved', n;
    END IF;
    SELECT a.value - b.value INTO d_prod FROM _res a JOIN _res b ON b.category = a.category AND b.ver = 'before'
    WHERE a.ver = 'after' AND a.category = 'Production';
    SELECT COALESCE((SELECT value FROM _res WHERE ver = 'after' AND category = 'Unassigned'), 0)
         - COALESCE((SELECT value FROM _res WHERE ver = 'before' AND category = 'Unassigned'), 0) INTO d_unas;
    IF abs(d_prod + d_unas) >= 0.5 OR d_prod < 0.5 THEN
        RAISE EXCEPTION '058: Production moved by %, Unassigned by %', d_prod, d_unas;
    END IF;
    SELECT count(*) INTO n
    FROM graph.sankey_nodes(3, '2026-09-01', '2026-09-30') s
    WHERE s.category_how = 'UNASSIGNED' AND s.own >= 0.5 AND s.node_class <> 'SOURCE';
    IF n <> 0 THEN
        RAISE EXCEPTION '058: % nodes other than a source remainder are still Unassigned', n;
    END IF;
END
$$;

\echo ''
\echo '=== What moved (September 2026, kWh) ==='
SELECT COALESCE(b.category, a.category) AS category, round(b.value) AS before, round(a.value) AS after
FROM (SELECT category, value FROM _res WHERE ver = 'before') b
FULL JOIN (SELECT category, value FROM _res WHERE ver = 'after') a ON a.category = b.category
WHERE a.category IS NULL OR b.category IS NULL OR abs(a.value - b.value) >= 0.5
ORDER BY 1;
-- on dev: Fabric 944,024 -> 971,880; Heater 8,761 -> 9,000; MC Motor 66,727 -> 91,973;
--         Production 1,303,661 -> 1,493,602; Spinning 112,882 -> 193,747;
--         Unassigned 390,413 -> 200,472; Yarn 298,006 -> 427,918

COMMIT;


-- ============================================================================
-- Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== The G3 nodes after 058 ==='
SELECT s.node_code, round(s.own) AS own, c.category_code, s.category_how
FROM graph.sankey_nodes(3, '2026-09-01', '2026-09-30') s
LEFT JOIN graph.category c ON c.id = s.category_id
WHERE s.node_code IN ('LVMDB_A1', 'HEATER_TOTAL', 'MC_MOTOR_5', 'LVMDP_SPINNING_2', 'LVMDB_TF630',
                      'LVMDB_B2', 'LVMDB_TEXTURE_2', 'INCOMING_PLN')
ORDER BY 1;
-- expect HEATER_TOTAL by CHILDREN, INCOMING_PLN UNASSIGNED (200,472), the rest EXPLICIT

-- Undo (commented):
-- DELETE FROM graph.node_category nc USING graph.node n
--  WHERE n.id = nc.node_id AND n.tenant_id = 3
--    AND n.node_code IN ('LVMDB_A1', 'HEATER_5', 'HEATER_6', 'HEATER_11', 'MC_MOTOR_5', 'MC_MOTOR_6',
--                        'MC_SP_A', 'MC_SP_B', 'MC_SP_C', 'LVMDP_SPINNING_2', 'OFFICE_2',
--                        'LVMDB_TF630', 'LVMDB_B2', 'LABKNIT', 'LVMDB_TEXTURE_2');
