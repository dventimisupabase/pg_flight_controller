-- S1: govern-audit retention + policy_history.
-- The append-only audit tables (decision_log/action_history/tick_log/diagnostics)
-- must be prunable by time cutoff; policy changes must be captured in policy_history
-- and must NOT be pruned by retain() (indefinite). retain() must respect the
-- action_history -> decision_log FK (never orphan a retained action's decision).
BEGIN;
SELECT plan(16);

-- ── policy_history capture (trigger) ────────────────────────────────────────
SELECT has_table('pgfc_govern', 'policy_history', 'policy_history table exists');

-- INSERT of a new policy is logged.
INSERT INTO pgfc_govern.policy (policy_name, description)
VALUES ('test_pol', 'retention test policy');
SELECT is((SELECT operation FROM pgfc_govern.policy_history
           WHERE policy_name = 'test_pol' ORDER BY history_id DESC LIMIT 1),
          'insert', 'inserting a policy logs an insert in policy_history');

-- UPDATE is logged, and new_row reflects the change.
UPDATE pgfc_govern.policy SET aggressiveness = 2.0 WHERE policy_name = 'test_pol';
SELECT is((SELECT operation FROM pgfc_govern.policy_history
           WHERE policy_name = 'test_pol' ORDER BY history_id DESC LIMIT 1),
          'update', 'updating a policy logs an update');
SELECT is((SELECT (new_row->>'aggressiveness')::float8 FROM pgfc_govern.policy_history
           WHERE policy_name = 'test_pol' AND operation = 'update'
           ORDER BY history_id DESC LIMIT 1),
          2.0::float8, 'policy_history.new_row carries the changed value');

-- DELETE is logged.
DELETE FROM pgfc_govern.policy WHERE policy_name = 'test_pol';
SELECT is((SELECT operation FROM pgfc_govern.policy_history
           WHERE policy_name = 'test_pol' ORDER BY history_id DESC LIMIT 1),
          'delete', 'deleting a policy logs a delete');

-- The auto-seeded 'default' policy was created before the trigger exists, so it is
-- deliberately NOT in history (only real human changes are).
SELECT is((SELECT count(*) FROM pgfc_govern.policy_history WHERE policy_name = 'default'),
          0::bigint, 'the auto-seeded default policy is not logged');

-- ── retain(): time-cutoff pruning ───────────────────────────────────────────
-- Seed an OLD unreferenced decision (created 200d ago; default keep is 180d) and a
-- RECENT one; plus an OLD decision that a RECENT action references (FK-guard case).
INSERT INTO pgfc_govern.decision_log
    (tick_id, relid, actuator, observation, prev_state, desired_state, decision, created_at)
VALUES (900, 1, 'a', '{}', '{}', '{}', 'hold', now() - interval '200 days'),  -- old, unref
       (901, 2, 'a', '{}', '{}', '{}', 'hold', now()),                        -- recent
       (902, 3, 'a', '{}', '{}', '{}', 'hold', now() - interval '200 days');  -- old, referenced

-- A recent action that references the old decision 902 (guard must keep 902).
INSERT INTO pgfc_govern.action_history (batch_id, decision_id, relid, actuator, new_value, applied_at)
SELECT 1, decision_id, 3, 'a', '0.05', now()
FROM pgfc_govern.decision_log WHERE tick_id = 902;
-- An OLD action that should be pruned.
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, applied_at)
VALUES (2, 9, 'a', '0.05', now() - interval '200 days');

-- Ticks: one old, one recent.
INSERT INTO pgfc_govern.tick_log (snapshot_id, started_at)
VALUES (1, now() - interval '200 days'), (2, now());

-- Diagnostics: old+resolved (prunable), old+unresolved (kept), recent.
INSERT INTO pgfc_govern.diagnostics (relid, evidence, detected_at, resolved_at)
VALUES (1, '{}', now() - interval '400 days', now() - interval '399 days'),  -- old, resolved
       (2, '{}', now() - interval '400 days', NULL),                          -- old, unresolved
       (3, '{}', now(), NULL);                                                -- recent

-- Health-state transitions (Phase 1.7 F2): one old (prunable), one recent (kept).
INSERT INTO pgfc_govern.state_transitions (from_state, to_state, transitioned_at)
VALUES ('normal', 'degraded', now() - interval '200 days'),
       ('normal', 'degraded', now());

SELECT pgfc_govern.retain();

-- decision_log: old unreferenced gone; recent kept; FK-guarded old kept.
SELECT is((SELECT count(*) FROM pgfc_govern.decision_log WHERE tick_id = 900),
          0::bigint, 'old unreferenced decision is pruned');
SELECT is((SELECT count(*) FROM pgfc_govern.decision_log WHERE tick_id = 901),
          1::bigint, 'recent decision is kept');
SELECT is((SELECT count(*) FROM pgfc_govern.decision_log WHERE tick_id = 902),
          1::bigint, 'old decision still referenced by a retained action is kept (FK guard)');

-- action_history: old pruned; recent kept.
SELECT is((SELECT count(*) FROM pgfc_govern.action_history WHERE batch_id = 2),
          0::bigint, 'old action is pruned');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history WHERE batch_id = 1),
          1::bigint, 'recent action is kept');

-- tick_log: old pruned; recent kept.
SELECT is((SELECT count(*) FROM pgfc_govern.tick_log WHERE snapshot_id = 1),
          0::bigint, 'old tick is pruned');

-- diagnostics: old+resolved pruned; old+unresolved kept (still a live finding).
SELECT is((SELECT count(*) FROM pgfc_govern.diagnostics
           WHERE relid = 1 AND detected_at < now() - interval '365 days'),
          0::bigint, 'old resolved diagnostic is pruned');
SELECT is((SELECT count(*) FROM pgfc_govern.diagnostics WHERE relid = 2),
          1::bigint, 'old UNRESOLVED diagnostic is kept (active finding, never aged out)');

-- state_transitions: old pruned; recent kept.
SELECT is((SELECT count(*) FROM pgfc_govern.state_transitions
           WHERE transitioned_at < now() - interval '1 day'),
          0::bigint, 'old state_transition is pruned');
SELECT is((SELECT count(*) FROM pgfc_govern.state_transitions
           WHERE transitioned_at >= now() - interval '1 day'),
          1::bigint, 'recent state_transition is kept');

SELECT * FROM finish();
ROLLBACK;
