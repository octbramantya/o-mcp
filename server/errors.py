"""Errors a model can act on. Returned as a tool result with isError and the message as is; every
other exception is logged in full and answered with one generic sentence (design/mcp-server.md §5)."""


class ToolError(Exception):
    pass
