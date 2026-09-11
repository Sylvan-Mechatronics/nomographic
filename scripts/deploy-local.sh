#!/usr/bin/env bash
# deploy-local.sh - Deploy local ArcadeDB service + local migrations to a Pi.
#
# Usage:
#   ./scripts/deploy-local.sh [<pi-host>]
#
# Arguments:
#   pi-host   SSH host (user@host or hostname). Overrides NOMON_PI_HOST/PI_HOST.
#
# Environment:
#   NOMON_PI_HOST                  SSH target (overridden by pi-host arg)
#   PI_HOST                        Backward-compatible SSH target alias
#   NOMON_SSH_KEY                  Path to SSH private key (optional)
#   NOMON_REMOTE_DIR               Remote nomographic directory on Pi
#                                   (default: ~/perceptua-nomon/nomographic)
#   sudo password env var          Optional sudo password for non-interactive
#                                   remote sudo operations
#   NOMOGRAPHIC_LOCAL_DB_SNAPSHOT  1 to snapshot local DB data before deploy
#                                   (default: 1)
#
# Remote behavior:
#   1. Sync nomographic to Pi.
#   2. Install/update systemd unit and env file.
#   3. Restart service and wait for readiness.
#   4. Run local migrations against the running local DB service.
#   5. On failure, rollback unit/env (and optional data snapshot) and ensure
#      service availability.

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"

