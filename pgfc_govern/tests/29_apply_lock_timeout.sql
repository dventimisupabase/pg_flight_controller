-- Fortification Phase 3 (test hardening): the apply() LIVE lock-timeout path. Invariant 1 —
-- never wait on locks — at the actuation point. apply() sets a bounded, txn-local lock_timeout
-- (registry default 100ms) and ALTERs the relation; if it cannot take the lock in time the
-- ALTER raises lock_not_available (SQLSTATE 55P03), which apply() catches to record a 'failed'
-- 'lock_timeout' (actuation-class) action and return false. Until now this path was exercised
-- only by SEEDED action_history rows (13_governor_metrics, 18_load_shedding) — the live
-- contention that actually trips the timeout was the Phase-1 doc's recorded coverage gap
-- (01-security-correctness-apply.md, traceability row for Inv 1). This closes it end to end.
--
-- The contention is real, not simulated: a SECOND session (a dblink connection back to this same
-- database) holds ACCESS EXCLUSIVE on the governed table while apply() runs, so apply()'s ALTER
-- TABLE genuinely blocks and times out. CREATE EXTENSION dblink is test-only and never appears
-- in install.sql.
--
-- Why the victim table is created OUTSIDE the BEGIN…ROLLBACK (the one structural difference from
-- every other test file here): the locker is a separate backend, and a separate backend can only
-- see COMMITTED objects. A table created inside the test's open transaction is invisible to it
-- (the dblink LOCK would raise 42P01). So the table is committed up front and dropped at the end;
-- everything else (observe/plan/apply and the audit rows they write) stays inside the rolled-back
-- transaction exactly as usual. DROP … IF EXISTS guards make a re-run (or a leak from an aborted
-- prior run) clean.

-- ── committed resource setup (a separate backend must be able to see it) ──────────────────
DROP TABLE IF EXISTS public._pgfc_lock_victim;
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE TABLE public._pgfc_lock_victim (id int);

BEGIN;
SELECT plan(16);

-- Generous Invariant-4 budgets so no rate/blast-radius tier can short-circuit apply() before it
-- reaches the mutation — we are isolating the lock-timeout path, not the budget gates.
UPDATE pgfc_govern.policy
   SET global_max_changes_per_cycle = 50, daily_mutation_budget = 50 WHERE policy_name = 'default';

-- Register the victim and plan an 'adjust' for it. advisory_only stays true (the default), so
-- control_tick() PLANS but does not apply — we then drive apply() directly under contention
-- (the 16/24 idiom). A 'queue' class with no scale-factor reloption yields a target that differs
-- from the (absent) current value, so plan() proposes 'adjust'.
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue'
 WHERE relid = 'public._pgfc_lock_victim'::regclass;
SELECT pgfc_govern.control_tick();
CREATE TEMP TABLE _tk AS SELECT max(tick_id) AS id FROM pgfc_govern.tick_log;

-- ── preconditions: the contention scenario is genuinely set up ────────────────────────────
SELECT is((SELECT decision FROM pgfc_govern.decision_log
            WHERE relid = 'public._pgfc_lock_victim'::regclass
            ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'precondition: the victim was planned an adjust (it reaches apply())');
SELECT is((SELECT state::text FROM pgfc_govern.governor_state), 'normal',
          'precondition: the governor is in normal health (the authority gate is open)');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = 'public._pgfc_lock_victim'::regclass AND status = 'failed'),
          0::bigint, 'precondition: no failed action recorded for the victim yet');

-- Hold ACCESS EXCLUSIVE on the victim from a separate backend (its own open transaction). A
-- defensive lock_timeout on the locker means a future regression that left the test session
-- holding a conflicting lock fails fast and loud instead of hanging CI.
SELECT dblink_connect('pgfc_locker', format('dbname=%s user=%s', current_database(), current_user));
SELECT dblink_exec('pgfc_locker', 'SET lock_timeout = ''5s''');
SELECT dblink_exec('pgfc_locker', 'BEGIN');
SELECT dblink_exec('pgfc_locker', 'LOCK TABLE public._pgfc_lock_victim IN ACCESS EXCLUSIVE MODE');

