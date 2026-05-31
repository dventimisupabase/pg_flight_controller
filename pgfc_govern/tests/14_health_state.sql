-- Phase 1.7 F2: the governor health-state machine. evaluate_health() computes a state
-- (normal/degraded/diagnostic/emergency/disabled) from the F1 governor_metrics substrate
-- against born-governed registry thresholds, writes the singleton governor_state, and
-- records a state_transitions row ONLY when the state changes. It is advisory in F2 — it
-- does not yet gate actuation (that is F4). The subtle contract, the F2 analog of F1's
-- one-row guarantee: a fresh governor with no observations evaluates to NORMAL, not
-- emergency — absence of data at boot is not ill health.
BEGIN;
SELECT plan(25);

-- ── shape ──────────────────────────────────────────────────────────────────────
SELECT has_type('pgfc_govern', 'governor_health_state', 'the health-state enum exists');
SELECT has_table('pgfc_govern', 'governor_state', 'governor_state singleton table exists');
SELECT has_table('pgfc_govern', 'state_transitions', 'state_transitions audit table exists');
SELECT has_function('pgfc_govern', 'evaluate_health', 'evaluate_health() exists');
SELECT has_column('pgfc_govern', 'governor_state', 'state', 'governor_state has state');
SELECT has_column('pgfc_govern', 'governor_state', 'since', 'governor_state has since');
SELECT has_column('pgfc_govern', 'governor_state', 'reason', 'governor_state has reason');
SELECT has_column('pgfc_govern', 'state_transitions', 'from_state', 'state_transitions has from_state');
SELECT has_column('pgfc_govern', 'state_transitions', 'to_state', 'state_transitions has to_state');
SELECT has_column('pgfc_govern', 'state_transitions', 'triggering_condition',
                  'state_transitions has triggering_condition');

-- ── singleton ───────────────────────────────────────────────────────────────────
SELECT is((SELECT count(*) FROM pgfc_govern.governor_state), 1::bigint,
          'governor_state is seeded with exactly one row');
SELECT throws_ok($$ INSERT INTO pgfc_govern.governor_state (singleton, state)
                    VALUES (true, 'normal') $$,
                 NULL, NULL, 'governor_state rejects a second row (enforced singleton)');

-- ── boot: absence of data is NOT ill health ───────────────────────────────────────
SELECT is(pgfc_govern.evaluate_health()::text, 'normal',
          'a fresh governor (no snapshots, no actions) evaluates to normal');
SELECT is((SELECT state::text FROM pgfc_govern.governor_state), 'normal',
          'governor_state stays normal after a clean evaluation');
SELECT is((SELECT count(*) FROM pgfc_govern.state_transitions), 0::bigint,
          'no transition is recorded when the state does not change (normal→normal)');

-- ── failed actions drive degraded, then diagnostic ────────────────────────────────
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, status, applied_at)
SELECT 1, g, 'a', '0.05', 'failed', now() FROM generate_series(1, 4) g;
SELECT is(pgfc_govern.evaluate_health()::text, 'degraded',
          'a handful of failed actions in the last hour → degraded');
SELECT is((SELECT count(*) FROM pgfc_govern.state_transitions
           WHERE from_state = 'normal' AND to_state = 'degraded'), 1::bigint,
          'the normal→degraded transition is recorded');
SELECT isnt((SELECT reason FROM pgfc_govern.governor_state), NULL,
            'governor_state carries a human-readable reason for the current state');

INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, status, applied_at)
SELECT 2, g, 'a', '0.05', 'failed', now() FROM generate_series(1, 7) g;   -- 11 total
SELECT is(pgfc_govern.evaluate_health()::text, 'diagnostic',
          'many failed actions in the last hour → diagnostic');
SELECT ok((SELECT EXISTS (SELECT 1 FROM pgfc_govern.state_transitions
                          WHERE from_state = 'degraded' AND to_state = 'diagnostic')),
          'the degraded→diagnostic escalation is recorded');

-- ── recovery ──────────────────────────────────────────────────────────────────────
DELETE FROM pgfc_govern.action_history;
SELECT is(pgfc_govern.evaluate_health()::text, 'normal',
          'the governor recovers to normal once the failures are gone');

-- ── stale observation drives degraded then emergency ──────────────────────────────
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at)
VALUES (170000, now() - interval '700 seconds');
SELECT is(pgfc_govern.evaluate_health()::text, 'degraded',
          'observation lag past the degraded bound → degraded');
DELETE FROM pgfc_observe.snapshots;
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at)
VALUES (170000, now() - interval '2 hours');
SELECT is(pgfc_govern.evaluate_health()::text, 'emergency',
          'observation lag past the emergency bound (flying blind) → emergency');
DELETE FROM pgfc_observe.snapshots;

-- ── storage pressure ──────────────────────────────────────────────────────────────
UPDATE pgfc_govern.storage_config SET budget_bytes = 0;   -- any footprint now exceeds the cap
SELECT is(pgfc_govern.evaluate_health()::text, 'degraded',
          'governor over its own storage budget → degraded');

-- ── worst signal wins ──────────────────────────────────────────────────────────────
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, status, applied_at)
SELECT 3, g, 'a', '0.05', 'failed', now() FROM generate_series(1, 11) g;   -- diagnostic
SELECT is(pgfc_govern.evaluate_health()::text, 'diagnostic',
          'the worst signal wins: diagnostic (failures) over degraded (storage)');
UPDATE pgfc_govern.storage_config SET budget_bytes = NULL;

SELECT * FROM finish();
ROLLBACK;
