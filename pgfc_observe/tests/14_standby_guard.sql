-- FMEA-002 (+ daily-job follow-up): observe() and the daily maintenance writers
-- rollup()/rollup_retain() must idle (no-op) on a read-only standby instead of erroring with
-- "cannot execute ... in a read-only transaction". The seam is
-- pgfc_observe._is_standby() (wraps pg_is_in_recovery()); a test stubs it to simulate a
-- standby without a real replica. We assert BOTH directions in one file so a stub that fails
-- to propagate (plpgsql plan cache / SQL inlining) cannot masquerade as a pass — and because
-- earlier test files already called observe() in this session, the plan is warm, so the
-- true-direction here is the HARD case (a cached plan must pick up the redefinition).
BEGIN;
SELECT plan(11);

-- ── shape ──────────────────────────────────────────────────────────────────────
SELECT has_function('pgfc_observe', '_is_standby', 'the standby seam pgfc_observe._is_standby() exists');
-- structural: the seam is wired to the real recovery check, and observe() consults the seam.
-- (Proves the guard is present even if a future refactor were to break the behavioral path.)
SELECT ok((SELECT p.prosrc LIKE '%pg_is_in_recovery%'
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgfc_observe' AND p.proname = '_is_standby'),
          '_is_standby() is defined in terms of pg_is_in_recovery()');
SELECT ok((SELECT p.prosrc LIKE '%_is_standby%'
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgfc_observe' AND p.proname = 'observe'),
          'observe() consults the standby guard');
SELECT ok((SELECT p.prosrc LIKE '%_is_standby%'
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgfc_observe' AND p.proname = 'rollup'),
          'rollup() consults the standby guard');
SELECT ok((SELECT p.prosrc LIKE '%_is_standby%'
             FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgfc_observe' AND p.proname = 'rollup_retain'),
          'rollup_retain() consults the standby guard');

-- ── primary (default): observe() runs ──────────────────────────────────────────────
SELECT isnt(pgfc_observe.observe(), NULL, 'observe() runs and returns a snapshot id on a primary');

-- ── standby (stubbed): observe() is a no-op ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgfc_observe._is_standby() RETURNS boolean
  LANGUAGE sql STABLE AS $$ SELECT true $$;
CREATE TEMP TABLE _snap_before AS SELECT count(*) AS n FROM pgfc_observe.snapshots;
SELECT is(pgfc_observe.observe(), NULL,
          'observe() is a no-op on a standby — returns NULL instead of erroring or writing');
SELECT is((SELECT count(*) FROM pgfc_observe.snapshots), (SELECT n FROM _snap_before),
          'observe() wrote no snapshot row on a standby');

-- The daily writers also idle. Seed one raw sample directly (a plain INSERT is unguarded) so
-- rollup() would have something to aggregate — making "wrote nothing" a real assertion, not a
-- vacuous one. With the stub active, the guarded rollup()/rollup_retain() must no-op.
INSERT INTO pgfc_observe.snapshots (slot, collected_day, collected_at, server_version_num)
VALUES ((pgfc_observe._epoch_day(now()) % pgfc_observe._ring_slots())::smallint,
        pgfc_observe._epoch_day(now()), now(), 170000);
INSERT INTO pgfc_observe.relation_samples
    (slot, snapshot_id, collected_day, relid, schemaname, relname, n_dead_tup)
VALUES ((pgfc_observe._epoch_day(now()) % pgfc_observe._ring_slots())::smallint,
        (SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
        pgfc_observe._epoch_day(now()), 1::oid, 'public', 'sb_t', 5);
CREATE TEMP TABLE _rollup_before AS SELECT count(*) AS n FROM pgfc_observe.rollup_1m;
SELECT is(pgfc_observe.rollup(), NULL,
          'rollup() is a no-op on a standby — returns NULL instead of aggregating or erroring');
SELECT is((SELECT count(*) FROM pgfc_observe.rollup_1m), (SELECT n FROM _rollup_before),
          'rollup() wrote no rollup_1m rows on a standby');
SELECT is(pgfc_observe.rollup_retain(), NULL,
          'rollup_retain() is a no-op on a standby — returns NULL');

SELECT * FROM finish();
ROLLBACK;
