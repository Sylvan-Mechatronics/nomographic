#!/usr/bin/env bash
# Run local embedded migrations using ArcadeDB HTTP API.
#
# Usage:
#   ./scripts/migrate-local.sh [migrate|validate|info|reconcile-lineage]
#
# Environment variables:
#   ARCADEDB_LOCAL_DATA               Path for local embedded data (default: local/data)
#   ARCADEDB_LOCAL_DB                 Local database name (default: nomon_local)
#   ARCADEDB_LOCAL_HOST               Local DB host when using running service (default: 127.0.0.1)
#   ARCADEDB_LOCAL_HTTP_PORT          Local DB API port when using running service
#                                     (default: LOCAL_MIGRATOR_HTTP_PORT)
#   ARCADEDB_LOCAL_ROOT_PASSWORD      Root password when using running service
#                                     (default: LOCAL_ARCADEDB_ROOT_PASSWORD)
#   LOCAL_ARCADEDB_ROOT_PASSWORD      Shared root password for local service + migrator
#                                     (required; no default)
#   LOCAL_ARCADEDB_OPTS_MEMORY        Shared ArcadeDB memory options for local service + migrator
#   LOCAL_MIGRATOR_IMAGE              ArcadeDB Docker image (default: arcadedata/arcadedb:latest)
#   LOCAL_MIGRATOR_HTTP_PORT          Local temporary migrator HTTP port (default: 2481)
#   LOCAL_MIGRATOR_STARTUP_RETRIES    Readiness retries (default: 30)
#   LOCAL_MIGRATOR_STARTUP_DELAY      Seconds between readiness retries (default: 1)
#   LOCAL_MIGRATOR_USE_RUNNING_SERVICE 1 to run migrations against existing service
#                                     (default: 0)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATIONS_DIR="$PROJECT_DIR/local/sql"

# .env.local uses plain assignments (not ${VAR:-default}), so sourcing it
# unconditionally would silently clobber overrides a caller already exported
# (e.g. deploy-local.sh setting LOCAL_MIGRATOR_USE_RUNNING_SERVICE=1 to reuse
# the running service instead of starting a second, memory-hungry temporary
# migrator container). Preserve any caller-provided values across the source.
_CALLER_OVERRIDE_VARS=(
    LOCAL_MIGRATOR_USE_RUNNING_SERVICE
    ARCADEDB_LOCAL_HOST
    ARCADEDB_LOCAL_HTTP_PORT
    ARCADEDB_LOCAL_ROOT_PASSWORD
    ARCADEDB_LOCAL_DB
)
for _var in "${_CALLER_OVERRIDE_VARS[@]}"; do
    if [[ -n "${!_var+x}" ]]; then
        declare "_preset_${_var}=${!_var}"
    fi
done

