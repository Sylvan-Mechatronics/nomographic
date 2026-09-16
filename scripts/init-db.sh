#!/usr/bin/env bash
# Initialize nomon databases: create instances and run migrations.
#
# Usage:
#   ./scripts/init-db.sh [central|local|all]
#
# Default: all (creates and migrates both central and local databases)
#
# Environment variables:
#   ARCADEDB_HOST          — ArcadeDB server hostname (default: localhost)
#   ARCADEDB_HTTP_PORT     — ArcadeDB HTTP API port (default: 2480)
#   ARCADEDB_ROOT_PASSWORD — ArcadeDB root password (required; no default)
#   ARCADEDB_LOCAL_DATA    — Path for local embedded data (default: local/data)
#   INIT_DB_RETRIES        — Max health-check retries (default: 30)
#   INIT_DB_RETRY_DELAY    — Seconds between retries (default: 2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/curl-auth.sh"

TARGET="${1:-all}"

usage() {
    echo "Usage: $0 [central|local|all]"
    echo ""
    echo "Initialize nomon databases and run central/local migrations."
    echo ""
    echo "Arguments:"
    echo "  central    Create and migrate central database only"
    echo "  local      Create and migrate local database only"
    echo "  all        Create and migrate both databases (default)"
    exit 1
}

# Source the central env (ARCADEDB_HOST/PORT/ROOT_PASSWORD, INIT_DB_*)
load_central_env() {
    if [ -f "$PROJECT_DIR/.env.central" ]; then
        set -a
        # shellcheck disable=SC1091
        . "$PROJECT_DIR/.env.central"
        set +a
    fi
}

# Source the local env (ARCADEDB_LOCAL_DATA, LOCAL_* vars)
load_local_env() {
    if [ -f "$PROJECT_DIR/.env.local" ]; then
        set -a
        # shellcheck disable=SC1091
        . "$PROJECT_DIR/.env.local"
        set +a
    fi
}

wait_for_arcadedb() {
    echo "==> Waiting for ArcadeDB at ${BASE_URL} ..."
    local attempt=0
    while [ "$attempt" -lt "$INIT_DB_RETRIES" ]; do
        if curl -sf "${BASE_URL}/api/v1/ready" > /dev/null 2>&1; then
            echo "==> ArcadeDB is ready."
            return 0
        fi
        attempt=$((attempt + 1))
        echo "    Attempt ${attempt}/${INIT_DB_RETRIES} — not ready, retrying in ${INIT_DB_RETRY_DELAY}s ..."
        sleep "$INIT_DB_RETRY_DELAY"
    done
    echo "Error: ArcadeDB did not become ready after ${INIT_DB_RETRIES} attempts."
    exit 1
}

create_central_database() {
    echo "==> Creating nomon_central database ..."
    local response
    local http_code
    # Capture both body and status code in a single request
    # shellcheck disable=SC2034  # consumed by curl_auth() in the sourced curl-auth.sh (dynamic scoping)
    local AUTH="root:${ARCADEDB_ROOT_PASSWORD}"
    response=$(curl_auth -s -w "\n%{http_code}" \
        -X POST "${BASE_URL}/api/v1/server" \
        -H "Content-Type: application/json" \
        -d '{"command": "create database nomon_central"}')
    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        echo "    nomon_central created."
    elif [ "$http_code" = "400" ] && echo "$response" | grep -qi "already exists"; then
        echo "    nomon_central already exists, skipping."
    else
        echo "Error: failed to create nomon_central (HTTP ${http_code}): ${response}"
        exit 1
    fi
}

create_local_database() {
    echo "==> Creating local data directory at ${ARCADEDB_LOCAL_DATA} ..."
    mkdir -p "${PROJECT_DIR}/${ARCADEDB_LOCAL_DATA}"
    echo "    Local data directory ready."
}

init_central() {
    load_central_env
    ARCADEDB_HOST="${ARCADEDB_HOST:-localhost}"
    ARCADEDB_HTTP_PORT="${ARCADEDB_HTTP_PORT:-2480}"
    if [[ -z "${ARCADEDB_ROOT_PASSWORD:-}" ]]; then
        echo "Error: ARCADEDB_ROOT_PASSWORD is not set (define it in .env.central)" >&2
        exit 1
    fi
    INIT_DB_RETRIES="${INIT_DB_RETRIES:-30}"
    INIT_DB_RETRY_DELAY="${INIT_DB_RETRY_DELAY:-2}"
    BASE_URL="http://${ARCADEDB_HOST}:${ARCADEDB_HTTP_PORT}"

    wait_for_arcadedb
    create_central_database
    echo "==> Running central migrations ..."
    "$SCRIPT_DIR/migrate-central.sh" migrate
}

init_local() {
    load_local_env
    ARCADEDB_LOCAL_DATA="${ARCADEDB_LOCAL_DATA:-local/data}"

    create_local_database
    echo "==> Running local migrations ..."
    ARCADEDB_LOCAL_DATA="$ARCADEDB_LOCAL_DATA" \
    "$SCRIPT_DIR/migrate-local.sh" migrate
}

case "$TARGET" in
    central)
        init_central
        ;;
    local)
        init_local
        ;;
    all)
        # Use subshells to prevent central vars from leaking into local init and vice versa.
        (init_central)
        (init_local)
        ;;
    *)
        echo "Error: unknown target '${TARGET}'."
        usage
        ;;
esac

echo "==> Database initialization complete."