if [ -f "$PROJECT_DIR/.env.local" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$PROJECT_DIR/.env.local"
    set +a
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,44p' "$0" | sed 's/^# \?//'
    exit 0
fi

PI_HOST="${1:-${NOMON_PI_HOST:-${PI_HOST:-}}}"
REMOTE_DIR="${NOMON_REMOTE_DIR:-~/perceptua-nomon/nomographic}"
SNAPSHOT_ENABLED="${NOMOGRAPHIC_LOCAL_DB_SNAPSHOT:-1}"

SERVICE_IMAGE="${LOCAL_ARCADEDB_IMAGE:-arcadedata/arcadedb:latest}"
SERVICE_HTTP_PORT="${LOCAL_ARCADEDB_HTTP_PORT:-2482}"
SERVICE_BINARY_PORT="${LOCAL_ARCADEDB_BINARY_PORT:-2425}"
SERVICE_ROOT_PASSWORD="${LOCAL_ARCADEDB_ROOT_PASSWORD:-testpassword}"
SERVICE_OPTS_MEMORY="${LOCAL_ARCADEDB_OPTS_MEMORY:-}"
SERVICE_DB_NAME="${ARCADEDB_LOCAL_DB:-nomon_local}"
SERVICE_DATA_PATH="${ARCADEDB_LOCAL_DATA:-/var/lib/nomographic/local-db}"

LOCAL_SERVICE_ENV_PAYLOAD="$(mktemp)"

cleanup_local_payload() {
    rm -f "$LOCAL_SERVICE_ENV_PAYLOAD" >/dev/null 2>&1 || true
}

escape_env_double_quoted() {
    local raw="$1"
    raw="${raw//\\/\\\\}"
    raw="${raw//\"/\\\"}"
    raw="${raw//\$/\\$}"
    raw="${raw//\`/\\\`}"
    printf '"%s"' "$raw"
}

write_env_line() {
    local key="$1"
    local value="$2"
    printf '%s=%s\n' "$key" "$(escape_env_double_quoted "$value")" >>"$LOCAL_SERVICE_ENV_PAYLOAD"
}

trap cleanup_local_payload EXIT

write_env_line "LOCAL_ARCADEDB_IMAGE" "$SERVICE_IMAGE"
write_env_line "LOCAL_ARCADEDB_HTTP_PORT" "$SERVICE_HTTP_PORT"
write_env_line "LOCAL_ARCADEDB_BINARY_PORT" "$SERVICE_BINARY_PORT"
write_env_line "LOCAL_ARCADEDB_ROOT_PASSWORD" "$SERVICE_ROOT_PASSWORD"
write_env_line "LOCAL_ARCADEDB_OPTS_MEMORY" "$SERVICE_OPTS_MEMORY"
write_env_line "ARCADEDB_LOCAL_DATA" "$SERVICE_DATA_PATH"
write_env_line "ARCADEDB_LOCAL_DB" "$SERVICE_DB_NAME"

if ! command -v base64 >/dev/null 2>&1; then
    echo "Error: required command 'base64' is not installed." >&2
    exit 127
fi

LOCAL_SERVICE_ENV_PAYLOAD_B64="$(base64 <"$LOCAL_SERVICE_ENV_PAYLOAD" | tr -d '\n')"

if [[ -z "$LOCAL_SERVICE_ENV_PAYLOAD_B64" ]]; then
    echo "Error: failed to generate local DB service env payload." >&2
    exit 1
fi

_NOMON_SUDO_PASS_QUOTED="$(printf '%q' "${NOMON_SUDO_PASS:-}")"

if [[ -n "$PI_HOST" ]]; then
    RSYNC_OPTS=(
        --archive
        --compress
        --delete
        --exclude='.git/'
        --exclude='__pycache__/'
        --exclude='*.pyc'
        --exclude='.env.local'
        --exclude='.env.central'
    )

    SSH_CMD="ssh -o StrictHostKeyChecking=accept-new"
    if [[ -n "${NOMON_SSH_KEY:-}" ]]; then
        SSH_CMD+=" -i ${NOMON_SSH_KEY}"
    fi
    RSYNC_OPTS+=(-e "${SSH_CMD}")

    rsync_dest="${PI_HOST}:${REMOTE_DIR}/"
    echo "==> Syncing nomographic to ${rsync_dest}..."
    rsync "${RSYNC_OPTS[@]}" "${PROJECT_DIR}/" "$rsync_dest"
    echo "  Sync complete"

    SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20)
    if [[ -n "${NOMON_SSH_KEY:-}" ]]; then
        SSH_OPTS+=(-i "${NOMON_SSH_KEY}")
    fi

    # ssh concatenates all trailing command-line arguments into a single
    # string with spaces and hands that whole string to the remote shell for
    # re-parsing — per-argument quoting from a local bash array does NOT
    # survive the trip. Any positional value containing shell metacharacters
    # (e.g. a password with '&' or ';') would otherwise be split/executed on
    # the remote side. Build one fully pre-quoted command string locally
    # instead of relying on ssh to preserve argv boundaries.
    REMOTE_ARGS_QUOTED="$(printf '%q ' \
        "$REMOTE_DIR" \
        "$LOCAL_SERVICE_ENV_PAYLOAD_B64" \
        "$SERVICE_HTTP_PORT" \
        "$SERVICE_ROOT_PASSWORD" \
        "$SERVICE_DB_NAME" \
        "$SERVICE_DATA_PATH" \
        "$SNAPSHOT_ENABLED")"
    REMOTE_CMD="NOMON_SUDO_PASS=${_NOMON_SUDO_PASS_QUOTED} bash -ls -- ${REMOTE_ARGS_QUOTED}"

    echo "==> Installing local DB service and applying migrations on ${PI_HOST}..."
    ssh "${SSH_OPTS[@]}" "$PI_HOST" "$REMOTE_CMD" <<'END_REMOTE'
set -eEuo pipefail

remote_dir="${1:-~/perceptua-nomon/nomographic}"
env_payload_b64="${2:-}"
service_http_port="${3:-2482}"
service_root_password="${4:-testpassword}"
service_db_name="${5:-nomon_local}"
service_data_path="${6:-/var/lib/nomographic/local-db}"
snapshot_enabled="${7:-1}"
remote_data_path_default="/var/lib/nomographic/local-db"
data_path_was_relative=0
data_path_rewritten_for_systemd=0

if [[ -n "${NOMON_SUDO_PASS:-}" ]]; then
    _askpass_script="$(mktemp)"
    chmod 700 "${_askpass_script}"
    cat > "${_askpass_script}" <<EOSUDOPASS
#!/bin/sh
printf '%s\n' "${NOMON_SUDO_PASS}"
EOSUDOPASS
    export SUDO_ASKPASS="${_askpass_script}"
    trap 'rm -f "${_askpass_script}"' EXIT
    sudo() { command sudo -A "$@"; }
