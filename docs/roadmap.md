# nomographic — Development Roadmap

## Status Summary

### Central Database

| Version | Name | Status |
|---------|------|--------|
| V1 | Vehicle & Telemetry Schema | ✅ Complete |
| V2 | User & Device Ownership Schema | ✅ Complete |
| V3 | Refresh Token Storage | ✅ Complete |
| V4 | Autonomy Run/Event Schema | ✅ Complete |

### Local Database

| Version | Name | Status |
|---------|------|--------|
| V1 | Device State Schema | ✅ Complete |

### Tooling

| Phase | Name | Status |
|-------|------|--------|
| 1 | Deployment Automation | ✅ Complete |
| 2 | Local Migrations Without Flyway | ✅ Complete |
| 3 | Complete Flyway Removal | ✅ Complete |
| 4 | Schema Lineage Tracking via MetaTypes | ✅ Complete |
| 5 | DX Improvements (Makefile, CI/CD) | ✅ Complete |
| 6 | Local DB systemd Service + Pi Deploy Rollback Safety | ✅ Complete |
| 7 | `.env`-Only Local Service Env Consolidation | ✅ Complete |

---

## Completed

### V1 — Central: Vehicle & Telemetry Schema

**File:** `central/sql/V1__create_vehicle_schema.sql`

**Deliverables:**
- [x] `Vehicle` vertex type: `vin`, `model`, `firmware_version`, `registered_at`, `last_seen_at`
- [x] `TelemetryReading` vertex type: `battery_voltage`, `cpu_temp_c`, `uptime_seconds`, `recorded_at`
- [x] `ReadFrom` edge type: links TelemetryReading → Vehicle
- [x] Unique index on `Vehicle.vin`
- [x] Non-unique index on `TelemetryReading.recorded_at`

### V1 — Local: Device State Schema

**File:** `local/sql/V1__create_device_schema.sql`

**Deliverables:**
- [x] `DeviceState` vertex type: `device_id`, `firmware_version`, `boot_count`, `last_boot_at`, `status`
- [x] `OperationLog` vertex type: `operation`, `result`, `detail`, `occurred_at`
- [x] `Performed` edge type: links DeviceState → OperationLog
- [x] Unique index on `DeviceState.device_id`
- [x] Non-unique index on `OperationLog.occurred_at`

---

### V2 — Central: User & Device Ownership Schema

**File:** `central/sql/V2__add_user_schema.sql`

**Deliverables:**
- [x] `User` vertex type:
  - `email` (STRING) — login identifier
  - `display_name` (STRING) — user-visible name
  - `password_hash` (STRING) — bcrypt hash, never plaintext
  - `created_at` (DATETIME) — registration timestamp
  - `last_login_at` (DATETIME) — most recent successful login
  - `active` (BOOLEAN) — soft-delete / account disable flag
- [x] Unique index on `User.email`
- [x] `OwnsDevice` edge type (User → Vehicle):
  - `role` (STRING) — access level: `owner`, `operator`, `viewer`

**Graph relationships:**
```
User ──OwnsDevice──▶ Vehicle ◀──ReadFrom── TelemetryReading
```

**Exit criteria:**
- ✅ `./scripts/migrate-central.sh validate` passes
- ✅ `./scripts/migrate-central.sh migrate` applies cleanly
- ✅ `User` vertex type queryable with email lookup
- ✅ `OwnsDevice` edge traversable from User to Vehicle

---

## Phase 1 — Deployment Automation

Tooling to make the databases runnable with a single command.

- [x] `docker-compose.yml` — ArcadeDB service with health check and Gremlin plugin
- [x] `scripts/migrate-central.sh` — Flyway wrapper with env-var-driven JDBC URLs
- [x] `scripts/init-db.sh` — Database creation and migration runner with health-check wait loop
- [x] `scripts/seed-central.sh` — Idempotent test data seeding (user, vehicle, ownership edge)
- [x] `.env.example` — Documented environment variable defaults
- [x] `.gitignore` — Ignores `.env`, data directories, secret configs
- [x] README Quick Start section — single-command setup instructions
- [x] Architecture doc — Deployment Automation section describing scripts and Docker Compose

---

## Phase 2 — Local Migrations Without Flyway (Implemented)

Goal: keep nomographic self-contained by removing Flyway from the local
embedded workflow and using ArcadeDB console-driven migrations for local
schema evolution, while preserving Flyway for central server migrations.

