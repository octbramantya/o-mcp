-- Migration: 013_fix_quantity_is_cumulative.sql
-- Description: Align public.quantities.is_cumulative with graph.quantity_rule
-- Author: Claude
-- Date: 2026-08-19
-- Phase: 3 (see §12.3 and §12.4 of design/graph-network-design.md)
-- Status: APPLIED to valkyrie on 2026-08-19. Section 2 is still commented out
--         below (the change was made out of band), so re-running this file is
--         read-only and simply re-prints the evidence. Section 3 returns zero
--         rows, which is the confirmation that it took.
--
-- ###########################################################################
-- # READ THIS BEFORE RUNNING
-- #
-- # This is the ONLY migration in the graph series that writes to a table the
-- # legacy path also reads: public.quantities.
-- #
-- # BLAST RADIUS -- corrected 2026-08-19 after tracing it on live.
-- #
-- # The energy chain does NOT read is_cumulative at any point:
-- #
-- #   telemetry_15min_agg                 continuous aggregate
-- #     -> telemetry_intervals_cumulative VIEW, hard-codes the cumulative
-- #                                       LAG-diff for a fixed quantity array
-- #                                       [62,89,96,124,130,131,481]
-- #       -> refresh_daily_energy_costs() the only writer
-- #         -> daily_energy_cost_summary  TABLE
-- #           -> graph.device_totals      routes on graph.quantity_rule
-- #
-- # telemetry_intervals_water is likewise a plain view with cumulative
-- # semantics baked in. So this migration changes NOTHING in the Sankey, the
-- # graph, or the cost summary, and carries no risk of a discontinuity at the
-- # date it is applied.
-- #
-- # What it does change is the three user-facing telemetry functions, the only
-- # objects in the database that reference the column:
-- #
-- #   public.get_bucketed_telemetry_for_user     (two overloads)
-- #   public.get_telemetry_aggregation_for_user
-- #   public.get_unified_telemetry_for_user
-- #
-- # Check the dashboard against those before running section 2. The value of
-- # this migration is that the two declarations of "is this a totaliser" --
-- # public.quantities.is_cumulative and graph.quantity_rule.raw_time_agg --
-- # stop disagreeing. Section 3 is what proves they agree.
-- #
-- # WHAT THE EVIDENCE ACTUALLY SHOWS
-- #
-- # These three rows are cumulative totalisers flagged as non-cumulative.
-- # They are NOT monotonic. Over 30 days to 2026-08-19, section 1 returns:
-- #
-- #     131   226,270 samples   480 decreases   7 devices
-- #     481   165,407 samples   697 decreases   9 devices
-- #    5696    16,860 samples     0 decreases
-- #
-- # That still supports the classification -- a per-interval register would
-- # decrease roughly half the time, not 0.2% of it -- but "only ever increases"
-- # was wrong. Most drops are zero-magnitude float jitter (smallest_drop 0.000,
-- # and six of the eight affected devices have max_drop 0.0). Two are genuine
-- # counter resets:
-- #
-- #   device 55  "MC 9"     481: 391 drops, largest 93,606, resetting to 0.0
-- #   device 27  "PLTS A"   481: drops 1,756,259 -> 1.0;  131: reaches -3.9
-- #
-- # There are also two NaN buckets: device 103 "MC 3", 2026-07-28 01:45, on
-- # both 131 and 481. 017 hardens graph.device_totals against both hazards;
-- # they are recorded here because section 1 is where they surface.
-- #
-- # Run section 1 FIRST and read it. Only then run section 2.
-- ###########################################################################

-- ============================================================================
-- 1. Evidence -- read-only.
--
-- A totaliser decreases rarely and for a reason; a per-interval register
-- decreases about half the time. Expect a decrease RATE well under 1%, not a
-- count of zero, and read the magnitudes: a drop of 0.000 is float jitter, a
-- drop of 93,606 to a value of 0.0 is a counter reset.
-- ============================================================================

SELECT 'Monotonicity check (expect a decrease rate well under 1%, not zero)' AS check_name;
WITH s AS (
    SELECT t.quantity_id, t.device_id, t.bucket, t.aggregated_value AS v,
           LAG(t.aggregated_value) OVER (PARTITION BY t.device_id, t.quantity_id
                                             ORDER BY t.bucket) AS prev
    FROM public.telemetry_15min_agg t
    WHERE t.tenant_id = 3
      AND t.quantity_id IN (131, 481, 5696)
      AND t.bucket >= NOW() - INTERVAL '30 days'
)
SELECT s.quantity_id, q.quantity_name,
       COUNT(*)                                        AS samples,
       COUNT(*) FILTER (WHERE s.v < s.prev)            AS decreases,
       MIN(s.v)                                        AS min_value,
       MAX(s.v)                                        AS max_value
FROM s JOIN public.quantities q ON q.id = s.quantity_id
GROUP BY 1, 2 ORDER BY 1;

SELECT 'Current flags' AS check_name;
SELECT id, quantity_code, quantity_name, unit, category, aggregation_method, is_cumulative
FROM public.quantities WHERE id IN (124, 130, 131, 481, 5696) ORDER BY id;

-- ============================================================================
-- 2. The correction -- COMMENTED OUT ON PURPOSE.
--
-- Uncomment only after reading section 1 for the rows you intend to change --
-- a low decrease rate with explainable magnitudes, not a count of zero -- and
-- after confirming with whoever owns the dashboard that a change in these
-- registers' aggregation is expected in the three *_for_user functions.
--
--   131  Active Energy Received     -- §12.3, needed for net P = 124 - 131
--   481  Apparent Energy Delivered  -- §12.3
--   5696 Water Volume Supply (m3)   -- §12.4, the only WATER register in the graph
--
-- Without these, graph.quantity_rule declares DELTA while the column says the
-- register is not cumulative. graph.device_totals is unaffected either way --
-- it routes on quantity_rule, never on the column -- so this is about removing
-- a contradiction between two declarations of the same fact, not about fixing
-- a number. The drift check in section 3 is what surfaces the disagreement.
-- ============================================================================

-- BEGIN;
-- UPDATE public.quantities SET is_cumulative = TRUE WHERE id IN (131, 481);
-- UPDATE public.quantities SET is_cumulative = TRUE WHERE id = 5696;
-- COMMIT;

-- ============================================================================
-- 3. Drift check -- run any time. Every row returned is a disagreement between
--    what graph.quantity_rule assumes and what public.quantities declares.
-- ============================================================================

SELECT 'Rule vs column drift' AS check_name;
SELECT qr.quantity_id, q.quantity_name, qr.utility_code,
       qr.raw_time_agg, q.is_cumulative,
       CASE
           WHEN qr.raw_time_agg = 'DELTA' AND NOT q.is_cumulative
                THEN 'rule says DELTA, column says not cumulative'
           WHEN qr.raw_time_agg <> 'DELTA' AND q.is_cumulative
                THEN 'column says cumulative, rule does not take a delta'
       END AS drift
FROM graph.quantity_rule qr
JOIN public.quantities q ON q.id = qr.quantity_id
WHERE (qr.raw_time_agg = 'DELTA') <> q.is_cumulative
ORDER BY qr.quantity_id;