else
    sudo() { command sudo "$@"; }
fi

if [[ "$remote_dir" == ~* ]]; then
    remote_dir="${remote_dir/#\~/${HOME}}"
fi

if [[ "$remote_dir" != /* ]]; then
    remote_dir="$(pwd)/${remote_dir}"
fi

normalize_remote_data_path() {
    local candidate="$1"
    if [[ "$candidate" == /* ]]; then
        if [[ "$candidate" == /var/lib/nomographic/* || "$candidate" == "/var/lib/nomographic" ]]; then
            printf '%s\n' "$candidate"
        else
            data_path_rewritten_for_systemd=1
            printf '%s\n' "${remote_data_path_default}"
        fi
    else
        data_path_was_relative=1
        printf '%s\n' "${remote_data_path_default}"
    fi
}

service_data_path="$(normalize_remote_data_path "$service_data_path")"

SERVICE_NAME="nomographic-local-db.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
ENV_PATH="/etc/nomographic/local-db.env"
BACKUP_DIR="$(mktemp -d /tmp/nomographic-local-db-deploy.XXXXXX)"
BACKUP_SERVICE_PATH="${BACKUP_DIR}/service.prev"
BACKUP_ENV_PATH="${BACKUP_DIR}/env.prev"
BACKUP_DATA_ARCHIVE="${BACKUP_DIR}/local-db-data.tar.gz"
DEPLOY_ENV_PAYLOAD_PATH="${BACKUP_DIR}/local-db.env.new"

had_service=0
had_env=0
had_data_snapshot=0
migration_started=0
rollback_port="$service_http_port"
rollback_data_path="$service_data_path"
expected_local_data_prefix="/var/lib/nomographic/"

quote_env_double_quoted() {
    local raw="$1"
    raw="${raw//\\/\\\\}"
    raw="${raw//\"/\\\"}"
    raw="${raw//\$/\\$}"
    raw="${raw//\`/\\\`}"
    printf '"%s"' "$raw"
}

normalize_env_data_path_file() {
    local input_path="$1"
    local output_path="$2"
    local normalized_data_path="$3"
    local replaced=0

    : >"$output_path"

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == ARCADEDB_LOCAL_DATA=* ]]; then
            printf 'ARCADEDB_LOCAL_DATA=%s\n' "$(quote_env_double_quoted "$normalized_data_path")" >>"$output_path"
            replaced=1
        else
            printf '%s\n' "$line" >>"$output_path"
        fi
    done <"$input_path"

    if [[ "$replaced" -eq 0 ]]; then
        printf 'ARCADEDB_LOCAL_DATA=%s\n' "$(quote_env_double_quoted "$normalized_data_path")" >>"$output_path"
    fi
}

log() {
    printf '%s\n' "$*"
}

if [[ "$data_path_was_relative" -eq 1 ]]; then
    log "==> Non-absolute ARCADEDB_LOCAL_DATA detected; using ${service_data_path} for systemd compatibility."
fi
if [[ "$data_path_rewritten_for_systemd" -eq 1 ]]; then
    log "==> ARCADEDB_LOCAL_DATA outside /var/lib/nomographic detected; using ${service_data_path} for systemd compatibility."
fi

cleanup() {
    rm -rf "$BACKUP_DIR" >/dev/null 2>&1 || true
}

wait_for_ready() {
    local port="$1"
    local retries=40
    local delay=2
    local attempt=0
    while [[ "$attempt" -lt "$retries" ]]; do
        if curl -sf "http://127.0.0.1:${port}/api/v1/ready" >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep "$delay"
    done
    return 1
}

ensure_data_path_access() {
    local data_path="$1"
    local parent_path
    parent_path="$(dirname "$data_path")"

    sudo mkdir -p "$data_path"
    sudo chmod 755 "$parent_path" || true

    # ArcadeDB container runs as uid/gid 1000 by default.
    sudo chown -R 1000:1000 "$data_path"
    sudo chmod 775 "$data_path"
}

ensure_service_up() {
    local port="$1"
    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    sudo systemctl restart "$SERVICE_NAME"
    wait_for_ready "$port"
}

is_service_available() {
    local port="$1"
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        return 1
    fi
    wait_for_ready "$port"
}

validate_restore_delete_path() {
    local target_path="$1"
    local expected_prefix="$2"

    if [[ -z "$target_path" ]]; then
        log "!! Unsafe rollback path: empty path"
        return 1
    fi

    if [[ "$target_path" != /* ]]; then
        log "!! Unsafe rollback path: must be absolute: ${target_path}"
        return 1
    fi

    if [[ "$target_path" == "/" ]]; then
        log "!! Unsafe rollback path: refusing to delete root '/'"
        return 1
    fi

    if [[ -z "$expected_prefix" || "$expected_prefix" != /* ]]; then
        log "!! Unsafe rollback prefix configuration: ${expected_prefix}"
        return 1
    fi

    if [[ "$expected_prefix" != */ ]]; then
        expected_prefix="${expected_prefix}/"
    fi

    if [[ "$target_path/" != "$expected_prefix"* ]]; then
        log "!! Unsafe rollback path: ${target_path} is outside expected prefix ${expected_prefix}"
        return 1
    fi

    return 0
}