### 2.1 — Local migration runner and script split

- [x] Add local migration runner script (ArcadeDB console/API based) to apply
  `local/sql/V*__*.sql` in version order and persist applied versions in
  local database metadata.
- [x] Refactor `scripts/migrate-central.sh` to central-only Flyway path.
- [x] Route local workflows to `scripts/migrate-local.sh`.
- [x] Update `scripts/init-db.sh` so `local` target uses the console runner.

### 2.2 — Dependency and compose updates

- [x] Update `.env.example` migration variables so local workflow does not
  require Flyway-specific settings.
- [x] Add/adjust Docker helper configuration so the ArcadeDB console/API path can run
  reproducibly in CI/dev even when host tools are missing.
- [x] Keep central Flyway config intact (`central/flyway.toml`).

### 2.3 — Documentation and ADR

- [x] Add ADR documenting migration strategy split:
  `docs/adr/001-local-console-migrations.md`
  - central = Flyway
  - local = ArcadeDB console runner
- [x] Update README commands and quick-start flow to remove local Flyway
  examples and replace with local console migration commands.
- [x] Update `docs/architecture.md` migration strategy and script reference to
  reflect the split model.

### 2.4 — Validation and rollback

- [x] Add verification steps for central and local migration paths:
  - central: Flyway `validate` and `migrate`
  - local: runner `validate/info` and idempotent rerun
- [x] Document rollback playbook for local migration failures
  (restore local data snapshot, rerun from known version).

### Phase 2 Exit Criteria

- Local migration flow runs without Flyway installed.
- Central migration flow remains Flyway-based and unchanged.
- `./scripts/init-db.sh local` succeeds on clean and already-migrated states.
- README and architecture docs match actual script behavior.
- ADR accepted and linked from roadmap/architecture docs.

---

## Phase 3 — Complete Flyway Removal (Implemented)

Goal: unify both central and local migration targets on ArcadeDB HTTP API
runners, eliminating all Flyway dependencies from the project.

### Deliverables

- [x] Rewrite `scripts/migrate-central.sh` as ArcadeDB HTTP API runner for central
  migrations (matching local runner pattern)
- [x] Remove `central/flyway.toml` and `local/flyway.toml`
- [x] Remove Flyway-specific environment variables (`ARCADEDB_USER`,
  `ARCADEDB_PASSWORD`, `FLYWAY_DOCKER_IMAGE`) from `.env.example`
- [x] Remove Flyway runtime entries from `.gitignore`
- [x] Update `scripts/init-db.sh` to call `migrate-central.sh` without `central` arg
- [x] Update README, architecture docs, and roadmap
- [x] Create ADR-002 documenting the complete Flyway removal decision
- [x] Update ADR-001 status to superseded
- [x] Remove all Flyway references from nomourgoi agents, prompts, and context
- [x] Remove all Flyway references from nomothetic documentation

### Phase 3 Exit Criteria

- Zero Flyway references remain in the workspace.
- `./scripts/migrate-central.sh migrate` applies central migrations via ArcadeDB API.
- `./scripts/migrate-central.sh validate` validates central migration checksums.
- `./scripts/init-db.sh all` succeeds end-to-end.
- ADR-002 accepted and linked.

## Phase 4 — Schema Lineage Tracking via MetaTypes (Implemented)

Goal: automatically track which migrations touched which schema types,
forming a chronological linked list of changes per type via MetaType
vertices and Supersedes edges.

### Deliverables

- [x] Shared library `scripts/lib/migrate-common.sh` — extracted lineage
  logic consumed by both `migrate-central.sh` and `migrate-local.sh`
- [x] `parse_affected_types` — SQL parser extracting type names and change
  classifications (created / modified / deleted) from migration files
- [x] `record_lineage` — post-migration hook that creates `{Type}Meta`
  vertices and `Supersedes` edges after each migration is applied
- [x] `reconcile-lineage` subcommand added to both `migrate-central.sh` and
  `migrate-local.sh` — replays lineage for all previously applied
  migrations (idempotent)
- [x] `Supersedes` edge type: links previous MetaType head → new MetaType
  record, forming a chronological linked list per schema type
- [x] MetaType naming convention: `{Type}Meta` (e.g. `VehicleMeta`,
  `DeviceStateMeta`)
- [x] Lineage types are self-excluded from tracking (MetaType and
  Supersedes are filtered out by `parse_affected_types`)