if [ -f "$PROJECT_DIR/.env.local" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/.env.local"
    set +a
fi

for _var in "${_CALLER_OVERRIDE_VARS[@]}"; do
    _preset_name="_preset_${_var}"
    if [[ -n "${!_preset_name+x}" ]]; then
        declare "${_var}=${!_preset_name}"
        unset "$_preset_name"
    fi
done
unset _var _preset_name _CALLER_OVERRIDE_VARS

# Deprecated vars are intentionally ignored.
unset LOCAL_MIGRATOR_ROOT_PASSWORD LOCAL_MIGRATOR_OPTS_MEMORY

SUBCOMMAND="${1:-migrate}"

ARCADEDB_LOCAL_DATA="${ARCADEDB_LOCAL_DATA:-local/data}"
ARCADEDB_LOCAL_DB="${ARCADEDB_LOCAL_DB:-nomon_local}"
if [[ -z "${LOCAL_ARCADEDB_ROOT_PASSWORD:-}" ]]; then
    echo "Error: LOCAL_ARCADEDB_ROOT_PASSWORD is not set (define it in .env.local)" >&2
    exit 1
fi
LOCAL_ARCADEDB_OPTS_MEMORY="${LOCAL_ARCADEDB_OPTS_MEMORY:-}"
LOCAL_MIGRATOR_IMAGE="${LOCAL_MIGRATOR_IMAGE:-arcadedata/arcadedb:latest}"
LOCAL_MIGRATOR_HTTP_PORT="${LOCAL_MIGRATOR_HTTP_PORT:-2481}"
LOCAL_MIGRATOR_JAVA_OPTS="${LOCAL_MIGRATOR_JAVA_OPTS:--Darcadedb.server.rootPassword=${LOCAL_ARCADEDB_ROOT_PASSWORD}}"
LOCAL_MIGRATOR_STARTUP_RETRIES="${LOCAL_MIGRATOR_STARTUP_RETRIES:-30}"
LOCAL_MIGRATOR_STARTUP_DELAY="${LOCAL_MIGRATOR_STARTUP_DELAY:-1}"
LOCAL_MIGRATOR_USE_RUNNING_SERVICE="${LOCAL_MIGRATOR_USE_RUNNING_SERVICE:-0}"

ARCADEDB_LOCAL_HOST="${ARCADEDB_LOCAL_HOST:-127.0.0.1}"
ARCADEDB_LOCAL_HTTP_PORT="${ARCADEDB_LOCAL_HTTP_PORT:-$LOCAL_MIGRATOR_HTTP_PORT}"
ARCADEDB_LOCAL_ROOT_PASSWORD="${ARCADEDB_LOCAL_ROOT_PASSWORD:-$LOCAL_ARCADEDB_ROOT_PASSWORD}"

# In temporary-container mode, always use the same resolved root password
# for startup and API auth to prevent mismatches.
if [[ "$LOCAL_MIGRATOR_USE_RUNNING_SERVICE" != "1" ]]; then
    if [[ "$LOCAL_MIGRATOR_JAVA_OPTS" =~ -Darcadedb\.server\.rootPassword=([^[:space:]]+) ]]; then
        ARCADEDB_LOCAL_ROOT_PASSWORD="${BASH_REMATCH[1]}"
    else
        ARCADEDB_LOCAL_ROOT_PASSWORD="$LOCAL_ARCADEDB_ROOT_PASSWORD"
    fi
    # ...and always talk to the temporary container we just published, not to
    # the running local *service*. ARCADEDB_LOCAL_HOST/HTTP_PORT describe that
    # service (the Pi's embedded DB on 2482) and are only meaningful when
    # LOCAL_MIGRATOR_USE_RUNNING_SERVICE=1; honouring them here pointed the
    # readiness probe at a port the migrator never publishes, so startup could
    # never succeed whenever the two ports differ — as they do in
    # .env.local.example (migrator 2481 vs service 2482).
    ARCADEDB_LOCAL_HOST="127.0.0.1"
    ARCADEDB_LOCAL_HTTP_PORT="$LOCAL_MIGRATOR_HTTP_PORT"
fi

BASE_URL="http://${ARCADEDB_LOCAL_HOST}:${ARCADEDB_LOCAL_HTTP_PORT}"
# shellcheck disable=SC2034  # consumed by curl_auth() in the sourced curl-auth.sh (dynamic scoping)
AUTH="root:${ARCADEDB_LOCAL_ROOT_PASSWORD}"
CONTAINER_NAME="nomon-local-migrator-$$"

# shellcheck disable=SC2034
REPO_RELATIVE_PREFIX="local/sql"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/curl-auth.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/migrate-common.sh"

usage() {
    echo "Usage: $0 [migrate|validate|info|reconcile-lineage]"
    echo ""
    echo "Apply or inspect local embedded migrations using ArcadeDB API."
    exit 1
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command '$1' is not installed."
        exit 127
    fi
}

escape_json() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'
}

escape_sql_literal() {
    printf '%s' "$1" | sed "s/'/''/g"
}


sha256_file() {
    local file_path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file_path" | awk '{print $1}'
        return
    fi
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file_path" | awk '{print $1}'
        return
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file_path" | awk '{print $NF}'
        return
    fi
    echo "Error: no SHA-256 tool found (sha256sum, shasum, or openssl)."
    exit 127
}

api_server_command() {
    local command="$1"
    local payload
    payload="{\"command\":\"$(escape_json "$command")\"}"
    curl_auth -sS -w "\n%{http_code}" \
        -X POST "${BASE_URL}/api/v1/server" \
        -H "Content-Type: application/json" \
        -d "$payload"
}

api_db_sql() {
    local sql="$1"
    local lang="${2:-sqlscript}"
    local payload
    payload="{\"language\":\"${lang}\",\"command\":\"$(escape_json "$sql")\"}"
    curl_auth -sS -w "\n%{http_code}" \
        -X POST "${BASE_URL}/api/v1/command/${ARCADEDB_LOCAL_DB}" \
        -H "Content-Type: application/json" \
        -d "$payload"
}

run_sql() {
    local sql="$1"
    local action="$2"
    local allow_already_exists="${3:-0}"
    local response
    local http_code
    response="$(api_db_sql "$sql")"
    http_code="$(echo "$response" | tail -1)"
    response="$(echo "$response" | sed '$d')"

    if [ "$http_code" != "200" ]; then
        if [ "$allow_already_exists" = "1" ] && echo "$response" | grep -qi "already exists"; then
            printf '%s' "$response"
            return
        fi
        echo "Error: ${action} failed (HTTP ${http_code}): ${response}"
        exit 1
    fi

    if echo "$response" | grep -q '"error"'; then
        echo "Error: ${action} failed: ${response}"
        exit 1
    fi

    printf '%s' "$response"
}

