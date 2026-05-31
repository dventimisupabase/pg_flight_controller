-- Phase 1.7 F1: governor_metrics — the read-only self-monitoring substrate the
-- F2 health-state evaluator will read. The defining contract is that it ALWAYS
-- returns exactly one row (it has no driving FROM): counts COALESCE to 0, and
-- freshness signals are NULL when nothing has been observed/ticked yet — so the
-- view never vanishes precisely when the governor is least healthy.
BEGIN;
SELECT plan(23);

-- ── shape ────────────────────────────────────────────────────────────────────
SELECT has_view('pgfc_govern', 'governor_metrics', 'governor_metrics view exists');
SELECT has_column('pgfc_govern', 'governor_metrics', 'applied_actions_last_hour',
                  'governor_metrics has applied_actions_last_hour');
SELECT has_column('pgfc_govern', 'governor_metrics', 'failed_actions_last_hour',
                  'governor_metrics has failed_actions_last_hour');
SELECT has_column('pgfc_govern', 'governor_metrics', 'lock_timeouts_last_hour',
                  'governor_metrics has lock_timeouts_last_hour');
SELECT has_column('pgfc_govern', 'governor_metrics', 'observation_lag',
                  'governor_metrics has observation_lag');
SELECT has_column('pgfc_govern', 'governor_metrics', 'last_tick_duration',
                  'governor_metrics has last_tick_duration');
SELECT has_column('pgfc_govern', 'governor_metrics', 'storage_bytes',
                  'governor_metrics has storage_bytes');
SELECT has_column('pgfc_govern', 'governor_metrics', 'over_budget',
                  'governor_metrics has over_budget');
SELECT has_column('pgfc_govern', 'governor_metrics', 'oldest_action_at',
                  'governor_metrics has oldest_action_at');

-- ── the one-row contract on empty audit tables ────────────────────────────────
SELECT is((SELECT count(*) FROM pgfc_govern.governor_metrics),
          1::bigint, 'governor_metrics returns exactly one row even with no actions');
SELECT is((SELECT applied_actions_last_hour FROM pgfc_govern.governor_metrics),
          0::bigint, 'applied count is 0 (not NULL) when no actions exist');
SELECT is((SELECT failed_actions_last_hour FROM pgfc_govern.governor_metrics),
          0::bigint, 'failed count is 0 (not NULL) when no actions exist');
SELECT is((SELECT lock_timeouts_last_hour FROM pgfc_govern.governor_metrics),
          0::bigint, 'lock-timeout count is 0 (not NULL) when no actions exist');
SELECT ok((SELECT observation_lag IS NULL FROM pgfc_govern.governor_metrics),
          'observation_lag is NULL when nothing has been observed yet');
SELECT ok((SELECT last_tick_duration IS NULL FROM pgfc_govern.governor_metrics),
          'last_tick_duration is NULL when nothing has ticked yet');
SELECT ok((SELECT oldest_action_at IS NULL FROM pgfc_govern.governor_metrics),
          'oldest_action_at is NULL when there are no audit rows');

-- ── actuation counts over the window ──────────────────────────────────────────
-- two applied (recent), one plain failure (recent), one lock-timeout (recent),
-- and one applied long ago that must fall outside the 1-hour window.
INSERT INTO pgfc_govern.action_history
  (batch_id, relid, actuator, new_value, status, applied_at)
VALUES (1, 100, 'a', '0.05', 'applied', now()),
       (1, 101, 'a', '0.05', 'applied', now()),
       (1, 102, 'a', '0.05', 'applied', now() - interval '200 days');
INSERT INTO pgfc_govern.action_history
  (batch_id, relid, actuator, new_value, status, failure_reason, lock_wait_outcome, applied_at)
VALUES (2, 103, 'a', '0.05', 'failed', 'insufficient_privilege', NULL, now()),
       (2, 104, 'a', '0.05', 'failed', 'lock_timeout', 'timeout', now());

SELECT is((SELECT applied_actions_last_hour FROM pgfc_govern.governor_metrics),
          2::bigint, 'applied_actions_last_hour counts only the two recent applied actions');
SELECT is((SELECT applied_actions_last_day FROM pgfc_govern.governor_metrics),
          2::bigint, 'applied_actions_last_day still excludes the 200-day-old action');
SELECT is((SELECT failed_actions_last_hour FROM pgfc_govern.governor_metrics),
          2::bigint, 'failed_actions_last_hour counts both recent failures');
SELECT is((SELECT lock_timeouts_last_hour FROM pgfc_govern.governor_metrics),
          1::bigint, 'lock_timeouts_last_hour counts only the lock_timeout failure');

-- retention backlog: oldest retained mutation audit row (the 200-day-old action).
SELECT ok((SELECT now() - oldest_action_at BETWEEN interval '199 days' AND interval '201 days'
           FROM pgfc_govern.governor_metrics),
          'oldest_action_at is the timestamp of the oldest retained action row');

-- ── observation freshness + loop duration ─────────────────────────────────────
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at)
VALUES (170000, now() - interval '5 minutes');
SELECT ok((SELECT observation_lag BETWEEN interval '4 minutes' AND interval '6 minutes'
           FROM pgfc_govern.governor_metrics),
          'observation_lag reflects the age of the newest snapshot');

INSERT INTO pgfc_govern.tick_log (snapshot_id, started_at, finished_at)
VALUES (1, now() - interval '2 seconds', now());
SELECT ok((SELECT last_tick_duration BETWEEN interval '1 second' AND interval '3 seconds'
           FROM pgfc_govern.governor_metrics),
          'last_tick_duration is finished_at - started_at of the latest tick');

SELECT * FROM finish();
ROLLBACK;