### Phase 4 Exit Criteria

- `./scripts/migrate-central.sh migrate` records lineage automatically.
- `./scripts/migrate-local.sh migrate` records lineage automatically.
- `./scripts/migrate-central.sh reconcile-lineage` replays all central lineage.
- `./scripts/migrate-local.sh reconcile-lineage` replays all local lineage.
- MetaType records are idempotent — re-running does not duplicate records.
- `SchemaMigration`, `*Meta`, and `Supersedes` types are excluded from
  lineage tracking.

## Phase 5 — DX Improvements (Makefile, CI/CD) (Implemented)

Goal: improve developer experience with a unified task runner, automated
CI checks, and reliable environment variable loading.

### Deliverables

- [x] Fix `.env` loading in `scripts/deploy-local.sh` — source `.env` file
  before referencing variables so embedded ArcadeDB deployment uses
  configured credentials
- [x] `Makefile` with 16 targets covering the full development workflow:
  `up`, `down`, `restart`, `logs`, `ps`, `init`, `migrate-central`,
  `migrate-local`, `migrate-all`, `seed`, `validate-central`,
  `validate-local`, `reconcile-central`, `reconcile-local`, `clean`,
  `help`
- [x] `Makefile` `help` target — auto-generates target documentation from
  inline comments
- [x] GitHub Actions CI workflow (`.github/workflows/ci.yml`) with three
  checks:
  - ShellCheck lint for all shell scripts
  - Migration naming convention validation (`V<N>__<name>.sql`)
  - Docker Compose config validation (`docker compose config --quiet`)

### Phase 5 Exit Criteria

- `make help` lists all targets with descriptions.
- `make up && make migrate-all && make seed` succeeds end-to-end.
- `deploy-local.sh` loads `.env` before variable references.
- CI workflow passes on clean checkout.

## Phase 6 — Local DB systemd Service + Pi Deploy Rollback Safety (Implemented)

Goal: run the on-device local ArcadeDB instance under a dedicated systemd
service with isolated environment configuration, and make Pi deployments
transactional enough to recover from failures while ending with local DB
service availability.

### 6.1 — Add dedicated local DB service unit + environment file

- [x] Add systemd unit template for Pi local database service:
  `systemd/nomographic-local-db.service`
  - Uses `EnvironmentFile=` for all runtime settings
  - Uses local data path (`ARCADEDB_LOCAL_DATA`) and local DB name
    (`ARCADEDB_LOCAL_DB`) only (no central settings)
  - Uses a local-only HTTP port variable (for example
    `LOCAL_ARCADEDB_HTTP_PORT`) to avoid central port coupling
  - Includes restart policy and startup ordering suitable for boot-time
    availability on Raspberry Pi
- [x] Define local DB service environment variables and namespace
  (`LOCAL_ARCADEDB_*`, `ARCADEDB_LOCAL_*`) for deployment/runtime separation

Verification:
- [x] `systemd-analyze verify systemd/nomographic-local-db.service`
- [x] Unit contains `EnvironmentFile=` and does not hardcode secrets

### 6.2 — Extend deploy-local flow to manage service lifecycle on Pi

- [x] Update `scripts/deploy-local.sh`:
  - Sync migration scripts and local SQL files to Pi
  - Install/refresh unit file under `/etc/systemd/system/`
  - Install/refresh environment file under `/etc/nomographic/`
  - Run `systemctl daemon-reload`
  - Start (or restart) `nomographic-local-db.service`
  - Wait for `/api/v1/ready` on configured local port
  - Run `./scripts/migrate-local.sh migrate` against the on-device local DB
    instance
- [x] Add explicit health-check function for deploy gating

Verification:
- [x] `./scripts/deploy-local.sh <pi-host>` exits 0 on clean device
- [x] `ssh <pi-host> systemctl is-active nomographic-local-db.service` returns
      `active`
- [x] `ssh <pi-host> curl -sf http://127.0.0.1:${LOCAL_ARCADEDB_HTTP_PORT}/api/v1/ready`

### 6.3 — Rollback semantics and failure-safe end state

- [x] Define rollback checkpoints in `scripts/deploy-local.sh`:
  - Pre-deploy snapshot of currently installed unit file and env file
  - Optional pre-deploy local DB data snapshot (configurable flag) for
    migration rollback scenarios
