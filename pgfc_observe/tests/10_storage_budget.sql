-- S6 (observe half): static autovacuum reloptions on the telemetry/rollup partitions,
-- a per-relation storage_budget() report, and a one-row self_health summary. The
-- governor maintains its own schema with EXPLICIT, STATIC settings (it must not govern
-- itself), and must be able to report its own footprint. Tests assert the reloptions
-- are present on every partition (new AND backfilled), that storage_budget folds child
-- partitions into their logical parent, and that self_health summarizes correctly.
BEGIN;
SELECT plan(16);

-- ── schema surface ───────────────────────────────────────────────────────────
SELECT has_function('pgfc_observe', 'storage_budget', 'storage_budget() exists');
SELECT has_function('pgfc_observe', '_telemetry_reloptions',
                    '_telemetry_reloptions() helper exists');
SELECT has_view('pgfc_observe', 'self_health', 'self_health view exists');

-- ── static reloptions on every partition ─────────────────────────────────────
-- Parent reloptions never propagate to children, so the option must be on each child.
-- Install created the fixed raw ring slots + today's rollup partitions, and the upgrade
-- block backfills any pre-S6 partitions; assert NONE is missing the static threshold.
SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory() pi
           JOIN pg_class c ON c.relname = pi.partition
                          AND c.relnamespace = 'pgfc_observe'::regnamespace
           WHERE NOT EXISTS (SELECT 1 FROM unnest(c.reloptions) o
                             WHERE o LIKE 'autovacuum_vacuum_threshold=%')),
          0::bigint, 'every raw partition carries a static autovacuum_vacuum_threshold');

SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory() pi
           JOIN pg_class c ON c.relname = pi.partition
                          AND c.relnamespace = 'pgfc_observe'::regnamespace
           WHERE NOT EXISTS (SELECT 1 FROM unnest(c.reloptions) o
                             WHERE o LIKE 'autovacuum_vacuum_scale_factor=0%')),
          0::bigint, 'every raw partition pins scale_factor=0 (static, not drifting)');

SELECT is((SELECT count(*) FROM pgfc_observe._rollup_inventory() ri
           JOIN pg_class c ON c.relname = ri.partition
                          AND c.relnamespace = 'pgfc_observe'::regnamespace
           WHERE NOT EXISTS (SELECT 1 FROM unnest(c.reloptions) o
                             WHERE o LIKE 'autovacuum_vacuum_threshold=%')),
          0::bigint, 'every rollup partition carries a static autovacuum_vacuum_threshold');

-- The raw ring is a FIXED set of slots created once at install (FMEA-001) — no on-demand
-- partitions — so assert the ring is exactly _ring_slots() slot partitions per raw table.
SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory()
           WHERE parent = 'snapshots'),
          pgfc_observe._ring_slots()::bigint,
          'the snapshots ring is exactly _ring_slots() fixed slot partitions');

-- ── storage_budget() ─────────────────────────────────────────────────────────
SELECT ok(EXISTS (SELECT 1 FROM pgfc_observe.storage_budget()
                  WHERE relation = 'relation_samples'),
          'storage_budget reports relation_samples');
SELECT ok(EXISTS (SELECT 1 FROM pgfc_observe.storage_budget()
                  WHERE relation = 'rollup_1m'),
          'storage_budget reports rollup_1m');
SELECT ok(EXISTS (SELECT 1 FROM pgfc_observe.storage_budget()
                  WHERE relation = 'relation_last_state'),
          'storage_budget reports the relation_last_state side table');

-- Child partitions are folded into the parent: relation_samples reports exactly ONE
-- row even though several daily partitions exist.
SELECT is((SELECT count(*) FROM pgfc_observe.storage_budget()
           WHERE relation = 'relation_samples'),
          1::bigint, 'partitioned table reports a single folded row, not one per partition');

SELECT ok((SELECT bytes FROM pgfc_observe.storage_budget()
           WHERE relation = 'relation_samples') >= 0,
          'reported bytes is non-negative');
SELECT ok((SELECT dead_tuples FROM pgfc_observe.storage_budget()
           WHERE relation = 'relation_samples') >= 0,
          'reported dead_tuples is non-negative');

-- ── self_health ──────────────────────────────────────────────────────────────
SELECT is((SELECT count(*) FROM pgfc_observe.self_health), 1::bigint,
          'self_health is exactly one row');
SELECT is((SELECT raw_partitions FROM pgfc_observe.self_health),
          (2 * pgfc_observe._ring_slots())::bigint,
          'self_health counts the fixed ring (2 × _ring_slots() raw partitions)');
SELECT is((SELECT total_dead_tuples FROM pgfc_observe.self_health),
          (SELECT COALESCE(sum(dead_tuples), 0) FROM pgfc_observe.storage_budget()),
          'self_health.total_dead_tuples agrees with storage_budget()');

SELECT * FROM finish();
ROLLBACK;
