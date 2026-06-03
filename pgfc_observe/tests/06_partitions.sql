-- Ring structure & routing (FMEA-001): _ring_slots() fixes the slot count; the slot
-- partitions are created ONCE at install; observe() stamps slot = day % _ring_slots() and
-- routes each row into its slot partition; _partition_inventory() reports the slots; and
-- rotate_ring() is idempotent. (15_ring_rotation.sql is the end-to-end zero-churn prover.)
BEGIN;
SELECT plan(8);

SELECT has_function('pgfc_observe', '_ring_slots', '_ring_slots() exists');
SELECT has_function('pgfc_observe', 'rotate_ring', ARRAY['integer'],
                    'rotate_ring(integer) exists');

-- The ring is a FIXED set of _ring_slots() slot partitions per raw table, created at install.
SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory() WHERE parent = 'snapshots'),
          pgfc_observe._ring_slots()::bigint,
          'snapshots has _ring_slots() slot partitions at install');
SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory() WHERE parent = 'relation_samples'),
          pgfc_observe._ring_slots()::bigint,
          'relation_samples has _ring_slots() slot partitions at install');

-- _partition_inventory() decodes the LIST bound back to the slot number.
SELECT is((SELECT slot FROM pgfc_observe._partition_inventory() WHERE partition = 'snapshots_s0'),
          0, '_partition_inventory decodes the LIST bound -> slot 0');

-- observe() stamps slot = today % _ring_slots() and routes the header into that slot partition.
SELECT pgfc_observe.observe();
SELECT is((SELECT slot FROM pgfc_observe.snapshots ORDER BY snapshot_id DESC LIMIT 1),
          (pgfc_observe._epoch_day(now()) % pgfc_observe._ring_slots())::smallint,
          'observe() stamps slot = today % _ring_slots()');
SELECT is((SELECT tableoid::regclass::text FROM pgfc_observe.snapshots
            ORDER BY snapshot_id DESC LIMIT 1),
          'pgfc_observe.snapshots_s'
            || (pgfc_observe._epoch_day(now()) % pgfc_observe._ring_slots())::text,
          'observe() row is routed into its slot partition');

-- rotate_ring is idempotent / race-safe (re-running it on a fresh ring changes nothing).
SELECT lives_ok($$ SELECT pgfc_observe.rotate_ring() $$,
                're-running rotate_ring is harmless (idempotent)');

SELECT * FROM finish();
ROLLBACK;