- [x] On failure at any step:
  - Restore previous unit/env files if they were replaced
  - Run `systemctl daemon-reload`
  - Attempt to recover service with known-good config when backup exists,
    otherwise continue with newly deployed service/env for first-time deploys
  - If migration step fails after partial application, execute documented
    operator playbook: stop service, restore data snapshot, restart service,
    re-run validate/info checks
- [x] Guarantee script exit behavior:
  - Non-zero exit when deploy/migration fails
  - Best-effort finalizer always runs to ensure service ends `active`
    (or emits explicit terminal failure if impossible)

Verification:
- [x] Simulated failure (bad migration or intentionally invalid env) triggers
      rollback path and logs restored artifacts
- [x] Post-failure check still reports service `active` when rollback succeeds
- [x] `./scripts/migrate-local.sh validate` reports no checksum mismatches after
      rollback restore

### 6.4 — Documentation and operator runbook updates

- [x] Update `docs/architecture.md`:
  - Add Local Pi service lifecycle subsection
  - Clarify central server vs local embedded service boundaries
  - Document deploy + rollback flow sequence
- [x] Update `README.md` with Pi deployment prerequisites and commands
- [x] Document rollback operator checklist in `README.md` and
  `docs/architecture.md` deploy sequence notes (no separate runbook file)

Verification:
- [x] Fresh operator can perform deploy and rollback using docs only
- [x] Architecture doc and scripts are command-consistent

### Phase 6 Exit Criteria

- Local DB runs under `nomographic-local-db.service` on Pi with dedicated
  environment file.
- `scripts/deploy-local.sh` manages service lifecycle and applies local
  migrations on-device.
- Failed deploy attempts execute rollback and leave service available.
- Local migration lineage and checksum validation remain intact after deploy
  and rollback cycles.

## Phase 7 — `.env`-Only Local Service Env Consolidation (Implemented)

Goal: remove dedicated local-service env template files and make `.env` the only source
for local DB service deploy configuration, while still restricting what reaches
`/etc/nomographic/local-db.env` on Pi.

### Deliverables

- [x] `scripts/deploy-local.sh` no longer reads dedicated local-service env
  template files
- [x] Added explicit allowlist payload generation from `.env` for service env
  install (`LOCAL_ARCADEDB_*`, `ARCADEDB_LOCAL_*` only)
- [x] Added fallback/default resolution for local service vars:
  - `LOCAL_ARCADEDB_ROOT_PASSWORD` is required (no default since 2026-09-13, review S-7)
  - local service ports/image/memory/db/data get deterministic defaults
- [x] Preserved rollback semantics and service availability recovery behavior
- [x] Removed the dedicated local-service env template file from repository
- [x] Updated `.env.example`, README, and architecture docs for single-source
  `.env` flow

### Phase 7 Exit Criteria

- `deploy-local.sh` uses only `.env` as config input for Pi local service env.
- `/etc/nomographic/local-db.env` is generated from an explicit allowlist,
  not copied from full `.env`.
- Deploy rollback behavior remains unchanged and continues attempting service
  availability recovery.

---

> **Note (2026-06-27):** the V1 central `TelemetryReading` vertex and `ReadFrom`
> edge are now actively consumed by nomothetic **Phase 25** (Fleet Telemetry
> History): a central-mode MQTT consumer writes `TelemetryReading` rows linked to
> their `Vehicle` via `ReadFrom`, and `GET /api/fleet/devices/{vin}/telemetry`
> serves them back to the nomotactic dashboard (nomotactic Phase 4). No schema
> change was required. A `ReadFrom` / `recorded_at` composite index is a possible
> follow-up if query volume warrants — not needed for the current MVP.

- **V2 Local — AI Context:** On-device intelligence data (learned patterns,
  environment models) if local AI features are added.
- **Telemetry partitioning:** Time-based pruning of `TelemetryReading`
  vertices for long-running deployments (now that Phase 25 writes them).
- **Central — Autonomy telemetry schema (deferred):** `AutonomyRun` and
  `AutonomyEvent` vertex types to persist autonomy run records and lifecycle
  events from the brain. Tracks the downstream half of autonomon Phase 7
  (Autonomy Telemetry to ArcadeDB), which is itself deferred pending the
  device→central transport/auth design; the matching ingestion endpoint is
  `POST /api/telemetry/autonomy` (nomothetic, central mode). Build alongside
  that phase, not before.
