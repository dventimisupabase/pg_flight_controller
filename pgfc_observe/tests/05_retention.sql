-- Retention is whole-partition rotation (S2): tier-1 retain() TRUNCATEs out-of-window
-- partitions; tier-2 drop_empty_partitions() DROPs the empty shells that remain.
BEGIN;
SELECT plan(8);

SELECT has_function('pgfc_observe', 'retain', ARRAY['interval'],
                    'retain(interval) exists');
SELECT has_function('pgfc_observe', 'drop_empty_partitions', ARRAY['interval'],
                    'drop_empty_partitions(interval) exists');

-- An out-of-window day (~40d ago) and its partition. Today's partition already exists
-- from install, so the recent rows route there.
SELECT pgfc_observe._ensure_partition(pgfc_observe._epoch_day(now() - interval '40 days'));

-- One snapshot + sample in the old partition, one in today's.
INSERT INTO pgfc_observe.snapshots (collected_day, collected_at, server_version_num)
VALUES (pgfc_observe._epoch_day(now() - interval '40 days'),
        now() - interval '40 days', 170000);
INSERT INTO pgfc_observe.relation_samples (snapshot_id, collected_day, relid, schemaname, relname)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
        pgfc_observe._epoch_day(now() - interval '40 days'), 1, 'public', 'old_t');

INSERT INTO pgfc_observe.snapshots (server_version_num) VALUES (170000);   -- today (defaults)
INSERT INTO pgfc_observe.relation_samples (snapshot_id, relid, schemaname, relname)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 2, 'public', 'new_t');

-- Tier 1: TRUNCATE the two old partitions (snapshots + relation_samples); keep today.
SELECT is(pgfc_observe.retain('14 days'), 2::bigint,
          'retain() truncates the two out-of-window partitions that held data');
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 'old_t'),
          0::bigint, 'old relation_samples truncated away');
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 'new_t'),
          1::bigint, 'in-window samples are kept');

-- Tier 1 leaves the empty shell behind (zero-bloat, instant reclaim, no DDL churn).
SELECT isnt((SELECT count(*) FROM pgfc_observe._partition_inventory()
             WHERE day = pgfc_observe._epoch_day(now() - interval '40 days')),
            0::bigint, 'truncated old partition shells still exist after retain()');

-- Tier 2: DROP the now-empty old shells; the populated current-day partitions stay.
SELECT is(pgfc_observe.drop_empty_partitions('30 days'), 2::bigint,
          'drop_empty_partitions() drops the two empty old shells');
SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory()
           WHERE day = pgfc_observe._epoch_day(now() - interval '40 days')),
          0::bigint, 'old partition shells are gone after tier-2 GC');

SELECT * FROM finish();
ROLLBACK;
