"""Run the frontend's API, or create the first super admin.

    uv run python -m api --env-file .env serve
    uv run python -m api --env-file .env create-super-admin EMAIL [--name NAME]

DB_* (host, name, TLS) as for the MCP server; O_API_DB_USER and O_API_DB_PASSWORD are frontend_api's
log-in (migration 061), O_API_BIND the host:port to listen on. None has a default.
"""
import argparse
import asyncio
import sys

import psycopg
import uvicorn

from . import app, config


def main():
    ap = argparse.ArgumentParser(prog="python -m api", description=__doc__.split("\n\n")[0])
    ap.add_argument("--env-file", help="read configuration from this file (parsed, never sourced)")
    sub = ap.add_subparsers(dest="command", required=True)
    sub.add_parser("serve", help="serve the API")
    sa = sub.add_parser("create-super-admin", help="create a super admin and print a temporary password")
    sa.add_argument("email")
    sa.add_argument("--name", help="display name")
    a = ap.parse_args()
    try:
        cfg = config.load(a.env_file)
    except config.ConfigError as e:
        sys.exit(f"o-mcp-api: {e}")
    print(f"o-mcp-api: database {cfg.db_label} ({cfg.db_name} on {cfg.db_host}) as {cfg.db_user}", file=sys.stderr)
    if a.command == "create-super-admin":
        try:
            temp = asyncio.run(app.create_super_admin(cfg, a.email, a.name))
        except psycopg.errors.UniqueViolation:
            sys.exit(f"o-mcp-api: an account with email {a.email} already exists")
        print(f"created super admin {a.email}; temporary password, to be changed at the first log-in:\n{temp}")
        return
    app.configure_logging()
    print(f"o-mcp-api: listening on {cfg.bind_host}:{cfg.bind_port}", file=sys.stderr)
    uvicorn.run(app.build(cfg), host=cfg.bind_host, port=cfg.bind_port, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
