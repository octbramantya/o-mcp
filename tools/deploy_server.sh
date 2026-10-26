#!/usr/bin/env bash
# Deploy the MCP server to a tenant's agent instance, from a pushed commit.
#
#   tools/deploy_server.sh HOST [--rev REV] --confirm HOST
#
# HOST     an ssh host alias (SSH over SSM, e.g. hermes-prs); the user there needs sudo.
# --rev    the commit to deploy, default HEAD. It must be on origin/main, so what runs is
#          always something the repository holds; the working tree must be clean.
# --confirm  must repeat HOST.
#
# What it does: packs the files the server needs from that commit (git archive: server/,
# plant/, pyproject.toml, uv.lock, tools/sld.sql, the output schemas, the smoke test), copies them over,
# and on the host, as root:
#   - first run only: creates the system user o-mcp and installs uv (pinned, checksum checked);
#   - unpacks to /opt/o-mcp/releases/<commit>, builds its .venv with `uv sync --frozen --no-dev`
#     against the system Python, and writes REVISION;
#   - installs deploy/o-mcp.service, switches /opt/o-mcp/current to the new release, restarts
#     the unit, and waits for /healthz. If it does not answer 200, current goes back to the
#     previous release and that is restarted;
#   - keeps the last three releases.
# It never creates or reads /etc/o-mcp/env: the database password and token are set there by hand
# (design/mcp-server.md §6). Without it, or with DB_PASSWORD empty, it stops before switching.
# The code is root's and read-only to o-mcp; the unit runs it under systemd's sandbox.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "${0##*/}: $*" >&2; exit 1; }

UV_VERSION=0.11.32
UV_TARGET=aarch64-unknown-linux-gnu

HOST= REV=HEAD CONFIRM=
while [ $# -gt 0 ]; do
    case "$1" in
        --rev) REV=$2; shift 2 ;;
        --confirm) CONFIRM=$2; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown argument: $1 (see --help)" ;;
        *) [ -z "$HOST" ] || die "one HOST only"; HOST=$1; shift ;;
    esac
done
[ -n "$HOST" ] || die "HOST is required (see --help)"
[ "$CONFIRM" = "$HOST" ] || die "this restarts the server on $HOST; repeat it: --confirm $HOST"

cd "$ROOT"
[ -z "$(git status --porcelain)" ] || die "the working tree has uncommitted changes; commit and push first"
SHA=$(git rev-parse --verify "$REV^{commit}") || die "no commit $REV"
git fetch -q origin main
git merge-base --is-ancestor "$SHA" origin/main || die "$SHA is not on origin/main; push it first"
SHORT=${SHA:0:12}

FILES=(server plant pyproject.toml uv.lock deploy/o-mcp.service tools/sld.sql tools/mcp_smoke.py tools/check_subgraph.py)
while IFS= read -r f; do FILES+=("$f"); done < <(git ls-tree --name-only "$SHA" design/ | grep -E -- '-v1\.schema\.json$')

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git archive --format=tar.gz -o "$TMP/o-mcp.tar.gz" "$SHA" -- "${FILES[@]}"
echo "deploying $SHORT ($(git log -1 --format=%s "$SHA")) to $HOST"

scp -q "$TMP/o-mcp.tar.gz" "$HOST:/tmp/o-mcp-$SHORT.tar.gz"
# shellcheck disable=SC2087  # expanded here on purpose: only the values below cross over
ssh "$HOST" sudo bash -s -- "$SHA" "$SHORT" "$UV_VERSION" "$UV_TARGET" <<'REMOTE'
set -euo pipefail
SHA=$1 SHORT=$2 UV_VERSION=$3 UV_TARGET=$4
BASE=/opt/o-mcp REL=/opt/o-mcp/releases/$SHORT TARBALL=/tmp/o-mcp-$SHORT.tar.gz
say() { echo "[$HOSTNAME] $*"; }
fail() { echo "[$HOSTNAME] FAILED: $*" >&2; exit 1; }
trap 'rm -f "$TARBALL"' EXIT

# --- first run: user and uv ------------------------------------------------------------------
if ! id o-mcp >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin o-mcp
    say "created system user o-mcp"
