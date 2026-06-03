-- Fortification FMEA-004 (#81): Invariant 1 — never wait on locks — outside the apply()
-- path. The observe-side maintenance DDL takes ACCESS EXCLUSIVE and, unbounded, would wait
-- forever behind a long reader/writer of a telemetry partition. After FMEA-001 the raw tables
-- recycle via the ring (rotate_ring TRUNCATEs the slot rolling off); the rollup tables still
-- CREATE/DROP RANGE partitions (_ensure_part / rollup_retain). Every recurring maintenance
-- function sets a bounded, txn-local lock_timeout at the top of its body. We verify the bound
-- is set deterministically (baseline the GUC to '0' = unbounded, call the function, assert it
-- is no longer unbounded). The skip-and-retry behavior on an actual timeout needs
-- concurrent-lock infra → Phase 3.
BEGIN;
SELECT plan(4);

SELECT has_function('pgfc_observe', '_maintenance_lock_timeout',
                    'the maintenance lock_timeout bound is single-sourced in a helper');

-- Each maintenance function bounds its lock wait. set_config(..., is_local := true) inside a
-- function called from this transaction persists after the function returns, so we can read
-- it back; a plain SET between calls re-baselines to the unbounded default.

-- rotate_ring(): the raw ring's TRUNCATE-based recycle (FMEA-001), called hot by observe().
SET lock_timeout = '0';
SELECT pgfc_observe.rotate_ring();
SELECT isnt(current_setting('lock_timeout'), '0', 'rotate_ring() sets a bounded lock_timeout');

-- rollup_retain(): the coarse rollup tiers still DROP RANGE partitions.
SET lock_timeout = '0';
SELECT pgfc_observe.rollup_retain();
SELECT isnt(current_setting('lock_timeout'), '0', 'rollup_retain() sets a bounded lock_timeout');

-- _ensure_part(): the rollup parents still CREATE PARTITION OF on demand.
SET lock_timeout = '0';
SELECT pgfc_observe._ensure_part('rollup_1m', pgfc_observe._epoch_day(now()), 'day');
SELECT isnt(current_setting('lock_timeout'), '0', '_ensure_part() sets a bounded lock_timeout');

RESET lock_timeout;
SELECT * FROM finish();
ROLLBACK;
