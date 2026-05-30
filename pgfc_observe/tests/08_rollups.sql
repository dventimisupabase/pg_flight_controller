-- S4 rollups: rollup() aggregates raw samples into the 1m/1h/1d tiers (cascading,
-- sample-count-weighted, idempotent); current_rollup() carries the latest bucket forward so
-- a relation stays answerable after raw rotates away; rollup_retain() drops out-of-window
-- partitions per tier. The carry-forward-after-truncate test IS the increment's exit
-- criterion ("rollups answer long-range queries after raw data is gone").
--
-- Buckets are anchored to the START OF THE PREVIOUS HOUR (always in the past, within the
-- rollup lookback) so the test is independent of the current time-of-day. Two 1-minute
-- buckets with DIFFERENT sample counts feed the same hour, so the hour's average can only
-- be right if it is sample-count-WEIGHTED (a plain mean would give a different number).
BEGIN;
SELECT plan(24);

-- ── schema surface ───────────────────────────────────────────────────────────
SELECT has_table('pgfc_observe', 'rollup_1m', 'rollup_1m tier exists');
SELECT has_table('pgfc_observe', 'rollup_1h', 'rollup_1h tier exists');
SELECT has_table('pgfc_observe', 'rollup_1d', 'rollup_1d tier exists');
SELECT is((SELECT relkind FROM pg_class WHERE oid = 'pgfc_observe.rollup_1m'::regclass),
          'p', 'rollup_1m is RANGE partitioned');
SELECT has_function('pgfc_observe', 'rollup', ARRAY['interval'],
                    'rollup(interval) exists');
SELECT has_function('pgfc_observe', 'current_rollup',
                    ARRAY['text', 'timestamp with time zone'],
                    'current_rollup(text, timestamptz) exists');
SELECT has_function('pgfc_observe', 'rollup_retain',
                    ARRAY['interval', 'interval', 'interval'],
                    'rollup_retain(interval, interval, interval) exists');

-- ── seed raw: minute A (2 samples) and minute B (1 sample) in one hour ─────────
-- A => avg_dead 150, count 2, max 200, max xid age 1000.  B => avg_dead 600, count 1.
INSERT INTO pgfc_observe.snapshots (collected_at, server_version_num)
VALUES (date_trunc('hour', now() - interval '1 hour', 'UTC') + interval '10 min 10 sec', 170000);
INSERT INTO pgfc_observe.relation_samples
       (snapshot_id, relid, schemaname, relname, n_dead_tup, n_live_tup,
        n_mod_since_analyze, reltuples, relfrozenxid_age, total_size_bytes)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
        12345, 'public', 'rollup_t', 100, 1000, 30, 1000, 500, 8192);

INSERT INTO pgfc_observe.snapshots (collected_at, server_version_num)
VALUES (date_trunc('hour', now() - interval '1 hour', 'UTC') + interval '10 min 20 sec', 170000);
INSERT INTO pgfc_observe.relation_samples
       (snapshot_id, relid, schemaname, relname, n_dead_tup, n_live_tup,
        n_mod_since_analyze, reltuples, relfrozenxid_age, total_size_bytes)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
        12345, 'public', 'rollup_t', 200, 1000, 50, 1000, 1000, 8192);

INSERT INTO pgfc_observe.snapshots (collected_at, server_version_num)
VALUES (date_trunc('hour', now() - interval '1 hour', 'UTC') + interval '20 min 10 sec', 170000);
INSERT INTO pgfc_observe.relation_samples
       (snapshot_id, relid, schemaname, relname, n_dead_tup, n_live_tup,
        n_mod_since_analyze, reltuples, relfrozenxid_age, total_size_bytes)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
        12345, 'public', 'rollup_t', 600, 1000, 80, 1000, 700, 8192);

SELECT lives_ok($$ SELECT pgfc_observe.rollup('1 day') $$, 'rollup() runs');

-- ── tier 1m ← raw (assertions scoped to minute-A bucket) ──────────────────────
SELECT is((SELECT sample_count FROM pgfc_observe.rollup_1m WHERE relid = 12345
           AND bucket_start = date_trunc('hour', now() - interval '1 hour', 'UTC') + interval '10 min'),
          2, 'rollup_1m folds both same-minute samples into one bucket (sample_count = 2)');
SELECT is((SELECT avg_dead_tup FROM pgfc_observe.rollup_1m WHERE relid = 12345
           AND bucket_start = date_trunc('hour', now() - interval '1 hour', 'UTC') + interval '10 min'),
          150::float8, 'rollup_1m avg_dead_tup = mean(100, 200)');
