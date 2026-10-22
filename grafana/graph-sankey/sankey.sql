-- graph.sankey for the Business Charts panel (sankey.js). Setup: README.md.
--
-- graph.sankey works in whole days, site time, with an inclusive end date. The Grafana range is
-- turned into the days it touches in Asia/Jakarta; one millisecond comes off $__to so a range
-- ending at midnight doesn't pull in the next day. A range shorter than a day draws that whole day.
-- No ORDER BY: the function's row order is the layout order (Supply, then the category tree).
SELECT source, target, value, color, link_kind, is_ambiguous
FROM graph.sankey(
    3,                                                                    -- tenant
    (to_timestamp($__from / 1000.0) AT TIME ZONE 'Asia/Jakarta')::date,   -- first day
    (to_timestamp(($__to - 1) / 1000.0) AT TIME ZONE 'Asia/Jakarta')::date, -- last day, inclusive
    p_node_detail => ${node_detail}
);