record_count() {
    local sql="$1"
    local result
    result="$(run_sql "$sql" "count query")"
    echo "$result" | grep -o '"count":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "0"
}

record_checksum() {
    local version="$1"
    local escaped_version
    escaped_version="$(escape_sql_literal "$version")"
    local result
    result="$(run_sql "SELECT checksum FROM SchemaMigration WHERE version = '${escaped_version}' LIMIT 1" "checksum lookup")"
    if ! echo "$result" | grep -q '"checksum"'; then
        echo ""
        return
    fi
    echo "$result" | sed -n 's/.*"checksum":"\([^"]*\)".*/\1/p' | head -1
}

wait_for_arcadedb() {
    echo "==> Waiting for local migrator API on ${BASE_URL} ..."
    local attempt=0
    while [ "$attempt" -lt "$LOCAL_MIGRATOR_STARTUP_RETRIES" ]; do
        if curl -sf "${BASE_URL}/api/v1/ready" >/dev/null 2>&1; then
            echo "==> Local migrator API is ready."
            return
        fi
        attempt=$((attempt + 1))
        sleep "$LOCAL_MIGRATOR_STARTUP_DELAY"
    done
    echo "Error: local migrator did not become ready in time."
    docker logs "$CONTAINER_NAME" 2>/dev/null || true
    exit 1
}

cleanup() {
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
}

start_local_migrator() {
    local host_data_dir="$PROJECT_DIR/$ARCADEDB_LOCAL_DATA"
    mkdir -p "$host_data_dir"

    echo "==> Starting temporary local migrator container (${LOCAL_MIGRATOR_IMAGE}) ..."
    DOCKER_ENV_OPTS=(-e "JAVA_OPTS=${LOCAL_MIGRATOR_JAVA_OPTS}")
    if [[ -n "${LOCAL_ARCADEDB_OPTS_MEMORY}" ]]; then
        DOCKER_ENV_OPTS+=( -e "ARCADEDB_OPTS_MEMORY=${LOCAL_ARCADEDB_OPTS_MEMORY}" )
    fi
    docker run -d --rm \
        --name "$CONTAINER_NAME" \
        -p "${LOCAL_MIGRATOR_HTTP_PORT}:2480" \
        "${DOCKER_ENV_OPTS[@]}" \
        -v "${host_data_dir}:/home/arcadedb/databases" \
        "$LOCAL_MIGRATOR_IMAGE" >/dev/null

    wait_for_arcadedb
}

ensure_local_database() {
    local response
    local http_code
    response="$(api_server_command "create database ${ARCADEDB_LOCAL_DB}")"
    http_code="$(echo "$response" | tail -1)"
    response="$(echo "$response" | sed '$d')"

    if [ "$http_code" = "200" ]; then
        echo "==> Database ${ARCADEDB_LOCAL_DB} created."
        return
    fi

    if [ "$http_code" = "400" ] && echo "$response" | grep -qi "already exists"; then
        echo "==> Database ${ARCADEDB_LOCAL_DB} already exists."
        return
    fi

    echo "Error: failed to ensure database ${ARCADEDB_LOCAL_DB} (HTTP ${http_code}): ${response}"
    exit 1
}

ensure_metadata_schema() {
    run_sql "CREATE VERTEX TYPE SchemaMigration IF NOT EXISTS" "create SchemaMigration type" >/dev/null
    run_sql "CREATE PROPERTY SchemaMigration.version IF NOT EXISTS STRING" "create version property" >/dev/null
    run_sql "CREATE PROPERTY SchemaMigration.description IF NOT EXISTS STRING" "create description property" >/dev/null
    run_sql "CREATE PROPERTY SchemaMigration.script IF NOT EXISTS STRING" "create script property" >/dev/null
    run_sql "CREATE PROPERTY SchemaMigration.checksum IF NOT EXISTS STRING" "create checksum property" >/dev/null
    run_sql "CREATE PROPERTY SchemaMigration.applied_at IF NOT EXISTS DATETIME" "create applied_at property" >/dev/null
    run_sql "CREATE INDEX IF NOT EXISTS ON SchemaMigration (version) UNIQUE" "create migration index" >/dev/null
}

load_migration_files() {
    if [ ! -d "$MIGRATIONS_DIR" ]; then
        echo "Error: local migrations directory not found: $MIGRATIONS_DIR"
        exit 1
    fi

    mapfile -t MIGRATION_FILES < <(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name 'V*__*.sql' | sort -V)

    if [ "${#MIGRATION_FILES[@]}" -eq 0 ]; then
        echo "Error: no local migration files found in $MIGRATIONS_DIR"
        exit 1
    fi
}

