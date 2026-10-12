-- Migration: 045_process_heater_description.sql
-- Description: Describe PROCESS_HEATER generically, without tenant 3's heaters.
-- Author: Claude
-- Date: 2026-10-12
-- Design: design/mcp-tenancy.md §5 (shared vocabulary describes types, never one tenant's plant)
-- Requires: 044_tenant_agent_role.sql
--
-- WHY
-- ---
-- graph.node_type is shared by every tenant, and every tenant's agent reads its descriptions.
-- PROCESS_HEATER's, from 030 (tools/gen_030.py), ended "The ten Texture heaters sit under
-- HEATER_TOTAL": tenant 3's plant, not the type. The new text keeps what is general in that
-- sentence: heaters fed together hang under a board of their own (HEATER_TOTAL is a SUB_BOARD
-- with ten PROCESS_HEATER children), which carries their total. Whether one node is one heater
-- or a machine's heater bank is not known, so it is not said.
--
-- One description only; no type, class, property or node changes. tools/gen_030.py still
-- holds the 030 text, which is what ran; it no longer overwrites 030.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Evidence (read-only)
-- ============================================================================

\echo ''
\echo '=== 1.1 The description being replaced ==='
SELECT code, node_class, description FROM graph.node_type WHERE code = 'PROCESS_HEATER';
-- expect LOAD, "Electric heater serving a process line, not space heating. The ten Texture
-- heaters sit under HEATER_TOTAL."


-- ============================================================================
-- 2. Change
-- ============================================================================

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM graph.node_type
        WHERE code = 'PROCESS_HEATER' AND node_class = 'LOAD'
          AND description = 'Electric heater serving a process line, not space heating. The ten Texture heaters sit under HEATER_TOTAL.'
    ) THEN
        RAISE EXCEPTION '045: PROCESS_HEATER does not have the description 030 wrote; check what changed it';
    END IF;
END $$;

UPDATE graph.node_type
SET description = 'Electric heater serving a production process, not space heating. Heaters fed together usually hang under a board of their own (a SUB_BOARD), which carries their combined consumption; the heaters are its children.'
WHERE code = 'PROCESS_HEATER';

COMMIT;


-- ============================================================================
-- 3. Verification (read-only)
-- ============================================================================

\echo ''
\echo '=== 3.1 No shared description names a node of any tenant ==='
SELECT t.code, n.node_code FROM graph.node_type t
JOIN graph.node n ON t.description ~ ('\m' || n.node_code || '\M');
-- expect 0 rows

\echo ''
\echo '=== 3.2 Nothing else moved ==='
SELECT count(*) AS types, count(*) FILTER (WHERE is_abstract) AS abstract FROM graph.node_type;
-- expect 27 types, 2 abstract


-- ============================================================================
-- 4. Undo (commented)
-- ============================================================================
--
-- BEGIN;
-- UPDATE graph.node_type SET description = 'Electric heater serving a process line, not space heating. The ten Texture heaters sit under HEATER_TOTAL.'
-- WHERE code = 'PROCESS_HEATER';
-- COMMIT;