SELECT is((SELECT count(*) FROM pg_locks
            WHERE relation = 'public._pgfc_lock_victim'::regclass
              AND mode = 'AccessExclusiveLock' AND granted AND pid <> pg_backend_pid()),
          1::bigint, 'precondition: a separate backend holds ACCESS EXCLUSIVE on the victim');

-- ── THE PROVER: apply() under live contention trips the bounded lock_timeout ───────────────
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public._pgfc_lock_victim'::regclass),
          'apply() returns false when it cannot take the lock within lock_timeout');

SELECT is((SELECT status FROM pgfc_govern.action_history
            WHERE relid = 'public._pgfc_lock_victim'::regclass ORDER BY action_id DESC LIMIT 1),
          'failed', 'a failed action is recorded (not a silent refusal)');
SELECT is((SELECT failure_reason FROM pgfc_govern.action_history
            WHERE relid = 'public._pgfc_lock_victim'::regclass ORDER BY action_id DESC LIMIT 1),
          'lock_timeout', 'the failure_reason is lock_timeout');
SELECT is((SELECT failure_class FROM pgfc_govern.action_history
            WHERE relid = 'public._pgfc_lock_victim'::regclass ORDER BY action_id DESC LIMIT 1),
          'actuation', 'the failure is classified actuation (failure taxonomy F6)');
SELECT is((SELECT lock_wait_outcome FROM pgfc_govern.action_history
            WHERE relid = 'public._pgfc_lock_victim'::regclass ORDER BY action_id DESC LIMIT 1),
          'timeout', 'the lock_wait_outcome is timeout');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = 'public._pgfc_lock_victim'::regclass AND status = 'failed'),
          1::bigint, 'exactly one failed action (the contended apply), attributable to this call');

-- Invariant 1 held: the contended ALTER never landed; the catalog is untouched.
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public._pgfc_lock_victim'::regclass),
              'autovacuum_vacuum_scale_factor'),
          NULL, 'the victim reloption is untouched (the contended ALTER never landed)');

-- ── the lights: the failure surfaces in the self-monitoring substrate ──────────────────────
SELECT is((SELECT lock_timeouts_last_hour FROM pgfc_govern.governor_metrics),
          1::bigint, 'governor_metrics counts the lock timeout (lock_timeouts_last_hour)');
SELECT ok((SELECT condition_present FROM pgfc_govern.failure_taxonomy
            WHERE failure_class = 'actuation'),
          'failure_taxonomy lights the actuation row (condition_present)');
SELECT ok((SELECT recorded_failures_last_day FROM pgfc_govern.failure_taxonomy
            WHERE failure_class = 'actuation') >= 1,
          'failure_taxonomy records the actuation failure over the day');

-- ── control: releasing the lock flips the SAME call from failure to success ────────────────
-- Same tick, same relation, same decision — only the held lock differs. Proves the timeout was
-- caused by the contention itself, not by some unrelated gate.
SELECT dblink_exec('pgfc_locker', 'ROLLBACK');
SELECT dblink_disconnect('pgfc_locker');

SELECT ok(pgfc_govern.apply((SELECT id FROM _tk), 'public._pgfc_lock_victim'::regclass),
          'with the lock released, the same apply() now succeeds');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public._pgfc_lock_victim'::regclass),
              'autovacuum_vacuum_scale_factor'),
          (SELECT proposed_value FROM pgfc_govern.decision_log
            WHERE relid = 'public._pgfc_lock_victim'::regclass AND decision = 'adjust'
            ORDER BY decision_id DESC LIMIT 1),
          'and the victim is actuated to its proposed value');

SELECT * FROM finish();
ROLLBACK;

-- ── committed teardown ─────────────────────────────────────────────────────────────────────
DROP TABLE IF EXISTS public._pgfc_lock_victim;
