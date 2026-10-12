"""Run the server.

    uv run python -m server                    # configuration from the environment (production)
    uv run python -m server --env-file .env    # DB_* from a file, O_MCP_* from the file or environment
    uv run python -m server --env-file .env --phase 1

--phase 1 serves only the phase-1 tools (no telemetry); see design/mcp-catalogue.md §3.
"""
import argparse
import sys

import uvicorn

from . import app, config, tools


def main():
    ap = argparse.ArgumentParser(prog="python -m server", description=__doc__.split("\n\n")[0])
    ap.add_argument("--env-file", help="read configuration from this file (parsed, never sourced)")
    ap.add_argument("--phase", type=int, choices=(1, 2), default=2, help="serve the tools up to this phase")
    a = ap.parse_args()
    try:
        cfg = config.load(a.env_file)
    except config.ConfigError as e:
        sys.exit(f"o-mcp: {e}")
    app.configure_logging()
    print(f"o-mcp: database {cfg.db_label} ({cfg.db_name} on {cfg.db_host}), tenant {cfg.tenant}, "
          f"listening on {cfg.bind_host}:{cfg.bind_port}", file=sys.stderr)
    tool_set = tools.PHASE_1 if a.phase == 1 else tools.ALL
    uvicorn.run(app.build(cfg, tool_set), host=cfg.bind_host, port=cfg.bind_port, log_level="warning",
                access_log=False)


if __name__ == "__main__":
    main()
