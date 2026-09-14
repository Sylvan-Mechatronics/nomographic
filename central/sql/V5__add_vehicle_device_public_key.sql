-- =============================================================
-- V5: Pin each Vehicle's identity public key
-- =============================================================
-- The device signs its fleet-registration proof with an Ed25519 key
-- generated on first boot (nomothetic device_identity). Central verifies
-- the proof against this key and pins it on the first successful
-- registration, so a later registration of the same VIN must be signed by
-- the same device (workspace review 2026-09-13, finding S-3).
-- Nullable: vehicles registered before this migration (or via the legacy
-- structural proof) have no key until they re-register.

CREATE PROPERTY Vehicle.device_public_key IF NOT EXISTS STRING;
