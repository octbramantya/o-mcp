"""The plant queries, shared by the MCP server (server/) and the frontend's API (api/), so the two
never give different answers (design/frontend.md §9): time windows, node resolution, the vocabulary,
and solving a value over a window that the plant may change inside."""
