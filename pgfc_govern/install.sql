-- pgfc_govern — Decide + Act (Phase 1: advisory)
--
-- The control loop of the pg_flight_controller autovacuum governor. It reads
-- pgfc_observe (cross-schema, read-only) and decides per-relation autovacuum
-- setpoints. In Phase 1 every policy is advisory_only by default: plan() writes a
-- full decision trail but apply() never fires.
--
-- Depends on pgfc_observe being installed first.
--
-- Re-running this file is safe and idempotent for the CURRENT schema
-- (CREATE ... IF NOT EXISTS / CREATE OR REPLACE; the harness applies it twice).
-- Schema evolution is additive-only (new NULLABLE columns; never drop/rename); a
-- new column must be added to its CREATE TABLE below AND to an
-- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` in the "Additive upgrades" section.

CREATE SCHEMA IF NOT EXISTS pgfc_govern;
COMMENT ON SCHEMA pgfc_govern IS
  'pg_flight_controller control loop: classify, estimate, plan, (apply), verify.';

-- Guard: pgfc_govern reads pgfc_observe cross-schema; fail early with a clear
-- message if the dependency is missing.
DO $$
BEGIN
    IF to_regnamespace('pgfc_observe') IS NULL THEN
        RAISE EXCEPTION 'pgfc_govern requires pgfc_observe to be installed first';
    END IF;
END $$;

-- Relation workload classes (choose the desired-state template). CREATE TYPE has no
-- IF NOT EXISTS, so guard it for re-runnable install.
DO $$
BEGIN
    CREATE TYPE pgfc_govern.relation_kind AS ENUM
        ('append_only','oltp','queue','delete_heavy','archive','mixed');
EXCEPTION WHEN duplicate_object THEN
    NULL;
END $$;
