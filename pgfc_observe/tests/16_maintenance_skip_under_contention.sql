-- Fortification Phase 3 (test hardening): the observe-side maintenance DDL's LIVE
-- skip-under-contention path. Invariant 1 — never wait unboundedly on locks — outside apply().
-- Closes two gap-inventory rows at once (docs/fortification/03-test-hardening.md):
--   • "Maintenance-DDL skip-under-contention (FMEA-004)" — rollup_retain() DROPs a rollup
--     partition past its window in a per-partition subtransaction; a busy partition is SKIPPED
--     (retried next run), not an error that aborts the whole sweep.
--   • "rotate_ring slot skip (FMEA-001)" — rotate_ring() TRUNCATEs a stale ring slot in a
--     per-partition subtransaction for any NON-current slot; a busy stale slot is SKIPPED.
-- Until now both were "exercised only by construction" (13_maintenance_lock_timeout asserts the
-- bound is SET, not that contention is survived). This closes them end to end, mirroring the
-- apply() live-lock-timeout template (pgfc_govern/tests/29_apply_lock_timeout).
--
-- The contention is real, not simulated: a SECOND session (a dblink connection back to this same
-- database) holds a conflicting lock on a telemetry partition while the maintenance function
-- runs, so its TRUNCATE/DROP genuinely blocks and the function's bounded lock_timeout (5s,
-- pgfc_observe._maintenance_lock_timeout) fires. CREATE EXTENSION dblink is test-only and never
-- appears in install.sql.
--
-- Why ROW EXCLUSIVE (a concurrent *writer*), not ACCESS EXCLUSIVE: both rotate_ring and
-- rollup_retain wrap ONLY the mutating DDL (the TRUNCATE / DROP, which take ACCESS EXCLUSIVE) in
-- the skip subtransaction. Each also has an UNWRAPPED read-side step that takes ACCESS SHARE —
-- rotate_ring's "is this slot stale?" EXISTS probe, and rollup_retain's _rollup_inventory()
-- (pg_total_relation_size opens each partition). ROW EXCLUSIVE is compatible with ACCESS SHARE
-- (the read-side step proceeds) but conflicts with ACCESS EXCLUSIVE (the mutation blocks → times
-- out → is caught → the partition is skipped). This is exactly the realistic contention the skip
-- guards against — a long writer of a telemetry partition. (An ACCESS EXCLUSIVE holder — only
-- another concurrent DDL — would instead block the unwrapped read-side step and abort the whole
-- run; that is bounded and fail-safe, not the per-partition skip path under test here.)
--
-- TDD note: against the pre-fix code (no lock_timeout) the TRUNCATE/DROP waits FOREVER on the
-- locker — it hangs, it does not fail cleanly, so there is no ordinary "watch it go red". The
-- evidence that the test exercises the real path is instead the pair the apply() test uses: a
-- pg_locks precondition (the contention is genuinely held by another backend) plus a control
-- re-run (the SAME call, lock released, now does the work) — proving the skip was caused by the
-- contention, not by some unrelated short-circuit.
--
-- Committed-resource setup (OUTSIDE the BEGIN…ROLLBACK — the one structural difference from the
-- other observe test files): a separate backend can only see COMMITTED objects. The raw ring's
-- slot partitions already exist (created committed at install), so rotate_ring needs none — only
-- an (uncommitted, this-session-only) stale row to make a slot recyclable, which the locker need
-- not see. rollup_retain needs a *droppable* rollup partition the locker can lock, so one is
-- created committed up front (an ancient throwaway, dropped at the end). DROP … IF EXISTS guards
-- make a re-run (or a leak from an aborted prior run) clean.

-- ── committed resource setup (a separate backend must be able to see what it locks) ──────────
DROP TABLE IF EXISTS pgfc_observe.rollup_1m_p20000101;
CREATE EXTENSION IF NOT EXISTS dblink;
-- An ancient, empty rollup_1m partition: range [2000-01-01, 2000-01-02) is decades past the 7-day
-- keep_1m window, so rollup_retain() targets it for DROP. Named deterministically by _ensure_part
-- (rollup_1m_p20000101), so teardown can drop it by name regardless of how the test exits.
SELECT pgfc_observe._ensure_part(
           'rollup_1m', pgfc_observe._epoch_day('2000-01-01 00:00:00+00'::timestamptz), 'day');

BEGIN;
SELECT plan(12);

-- ═════════════════════════════════════════════════════════════════════════════════════════════
-- rotate_ring(): a busy NON-current stale slot is skipped (FMEA-001 slot skip)
-- ═════════════════════════════════════════════════════════════════════════════════════════════
-- Seed one stale row into slot 3 (collected_day 100). It is uncommitted — only this session's
-- rotate_ring sees it, which is all that matters: the locker locks the partition (committed at
-- install), not the row. With the committed ring empty, slot 3 is the ONLY stale slot, so the
-- recycle count is an exact 0 (skipped) / 1 (truncated). collected_day is NOT NULL with a default;
-- server_version_num is NOT NULL with none, so it is supplied.
INSERT INTO pgfc_observe.snapshots (slot, collected_day, server_version_num)
VALUES (3, 100, current_setting('server_version_num')::int);

SELECT is((SELECT count(*) FROM pgfc_observe.snapshots_s3 WHERE collected_day = 100),
          1::bigint, 'precondition: a stale row sits in non-current ring slot 3');