SELECT is((SELECT max_dead_tup FROM pgfc_observe.rollup_1m WHERE relid = 12345
           AND bucket_start = date_trunc('hour', now() - interval '1 hour', 'UTC') + interval '10 min'),
          200::bigint, 'rollup_1m max_dead_tup = max(100, 200)');
SELECT is((SELECT max_relfrozenxid_age FROM pgfc_observe.rollup_1m WHERE relid = 12345
           AND bucket_start = date_trunc('hour', now() - interval '1 hour', 'UTC') + interval '10 min'),
          1000::bigint, 'rollup_1m max_relfrozenxid_age = max xid age over the bucket');

-- ── cascade 1h ← 1m: the average MUST be sample-count-weighted ─────────────────
-- weighted: (150*2 + 600*1)/3 = 300  (a plain mean would be (150+600)/2 = 375)
SELECT is((SELECT avg_dead_tup FROM pgfc_observe.rollup_1h WHERE relid = 12345),
          300::float8, 'rollup_1h avg_dead_tup is sample-count-weighted across its 1m buckets');
SELECT is((SELECT max_dead_tup FROM pgfc_observe.rollup_1h WHERE relid = 12345),
          600::bigint, 'rollup_1h max_dead_tup = max across its 1m buckets');

-- ── cascade 1d ← 1h (same weighted helper as 1h) ──────────────────────────────
SELECT is((SELECT avg_dead_tup FROM pgfc_observe.rollup_1d WHERE relid = 12345),
          300::float8, 'rollup_1d carries the weighted average up from 1h');
SELECT is((SELECT max_dead_tup FROM pgfc_observe.rollup_1d WHERE relid = 12345),
          600::bigint, 'rollup_1d carries the max up from 1h');

-- ── idempotency: re-running upserts, never duplicates a bucket ─────────────────
SELECT pgfc_observe.rollup('1 day');
SELECT is((SELECT count(*) FROM pgfc_observe.rollup_1m WHERE relid = 12345),
          2::bigint, 're-running rollup() upserts the same two 1m buckets (no duplicates)');

-- ── carry-forward across a gap: as-of between A and B returns A (the prior bucket) ──
SELECT is((SELECT avg_dead_tup FROM pgfc_observe.current_rollup('1m',
            date_trunc('hour', now() - interval '1 hour', 'UTC') + interval '15 min')
           WHERE relid = 12345),
          150::float8, 'current_rollup() carries the last bucket forward across a quiet gap');

-- ── exit criterion: still answerable after raw is gone ────────────────────────
TRUNCATE pgfc_observe.relation_samples;   -- raw rotated away
SELECT is((SELECT count(*) FROM pgfc_observe.current_rollup('1m') WHERE relid = 12345),
          1::bigint, 'current_rollup() returns one (latest) bucket per relation after raw truncation');
SELECT is((SELECT avg_dead_tup FROM pgfc_observe.current_rollup('1m') WHERE relid = 12345),
          600::float8, 'the carried-forward bucket is the latest one (minute B)');
SELECT throws_ok($$ SELECT pgfc_observe.current_rollup('5m') $$, NULL,
                 'current_rollup() rejects an unknown tier');

-- ── retention: cascading per-tier partition drop ──────────────────────────────
-- An old 1m partition (~30 d ago) is past the 7-day 1m window; rollup_retain() drops it,
-- while this month's in-window 1h/1d partitions stay.
SELECT pgfc_observe._ensure_part('rollup_1m',
       pgfc_observe._epoch_day(now() - interval '30 days'), 'day');
SELECT isnt((SELECT count(*) FROM pgfc_observe._rollup_inventory()
             WHERE parent = 'rollup_1m'
               AND part_key = pgfc_observe._epoch_day(now() - interval '30 days')),
            0::bigint, 'the old 1m partition exists before retention');
SELECT ok(pgfc_observe.rollup_retain() >= 1,
          'rollup_retain() drops at least the out-of-window 1m partition');
SELECT is((SELECT count(*) FROM pgfc_observe._rollup_inventory()
           WHERE parent = 'rollup_1m'
             AND part_key = pgfc_observe._epoch_day(now() - interval '30 days')),
          0::bigint, 'the old 1m partition is gone after rollup_retain()');

SELECT * FROM finish();
ROLLBACK;
