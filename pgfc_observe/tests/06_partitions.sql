-- S2 partition infrastructure: _ensure_partition() creates the daily partitions and is
-- idempotent; _partition_inventory() reports them with decoded ranges; observe() stamps
-- collected_day and routes the row into the matching daily partition.
BEGIN;
SELECT plan(8);

SELECT has_function('pgfc_observe', '_ensure_partition', ARRAY['integer'],
                    '_ensure_partition(integer) exists');
SELECT has_function('pgfc_observe', '_partition_inventory',
                    '_partition_inventory() exists');

-- Use a far-future day so we never collide with the install/today partition.
SELECT pgfc_observe._ensure_partition(pgfc_observe._epoch_day(now() + interval '100 days'));

SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory()
           WHERE parent = 'snapshots'
             AND day = pgfc_observe._epoch_day(now() + interval '100 days')),
          1::bigint, '_ensure_partition created the snapshots daily partition');
SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory()
           WHERE parent = 'relation_samples'
             AND day = pgfc_observe._epoch_day(now() + interval '100 days')),
          1::bigint, '_ensure_partition created the relation_samples daily partition');

-- Calling it again is a harmless no-op (idempotent / race-safe).
SELECT lives_ok(
    $$ SELECT pgfc_observe._ensure_partition(pgfc_observe._epoch_day(now() + interval '100 days')) $$,
    're-ensuring an existing partition is idempotent');

-- The inventory decodes the int4 day back to its UTC range start.
SELECT is((SELECT range_start FROM pgfc_observe._partition_inventory()
           WHERE day = pgfc_observe._epoch_day(now() + interval '100 days') LIMIT 1),
          to_timestamp(pgfc_observe._epoch_day(now() + interval '100 days')::bigint * 86400),
          '_partition_inventory decodes day -> UTC range_start');

-- observe() stamps collected_day with today and routes the header into today's partition.
SELECT pgfc_observe.observe();
SELECT is((SELECT collected_day FROM pgfc_observe.snapshots ORDER BY snapshot_id DESC LIMIT 1),
          pgfc_observe._epoch_day(now()),
          'observe() stamps collected_day = today');
SELECT is((SELECT tableoid::regclass::text FROM pgfc_observe.snapshots
            ORDER BY snapshot_id DESC LIMIT 1),
          'pgfc_observe.snapshots_p' || to_char((now() AT TIME ZONE 'UTC'), 'YYYYMMDD'),
          'observe() row is routed into today''s partition');

SELECT * FROM finish();
ROLLBACK;