migration_version() {
    local file_name="$1"
    echo "$file_name" | sed -E 's/^V([0-9]+)__.*\.sql$/\1/'
}

migration_description() {
    local file_name="$1"
    echo "$file_name" | sed -E 's/^V[0-9]+__(.*)\.sql$/\1/'
}

apply_migrations() {
    local applied_count=0
    for file_path in "${MIGRATION_FILES[@]}"; do
        local file_name
        local version
        local description
        local escaped_version
        local count
        local checksum
        local escaped_description
        local escaped_file
        local escaped_checksum

        file_name="$(basename "$file_path")"
        version="$(migration_version "$file_name")"
        description="$(migration_description "$file_name")"
        escaped_version="$(escape_sql_literal "$version")"

        count="$(record_count "SELECT count(*) as count FROM SchemaMigration WHERE version = '${escaped_version}'")"
        if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
            echo "  [skip] ${file_name} (version ${version}) already applied"
            continue
        fi

        echo "  [apply] ${file_name}"
        run_sql "$(cat "$file_path")" "apply migration ${file_name}" >/dev/null

        checksum="$(sha256_file "$file_path")"
        escaped_description="$(escape_sql_literal "$description")"
        escaped_file="$(escape_sql_literal "$file_name")"
        escaped_checksum="$(escape_sql_literal "$checksum")"

        run_sql "INSERT INTO SchemaMigration SET version = '${escaped_version}', description = '${escaped_description}', script = '${escaped_file}', checksum = '${escaped_checksum}', applied_at = sysdate()" "record migration ${file_name}" >/dev/null

        record_lineage "$file_path" "local/sql/${file_name}"

        applied_count=$((applied_count + 1))
    done

    echo "==> Local migration apply complete (${applied_count} newly applied)."
}

validate_migrations() {
    local mismatches=0
    local pending=0

    for file_path in "${MIGRATION_FILES[@]}"; do
        local file_name
        local version
        local escaped_version
        local count
        local expected_checksum
        local actual_checksum

        file_name="$(basename "$file_path")"
        version="$(migration_version "$file_name")"
        escaped_version="$(escape_sql_literal "$version")"
        count="$(record_count "SELECT count(*) as count FROM SchemaMigration WHERE version = '${escaped_version}'")"

        if [ "${count:-0}" -eq 0 ] 2>/dev/null; then
            echo "  [pending] ${file_name}"
            pending=$((pending + 1))
            continue
        fi

        expected_checksum="$(sha256_file "$file_path")"
        actual_checksum="$(record_checksum "$version")"
        if [ "$expected_checksum" != "$actual_checksum" ]; then
            echo "  [error] checksum mismatch for ${file_name}"
            mismatches=$((mismatches + 1))
        else
            echo "  [ok] ${file_name}"
        fi
    done

    if [ "$mismatches" -gt 0 ]; then
        echo "Error: local migration validation failed with ${mismatches} checksum mismatch(es)."
        exit 1
    fi

    echo "==> Local migration validation complete (${pending} pending)."
}

info_migrations() {
    echo "==> Local migration status"
    for file_path in "${MIGRATION_FILES[@]}"; do
        local file_name
        local version
        local escaped_version
        local count

        file_name="$(basename "$file_path")"
        version="$(migration_version "$file_name")"
        escaped_version="$(escape_sql_literal "$version")"
        count="$(record_count "SELECT count(*) as count FROM SchemaMigration WHERE version = '${escaped_version}'")"

        if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
            echo "  [applied] ${file_name}"
        else
            echo "  [pending] ${file_name}"
        fi
    done
}

case "$SUBCOMMAND" in
    migrate|validate|info|reconcile-lineage)
        ;;
    *)
        echo "Error: unknown subcommand '${SUBCOMMAND}'."
        usage
        ;;
esac

require_command curl

trap cleanup EXIT

if [[ "$LOCAL_MIGRATOR_USE_RUNNING_SERVICE" == "1" ]]; then
    echo "==> Using running local DB service at ${BASE_URL}"
    wait_for_arcadedb
else
    require_command docker
    start_local_migrator
fi

ensure_local_database
ensure_metadata_schema
load_migration_files

case "$SUBCOMMAND" in
    migrate)
        apply_migrations
        ;;
    validate)
        validate_migrations
        ;;
    info)
        info_migrations
        ;;
    reconcile-lineage)
        echo "==> Reconciling local schema lineage ..."
        reconcile_all_lineage
        ;;
esac
