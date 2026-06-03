-- Fortification FMEA-004 (#81): Invariant 1 — never wait on locks — outside the apply()
-- path. The observe-side maintenance DDL (CREATE PARTITION OF, TRUNCATE, DROP) takes
-- ACCESS EXCLUSIVE and, unbounded, would wait forever behind a long reader/writer of a
-- telemetry partition. Every recurring maintenance function now sets a bounded, txn-local
-- lock_timeout at the top of its body. We verify the bound is set deterministically (baseline
-- the GUC to '0' = unbounded, call the function, assert it is no longer unbounded). The
-- skip-and-retry behavior on an actual timeout needs concurrent-lock infra → Phase 3.
BEGIN;
SELECT plan(6);

SELECT has_function('pgfc_observe', '_maintenance_lock_timeout',
                    'the maintenance lock_timeout bound is single-sourced in a helper');

-- Each maintenance function bounds its lock wait. set_config(..., is_local := true) inside a
-- function called from this transaction persists after the function returns, so we can read
-- it back; a plain SET between calls re-baselines to the unbounded default.
SET lock_timeout = '0';
SELECT pgfc_observe.retain();
SELECT isnt(current_setting('lock_timeout'), '0', 'retain() sets a bounded lock_timeout');

SET lock_timeout = '0';
SELECT pgfc_observe.drop_empty_partitions();
SELECT isnt(current_setting('lock_timeout'), '0', 'drop_empty_partitions() sets a bounded lock_timeout');

SET lock_timeout = '0';
SELECT pgfc_observe.rollup_retain();
SELECT isnt(current_setting('lock_timeout'), '0', 'rollup_retain() sets a bounded lock_timeout');

SET lock_timeout = '0';
SELECT pgfc_observe._ensure_partition();
SELECT isnt(current_setting('lock_timeout'), '0', '_ensure_partition() sets a bounded lock_timeout');

SET lock_timeout = '0';
SELECT pgfc_observe._ensure_part('rollup_1m', pgfc_observe._epoch_day(now()), 'day');
SELECT isnt(current_setting('lock_timeout'), '0', '_ensure_part() sets a bounded lock_timeout');

RESET lock_timeout;
SELECT * FROM finish();
ROLLBACK;
