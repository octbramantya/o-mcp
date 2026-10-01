# Sourced by tools/*.sh. A connection comes from an env file and nowhere else:
# the file is parsed, never sourced, every key is required, and PG* shell
# variables are cleared so nothing from the shell can redirect a run.

die() { echo "${0##*/}: $*" >&2; exit 1; }

env_get() {   # env_get FILE KEY
    local v
    v=$(grep -E "^$2=" "$1" | tail -n 1 | cut -d= -f2-) || true
    v=${v%$'\r'}; v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
    [ -n "$v" ] || die "$1 is missing $2. See .env.example."
    printf '%s' "$v"
}

load_conn() { # load_conn FILE PREFIX  ->  PREFIX_LABEL PREFIX_HOST PREFIX_PORT PREFIX_NAME PREFIX_USER PREFIX_PASSWORD
    local k v
    [ -f "$1" ] || die "$1 not found. Copy .env.example and fill it in."
    for k in LABEL HOST PORT NAME USER PASSWORD; do
        v=$(env_get "$1" "DB_$k") || exit 1
        printf -v "${2}_$k" '%s' "$v"
    done
}

unset PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGPASSFILE PGSERVICE PGSERVICEFILE PGOPTIONS
