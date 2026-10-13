#!/usr/bin/env bash
# Install or update Hermes Agent's Telegram gateway on a tenant's agent instance, from a pushed commit.
#
#   tools/deploy_hermes.sh HOST [--rev REV] --confirm HOST
#
# HOST     an ssh host alias (SSH over SSM, e.g. hermes-prs); the user there needs sudo.
# --rev    the commit of this repository whose deploy files are used, default HEAD. It must be on
#          origin/main; the working tree must be clean.
# --confirm  must repeat HOST.
#
# The Hermes release is pinned below (HERMES_TAG, HERMES_COMMIT): a release at least two weeks
# old, checked out by tag on the host and refused unless it is that exact commit.
#
# On the host, as root:
#   - first run only: creates the system user hermes (home /var/lib/hermes, no shell) and
#     $HERMES_HOME=/var/lib/hermes/.hermes, 0700;
#   - clones Hermes into /opt/hermes/releases/<tag>, builds its .venv with `uv sync --frozen
#     --no-dev` and only the extras used here (mcp, bedrock, anthropic, messaging), root's and
#     read-only to hermes: no `install.sh`, no Node, no browser, no self-update;
#   - installs deploy/hermes-managed.yaml as /etc/hermes/config.yaml, the managed scope Hermes
#     will not let the agent or its users override, and as $HERMES_HOME/config.yaml, root's;
#   - installs deploy/hermes-SOUL.md, the agent's standing instructions, as $HERMES_HOME/SOUL.md, root's;
#   - copies O_MCP_TOKEN from /etc/o-mcp/env into $HERMES_HOME/.env (0600 hermes), host to host;
#   - runs tools/hermes_toolcheck.py as hermes: the tools the model gets must be the o-mcp tools
#     plus memory, or nothing is switched or started;
#   - installs deploy/hermes-gateway.service, switches /opt/hermes/current, and starts the gateway
#     only if TELEGRAM_BOT_TOKEN is set in $HERMES_HOME/.env.
# It never writes /etc/hermes/.env (the Telegram user IDs, by hand) or the bot token (by hand:
# `sudo -u hermes nano /var/lib/hermes/.hermes/.env`). design/mcp-server.md §9.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "${0##*/}: $*" >&2; exit 1; }

HERMES_TAG=v2026.9.24
HERMES_COMMIT=f97608f178d1ffeca59860195ab7da295f7c8e5f
HERMES_EXTRAS="mcp bedrock anthropic messaging"

HOST= REV=HEAD CONFIRM=
while [ $# -gt 0 ]; do
    case "$1" in
        --rev) REV=$2; shift 2 ;;
        --confirm) CONFIRM=$2; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown argument: $1 (see --help)" ;;
        *) [ -z "$HOST" ] || die "one HOST only"; HOST=$1; shift ;;
    esac
done
[ -n "$HOST" ] || die "HOST is required (see --help)"
[ "$CONFIRM" = "$HOST" ] || die "this changes the agent on $HOST; repeat it: --confirm $HOST"

cd "$ROOT"
[ -z "$(git status --porcelain)" ] || die "the working tree has uncommitted changes; commit and push first"
SHA=$(git rev-parse --verify "$REV^{commit}") || die "no commit $REV"
git fetch -q origin main
git merge-base --is-ancestor "$SHA" origin/main || die "$SHA is not on origin/main; push it first"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git archive --format=tar.gz -o "$TMP/hermes-deploy.tar.gz" "$SHA" -- \
    deploy/hermes-managed.yaml deploy/hermes-SOUL.md deploy/hermes-gateway.service tools/hermes_toolcheck.py
echo "deploying Hermes $HERMES_TAG with the deploy files of ${SHA:0:12} to $HOST"

scp -q "$TMP/hermes-deploy.tar.gz" "$HOST:/tmp/hermes-deploy-${SHA:0:12}.tar.gz"
ssh "$HOST" sudo bash -s -- "$SHA" "$HERMES_TAG" "$HERMES_COMMIT" "$HERMES_EXTRAS" <<'REMOTE'
set -euo pipefail
SHA=$1 TAG=$2 COMMIT=$3 EXTRAS=$4
BASE=/opt/hermes REL=/opt/hermes/releases/$2 TARBALL=/tmp/hermes-deploy-${1:0:12}.tar.gz
HH=/var/lib/hermes/.hermes
say() { echo "[$HOSTNAME] $*"; }
fail() { echo "[$HOSTNAME] FAILED: $*" >&2; exit 1; }
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE" "$TARBALL"' EXIT
tar -xzf "$TARBALL" -C "$STAGE"; chmod -R go+rX "$STAGE"; chmod 0755 "$STAGE"

# --- first run: user and home ----------------------------------------------------------------
if ! id hermes >/dev/null 2>&1; then
    useradd --system --create-home --home-dir /var/lib/hermes --shell /usr/sbin/nologin hermes
    say "created system user hermes"
fi
install -d -m 0700 -o hermes -g hermes /var/lib/hermes "$HH"
# Skills are off; never seed the bundled ones.
[ -f "$HH/.no-bundled-skills" ] || install -m 0600 -o hermes -g hermes /dev/null "$HH/.no-bundled-skills"
[ -x /usr/local/bin/uv ] || fail "uv is missing; deploy o-mcp first (tools/deploy_server.sh)"

# --- the release -----------------------------------------------------------------------------
install -d -m 0755 -o root -g root "$BASE" "$BASE/releases"
if [ -f "$REL/REVISION" ] && [ "$(cat "$REL/REVISION")" = "$COMMIT $EXTRAS" ]; then
    say "release $TAG already built"
