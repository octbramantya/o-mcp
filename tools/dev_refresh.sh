#!/usr/bin/env bash
# Rebuild the development database from production: the whole structure, the
# data of the graph schema, public.devices and public.quantities, and optionally
# one window of 15-minute telemetry.
#
#   tools/dev_refresh.sh -s SOURCE_ENV [-t TARGET_ENV] [--telemetry FROM TO] --confirm LABEL
#
# -s           production. Read-only credentials (grafReader) are enough, and every
#              source session is forced read-only regardless.
# -t           the dev database, default .env. It is DROPPED and recreated.
# --telemetry  copy public.telemetry_15min_agg rows for tenant 3 (--tenant to
#              change) with FROM - 1 day <= bucket < TO. The day before FROM feeds
#              the first interval. Needed only to test migrations that touch the
#              solver; without it, before/after solver checks compare empty to empty.
# --confirm    must repeat the target's DB_LABEL. A target labelled prod is refused.
#
# Dev does not need TimescaleDB. Hypertables and continuous aggregates become
# plain tables with the same columns, so views over them (for example
# public.telemetry_intervals_cumulative) still restore and still work.
#
# Objects outside graph that cannot be created on dev, such as a SQL function
# calling time_bucket, are reported and skipped. The graph schema must arrive
# complete: the run fails if any graph object or row count differs from the source.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tools/_env.sh"

SRC_ENV= TGT_ENV="$ROOT/.env" CONFIRM= TEL_FROM= TEL_TO= TENANT=3
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SRC_ENV=$2; shift 2 ;;
        -t) TGT_ENV=$2; shift 2 ;;
        --confirm) CONFIRM=$2; shift 2 ;;
        --telemetry) TEL_FROM=$2; TEL_TO=$3; shift 3 ;;
        --tenant) TENANT=$2; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
[ -n "$SRC_ENV" ] || die "-s SOURCE_ENV is required"
if [ -n "$TEL_FROM" ]; then
    for d in "$TEL_FROM" "$TEL_TO"; do
        [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--telemetry dates must be YYYY-MM-DD, got '$d'"
    done
    [[ "$TEL_FROM" < "$TEL_TO" ]] || die "--telemetry FROM must be before TO"
fi
[[ "$TENANT" =~ ^[0-9]+$ ]] || die "--tenant must be a number"

load_conn "$SRC_ENV" SRC
load_conn "$TGT_ENV" TGT

# ---------------------------------------------------------------------------
# guards: never write to production, never write to the source
# ---------------------------------------------------------------------------
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
case "$(lc "$TGT_LABEL")" in prod|production|valkyrie) die "target is labelled '$TGT_LABEL'; refusing to overwrite it" ;; esac
[ "$TGT_HOST:$TGT_PORT/$TGT_NAME" != "$SRC_HOST:$SRC_PORT/$SRC_NAME" ] || die "source and target are the same database"
[ "$CONFIRM" = "$TGT_LABEL" ] || die "this DROPS '$TGT_NAME' on '$TGT_LABEL'; repeat it: --confirm $TGT_LABEL"

echo "source: $SRC_LABEL  $SRC_USER@$SRC_HOST:$SRC_PORT/$SRC_NAME  (read-only)"
echo "target: $TGT_LABEL  $TGT_USER@$TGT_HOST:$TGT_PORT/$TGT_NAME  (will be dropped and rebuilt)"

# ---------------------------------------------------------------------------
# client tools: pg_dump must be at least the source server's major version
# ---------------------------------------------------------------------------
src() {   # src [psql args]; read-only by construction
    PGPASSWORD="$SRC_PASSWORD" PGOPTIONS='-c default_transaction_read_only=on' PGCONNECT_TIMEOUT=5 \
        "$PG_BIN/psql" -X -v ON_ERROR_STOP=1 -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_NAME" "$@"
}
tgt_db() {   # tgt_db DBNAME [psql args]
    local db=$1; shift
    PGPASSWORD="$TGT_PASSWORD" PGCONNECT_TIMEOUT=15 \
        "$PG_BIN/psql" -X -v ON_ERROR_STOP=1 -h "$TGT_HOST" -p "$TGT_PORT" -U "$TGT_USER" -d "$db" "$@"
}
tgt() { tgt_db "$TGT_NAME" "$@"; }
src_dump() {
    PGPASSWORD="$SRC_PASSWORD" PGOPTIONS='-c default_transaction_read_only=on' \
        "$PG_BIN/pg_dump" -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" -d "$SRC_NAME" "$@"
}
tgt_restore() {
    PGPASSWORD="$TGT_PASSWORD" \
        "$PG_BIN/pg_restore" -h "$TGT_HOST" -p "$TGT_PORT" -U "$TGT_USER" -d "$TGT_NAME" --no-owner "$@"
}

