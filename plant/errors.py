"""Errors the caller can act on: their message is for the person or model asking, and is returned
as is. The MCP server answers them as tool errors, the API as 400s."""


class PlantError(Exception):
    pass