rollback() {
    local recovered=0
    local rollback_failed=0
    local service_active=0
    local service_ready=0
    log "!! Deploy failed. Starting rollback."

    if [[ "$had_data_snapshot" -eq 1 && "$migration_started" -eq 1 ]]; then
        if validate_restore_delete_path "$rollback_data_path" "$expected_local_data_prefix"; then
            log "  Restoring local DB data snapshot from ${BACKUP_DATA_ARCHIVE}"
            sudo systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
            sudo rm -rf -- "$rollback_data_path"
            sudo mkdir -p -- "$(dirname "$rollback_data_path")"
            sudo tar -xzf "$BACKUP_DATA_ARCHIVE" -C "$(dirname "$rollback_data_path")"
            ensure_data_path_access "$rollback_data_path"
        else
            rollback_failed=1
            log "!! Rollback data restore skipped due to unsafe path validation failure."
        fi
    fi

    if [[ "$had_service" -eq 1 ]]; then
        log "  Restoring previous service unit"
        sudo install -Dm644 "$BACKUP_SERVICE_PATH" "$SERVICE_PATH"
    else
        # First-time deploy failure: keep the installed unit so recovery can
        # still start the database service and maintain availability.
        log "  No previous service unit backup; keeping deployed service unit for recovery"
    fi

    if [[ "$had_env" -eq 1 ]]; then
        log "  Restoring previous env file"
        sudo install -Dm640 "$rollback_env_payload_path" "$ENV_PATH"
    else
        # First-time deploy failure: keep the deployed env so the service can
        # still restart with a valid runtime configuration.
        log "  No previous env backup; keeping deployed env file for recovery"
    fi

    ensure_data_path_access "$rollback_data_path"

    if ensure_service_up "$rollback_port"; then
        recovered=1
    fi

    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        service_active=1
    fi

    if wait_for_ready "$rollback_port"; then
        service_ready=1
    fi

    if [[ "$rollback_failed" -eq 0 && "$service_active" -eq 1 && "$service_ready" -eq 1 ]]; then
        log "!! Rollback succeeded and service is available."
        return 0
    fi

    log "!! Rollback completed with issues. service_active=${service_active} service_ready=${service_ready} data_restore_failed=${rollback_failed}"
    return 1
}

on_error() {
    failed_code=$?
    trap - ERR
    set +e
    if rollback; then
        if is_service_available "$rollback_port"; then
            log "!! Rollback status: success. Service is active and ready after failure recovery."
        else
            log "!! Rollback status: success, but service readiness check failed after rollback attempt."
        fi
    else
        if is_service_available "$rollback_port"; then
            log "!! Rollback status: failed, but service appears active and ready."
        else
            log "!! Rollback status: failed and service is not available."
        fi
    fi

    log "!! Deploy failed (exit=${failed_code}); returning non-zero even after rollback attempt."
    cleanup
    exit "$failed_code"
}

trap on_error ERR

cd "$remote_dir"

if [[ ! -f "systemd/nomographic-local-db.service" ]]; then
    log "Error: missing service file at ${remote_dir}/systemd/nomographic-local-db.service"
    exit 1
