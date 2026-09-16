#!/usr/bin/env bash
# Run central migrations using ArcadeDB HTTP API.
#
# Usage:
#   ./scripts/migrate-central.sh [migrate|validate|info|reconcile-lineage]
#
# Environment variables:
#   ARCADEDB_HOST              ArcadeDB server hostname (default: localhost)
#   ARCADEDB_HTTP_PORT         ArcadeDB HTTP API port (default: 2480)
#   ARCADEDB_ROOT_PASSWORD     Root password (required; no default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MIGRATIONS_DIR="$PROJECT_DIR/central/sql"

if [ -f "$PROJECT_DIR/.env.central" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/.env.central"
    set +a
fi

SUBCOMMAND="${1:-migrate}"

ARCADEDB_HOST="${ARCADEDB_HOST:-localhost}"
ARCADEDB_HTTP_PORT="${ARCADEDB_HTTP_PORT:-2480}"
# No default root password (review finding S-7): refuse to run without one.
if [[ -z "${ARCADEDB_ROOT_PASSWORD:-}" ]]; then
    echo "Error: ARCADEDB_ROOT_PASSWORD is not set (define it in .env.central)" >&2
    exit 1
fi
ARCADEDB_CENTRAL_DB="nomon_central"

BASE_URL="http://${ARCADEDB_HOST}:${ARCADEDB_HTTP_PORT}"
# shellcheck disable=SC2034  # consumed by curl_auth() in the sourced curl-auth.sh (dynamic scoping)
AUTH="root:${ARCADEDB_ROOT_PASSWORD}"

# shellcheck disable=SC2034
REPO_RELATIVE_PREFIX="central/sql"

source "$SCRIPT_DIR/lib/curl-auth.sh"
source "$SCRIPT_DIR/lib/migrate-common.sh"

usage() {
    echo "Usage: $0 [migrate|validate|info|reconcile-lineage|repair-checksums]"
    echo ""
    echo "Apply or inspect central migrations using ArcadeDB API."
    echo ""
    echo "  repair-checksums  Re-record the stored checksum of already-applied"
    echo "                    migrations from the current file contents."
    echo "                    Requires NOMOGRAPHIC_CONFIRM_REPAIR=1. Only use"
    echo "                    after confirming the live schema matches the files;"
    echo "                    it cannot tell a legacy hash from a real edit."
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

api_db_sql() {
    local sql="$1"
    local lang="${2:-sqlscript}"
    local payload
    payload="{\"language\":\"${lang}\",\"command\":\"$(escape_json "$sql")\"}"
    curl_auth -sS -w "\n%{http_code}" \
        -X POST "${BASE_URL}/api/v1/command/${ARCADEDB_CENTRAL_DB}" \
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
        echo "Error: central migrations directory not found: $MIGRATIONS_DIR"
        exit 1
    fi

    mapfile -t MIGRATION_FILES < <(find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name 'V*__*.sql' | sort -V)

    if [ "${#MIGRATION_FILES[@]}" -eq 0 ]; then
        echo "Error: no central migration files found in $MIGRATIONS_DIR"
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

        record_lineage "$file_path" "central/sql/${file_name}"

        applied_count=$((applied_count + 1))
    done

    echo "==> Central migration apply complete (${applied_count} newly applied)."
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
        echo "Error: central migration validation failed with ${mismatches} checksum mismatch(es)."
        exit 1
    fi

    echo "==> Central migration validation complete (${pending} pending)."
}

repair_checksums() {
    if [ "${NOMOGRAPHIC_CONFIRM_REPAIR:-0}" != "1" ]; then
        echo "Error: repair-checksums rewrites recorded migration checksums."
        echo ""
        echo "A mismatch means the file on disk differs from what was recorded"
        echo "when the migration was applied. That is either a legacy hash, or a"
        echo "migration that was edited after being applied — and this command"
        echo "cannot tell the two apart. Confirm the live schema really matches"
        echo "the files first, then re-run with NOMOGRAPHIC_CONFIRM_REPAIR=1."
        exit 1
    fi

    echo "==> Repairing central migration checksums"
    local repaired=0
    local checked=0

    for file_path in "${MIGRATION_FILES[@]}"; do
        local file_name
        local version
        local escaped_version
        local count
        local expected_checksum
        local actual_checksum
        local escaped_checksum

        file_name="$(basename "$file_path")"
        version="$(migration_version "$file_name")"
        escaped_version="$(escape_sql_literal "$version")"
        count="$(record_count "SELECT count(*) as count FROM SchemaMigration WHERE version = '${escaped_version}'")"

        if [ "${count:-0}" -eq 0 ] 2>/dev/null; then
            echo "  [skip] ${file_name} (not applied)"
            continue
        fi

        checked=$((checked + 1))
        expected_checksum="$(sha256_file "$file_path")"
        actual_checksum="$(record_checksum "$version")"
        if [ "$expected_checksum" = "$actual_checksum" ]; then
            echo "  [ok] ${file_name}"
            continue
        fi

        escaped_checksum="$(escape_sql_literal "$expected_checksum")"
        run_sql "UPDATE SchemaMigration SET checksum = '${escaped_checksum}' WHERE version = '${escaped_version}'" \
            "repair checksum ${file_name}" >/dev/null
        echo "  [repaired] ${file_name}"
        echo "             was ${actual_checksum}"
        echo "             now ${expected_checksum}"
        repaired=$((repaired + 1))
    done

    echo "==> Repaired ${repaired} of ${checked} applied migration(s)."
}

info_migrations() {
    echo "==> Central migration status"
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
    migrate|validate|info|reconcile-lineage|repair-checksums)
        ;;
    *)
        echo "Error: unknown subcommand '${SUBCOMMAND}'."
        usage
        ;;
esac

require_command curl

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
        echo "==> Reconciling central schema lineage ..."
        reconcile_all_lineage
        ;;
    repair-checksums)
        repair_checksums
        ;;
esac