major_of() { "$1/pg_dump" --version 2>/dev/null | sed -E 's/.* ([0-9]+)(\.[0-9]+)*.*/\1/'; }
PG_BIN=$(dirname "$(command -v psql)")
SRC_MAJOR=$(PGPASSWORD="$SRC_PASSWORD" PGCONNECT_TIMEOUT=5 "$PG_BIN/psql" -X -tA -h "$SRC_HOST" -p "$SRC_PORT" \
    -U "$SRC_USER" -d "$SRC_NAME" -c "SELECT current_setting('server_version_num')::int / 10000" 2>/dev/null) \
    || die "cannot connect to the source. Is the tunnel up?"
found=
for b in "$PG_BIN" /opt/homebrew/opt/postgresql@{16,17,18}/bin /usr/local/opt/postgresql@{16,17,18}/bin; do
    m=$(major_of "$b") || continue
    [ -n "$m" ] && [ "$m" -ge "$SRC_MAJOR" ] && [ -x "$b/pg_restore" ] && { PG_BIN=$b; found=1; break; }
done
[ -n "$found" ] || die "need pg_dump >= $SRC_MAJOR (source server version); brew install postgresql@$SRC_MAJOR"
TGT_MAJOR=$(tgt_db postgres -tAq -c "SELECT current_setting('server_version_num')::int / 10000" 2>/dev/null) \
    || die "cannot connect to the target server"
[ "$TGT_MAJOR" -ge "$SRC_MAJOR" ] || die "target server is PostgreSQL $TGT_MAJOR; it must be at least $SRC_MAJOR, like the source"
echo "tools:  $PG_BIN (source server is PostgreSQL $SRC_MAJOR)"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dev_refresh.XXXXXX")
trap 'rm -rf "$WORK"' EXIT     # the dumps hold production data; never keep them

