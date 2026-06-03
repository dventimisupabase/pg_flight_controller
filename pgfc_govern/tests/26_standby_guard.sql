-- FMEA-002: the govern loops must idle on a read-only standby. observe_tick() and
-- control_tick() both write (snapshots/estimates via observe_tick; tick_log + governor_state
-- via control_tick), so on a standby every cron tick errors — and after a failover the old
-- primary errors forever while a promoted standby silently starts actuating. Both loops — and
-- the daily maintenance writers retain()/degrade() (FMEA-002 follow-up) — now guard on
-- pgfc_observe._is_standby() (the shared seam) as their first statement. We stub the seam to
-- simulate a standby and assert BOTH directions, so a non-propagating stub can't pass.
BEGIN;
SELECT plan(11);

-- ── shape: both loops consult the shared guard ─────────────────────────────────────
SELECT ok((SELECT p.prosrc LIKE '%_is_standby%'
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgfc_govern' AND p.proname = 'observe_tick'),
          'observe_tick() consults the standby guard');
SELECT ok((SELECT p.prosrc LIKE '%_is_standby%'
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgfc_govern' AND p.proname = 'control_tick'),
          'control_tick() consults the standby guard');
SELECT ok((SELECT p.prosrc LIKE '%_is_standby%'
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgfc_govern' AND p.proname = 'retain'),
          'pgfc_govern.retain() consults the standby guard');
SELECT ok((SELECT p.prosrc LIKE '%_is_standby%'
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgfc_govern' AND p.proname = 'degrade'),
          'pgfc_govern.degrade() consults the standby guard');

-- ── primary (default): both loops run ──────────────────────────────────────────────
SELECT isnt(pgfc_govern.observe_tick(), NULL, 'observe_tick() runs and returns a snapshot id on a primary');
SELECT isnt(pgfc_govern.control_tick(), NULL, 'control_tick() runs and returns a tick id on a primary');

-- ── standby (stubbed): both loops are no-ops ────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgfc_observe._is_standby() RETURNS boolean
  LANGUAGE sql STABLE AS $$ SELECT true $$;
CREATE TEMP TABLE _tick_before AS SELECT count(*) AS n FROM pgfc_govern.tick_log;
SELECT is(pgfc_govern.observe_tick(), NULL, 'observe_tick() is a no-op on a standby — returns NULL');
SELECT is(pgfc_govern.control_tick(), NULL, 'control_tick() is a no-op on a standby — returns NULL');
SELECT is((SELECT count(*) FROM pgfc_govern.tick_log), (SELECT n FROM _tick_before),
          'control_tick() wrote no tick_log row on a standby');

-- The daily maintenance writers also idle. On a primary retain() returns one row per pruned
-- table and degrade(0) returns the prune log; on the stubbed standby both must return NO rows.
SELECT is((SELECT count(*) FROM pgfc_govern.retain()), 0::bigint,
          'pgfc_govern.retain() is a no-op on a standby — returns no rows (deletes nothing)');
SELECT is((SELECT count(*) FROM pgfc_govern.degrade(0)), 0::bigint,
          'pgfc_govern.degrade() is a no-op on a standby — returns no rows (prunes nothing)');

SELECT * FROM finish();
ROLLBACK;
