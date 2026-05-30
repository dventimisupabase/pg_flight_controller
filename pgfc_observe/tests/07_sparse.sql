-- S3 sparse change-logging: observe() writes a relation_sample only when a relation's
-- observed state changed since its last sample (tracked in the UNLOGGED
-- relation_last_state side table). current_relation_state() reconstructs the dense
-- "current state per relation" view by joining forward from the last known sample,
-- computing the globally-ticking freeze ages LIVE from the stored raw xids.
BEGIN;
SELECT plan(12);

-- ── schema surface ───────────────────────────────────────────────────────────
SELECT has_table('pgfc_observe', 'relation_last_state',
                  'relation_last_state side table exists');
SELECT is((SELECT relpersistence FROM pg_class
            WHERE oid = 'pgfc_observe.relation_last_state'::regclass),
          'u', 'relation_last_state is UNLOGGED');
SELECT has_function('pgfc_observe', 'current_relation_state', ARRAY['bigint'],
                    'current_relation_state(bigint) reconciliation function exists');
SELECT has_column('pgfc_observe', 'relation_samples', 'relfrozenxid',
                  'relation_samples stores the raw relfrozenxid (stable signature key)');

-- ── change-logging: a sample is written only on observed change ───────────────
CREATE TABLE public.sparse_quiet (id int);

SELECT pgfc_observe.observe();   -- first sight of the table => one sample
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 'sparse_quiet'),
          1::bigint, 'a newly-seen relation is sampled once');

SELECT pgfc_observe.observe();   -- nothing changed => no new sample
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 'sparse_quiet'),
          1::bigint, 'an unchanged relation produces no second sample (sparse change-logging)');

-- A physical change (the heap grows) is observed and recorded.
INSERT INTO public.sparse_quiet SELECT g FROM generate_series(1, 1000) g;
SELECT pgfc_observe.observe();
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 'sparse_quiet'),
          2::bigint, 'a changed relation (heap grew) produces a new sample');

-- ── live freeze-age reconciliation (the wraparound-safety point) ──────────────
-- relfrozenxid_age ticks up globally every minute even for a table no one writes,
-- so it is NOT part of the change signature; readers recompute it live from the
-- stored raw relfrozenxid. A stale stored age must be ignored when the raw xid is set.
INSERT INTO pgfc_observe.snapshots (server_version_num) VALUES (170000);
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, relfrozenxid_age, relfrozenxid)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
        88888, 'public', 'frz_live', 5, '100'::xid);
SELECT is((SELECT relfrozenxid_age FROM pgfc_observe.current_relation_state() WHERE relid = 88888),
          age('100'::xid)::bigint,
          'freeze age is computed LIVE from the raw xid, not the stale stored age');

-- Pre-S3 / synthetic rows with a NULL raw xid fall back to the stored age.
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, relfrozenxid_age)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
        88887, 'public', 'frz_fallback', 42);
SELECT is((SELECT relfrozenxid_age FROM pgfc_observe.current_relation_state() WHERE relid = 88887),
          42::bigint,
          'freeze age falls back to the stored value when the raw xid is NULL');

-- ── forward-join reconciliation (dense view over sparse storage) ──────────────
-- A relation last sampled in an earlier snapshot is still "current" as of a later one.
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_dead_tup)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
        77777, 'public', 'carry', 99);
INSERT INTO pgfc_observe.snapshots (server_version_num) VALUES (170000);   -- later, no sample for 77777
SELECT is((SELECT n_dead_tup FROM pgfc_observe.current_relation_state(
               (SELECT max(snapshot_id) FROM pgfc_observe.snapshots)) WHERE relid = 77777),
          99::bigint, 'an unchanged relation is carried forward to a later snapshot');
SELECT is((SELECT snapshot_id FROM pgfc_observe.current_relation_state(
               (SELECT max(snapshot_id) FROM pgfc_observe.snapshots)) WHERE relid = 77777),
          (SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
          'the carried-forward row is stamped as-of the requested snapshot');

-- ── measured row reduction (S3 exit criterion) ───────────────────────────────
-- Five quiet tables across five observe() runs: sparse storage writes one sample
-- each (5), not one per table per run (25) -- an 80% reduction on idle relations.
DO $$ BEGIN
    FOR i IN 1..5 LOOP EXECUTE format('CREATE TABLE public.bench_q%s (id int)', i); END LOOP;
END $$;
SELECT pgfc_observe.observe();
SELECT pgfc_observe.observe();
SELECT pgfc_observe.observe();
SELECT pgfc_observe.observe();
SELECT pgfc_observe.observe();
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname LIKE 'bench_q%'),
          5::bigint,
          'sparse storage: 5 quiet tables x 5 runs => 5 samples (dense would be 25)');

SELECT * FROM finish();
ROLLBACK;