# ---------------------------------------------------------------------------
# 1. what cannot be copied as-is: TimescaleDB hypertables and continuous aggregates
# ---------------------------------------------------------------------------
STANDINS=
if [ "$(src -tAq -c "SELECT to_regclass('timescaledb_information.hypertables') IS NOT NULL")" = t ]; then
    STANDINS=$(src -tAq -c "
        SELECT format('%I.%I', hypertable_schema, hypertable_name) FROM timescaledb_information.hypertables
         WHERE hypertable_schema NOT LIKE '\_timescaledb%'
        UNION
        SELECT format('%I.%I', view_schema, view_name) FROM timescaledb_information.continuous_aggregates
        ORDER BY 1")
    echo "TimescaleDB on source; stand-in tables for: $(echo $STANDINS)"
fi

: > "$WORK/standins.sql"
for rel in $STANDINS; do
    src -tAq -c "
        SELECT format('CREATE TABLE %s (%s);', '$rel',
                      string_agg(format('%I %s', attname, format_type(atttypid, atttypmod)), ', ' ORDER BY attnum))
        FROM pg_attribute
        WHERE attrelid = '$rel'::regclass AND attnum > 0 AND NOT attisdropped" >> "$WORK/standins.sql"
done

# ---------------------------------------------------------------------------
# 2. privileges. Everything copied WITH data must be readable, or stop now.
#    Tables the source role cannot read are left out of the structure dump:
#    pg_dump locks every table it dumps, and LOCK needs SELECT.
# ---------------------------------------------------------------------------
NEED_TEL=false; [ -n "$TEL_FROM" ] && NEED_TEL=true
missing=$(src -tAq -c "
    SELECT string_agg(format('%I.%I', n.nspname, c.relname), ', ' ORDER BY 1)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE (   (n.nspname = 'graph' AND c.relkind IN ('r','p'))
           OR (n.nspname = 'public' AND c.relname IN ('devices','quantities'))
           OR ($NEED_TEL AND n.nspname = 'public' AND c.relname = 'telemetry_15min_agg'))
      AND NOT has_table_privilege(c.oid, 'SELECT')")
[ -z "$missing" ] || die "$SRC_USER cannot read what must be copied: $missing"

# What is copied with data: graph's tables and the two it points at. A partition
# is copied through its parent, never on its own, so rows are not doubled.
COPY_TABLES=$(src -tAq -c "
    SELECT format('%I.%I', n.nspname, c.relname)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE ((n.nspname = 'graph' AND c.relkind IN ('r','p'))
        OR (n.nspname = 'public' AND c.relname IN ('devices','quantities')))
      AND NOT c.relispartition
    ORDER BY 1")

# Their sequences, and whether each can be read. A sequence's position cannot be
# read without SELECT on it, not even through pg_sequences; those are set on dev
# from the column they feed, so dev's next id can be lower than production's.
SEQS=$(src -tAq -F ' ' -c "
    SELECT format('%I.%I', sn.nspname, s.relname),
           -- CASE: the planner may otherwise call the function on non-sequences
           CASE WHEN s.relkind = 'S' AND has_sequence_privilege(s.oid, 'SELECT') THEN 'exact' ELSE 'max' END
    FROM pg_depend d
    JOIN pg_class s      ON s.oid = d.objid AND s.relkind = 'S'
    JOIN pg_namespace sn ON sn.oid = s.relnamespace
    JOIN pg_class t      ON t.oid = d.refobjid
    JOIN pg_namespace tn ON tn.oid = t.relnamespace
    WHERE d.classid = 'pg_class'::regclass AND d.refclassid = 'pg_class'::regclass
      AND d.deptype IN ('a','i')
      AND format('%I.%I', tn.nspname, t.relname) = ANY (string_to_array('$(echo $COPY_TABLES)', ' '))
    ORDER BY 1")

# a schema without USAGE hides all of its tables, readable or not
NOUSAGE=$(src -tAq -c "
    SELECT quote_ident(nspname) FROM pg_namespace
    WHERE nspname NOT IN ('pg_catalog','information_schema') AND nspname NOT LIKE 'pg\_%'
      AND nspname NOT LIKE '\_timescaledb%' AND nspname NOT LIKE 'timescaledb%'
      AND NOT has_schema_privilege(oid, 'USAGE')
    ORDER BY 1")
[ -z "$NOUSAGE" ] || echo "schema(s) $SRC_USER cannot use are left out entirely: $(echo $NOUSAGE)"

UNREADABLE=$(src -tAq -c "
    SELECT format('%I.%I', n.nspname, c.relname)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r','p','f','m')
      AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg\_%'
      AND n.nspname NOT LIKE '\_timescaledb%' AND n.nspname NOT LIKE 'timescaledb%'
      AND has_schema_privilege(n.oid, 'USAGE')
      AND NOT has_table_privilege(c.oid, 'SELECT')
    ORDER BY 1")
if [ -n "$UNREADABLE" ]; then
    echo "$(echo "$UNREADABLE" | wc -l | tr -d ' ') table(s) $SRC_USER cannot read are left out of the structure, by schema:"
    echo "$UNREADABLE" | cut -d. -f1 | sort | uniq -c | sed 's/^ */  /'
fi

# ---------------------------------------------------------------------------
# 3. read: structure of everything readable, data of graph + devices + quantities
# ---------------------------------------------------------------------------
excl=(-N '_timescaledb*' -N 'timescaledb*')
for rel in $STANDINS $UNREADABLE; do excl+=(-T "$rel"); done
for nsp in $NOUSAGE; do excl+=(-N "$nsp"); done
echo "dumping structure..."
src_dump -Fc --schema-only "${excl[@]}" -f "$WORK/schema.dump"
echo "reading data: $(echo $COPY_TABLES | wc -w | tr -d ' ') tables (graph.*, public.devices, public.quantities)..."
# COPY, not pg_dump --data-only: pg_dump also reads every owned sequence, which
# needs SELECT on it. One REPEATABLE READ transaction keeps the tables consistent.
mkdir "$WORK/data"
cols_of() {   # non-generated columns, in order, as both COPY directions see them
    src -tAq -c "SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) FROM pg_attribute
                 WHERE attrelid = '$1'::regclass AND attnum > 0 AND NOT attisdropped AND attgenerated = ''"
}
{ echo "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;"
  i=0
  for t in $COPY_TABLES; do
      i=$((i + 1)); c=$(cols_of "$t")
      echo "$t|$c" >> "$WORK/data/manifest"
      echo "\\copy (SELECT $c FROM $t) TO '$WORK/data/$i.copy'"
  done
  echo "COMMIT;"; } > "$WORK/copy_out.sql"
src -q -f "$WORK/copy_out.sql"

# ---------------------------------------------------------------------------
# 4. rebuild the target
# ---------------------------------------------------------------------------
echo "recreating $TGT_NAME on $TGT_LABEL..."
tgt_db postgres -q -c "DROP DATABASE IF EXISTS \"$TGT_NAME\" WITH (FORCE)" -c "CREATE DATABASE \"$TGT_NAME\""

# roles named in grants must exist; created NOLOGIN, no passwords copied
roles=$(src -tAq -c "SELECT string_agg(quote_literal(rolname), ',') FROM pg_roles WHERE rolname !~ '^pg_'")
tgt -q -c "DO \$\$ DECLARE r text; BEGIN
    FOREACH r IN ARRAY ARRAY[$roles]::text[] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END \$\$"

"$PG_BIN/pg_restore" -l "$WORK/schema.dump" | grep -vE 'EXTENSION - timescaledb|EXTENSION .*timescaledb' > "$WORK/all.toc"
grep -E '^[0-9]+; [0-9]+ [0-9]+ SCHEMA - ' "$WORK/all.toc" | grep -vE ' SCHEMA - public ' > "$WORK/schemas.toc" || true
grep -vE '^[0-9]+; [0-9]+ [0-9]+ SCHEMA - ' "$WORK/all.toc" > "$WORK/rest.toc"

echo "restoring structure..."
tgt_restore -L "$WORK/schemas.toc" "$WORK/schema.dump"
[ -s "$WORK/standins.sql" ] && tgt -q -f "$WORK/standins.sql"
set +e
tgt_restore -L "$WORK/rest.toc" "$WORK/schema.dump" 2> "$WORK/restore.err"
set -e

echo "restoring data..."
# replica role: no triggers and no foreign-key checks, as for any dump restore
{ echo "BEGIN;"; echo "SET LOCAL session_replication_role = replica;"
  i=0
  while IFS='|' read -r t c; do
      i=$((i + 1)); echo "\\copy $t ($c) FROM '$WORK/data/$i.copy'"
  done < "$WORK/data/manifest"
  echo "COMMIT;"; } > "$WORK/copy_in.sql"
tgt -q -f "$WORK/copy_in.sql"

n_max=0
while read -r seq how; do
    [ -n "$seq" ] || continue
    if [ "$how" = exact ]; then
        read -r lv called < <(src -tAq -F ' ' -c "SELECT last_value, is_called FROM $seq")
        tgt -tAq -c "SELECT setval('$seq', $lv, $called)" >/dev/null
    else
        n_max=$((n_max + 1))
        tgt -tAq -c "
            DO \$\$ DECLARE col record; mx bigint;
            BEGIN
                SELECT format('%s', d.refobjid::regclass) tbl, quote_ident(a.attname) att INTO col
                  FROM pg_depend d JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
                 WHERE d.objid = '$seq'::regclass AND d.deptype IN ('a','i');
                EXECUTE format('SELECT max(%s) FROM %s', col.att, col.tbl) INTO mx;
                IF mx IS NULL THEN PERFORM setval('$seq', 1, false); ELSE PERFORM setval('$seq', mx, true); END IF;
            END \$\$" >/dev/null
    fi
done <<< "$SEQS"
[ "$n_max" = 0 ] || echo "  $n_max sequence(s) $SRC_USER cannot read were set from max(id): next ids on dev may be lower than on $SRC_LABEL"

if [ -n "$TEL_FROM" ]; then
    cols=$(tgt -tAq -c "SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) FROM pg_attribute
                        WHERE attrelid = 'public.telemetry_15min_agg'::regclass AND attnum > 0 AND NOT attisdropped")
    echo "copying telemetry_15min_agg, tenant $TENANT, $TEL_FROM (minus one day) to $TEL_TO..."
    src -q -c "\copy (SELECT $cols FROM public.telemetry_15min_agg WHERE tenant_id = $TENANT AND bucket >= DATE '$TEL_FROM' - 1 AND bucket < DATE '$TEL_TO') TO STDOUT" \
        | tgt -q -c "\copy public.telemetry_15min_agg ($cols) FROM STDIN"
    echo "  $(tgt -tAq -c "SELECT count(*) FROM public.telemetry_15min_agg") rows"
fi

tgt -q -c "ANALYZE"

# ---------------------------------------------------------------------------
# 5. verify: the graph schema and the copied tables must match the source exactly
# ---------------------------------------------------------------------------
INVENTORY="
SELECT 'rel ' || c.relkind::text || ' ' || c.relname FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'graph' AND c.relkind IN ('r','v','m','S','p','f','i')
UNION ALL
SELECT 'fn  ' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'graph'
UNION ALL
SELECT 'tg  ' || c.relname || '.' || t.tgname FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'graph' AND NOT t.tgisinternal
UNION ALL
SELECT 'con ' || conrelid::regclass || '.' || conname FROM pg_constraint co
  JOIN pg_namespace n ON n.oid = co.connamespace WHERE n.nspname = 'graph'
ORDER BY 1"
src -tAq -c "$INVENTORY" > "$WORK/inv.src"
tgt -tAq -c "$INVENTORY" > "$WORK/inv.tgt"

COUNTS_SQL="SELECT format('SELECT %L || '' '' || count(*) FROM %s;', t, t) FROM (
    SELECT format('%I.%I', schemaname, tablename) t FROM pg_tables WHERE schemaname = 'graph'
    UNION ALL SELECT 'public.devices' UNION ALL SELECT 'public.quantities') x ORDER BY 1"
src -tAq -c "$COUNTS_SQL" > "$WORK/counts.sql"
src -tAq -f "$WORK/counts.sql" > "$WORK/counts.src"
tgt -tAq -f "$WORK/counts.sql" > "$WORK/counts.tgt"

errs=$(grep -c '^pg_restore: error:' "$WORK/restore.err" || true)
if [ "$errs" -gt 0 ]; then
    echo ""
    echo "$errs object(s) could not be created on dev and were skipped (any in graph fails the run below):"
    { grep -oE '^Command was: [A-Z ]+[^ (;]+' "$WORK/restore.err" || true; } \
        | sed 's/^Command was: /  /' | sort -u | head -40
    grep -q '^Command was:' "$WORK/restore.err" || sed -n '1,20p' "$WORK/restore.err" | sed 's/^/  /'
fi

fail=
if ! diff -u "$WORK/inv.src" "$WORK/inv.tgt" > "$WORK/inv.diff"; then
    echo ""; echo "graph schema objects differ (- source, + dev):"
    grep -E '^[-+][^-+]' "$WORK/inv.diff" | sed 's/^/  /'; fail=1
fi
if ! diff -u "$WORK/counts.src" "$WORK/counts.tgt" > "$WORK/counts.diff"; then
    echo ""; echo "row counts differ (- source, + dev); rerun if production changed during the copy:"
    grep -E '^[-+][^-+]' "$WORK/counts.diff" | sed 's/^/  /'; fail=1
fi
[ -z "$fail" ] || die "dev is NOT a faithful copy of the graph schema"

echo ""
echo "graph schema identical: $(wc -l < "$WORK/inv.src" | tr -d ' ') objects; row counts identical:"
sed 's/^/  /' "$WORK/counts.tgt"
if [ "$(tgt -tAq -c "SELECT to_regclass('graph.schema_migration') IS NOT NULL")" = t ]; then
    echo "ledger copied from $SRC_LABEL: tools/migrate.sh status"
else
    echo "no ledger on $SRC_LABEL yet: tools/migrate.sh init --confirm $TGT_LABEL, then baseline 030"
fi
echo "done: $TGT_LABEL is a copy of $SRC_LABEL as of $(date '+%Y-%m-%d %H:%M')"
