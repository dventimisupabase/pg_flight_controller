-- Phase 2 FMEA-003: control-loop errors are visible to the health model.
--
-- A wedged control_tick() leaves no fresh, fully-completed tick_log row — a hard error
-- rolls the row back, and finished_at is set only after verify() succeeds, so
-- finished_at IS NOT NULL faithfully means "this whole cycle completed". control_loop_lag
-- (age of the last successfully-finished control cycle) is therefore the control-loop
-- heartbeat. evaluate_health() escalates on it (degraded -> emergency) exactly like
-- observation_lag, and — the load-bearing half — observe_tick() now refreshes health too,
-- so a wedged control loop is caught by the INDEPENDENT fast loop rather than by itself
-- (control_tick cannot evaluate its own health: evaluate_health() runs INSIDE it). The two
-- loops are mutual watchdogs: control_tick watches observe (observation_lag), observe
-- watches control (control_loop_lag).
--
-- Pre-fix this file is red: evaluate_health() had no control-lag signal and observe_tick()
-- never evaluated health, so a stalled control loop with perfectly fresh observation stayed
-- 'normal' — the silent cessation FMEA-003 names.
BEGIN;
SELECT plan(13);

-- ── shape ──────────────────────────────────────────────────────────────────────
SELECT has_column('pgfc_govern', 'governor_metrics', 'control_loop_lag',
                  'governor_metrics exposes control_loop_lag (the control-loop heartbeat)');
SELECT has_column('pgfc_govern', 'governor_metrics', 'last_successful_tick_at',
                  'governor_metrics exposes last_successful_tick_at');

-- ── boot: no completed cycle is NOT ill health ─────────────────────────────────────
-- (mirrors observation_lag's NULL-at-boot contract: absence of a heartbeat is not failure)
SELECT ok((SELECT control_loop_lag IS NULL FROM pgfc_govern.governor_metrics),
          'control_loop_lag is NULL when no control cycle has completed yet (boot)');
SELECT is(pgfc_govern.evaluate_health()::text, 'normal',
          'a governor that has never completed a control cycle evaluates to normal (boot)');

-- ── a normal between-cycle gap must NOT trip the breaker ───────────────────────────
-- control_tick runs every control_cadence (default 5 min); at evaluation the last success
-- is ~1 cadence old, so control_loop_lag sawtooths 0 -> ~5 min -> 0. The degraded bound
-- sits well above that so the steady-state gap never flaps the state.
INSERT INTO pgfc_govern.tick_log (snapshot_id, started_at, finished_at)
VALUES (NULL, now() - interval '5 minutes' - interval '2 seconds', now() - interval '5 minutes');
SELECT is(pgfc_govern.evaluate_health()::text, 'normal',
          'a control cycle that completed one cadence ago (5 min) keeps the governor normal');
DELETE FROM pgfc_govern.tick_log;

-- ── a stalling control loop drives degraded, then emergency ────────────────────────
INSERT INTO pgfc_govern.tick_log (snapshot_id, started_at, finished_at)
VALUES (NULL, now() - interval '25 minutes' - interval '2 seconds', now() - interval '25 minutes');
SELECT is(pgfc_govern.evaluate_health()::text, 'degraded',
          'no successful control cycle for 25 min (past the degraded bound) -> degraded');
SELECT ok((SELECT reason ILIKE '%control loop%' FROM pgfc_govern.governor_state),
          'governor_state explains the degraded state as a stalled control loop');

-- the decision failure category lights up from the heartbeat ALONE — no tick_log.error row
-- exists, which is exactly the production state FMEA-003 says was previously undetectable.
SELECT ok((SELECT condition_present FROM pgfc_govern.failure_taxonomy WHERE failure_class = 'decision'),
          'a stalled control loop lights the decision category with no error row written');

DELETE FROM pgfc_govern.tick_log;
INSERT INTO pgfc_govern.tick_log (snapshot_id, started_at, finished_at)
VALUES (NULL, now() - interval '65 minutes' - interval '2 seconds', now() - interval '65 minutes');
SELECT is(pgfc_govern.evaluate_health()::text, 'emergency',
          'no successful control cycle for 65 min (past the emergency bound) -> emergency');

-- ── the in-band error column remains a live hook (non-breaking with 18_load_shedding) ──
-- We deliberately do NOT record tick_log.error in-band (that would require swallowing the
-- error, blinding pg_cron's external retry/alerting). The column stays a latent hook for any
-- out-of-band recorder, and the OR keeps it lighting the category if a row ever carries one.
DELETE FROM pgfc_govern.tick_log;
INSERT INTO pgfc_govern.tick_log (snapshot_id, started_at, error)
VALUES (NULL, now(), 'boom');
SELECT ok((SELECT condition_present FROM pgfc_govern.failure_taxonomy WHERE failure_class = 'decision'),
          'a recorded tick error still lights the decision category (latent hook preserved)');

-- ── a fresh, completed cycle clears the category ───────────────────────────────────
DELETE FROM pgfc_govern.tick_log;
INSERT INTO pgfc_govern.tick_log (snapshot_id, started_at, finished_at)
VALUES (NULL, now() - interval '5 minutes' - interval '2 seconds', now() - interval '5 minutes');
SELECT ok((SELECT NOT condition_present FROM pgfc_govern.failure_taxonomy WHERE failure_class = 'decision'),
          'a fresh control cycle leaves the decision category clear');

-- ── THE FMEA-003 closer: the INDEPENDENT loop escalates the stalled control loop ───────
-- Stage a stalled control loop (last success 25 min ago) and force the state back to normal,
-- so the only thing that can re-escalate is observe_tick()'s own health refresh. Observation
-- is made fresh by observe_tick() itself — so the escalation can only come from
-- control_loop_lag, never observation_lag. Pre-fix: observe_tick never evaluated health and
-- evaluate_health had no control-lag signal, so the governor stayed 'normal' here.
DELETE FROM pgfc_govern.tick_log;
INSERT INTO pgfc_govern.tick_log (snapshot_id, started_at, finished_at)
VALUES (NULL, now() - interval '25 minutes' - interval '2 seconds', now() - interval '25 minutes');
UPDATE pgfc_govern.governor_state SET state = 'normal', reason = 'reset for test';
CREATE TABLE public.fmea003_t (id int);   -- give observe() a relation to sample
SELECT pgfc_govern.observe_tick();
SELECT is((SELECT state::text FROM pgfc_govern.governor_state), 'degraded',
          'observe_tick() escalated the governor to degraded from the stalled control loop (mutual watchdog)');
SELECT ok((SELECT observation_lag < interval '1 minute' FROM pgfc_govern.governor_metrics),
          'observation is fresh — the escalation came from control_loop_lag, not observation_lag (the FMEA-003 scenario)');

SELECT * FROM finish();
ROLLBACK;