fi

if [[ -z "$env_payload_b64" ]]; then
    log "Error: missing local DB env payload"
    exit 1
fi

if command -v base64 >/dev/null 2>&1; then
    if ! printf '%s' "$env_payload_b64" | base64 --decode >"$DEPLOY_ENV_PAYLOAD_PATH" 2>/dev/null; then
        if ! printf '%s' "$env_payload_b64" | base64 -d >"$DEPLOY_ENV_PAYLOAD_PATH" 2>/dev/null; then
            log "Error: failed to decode local DB env payload"
            exit 1
        fi
    fi
else
    log "Error: required command 'base64' is not installed on remote host"
    exit 127
fi

if [[ ! -s "$DEPLOY_ENV_PAYLOAD_PATH" ]]; then
    log "Error: decoded local DB env payload is empty"
    exit 1
fi

normalized_deploy_env_payload_path="${BACKUP_DIR}/local-db.env.normalized"
normalize_env_data_path_file "$DEPLOY_ENV_PAYLOAD_PATH" "$normalized_deploy_env_payload_path" "$service_data_path"
mv "$normalized_deploy_env_payload_path" "$DEPLOY_ENV_PAYLOAD_PATH"

if sudo test -f "$SERVICE_PATH"; then
    had_service=1
    sudo cp "$SERVICE_PATH" "$BACKUP_SERVICE_PATH"
fi

if sudo test -f "$ENV_PATH"; then
    had_env=1
    sudo cat "$ENV_PATH" >"$BACKUP_ENV_PATH"
    set +u
    # shellcheck disable=SC1090
    . "$BACKUP_ENV_PATH"
    set -u
    rollback_port="${LOCAL_ARCADEDB_HTTP_PORT:-$rollback_port}"
    rollback_data_path="${ARCADEDB_LOCAL_DATA:-$rollback_data_path}"
    rollback_data_path="$(normalize_remote_data_path "$rollback_data_path")"

    rollback_env_payload_path="${BACKUP_DIR}/env.prev.normalized"
    normalize_env_data_path_file "$BACKUP_ENV_PATH" "$rollback_env_payload_path" "$rollback_data_path"
fi

if [[ "$snapshot_enabled" == "1" ]] && sudo test -d "$rollback_data_path"; then
    log "==> Taking pre-deploy data snapshot from ${rollback_data_path}"
    sudo tar -czf "$BACKUP_DATA_ARCHIVE" \
        -C "$(dirname "$rollback_data_path")" "$(basename "$rollback_data_path")"
    had_data_snapshot=1
fi

log "==> Installing service unit ${SERVICE_NAME}"
sudo install -Dm644 "${remote_dir}/systemd/nomographic-local-db.service" "$SERVICE_PATH"

log "==> Installing env file /etc/nomographic/local-db.env"
log "    using ARCADEDB_LOCAL_DATA=${service_data_path}"
sudo install -Dm640 "$DEPLOY_ENV_PAYLOAD_PATH" "$ENV_PATH"

log "==> Preparing data path permissions"
ensure_data_path_access "$service_data_path"

log "==> Restarting local DB service"
ensure_service_up "$service_http_port"

log "==> Running local migrations against running local DB service"
migration_started=1
LOCAL_MIGRATOR_USE_RUNNING_SERVICE=1 \
ARCADEDB_LOCAL_HOST=127.0.0.1 \
ARCADEDB_LOCAL_HTTP_PORT="$service_http_port" \
ARCADEDB_LOCAL_ROOT_PASSWORD="$service_root_password" \
ARCADEDB_LOCAL_DB="$service_db_name" \
./scripts/migrate-local.sh migrate

trap - ERR
cleanup
log "==> Deploy complete. Service ${SERVICE_NAME} is available on 127.0.0.1:${service_http_port}."
END_REMOTE

    echo "Deploy completed for ${PI_HOST}."
else
    echo "==> No Pi host configured; running local migration workflow only."
    cd "$PROJECT_DIR"
    mkdir -p "$SERVICE_DATA_PATH"
    ./scripts/migrate-local.sh migrate
    echo "Local migrations applied."
fi
