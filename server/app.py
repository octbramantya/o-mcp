"""The MCP server: Streamable HTTP, stateless, JSON responses, behind a bearer token
(design/mcp-server.md §3, §5)."""
import contextlib
import hmac
import json
import logging
import sys
import time

import jsonschema
import mcp_types as types
from mcp.server.lowlevel import Server
from starlette.applications import Starlette
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Route

from . import timewin, tools, vocab
from .db import Database, rows
from .errors import ToolError

log = logging.getLogger("o-mcp")
calls = logging.getLogger("o-mcp.calls")

INSTRUCTIONS = """\
Tools over one industrial site's plant: its electricity, water and compressed-air networks, the \
meters on them, and what the network model works out for every node. Times are site time. \
Quote `findings[].message` as given, state the `as_of` date and window of what you report, and \
never add or average values yourself where a tool gives the total."""


def _with_defaults(schema, args):
    out = dict(args or {})
    for k, p in schema.get("properties", {}).items():
        if k not in out and "default" in p:
            out[k] = p["default"]
    return out


def _check(schema, args):
    errors = sorted(jsonschema.Draft202012Validator(schema).iter_errors(args), key=lambda e: list(e.path))
    if errors:
        e = errors[0]
        where = "/".join(map(str, e.absolute_path)) or "arguments"
        msg = e.message
        if e.validator == "oneOf" and isinstance(e.instance, str):
            allowed = [s.get("const") for s in e.schema["oneOf"]]
            msg = f"{e.instance!r} is not one of {', '.join(map(str, allowed))}"
            if e.instance in vocab.NOT_A_NODE_VALUE:
                msg += (f". {e.instance} is a meter's own quadrant-encoded reading; for a node's power factor use "
                        f"PF_TRUE, and for the meter's readings meter_readings")
        raise ToolError(f"Invalid {where}: {msg}.")
    for k in ("as_of", "start", "end"):
        if k in args and k in schema["properties"] and schema["properties"][k].get("format") == "date":
            timewin.parse_date(args[k], k)


def _result(text, doc=None, error=False):
    content = [types.TextContent(type="text", text=text)]
    if doc is not None:
        content.append(types.TextContent(type="text", text=json.dumps(doc, ensure_ascii=False, default=str)))
    return types.CallToolResult(content=content, structured_content=doc, is_error=error)


def build(config, tool_set=tools.ALL):
    db = Database(config)
    ctx = tools.Context(config=config, db=db, vocab=None)
    enabled = {t.NAME: t for t in tool_set}

    def tool_defs():
        return [types.Tool(name=t.NAME, title=t.TITLE, description=t.DESCRIPTION, input_schema=t.input_schema(ctx),
                           output_schema=tools.output_schema(t.FORMAT),
                           annotations=types.ToolAnnotations(read_only_hint=True, destructive_hint=False,
                                                             idempotent_hint=True, open_world_hint=False))
                for t in enabled.values()]

    async def list_tools(_ctx, _params):
        return types.ListToolsResult(tools=tool_defs())

    async def call_tool(_ctx, params):
        t0, name = time.monotonic(), params.name
        outcome, size, args = "ok", 0, params.arguments or {}
        try:
            tool = enabled.get(name)
            if tool is None:
                raise ToolError(f"No tool {name!r}. Tools: {', '.join(enabled)}.")
            schema = tool.input_schema(ctx)
            args = _with_defaults(schema, args)
            _check(schema, args)
            doc, summary = await tool.run(ctx, args)
            size = len(json.dumps(doc, default=str))
            return _result(summary, doc)
        except ToolError as e:
            outcome = "tool_error"
            return _result(str(e), error=True)
        except Exception:
            outcome = "failed"
            log.exception("tool %s failed", name)
            return _result("The plant database could not answer this just now. Try again, or narrow the request; "
                           "the error is logged on the server.", error=True)
        finally:
            calls.info(json.dumps({"tool": name, "args": args, "ms": round((time.monotonic() - t0) * 1000),
                                   "bytes": size, "outcome": outcome}, default=str))

    server = Server("o-mcp", version="0.1.0", title="Plant tools", instructions=INSTRUCTIONS,
                    on_list_tools=list_tools, on_call_tool=call_tool)
    inner = server.streamable_http_app(json_response=True, stateless_http=True, host=config.bind_host)

    async def healthz(_request):
        try:
            async with db.tx() as conn:
                await conn.execute("SELECT 1")
            return PlainTextResponse("ok")
        except Exception:
            log.exception("healthz")
            return PlainTextResponse("database unreachable", status_code=503)

    @contextlib.asynccontextmanager
    async def lifespan(_app):
        await db.open()
        async with db.tx() as conn:
            ctx.vocab = await vocab.load(conn, config.tenant)
            other = (await rows(conn, "SELECT count(*) AS n FROM devices WHERE tenant_id <> %s",
                                (config.tenant,)))[0]["n"]
        if other:
            log.warning("database role %s reads %d devices of other tenants: the database does not keep it to "
                        "tenant %s. Expected for a developer's own role; in production, use the tenant's role "
                        "(migration 044, design/mcp-tenancy.md)", config.db_user, other, config.tenant)
        else:
            log.info("database role %s sees only tenant %s", config.db_user, config.tenant)
        log.info("vocabulary loaded: %d node types, %d quantities; serving %s on %s (tenant %s, %s)",
                 len(ctx.vocab.node_types), len(ctx.vocab.quantities), ", ".join(enabled), config.db_label,
                 config.tenant, config.tz.key)
        async with server.session_manager.run():
            yield
        await db.close()

    app = Starlette(routes=[Route("/healthz", healthz), *inner.routes], lifespan=lifespan)
    app.state.ctx, app.state.tool_defs = ctx, tool_defs
    return BearerToken(app, config.token)


class BearerToken:
    """Every path but /healthz needs `Authorization: Bearer <O_MCP_TOKEN>`, compared in constant time."""

    def __init__(self, app, token):
        self.app, self.expected = app, f"Bearer {token}".encode()

    def __getattr__(self, name):
        return getattr(self.app, name)

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["path"] != "/healthz":
            got = dict(scope["headers"]).get(b"authorization", b"")
            if not hmac.compare_digest(got, self.expected):
                await JSONResponse({"error": "unauthorized"}, status_code=401,
                                   headers={"WWW-Authenticate": "Bearer"})(scope, receive, send)
                return
        await self.app(scope, receive, send)


def configure_logging():
    handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(logging.Formatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler])