-- Hold ROW EXCLUSIVE on slot 3's partition from a separate backend (its own open transaction) —
-- a concurrent writer. The defensive lock_timeout on the locker means a regression that left THIS
-- session holding a conflicting lock fails fast and loud instead of hanging CI.
SELECT dblink_connect('pgfc_locker', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_exec('pgfc_locker', 'SET lock_timeout = ''5s''');
SELECT dblink_exec('pgfc_locker', 'BEGIN');
SELECT dblink_exec('pgfc_locker', 'LOCK TABLE pgfc_observe.snapshots_s3 IN ROW EXCLUSIVE MODE');

SELECT is((SELECT count(*) FROM pg_locks
            WHERE relation = 'pgfc_observe.snapshots_s3'::regclass
              AND mode = 'RowExclusiveLock' AND granted AND pid <> pg_backend_pid()),
          1::bigint, 'precondition: a separate backend holds ROW EXCLUSIVE on slot 3');

-- THE PROVER: p_day 200 → cutoff 193 (slot 3's day 100 is stale) and v_cur = 200 % 8 = 0 (so
-- slot 3 is non-current → the wrapped, skip-on-contention branch). The probe (ACCESS SHARE) gets
-- past the writer; the TRUNCATE (ACCESS EXCLUSIVE) blocks, times out, is caught, slot skipped.
-- is(...) completing at all proves the run did not error; the 0 proves nothing was recycled.
SELECT is(pgfc_observe.rotate_ring(200), 0::bigint,
          'rotate_ring() skips the busy non-current slot (0 recycled, no error)');
SELECT is((SELECT count(*) FROM pgfc_observe.snapshots_s3 WHERE collected_day = 100),
          1::bigint, 'the stale row survives — the slot was skipped, not truncated');

-- Control: release the lock; the SAME sweep now recycles the slot. Same p_day, same slot, same
-- stale row — only the held lock differs, proving the skip was the contention, not an empty slot.
SELECT dblink_exec('pgfc_locker', 'ROLLBACK');
SELECT dblink_disconnect('pgfc_locker');

SELECT is(pgfc_observe.rotate_ring(200), 1::bigint,
          'with the lock released, the same sweep recycles the slot');
SELECT is((SELECT count(*) FROM pgfc_observe.snapshots_s3 WHERE collected_day = 100),
          0::bigint, 'the stale slot is truncated once the lock is gone');

-- ═════════════════════════════════════════════════════════════════════════════════════════════
-- rollup_retain(): a busy out-of-window rollup partition is skipped (FMEA-004)
-- ═════════════════════════════════════════════════════════════════════════════════════════════
SELECT has_table('pgfc_observe', 'rollup_1m_p20000101',
                 'precondition: an ancient, out-of-window rollup partition exists');

-- Same idiom: a concurrent writer (ROW EXCLUSIVE) holds the partition. ROW EXCLUSIVE — not ACCESS
-- EXCLUSIVE — because _rollup_inventory() (the loop source) calls pg_total_relation_size on every
-- partition, taking ACCESS SHARE; an ACCESS EXCLUSIVE holder would block that scan and abort the
-- run before the guarded DROP is ever reached.
SELECT dblink_connect('pgfc_locker', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_exec('pgfc_locker', 'SET lock_timeout = ''5s''');
SELECT dblink_exec('pgfc_locker', 'BEGIN');
SELECT dblink_exec('pgfc_locker', 'LOCK TABLE pgfc_observe.rollup_1m_p20000101 IN ROW EXCLUSIVE MODE');

SELECT is((SELECT count(*) FROM pg_locks
            WHERE relation = 'pgfc_observe.rollup_1m_p20000101'::regclass
              AND mode = 'RowExclusiveLock' AND granted AND pid <> pg_backend_pid()),
          1::bigint, 'precondition: a separate backend holds ROW EXCLUSIVE on the ancient partition');

-- THE PROVER: rollup_retain() runs the inventory (ACCESS SHARE, gets past the writer), then the
-- DROP (ACCESS EXCLUSIVE) blocks, times out, is caught — the partition is skipped, no error.
SELECT lives_ok($$ SELECT pgfc_observe.rollup_retain() $$,
                'rollup_retain() does not error when its target partition is busy');
SELECT has_table('pgfc_observe', 'rollup_1m_p20000101',
                 'the busy partition survives — it was skipped, not dropped');

-- Control: release the lock; the SAME GC now drops it (>= 1 tolerates any other partition that
-- also ages out, while hasnt_table pins the specific drop).
SELECT dblink_exec('pgfc_locker', 'ROLLBACK');
SELECT dblink_disconnect('pgfc_locker');

SELECT ok(pgfc_observe.rollup_retain() >= 1,
          'with the lock released, rollup_retain() now drops the aged-out partition');
SELECT hasnt_table('pgfc_observe', 'rollup_1m_p20000101',
                   'the partition is dropped once the lock is gone');

SELECT * FROM finish();
ROLLBACK;

-- ── committed teardown ───────────────────────────────────────────────────────────────────────
-- The control DROP above is inside the rolled-back transaction, so the partition is restored on
-- ROLLBACK; remove it for real here (and clean up any leak from an aborted run).
DROP TABLE IF EXISTS pgfc_observe.rollup_1m_p20000101;
