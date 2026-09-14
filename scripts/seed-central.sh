#!/usr/bin/env bash
# Seed the nomon_central database with test data.
#
# Usage:
#   ./scripts/seed-central.sh
#
# Creates:
#   - Test user: test@nomon.dev (password: testpassword123)
#   - Test vehicle: NOMON-TEST-001, explorer-v1
#   - OwnsDevice edge linking user → vehicle
#
# Idempotent: checks for existing records before inserting.
#
# SAFETY: this creates an account with a PUBLICLY KNOWN password. It refuses to
# run unless NOMOGRAPHIC_SEED_TEST_DATA=1 is set, so it cannot be run against a
# real central database by habit (review finding S-7).
#
# Environment variables:
#   NOMOGRAPHIC_SEED_TEST_DATA — must be "1" to run at all
#   ARCADEDB_HOST          — ArcadeDB server hostname (default: localhost)
#   ARCADEDB_HTTP_PORT     — ArcadeDB HTTP API port (default: 2480)
#   ARCADEDB_ROOT_PASSWORD — ArcadeDB root password (required; no default)

set -euo pipefail

if [[ "${NOMOGRAPHIC_SEED_TEST_DATA:-}" != "1" ]]; then
    echo "Refusing to seed: this inserts a test account with a well-known password." >&2
    echo "Set NOMOGRAPHIC_SEED_TEST_DATA=1 to run against a throwaway dev database only." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load project .env.central so script credentials match docker compose defaults.
if [ -f "$PROJECT_DIR/.env.central" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/.env.central"
    set +a
fi

ARCADEDB_HOST="${ARCADEDB_HOST:-localhost}"
ARCADEDB_HTTP_PORT="${ARCADEDB_HTTP_PORT:-2480}"
# No default root password (review finding S-7): refuse to run without one.
if [[ -z "${ARCADEDB_ROOT_PASSWORD:-}" ]]; then
    echo "Error: ARCADEDB_ROOT_PASSWORD is not set (define it in .env.central)" >&2
    exit 1
fi

BASE_URL="http://${ARCADEDB_HOST}:${ARCADEDB_HTTP_PORT}"
API_URL="${BASE_URL}/api/v1/command/nomon_central"
# shellcheck disable=SC2034  # consumed by curl_auth() in the sourced curl-auth.sh (dynamic scoping)
AUTH="root:${ARCADEDB_ROOT_PASSWORD}"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/curl-auth.sh"

# Pre-generated bcrypt hash of "testpassword123" (10 rounds)
TEST_PASSWORD_HASH='$2b$10$7xYbWolLGj/pkV7gSTPgIeXCrC93VLuhEzCL.yIR3EGKSMw14QKFO'

run_sql() {
    local sql="$1"
    curl_auth -s \
        -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{\"language\": \"sql\", \"command\": \"${sql}\"}"
}

run_cypher() {
    local cypher="$1"
    curl_auth -s \
        -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{\"language\": \"cypher\", \"command\": \"${cypher}\"}"
}

record_count() {
    local sql="$1"
    local result
    result=$(run_sql "$sql")
    # ArcadeDB returns result array; extract count from first record
    echo "$result" | grep -o '"count":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "0"
}

NOW=$(date -u '+%Y-%m-%d %H:%M:%S')

echo "==> Seeding nomon_central with test data ..."

# --- Test User ---
echo "--- Checking for test user (test@nomon.dev) ..."
USER_COUNT=$(record_count "SELECT count(*) as count FROM User WHERE email = 'test@nomon.dev'")

if [ "$USER_COUNT" -gt 0 ] 2>/dev/null; then
    echo "    Test user already exists, skipping."
else
    echo "    Inserting test user ..."
    run_cypher "CREATE (u:User {email: 'test@nomon.dev', display_name: 'Test User', password_hash: '${TEST_PASSWORD_HASH}', created_at: '${NOW}', active: true})" > /dev/null
    echo "    Test user created."
fi

# --- Test Vehicle ---
echo "--- Checking for test vehicle (NOMON-TEST-001) ..."
VEHICLE_COUNT=$(record_count "SELECT count(*) as count FROM Vehicle WHERE vin = 'NOMON-TEST-001'")

if [ "$VEHICLE_COUNT" -gt 0 ] 2>/dev/null; then
    echo "    Test vehicle already exists, skipping."
else
    echo "    Inserting test vehicle ..."
    run_cypher "CREATE (v:Vehicle {vin: 'NOMON-TEST-001', model: 'explorer-v1', registered_at: '${NOW}'})" > /dev/null
    echo "    Test vehicle created."
fi

# --- OwnsDevice Edge ---
echo "--- Checking for OwnsDevice edge ..."
EDGE_COUNT=$(record_count "SELECT count(*) as count FROM OwnsDevice WHERE in.vin = 'NOMON-TEST-001' AND out.email = 'test@nomon.dev'")

if [ "$EDGE_COUNT" -gt 0 ] 2>/dev/null; then
    echo "    OwnsDevice edge already exists, skipping."
else
    echo "    Creating OwnsDevice edge ..."
    run_cypher "MATCH (u:User {email: 'test@nomon.dev'}), (v:Vehicle {vin: 'NOMON-TEST-001'}) CREATE (u)-[:OwnsDevice {registered_at: '${NOW}', role: 'owner'}]->(v)" > /dev/null
    echo "    OwnsDevice edge created."
fi

echo "==> Seeding complete."
