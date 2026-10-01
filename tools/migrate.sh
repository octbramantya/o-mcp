#!/usr/bin/env bash
# Apply the numbered migrations in migrations/ to one database, and record each in
# that database's own ledger, graph.schema_migration.
#
#   tools/migrate.sh [-e ENV_FILE] status
#   tools/migrate.sh [-e ENV_FILE] init             --confirm LABEL
#   tools/migrate.sh [-e ENV_FILE] baseline NNN     --confirm LABEL
#   tools/migrate.sh [-e ENV_FILE] apply NNN        --confirm LABEL
#
# status    list every migration as applied (when, how) or PENDING; flags files
#           edited since they were applied. Read-only.
# init      create the ledger. Once per database.
# baseline  record 008..NNN as already applied WITHOUT running them -- for a
#           database where they ran before the ledger existed.
# apply     run exactly one migration, the next pending one, and record it.
#
# The connection comes from ENV_FILE (default: .env at the repo root) and nowhere
# else: no defaults, and PG* shell variables and ~/.psqlrc are ignored, so a run
# can never silently reach a different database. --confirm must repeat the file's
# DB_LABEL, so applying to prod needs the prod env file AND the word "prod".
#
# Managed files are migrations/NNN_*.sql except NNN_pre_*.sql, which are undo
# helpers (028_pre_solver_bodies.sql) and never run forward.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MIG="$ROOT/migrations"
ENV_FILE="$ROOT/.env"
LEDGER=graph.schema_migration

. "$ROOT/tools/_env.sh"

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
CMD= NUM= CONFIRM=
while [ $# -gt 0 ]; do
    case "$1" in
        -e) ENV_FILE=$2; shift 2 ;;
        --confirm) CONFIRM=$2; shift 2 ;;
        status|init|baseline|apply) CMD=$1; shift ;;
        [0-9][0-9][0-9]) NUM=$1; shift ;;
        -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
[ -n "$CMD" ] || die "no command (status | init | baseline NNN | apply NNN)"
case "$CMD" in baseline|apply) [ -n "$NUM" ] || die "$CMD needs a three-digit migration number" ;; esac

# ---------------------------------------------------------------------------
# connection, from the env file only
# ---------------------------------------------------------------------------
load_conn "$ENV_FILE" DB

psql_() {
    PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT=5 \
        psql -X -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" "$@"
}
q() { psql_ -v ON_ERROR_STOP=1 -tAq -c "$1"; }

TARGET="$DB_LABEL  $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
echo "target: $TARGET"
q "SELECT 1" >/dev/null 2>&1 || die "cannot connect to $TARGET. Is the tunnel or the dev server up?"

needs_confirm() {
    [ "$CONFIRM" = "$DB_LABEL" ] || die "$CMD writes to '$DB_LABEL'; repeat it: --confirm $DB_LABEL"
}

# ---------------------------------------------------------------------------
# migration files and the ledger
# ---------------------------------------------------------------------------
managed() {   # managed filenames, in order
    (cd "$MIG" && ls -1 [0-9][0-9][0-9]_*.sql) | grep -v '^[0-9][0-9][0-9]_pre_' | sort
}
file_for() {  # the one managed file numbered $1
    local f
    f=$(managed | grep "^$1_" || true)
    [ -n "$f" ] || die "no migration numbered $1 in migrations/"
    [ "$(printf '%s\n' "$f" | wc -l | tr -d ' ')" = 1 ] || die "more than one migration numbered $1: $f"
    printf '%s' "$f"
}
sha() { shasum -a 256 "$MIG/$1" | cut -d' ' -f1; }
ledger_exists() { [ "$(q "SELECT to_regclass('$LEDGER') IS NOT NULL")" = t ]; }
applied_row() { q "SELECT sha256 || ' ' || mode || ' ' || to_char(applied_at, 'YYYY-MM-DD HH24:MI') FROM $LEDGER WHERE filename = '$1'"; }
record() {    # filename mode
    q "INSERT INTO $LEDGER (filename, sha256, mode) VALUES ('$1', '$(sha "$1")', '$2')" >/dev/null
}

case "$CMD" in

# ---------------------------------------------------------------------------
status)
    ledger_exists || { echo "no ledger yet: run  tools/migrate.sh init --confirm $DB_LABEL"; exit 0; }
    managed | while read -r f; do
        row=$(applied_row "$f")
        if [ -z "$row" ]; then
            printf '  PENDING                          %s\n' "$f"
        else
            set -- $row
            note=""; [ "$1" = "$(sha "$f")" ] || note="  <-- file changed since it was recorded"
            printf '  %-8s %s %s  %s%s\n' "$2" "$3" "$4" "$f" "$note"
        fi
    done
    ;;

# ---------------------------------------------------------------------------
init)
    needs_confirm
    ledger_exists && die "$LEDGER already exists on $DB_LABEL"
    psql_ -v ON_ERROR_STOP=1 -q <<'SQL'
CREATE TABLE graph.schema_migration (
    filename   VARCHAR(80) PRIMARY KEY,
    sha256     CHAR(64)    NOT NULL,
    mode       VARCHAR(8)  NOT NULL CHECK (mode IN ('APPLIED', 'BASELINE')),
    applied_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    applied_by TEXT        NOT NULL DEFAULT current_user
);
COMMENT ON TABLE graph.schema_migration IS
    'Which o-mcp migrations this database has run. Written by tools/migrate.sh. '
    'BASELINE = ran before the ledger existed and was recorded, not executed.';
DO $$ BEGIN   -- a fresh dev cluster may not have the role; pg_dump does not carry roles
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafReader') THEN
        GRANT SELECT ON graph.schema_migration TO "grafReader";
    END IF;
END $$;
SQL
    echo "created $LEDGER on $DB_LABEL"
    ;;

# ---------------------------------------------------------------------------
baseline)
    needs_confirm
    ledger_exists || die "no ledger on $DB_LABEL; run init first"
    n=0
    for f in $(managed); do
        [ "${f:0:3}" \> "$NUM" ] && break
        [ -n "$(applied_row "$f")" ] && continue
        record "$f" BASELINE; n=$((n + 1)); echo "  BASELINE $f"
    done
    echo "recorded $n file(s) as already applied on $DB_LABEL"
    ;;

# ---------------------------------------------------------------------------
apply)
    needs_confirm
    ledger_exists || die "no ledger on $DB_LABEL; run init first"
    f=$(file_for "$NUM")
    [ -z "$(applied_row "$f")" ] || die "$f is already recorded on $DB_LABEL"
    for g in $(managed); do        # strictly in order: nothing earlier may be pending
        [ "$g" = "$f" ] && break
        [ -n "$(applied_row "$g")" ] || die "$g is still pending on $DB_LABEL; apply it first"
    done

    mkdir -p "$ROOT/logs/$DB_LABEL"
    log="$ROOT/logs/$DB_LABEL/${f%.sql}.$(date +%Y%m%d-%H%M%S).log"
    echo "applying $f  (log: ${log#$ROOT/})"
    set +e
    (cd "$ROOT" && psql_ -v ON_ERROR_STOP=1 -f "migrations/$f") 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    set -e
    [ "$rc" = 0 ] || die "$f FAILED (psql exit $rc); not recorded. See $log"

    record "$f" APPLIED || die "$f RAN but could not be recorded -- insert the ledger row by hand"
    echo "applied and recorded $f on $DB_LABEL"
    ;;
esac