else
    # Built in place: the venv and the editable install record their absolute path. REVISION is
    # written last, so a half-built release is rebuilt next time.
    rm -rf "$REL"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" \
        https://github.com/NousResearch/hermes-agent.git "$REL" </dev/null
    [ "$(git -C "$REL" rev-parse HEAD)" = "$COMMIT" ] || fail "tag $TAG is not commit $COMMIT"
    rm -rf "$REL/.git"
    args=(); for e in $EXTRAS; do args+=(--extra "$e"); done
    (cd "$REL" && UV_PYTHON=/usr/bin/python3 UV_PYTHON_DOWNLOADS=never UV_CACHE_DIR=/var/cache/hermes-uv \
        uv sync --frozen --no-dev --compile-bytecode --quiet "${args[@]}" </dev/null) || fail "uv sync"
    chown -R root:root "$REL"; chmod -R go-w,o+rX "$REL"
    echo "$COMMIT $EXTRAS" > "$REL/REVISION"; say "built release $TAG"
fi
"$REL/.venv/bin/python" -c "import hermes_cli.main, gateway.run, boto3, anthropic, mcp, telegram" </dev/null \
    || fail "the release does not import"

# --- configuration ---------------------------------------------------------------------------
[ -f /etc/hermes/.env ] || fail "/etc/hermes/.env is missing: TELEGRAM_ALLOWED_USERS and O_HERMES_ADMIN_ID, by hand"
[ "$(stat -c '%a %U' /etc/hermes/.env)" = "644 root" ] || fail "/etc/hermes/.env must be 0644 root"
"$REL/.venv/bin/python" -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$STAGE/deploy/hermes-managed.yaml" \
    || fail "deploy/hermes-managed.yaml does not parse"
install -d -m 0755 -o root -g root /etc/hermes
install -m 0644 -o root -g root "$STAGE/deploy/hermes-managed.yaml" /etc/hermes/config.yaml
install -m 0644 -o root -g root "$STAGE/deploy/hermes-managed.yaml" "$HH/config.yaml"
install -m 0644 -o root -g root "$STAGE/deploy/hermes-SOUL.md" "$HH/SOUL.md"

[ -f "$HH/.env" ] || install -m 0600 -o hermes -g hermes /dev/null "$HH/.env"
[ "$(stat -c '%a %U' "$HH/.env")" = "600 hermes" ] || fail "$HH/.env must be 0600 hermes"
TOKEN=$(sed -n 's/^O_MCP_TOKEN=//p' /etc/o-mcp/env | tr -d "\"'")
[ -n "$TOKEN" ] || fail "O_MCP_TOKEN is empty in /etc/o-mcp/env"
if ! grep -qxF "O_MCP_TOKEN=$TOKEN" "$HH/.env"; then
    { grep -v '^O_MCP_TOKEN=' "$HH/.env" || true; echo "O_MCP_TOKEN=$TOKEN"; } > "$HH/.env.new"
    chown hermes:hermes "$HH/.env.new"; chmod 0600 "$HH/.env.new"; mv "$HH/.env.new" "$HH/.env"
    say "O_MCP_TOKEN copied into $HH/.env"
fi
unset TOKEN

# --- what the model would get ----------------------------------------------------------------
systemctl is-active --quiet o-mcp || fail "o-mcp is not running; the check needs it"
say "tool check:"
(cd "$STAGE" && sudo -u hermes env -i HOME=/var/lib/hermes USER=hermes HERMES_HOME="$HH" \
    HERMES_MANAGED_DIR=/etc/hermes PATH=/usr/bin:/bin \
    "$REL/.venv/bin/python" tools/hermes_toolcheck.py </dev/null 2>&1 | sed "s/^/[$HOSTNAME]   /"; exit "${PIPESTATUS[0]}") \
    || fail "the tool check did not pass; nothing switched or started"

# --- unit, switch, start ---------------------------------------------------------------------
if ! cmp -s "$STAGE/deploy/hermes-gateway.service" /etc/systemd/system/hermes-gateway.service; then
    install -m 0644 -o root -g root "$STAGE/deploy/hermes-gateway.service" /etc/systemd/system/hermes-gateway.service
    systemctl daemon-reload; say "installed hermes-gateway.service"
fi
ln -sfn "releases/$TAG" "$BASE/current.new" && mv -T "$BASE/current.new" "$BASE/current"

if grep -Eq '^TELEGRAM_BOT_TOKEN=.+' "$HH/.env"; then
    systemctl enable --quiet hermes-gateway
    systemctl restart hermes-gateway
    sleep 15
    systemctl is-active --quiet hermes-gateway || {
        journalctl -u hermes-gateway -n 30 --no-pager -o cat | sed "s/^/[$HOSTNAME]   /" >&2
        fail "hermes-gateway is not running"; }
    say "hermes-gateway is running ($TAG)"
    journalctl -u hermes-gateway -n 8 --no-pager -o cat | sed "s/^/[$HOSTNAME]   /"
else
    systemctl disable --now --quiet hermes-gateway 2>/dev/null || true
    say "TELEGRAM_BOT_TOKEN is not in $HH/.env yet: the gateway is installed but not started"
fi

# --- keep the last two releases ---------------------------------------------------------------
cd "$BASE/releases"; ls -1t | grep -vx "$TAG" | tail -n +2 | xargs -r rm -rf
REMOTE
