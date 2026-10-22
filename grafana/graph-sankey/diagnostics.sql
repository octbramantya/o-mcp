-- graph.sankey_diagnostics for a table panel beside the sankey. Setup: README.md.
-- Same days as sankey.sql. What the diagram can't show: negative residuals (meters reading less
-- than what they feed), silent meters, reverse energy, Unassigned energy, estimated flows.
SELECT kind, node_code, round(value) AS value, detail
FROM graph.sankey_diagnostics(
    3,
    (to_timestamp($__from / 1000.0) AT TIME ZONE 'Asia/Jakarta')::date,
    (to_timestamp(($__to - 1) / 1000.0) AT TIME ZONE 'Asia/Jakarta')::date
)
ORDER BY CASE kind WHEN 'NEGATIVE_RESIDUAL' THEN 1 WHEN 'NEGATIVE_FLOW' THEN 2 WHEN 'NO_DATA' THEN 3
                   WHEN 'REVERSE_ENERGY' THEN 4 WHEN 'UNASSIGNED' THEN 5 ELSE 6 END,
         abs(value) DESC NULLS LAST, node_code;
