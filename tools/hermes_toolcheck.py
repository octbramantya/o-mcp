"""Check what Hermes would give the model on Telegram, before the gateway is started.

Runs on the agent instance, as the hermes user, with Hermes's own Python (tools/deploy_hermes.sh
does this; HERMES_HOME and HERMES_MANAGED_DIR as in deploy/hermes-gateway.service):

    sudo -u hermes env HOME=/var/lib/hermes HERMES_HOME=/var/lib/hermes/.hermes \\
        HERMES_MANAGED_DIR=/etc/hermes /opt/hermes/current/.venv/bin/python hermes_toolcheck.py

It loads the configuration the way the gateway does (user config.yaml, then the managed overlay),
connects to the MCP server, resolves the Telegram toolsets and builds the tool definitions the
model receives. It fails unless those are exactly the o-mcp tools plus memory, the model is the
pinned Bedrock one, and the Telegram allowlist and admin list are set and numeric. Hermes ignores
a malformed managed file instead of failing, which would fall back to the full toolset; this is
the check that catches it. Prints names and counts, never a secret.
"""

import os
import re
import sys

EXPECTED_MCP = {"plant_vocabulary", "plant_find", "plant_section", "node_meters", "meter_readings", "node_value"}
EXPECTED_OTHER = {"memory"}
MODEL = "global.anthropic.claude-sonnet-5-5"
NUMERIC_IDS = re.compile(r"^\d+(,\d+)*$")


def main() -> int:
    problems: list[str] = []

    from hermes_cli.env_loader import load_hermes_dotenv
    load_hermes_dotenv(hermes_home=os.environ["HERMES_HOME"])

    from hermes_cli import managed_scope
    print(f"managed dir: {managed_scope.get_managed_dir()}")

    from hermes_cli.config import load_config
    cfg = load_config()
    model = cfg.get("model") or {}
    print(f"model: {model.get('provider')} {model.get('default')}")
    if model.get("provider") != "bedrock" or model.get("default") != MODEL:
        problems.append("the model is not the pinned Bedrock one: the managed config did not apply")

    for var in ("GATEWAY_ALLOW_ALL_USERS", "TELEGRAM_ALLOW_ALL_USERS"):
        if os.environ.get(var):
            problems.append(f"{var} is set")
    allowed = os.environ.get("TELEGRAM_ALLOWED_USERS", "").replace(" ", "")
    if not NUMERIC_IDS.match(allowed):
        problems.append("TELEGRAM_ALLOWED_USERS is empty or not numeric IDs")
    print(f"telegram allowed users: {len(allowed.split(',')) if allowed else 0}")
    for var in ("TELEGRAM_BOT_TOKEN", "O_MCP_TOKEN"):
        print(f"{var}: {'set' if os.environ.get(var) else 'NOT SET'}")
    if not os.environ.get("O_MCP_TOKEN"):
        problems.append("O_MCP_TOKEN is not set")

    from gateway.config import load_gateway_config
    gw = load_gateway_config()
    tg = next((p for k, p in gw.platforms.items() if str(getattr(k, "value", k)) == "telegram"), None)
    extra = dict(getattr(tg, "extra", None) or {})
    admins = [str(a) for a in extra.get("allow_admin_from") or []]
    print(f"telegram admins: {len(admins)}; unauthorized DMs: {extra.get('unauthorized_dm_behavior')}; "
          f"user commands: {extra.get('user_allowed_commands')}")
    if not admins or not all(a.isdigit() for a in admins):
        problems.append("allow_admin_from is empty or not numeric (is O_HERMES_ADMIN_ID set?)")
    if extra.get("unauthorized_dm_behavior") != "ignore":
        problems.append("unauthorized_dm_behavior is not 'ignore'")

    from tools.mcp_tool_discovery import discover_mcp_tools
    discover_mcp_tools()

    import model_tools

    # The gateway's own per-turn loader (gateway/run_turn.py), not hermes_cli.config.load_config:
    # it returns {} on any error, and {} means the full default Telegram toolset.
    from gateway.run import _load_gateway_config
    from hermes_cli.tools_config import _get_platform_tools
    turn_cfg = _load_gateway_config()
    if not turn_cfg.get("platform_toolsets"):
        problems.append("the gateway's per-turn config has no platform_toolsets (empty or failed to load)")
    enabled = sorted(_get_platform_tools(turn_cfg, "telegram"))
    disabled = (turn_cfg.get("agent") or {}).get("disabled_toolsets") or None
    defs = model_tools.get_tool_definitions(enabled_toolsets=enabled, disabled_toolsets=disabled, quiet_mode=True)
    names = sorted(d["function"]["name"] for d in defs)
    print(f"telegram toolsets: {enabled}")
    print(f"tools the model gets ({len(names)}): {names}")

    mcp_found = {n for n in names if any(n == e or n.endswith("_" + e) for e in EXPECTED_MCP)}
    unexpected = set(names) - mcp_found - EXPECTED_OTHER
    if unexpected:
        problems.append(f"unexpected tools: {sorted(unexpected)}")
    if len(mcp_found) != len(EXPECTED_MCP):
        problems.append(f"expected the {len(EXPECTED_MCP)} o-mcp tools, found {len(mcp_found)}")
    if not EXPECTED_OTHER <= set(names):
        problems.append(f"missing: {sorted(EXPECTED_OTHER - set(names))}")

    for p in problems:
        print(f"FAIL: {p}")
    print("OK" if not problems else f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
