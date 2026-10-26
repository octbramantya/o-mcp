"""Errors a model can act on. Returned as a tool result with isError and the message as is; every
other exception is logged in full and answered with one generic sentence (design/mcp-server.md §5)."""

from plant.errors import PlantError as ToolError  # noqa: F401  (one class: plant/ raises what the server answers)
