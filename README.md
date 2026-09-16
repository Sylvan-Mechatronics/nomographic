# nomographic

Database schemas and migration tooling for the nomon fleet.

## Overview

nomographic manages [ArcadeDB](https://arcadedb.com/) schemas for two targets:

| Instance | Database | Runtime | SQL Directory |
|----------|----------|---------|---------------|
| Central | `nomon_central` | Persistent ArcadeDB server (Docker Compose) | `central/sql/` |
| Local | `nomon_local` | Pi-local systemd managed ArcadeDB service (loopback-only); temporary Docker migrator for local dev workflows | `local/sql/` |

Both targets use custom ArcadeDB HTTP API runners for migration management. After each migration, a post-migration hook automatically creates `{Type}Meta` lineage vertices and `Supersedes` edges to track schema history.

## Structure

```
nomographic/
├── central/
│   └── sql/                   # Central versioned migrations (V1__, V2__, ...)
├── local/
│   └── sql/                   # Local versioned migrations (independent version series)
├── scripts/
│   ├── init-db.sh             # Full orchestrator: spin up, create DBs, migrate, seed
│   ├── migrate-central.sh     # Central migration runner
│   ├── migrate-local.sh       # Local migration runner
│   ├── lib/
│   │   └── migrate-common.sh  # Shared lineage tracking library
│   ├── deploy-local.sh        # Deploy local migrations to Pi or local machine
│   └── seed-central.sh        # Seed central with test records
├── docs/
│   ├── architecture.md
│   ├── roadmap.md
│   └── adr/
└── docker-compose.yml
```

## Migration Conventions

Migration files use versioned naming:

```text
V{version}__{description}.sql
```

Rules:

1. Use `IF NOT EXISTS` on all `CREATE` statements.
2. Keep each migration to one logical change.
3. Never edit an already-applied migration — add a new version instead.
4. Type names are PascalCase, property names are snake_case.
5. Central and local version series are independent.

## Quick Start

```bash
# 1) Copy and configure environment files
cp .env.central.example .env.central
# Edit .env.central — set ARCADEDB_ROOT_PASSWORD

cp .env.local.example .env.local
# Edit .env.local — set NOMON_PI_HOST, NOMON_SUDO_PASS, etc.

# 2) Start central ArcadeDB server
docker compose --env-file .env.central up -d

# 3) Initialize both targets (creates DBs, applies all migrations, runs lineage hook)
./scripts/init-db.sh

# 4) Optional: seed central with test data
NOMOGRAPHIC_SEED_TEST_DATA=1 ./scripts/seed-central.sh   # dev databases only: inserts a well-known test login
```

## Script Reference

| Script | Subcommands | Purpose |
|--------|-------------|---------|
| `scripts/init-db.sh` | — | Orchestrate full setup: start check, create DBs, migrate, seed |
| `scripts/migrate-central.sh` | `migrate` `validate` `info` `reconcile-lineage` | Central migration runner |
| `scripts/migrate-local.sh` | `migrate` `validate` `info` `reconcile-lineage` | Local migration runner |
| `scripts/deploy-local.sh` | `[pi-host]` | Sync and apply local migrations on Pi or local machine |
| `scripts/seed-central.sh` | — | Seed central test records |

## Central Workflow

```bash
# Apply pending migrations (also runs lineage hook per migration)
./scripts/migrate-central.sh migrate

# Validate checksums against SchemaMigration records
./scripts/migrate-central.sh validate

# Show applied/pending status
./scripts/migrate-central.sh info

# Re-run lineage hook for all applied migrations (safe to run repeatedly)
./scripts/migrate-central.sh reconcile-lineage
```

## Local Workflow

```bash
# Apply local migrations
./scripts/migrate-local.sh migrate

# Validate checksums
./scripts/migrate-local.sh validate

# Show status
./scripts/migrate-local.sh info

# Reconcile lineage
./scripts/migrate-local.sh reconcile-lineage
```

## Pi Local DB Service Deploy

Phase 6 introduces a dedicated local DB systemd service on Pi:

- Unit file in repo: `systemd/nomographic-local-db.service`
- On-device unit path: `/etc/systemd/system/nomographic-local-db.service`
- On-device env path: `/etc/nomographic/local-db.env`

`scripts/deploy-local.sh` uses `.env.local` as the single source of truth,
resolves local-service defaults/fallbacks, and uploads only an allowlisted
payload to `/etc/nomographic/local-db.env`.

### Configure local DB service env

```bash
# Local deployment env
cp .env.local.example .env.local
# Edit .env.local values for your Pi deployment
```

`deploy-local.sh` only exports this allowlist into the Pi service env file:

- `LOCAL_ARCADEDB_IMAGE`
- `LOCAL_ARCADEDB_HTTP_PORT`
- `LOCAL_ARCADEDB_BINARY_PORT`
- `LOCAL_ARCADEDB_ROOT_PASSWORD`
- `LOCAL_ARCADEDB_OPTS_MEMORY`
- `ARCADEDB_LOCAL_DATA`
- `ARCADEDB_LOCAL_DB`

No other `.env.local` values are copied into `/etc/nomographic/local-db.env`.
In particular, `LOCAL_MIGRATOR_*` values are never exported there.

### Deploy to Pi

```bash
# Uses NOMON_PI_HOST / PI_HOST from .env.local when host arg is omitted
./scripts/deploy-local.sh <pi-host>
```

Deploy flow on Pi:

1. Sync repository content to the remote nomographic directory.
2. Install/update service unit and `/etc/nomographic/local-db.env`.
3. Reload systemd, restart service, and wait for `/api/v1/ready`.
4. Run `./scripts/migrate-local.sh migrate` against the running local DB service.
5. If any step fails, rollback restores previous unit/env when backups exist,
	 otherwise keeps deployed unit/env for first-time deploy recovery, and then
	 attempts to bring the service back to active/ready state.

Rollback behavior notes:

- Optional pre-deploy data snapshot/restore is controlled by
	`NOMOGRAPHIC_LOCAL_DB_SNAPSHOT` (default: `1`).
- The script exits non-zero on deploy failure even if rollback recovers service
	availability, so operators can treat the deploy as failed and investigate.


## Schema Lineage Tracking

After every migration is applied, `scripts/lib/migrate-common.sh` automatically:

1. Parses the SQL file to detect affected types (created / modified / deleted).
2. Creates a `{Type}Meta` vertex type if it doesn't exist.
3. Inserts a new `{Type}Meta` record capturing `type_name`, `migration_file`, `change_type`, and `applied_at`.
4. If a previous meta record exists for the type, creates a `Supersedes` edge from the old record to the new one, forming a chronological linked list.

This produces a queryable lineage graph:

```sql
-- All lineage records for Vehicle
SELECT * FROM VehicleMeta ORDER BY applied_at;

-- Follow the history chain from the earliest record
MATCH {type: VehicleMeta, as: v} -Supersedes-> {as: next} RETURN v, next;
```

The `reconcile-lineage` subcommand re-runs the hook for all already-applied migrations, relying on per-type idempotency to skip existing records. Use it to recover from a migration that succeeded but whose lineage hook was interrupted.

## Environment

Two separate env files:

- `.env.central` — central ArcadeDB server + `init-db.sh`/`migrate-central.sh`/`seed-central.sh` settings
- `.env.local` — Pi deploy credentials + local embedded DB settings

Copy example configs:

```bash
cp .env.central.example .env.central
cp .env.local.example .env.local
```

Key variables:

| Variable | Default | Purpose |
|----------|---------|---------|
| `ARCADEDB_ROOT_PASSWORD` | `changeme_before_deploy` | Central root password — **change before any non-local use** |
| `ARCADEDB_HOST` | `localhost` | Central server host |
| `ARCADEDB_HTTP_PORT` | `2480` | Central HTTP API port |
| `ARCADEDB_LOCAL_DATA` | `local/data` | Local DB data directory |
| `ARCADEDB_LOCAL_DB` | `nomon_local` | Local DB name |
| `LOCAL_ARCADEDB_IMAGE` | `arcadedata/arcadedb:latest` | Shared local runtime image default (Pi local DB service; migrator default source) |
| `LOCAL_ARCADEDB_HTTP_PORT` | `2482` | Pi local DB service HTTP API port (runtime service port) |
| `LOCAL_ARCADEDB_BINARY_PORT` | `2425` | Pi local DB service binary protocol port (runtime service port) |
| `LOCAL_ARCADEDB_ROOT_PASSWORD` | `changeme_before_deploy` | Baseline local auth password for service and migrator |
| `LOCAL_ARCADEDB_OPTS_MEMORY` | empty | Shared local memory tuning default |
| `LOCAL_MIGRATOR_IMAGE` | `arcadedata/arcadedb:latest` | Temporary migrator container image (migrate-local only) |
| `LOCAL_MIGRATOR_HTTP_PORT` | `2481` | Temporary migrator HTTP API port (not the Pi service port) |
| `LOCAL_MIGRATOR_JAVA_OPTS` | empty | Temporary migrator JVM opts; may embed rootPassword override |

Namespace boundaries and precedence:

- `LOCAL_ARCADEDB_*` is the shared local runtime namespace: Pi local DB service values and migrator baseline defaults.
- `LOCAL_MIGRATOR_*` controls temporary migrator behavior only and is never exported by `deploy-local.sh` into `/etc/nomographic/local-db.env`.
- Migrator auth precedence: baseline `LOCAL_ARCADEDB_ROOT_PASSWORD`, then optional `ARCADEDB_LOCAL_ROOT_PASSWORD`, then highest-precedence rootPassword embedded in `LOCAL_MIGRATOR_JAVA_OPTS` (temporary-container mode).

## Further Reading

- `docs/architecture.md` — schema inventory, migration strategy, lineage tracking design
- `docs/roadmap.md` — completed and planned phases
- `docs/adr/002-complete-flyway-removal.md` — rationale for ArcadeDB-native migrations
