-- pgfc_observe — Observe + Orient (Phase 0)
--
-- Read-only telemetry for the pg_flight_controller autovacuum governor: periodic
-- snapshots of autovacuum-relevant state. Writes only to its own schema.
--
-- Re-runnable: this file is the upgrade path. Everything uses
-- CREATE SCHEMA IF NOT EXISTS / CREATE OR REPLACE / CREATE TABLE IF NOT EXISTS,
-- and schema changes are additive-only (new nullable columns; never drop/rename).

CREATE SCHEMA IF NOT EXISTS pgfc_observe;
COMMENT ON SCHEMA pgfc_observe IS
  'pg_flight_controller telemetry: snapshots of autovacuum-relevant state (read-only).';