fi
if [ "$(/usr/local/bin/uv --version 2>/dev/null | awk '{print $2}')" != "$UV_VERSION" ]; then
    d=$(mktemp -d); url=https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-$UV_TARGET.tar.gz
    curl -fsSL -o "$d/uv.tar.gz" "$url" && curl -fsSL -o "$d/uv.sha256" "$url.sha256"
    (cd "$d" && echo "$(awk '{print $1}' uv.sha256)  uv.tar.gz" | sha256sum -c --quiet) || fail "uv checksum mismatch"
    tar -xzf "$d/uv.tar.gz" -C "$d"
    install -m 0755 -o root -g root "$d/uv-$UV_TARGET/uv" /usr/local/bin/uv
    rm -rf "$d"; say "installed uv $UV_VERSION"
fi

# --- the release -----------------------------------------------------------------------------
install -d -m 0755 -o root -g root "$BASE" "$BASE/releases"
if [ -f "$REL/REVISION" ] && [ "$(cat "$REL/REVISION")" = "$SHA" ]; then
    say "release $SHORT already built"
else
    rm -rf "$REL" "$REL.tmp"; install -d -m 0755 "$REL.tmp"
    tar -xzf "$TARBALL" -C "$REL.tmp"
    (cd "$REL.tmp" && UV_PYTHON=/usr/bin/python3 UV_PYTHON_DOWNLOADS=never UV_CACHE_DIR=/var/cache/o-mcp-uv \
        uv sync --frozen --no-dev --compile-bytecode --quiet) || fail "uv sync"
    /usr/bin/python3 -m compileall -q "$REL.tmp/server" "$REL.tmp/plant" >/dev/null
    echo "$SHA" > "$REL.tmp/REVISION"
    chown -R root:root "$REL.tmp"; chmod -R go-w,o+rX "$REL.tmp"
    mv "$REL.tmp" "$REL"; say "built release $SHORT"
fi
(cd "$REL" && .venv/bin/python -c "import server.app, server.__main__") || fail "the release does not import"

# --- configuration (never written here) ------------------------------------------------------
[ -f /etc/o-mcp/env ] || fail "/etc/o-mcp/env is missing; set it up by hand (design/mcp-server.md §6)"
[ "$(stat -c '%a %U' /etc/o-mcp/env)" = "600 root" ] || fail "/etc/o-mcp/env must be 0600 root"
grep -Eq '^DB_PASSWORD=.+' /etc/o-mcp/env || fail "DB_PASSWORD is empty in /etc/o-mcp/env"
BIND=$(sed -n 's/^O_MCP_BIND=//p' /etc/o-mcp/env | tr -d "\"'")
[ -n "$BIND" ] || fail "O_MCP_BIND is empty in /etc/o-mcp/env"

# --- unit, switch, restart, health -----------------------------------------------------------
if ! cmp -s "$REL/deploy/o-mcp.service" /etc/systemd/system/o-mcp.service; then
    install -m 0644 -o root -g root "$REL/deploy/o-mcp.service" /etc/systemd/system/o-mcp.service
    systemctl daemon-reload; say "installed o-mcp.service"
fi
PREV=$(readlink "$BASE/current" 2>/dev/null || true)
ln -sfn "releases/$SHORT" "$BASE/current.new" && mv -T "$BASE/current.new" "$BASE/current"
systemctl enable --quiet o-mcp
systemctl restart o-mcp

healthy() {
    for _ in $(seq 1 20); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$BIND/healthz")" = 200 ] && return 0
        sleep 1
    done
    return 1
}
if healthy; then
    say "o-mcp $SHORT is up: http://$BIND/healthz answers 200"
    journalctl -u o-mcp -n 4 --no-pager -o cat | sed "s/^/[$HOSTNAME]   /"
else
    journalctl -u o-mcp -n 25 --no-pager -o cat | sed "s/^/[$HOSTNAME]   /" >&2
    if [ -n "$PREV" ] && [ "$PREV" != "releases/$SHORT" ]; then
        ln -sfn "$PREV" "$BASE/current.new" && mv -T "$BASE/current.new" "$BASE/current"
        systemctl restart o-mcp
        healthy && say "rolled back to $PREV, which is up" || say "rolled back to $PREV, which is NOT up either"
    fi
    fail "o-mcp $SHORT did not answer /healthz within 20 s"
fi

# --- keep the last three releases ------------------------------------------------------------
cd "$BASE/releases"
ls -1t | grep -vx "$SHORT" | grep -vx "${PREV#releases/}" | tail -n +2 | xargs -r rm -rf
REMOTE
