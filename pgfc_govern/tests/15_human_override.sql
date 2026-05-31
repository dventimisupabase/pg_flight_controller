-- Phase 1.7 F3: the human-override surface. Operators retain ultimate authority — they
-- can force the governor into a MORE cautious state (suspend actuation, force diagnostic,
-- disable) and release the hold, all audited as state transitions. The load-bearing
-- invariant: the operator force is a caution FLOOR, never a ceiling — evaluate_health()
-- takes the WORST of the auto-computed state and the operator-forced state, so a human can
-- force more caution but never less. 'disabled' is reachable ONLY via the operator force;
-- the automatic evaluator never gets there. F3 sets the state only; it does not yet gate
-- actuation (that authority gate is F4), so this suite asserts state/transition/forced-
-- column behavior, not actuation suppression.
BEGIN;
SELECT plan(29);

-- ── shape ──────────────────────────────────────────────────────────────────────
SELECT has_column('pgfc_govern', 'governor_state', 'operator_forced',
                  'governor_state has operator_forced (NULL = automatic)');
SELECT has_column('pgfc_govern', 'governor_state', 'forced_reason',
                  'governor_state has forced_reason');
SELECT has_column('pgfc_govern', 'governor_state', 'forced_by',
                  'governor_state has forced_by');
SELECT has_column('pgfc_govern', 'governor_state', 'forced_at',
                  'governor_state has forced_at');
SELECT has_function('pgfc_govern', 'force_state', 'force_state() exists');
SELECT has_function('pgfc_govern', 'clear_forced_state', 'clear_forced_state() exists');
SELECT has_function('pgfc_govern', 'disable', 'disable() exists');
SELECT has_function('pgfc_govern', 'suspend_actuation', 'suspend_actuation() exists');

-- ── boot: no operator hold ─────────────────────────────────────────────────────
SELECT is((SELECT operator_forced FROM pgfc_govern.governor_state), NULL,
          'a fresh governor carries no operator-forced hold');

-- ── forcing a state: more caution, audited ──────────────────────────────────────
SELECT is(pgfc_govern.force_state('diagnostic', 'manual hold for investigation')::text,
          'diagnostic', 'force_state(diagnostic) returns the new effective state');
SELECT is((SELECT state::text FROM pgfc_govern.governor_state), 'diagnostic',
          'the forced state is written to governor_state');
SELECT is((SELECT operator_forced::text FROM pgfc_govern.governor_state), 'diagnostic',
          'operator_forced records the hold');
SELECT is((SELECT forced_by FROM pgfc_govern.governor_state), current_user::text,
          'forced_by records who placed the hold');
SELECT ok((SELECT EXISTS (SELECT 1 FROM pgfc_govern.state_transitions
                          WHERE from_state = 'normal' AND to_state = 'diagnostic')),
          'the normal→diagnostic transition is recorded');
SELECT ok((SELECT reason LIKE '%operator%' FROM pgfc_govern.governor_state),
          'the reason surfaces that the state is operator-forced');

-- ── worst-of: when the automatic state is WORSE than the hold, auto wins ─────────
SELECT is(pgfc_govern.clear_forced_state('release')::text, 'normal',
          'clearing the hold returns to automatic (normal when clean)');
SELECT is(pgfc_govern.force_state('degraded', 'soft hold')::text, 'degraded',
          'force_state(degraded) takes effect when nothing else is elevated');
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, status, applied_at)
SELECT 1, g, 'a', '0.05', 'failed', now() FROM generate_series(1, 11) g;   -- auto → diagnostic
SELECT is(pgfc_govern.evaluate_health()::text, 'diagnostic',
          'the worst signal wins: auto diagnostic (failures) over a degraded hold');
SELECT is((SELECT operator_forced::text FROM pgfc_govern.governor_state), 'degraded',
          'the operator hold persists even while a worse automatic state binds');

-- ── the floor never reduces caution below the automatic state ────────────────────
SELECT is(pgfc_govern.force_state('degraded', 'still soft')::text, 'diagnostic',
          'forcing a milder state cannot make the governor less cautious than auto demands');

-- ── 'normal' is not forcible — release is the only way back to less caution ──────
SELECT throws_ok($$ SELECT pgfc_govern.force_state('normal', 'nope') $$,
                 NULL, NULL, 'force_state rejects normal (use clear_forced_state to release)');

-- ── disable: the only path to the disabled state ─────────────────────────────────
DELETE FROM pgfc_govern.action_history;   -- clear the auto-elevated signal
SELECT is(pgfc_govern.disable('maintenance window')::text, 'disabled',
          'disable() forces the disabled state');
SELECT is((SELECT state::text FROM pgfc_govern.governor_state), 'disabled',
          'governor_state reflects the disabled hold');

-- ── release returns to automatic control ─────────────────────────────────────────
SELECT is(pgfc_govern.clear_forced_state('window over')::text, 'normal',
          'clear_forced_state releases disabled back to automatic');
SELECT is((SELECT operator_forced FROM pgfc_govern.governor_state), NULL,
          'releasing the hold clears operator_forced');

-- ── suspend_actuation maps to diagnostic (actuation off, diagnosis retained) ─────
SELECT is(pgfc_govern.suspend_actuation('draining traffic')::text, 'diagnostic',
          'suspend_actuation() forces diagnostic (no actuation, full diagnosis)');
SELECT is((SELECT operator_forced::text FROM pgfc_govern.governor_state), 'diagnostic',
          'suspend_actuation records the diagnostic hold');

-- ── the hold is sticky across evaluations (a later control tick keeps it) ─────────
SELECT is(pgfc_govern.evaluate_health()::text, 'diagnostic',
          'a re-evaluation with a clean database keeps the operator hold (sticky)');
SELECT is(pgfc_govern.clear_forced_state()::text, 'normal',
          'clear_forced_state (no reason) releases the sticky hold');

SELECT * FROM finish();
ROLLBACK;
