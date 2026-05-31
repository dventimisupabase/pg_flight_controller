-- Phase 1.7 F4: the apply() authority gate + the Invariant-4 mutation budget. This is the
-- active-control gate — the safety net that must exist before the governor acts live. Two
-- load-bearing properties:
--   1. Authority gate. apply() consults the governor health state computed by
--      evaluate_health() and refuses ordinary actuation when the governor is not healthy
--      (diagnostic / emergency / disabled). degraded still PERMITS actuation (it is
--      "limited", one breaker-step from suspension, not suspended). A withheld actuation
--      returns false SILENTLY — it must never be recorded as status='failed', or it would
--      feed the failed-action breaker and create a self-amplifying suspension loop.
--   2. Invariant 4 — never exceed mutation budgets. Three tiers, all enforced at the single
--      apply() chokepoint: per-relation min_interval, per-cycle cluster cap, per-day cluster
--      cap. Values come from the active policy (registry default as fallback), so an
--      operator who tightens the budget is honored at once.
-- Tested per the design's recipe: inject action_history + drive the health state, then call
-- apply() directly and assert refusal / capping. Refusing to TIGHTEN never violates
-- Invariant 3 (the freeze floor in plan(), which guarantees we never propose a looser
-- setting under freeze stress, is banked).
BEGIN;
SELECT plan(19);

-- ── setup: two relations the loop will plan an 'adjust' for ──────────────────────
CREATE TABLE public.gate_a (id int);
CREATE TABLE public.gate_b (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue'
 WHERE relid IN ('public.gate_a'::regclass, 'public.gate_b'::regclass);

-- Plan one cycle (advisory: control_tick plans but never applies); capture the tick id so
-- the tests can drive apply() directly against its decisions.
SELECT pgfc_govern.control_tick();
CREATE TEMP TABLE _tk AS SELECT max(tick_id) AS id FROM pgfc_govern.tick_log;

SELECT is((SELECT count(*) FROM pgfc_govern.decision_log
            WHERE tick_id = (SELECT id FROM _tk)
              AND relid IN ('public.gate_a'::regclass, 'public.gate_b'::regclass)
              AND decision = 'adjust'),
          2::bigint, 'both relations planned an adjust in the captured tick');

-- ── normal state: actuation is permitted (the happy path the gate must not block) ──
SELECT is((SELECT state::text FROM pgfc_govern.governor_state), 'normal',
          'the governor starts in normal health');
SELECT ok(pgfc_govern.apply((SELECT id FROM _tk), 'public.gate_a'::regclass),
          'normal state: apply() actuates gate_a');
SELECT isnt(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.gate_a'::regclass),
              'autovacuum_vacuum_scale_factor'),
            NULL, 'gate_a scale factor was actually set');

-- ── Invariant 4: per-relation min_interval rate-limits a single relation ───────────
-- A very recent mutation on gate_b blocks another within min_interval (default 1h).
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, status, applied_at)
VALUES (999, 'public.gate_b'::regclass, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now());
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.gate_b'::regclass),
          'per-relation min_interval: a recent mutation blocks another change to gate_b');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.gate_b'::regclass),
              'autovacuum_vacuum_scale_factor'),
          NULL, 'gate_b reloption left untouched while rate-limited');
DELETE FROM pgfc_govern.action_history WHERE batch_id = 999;   -- release the rate limit

-- ── authority gate: diagnostic / disabled withhold ordinary actuation ──────────────
SELECT pgfc_govern.suspend_actuation('investigating');            -- → diagnostic
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.gate_b'::regclass),
          'diagnostic state: the authority gate refuses actuation');
SELECT pgfc_govern.force_state('emergency', 'flying blind');      -- → emergency
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.gate_b'::regclass),
          'emergency state: the authority gate refuses actuation');
SELECT pgfc_govern.disable('maintenance');                        -- → disabled
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.gate_b'::regclass),
          'disabled state: the authority gate refuses actuation');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.gate_b'::regclass),
              'autovacuum_vacuum_scale_factor'),
          NULL, 'gate_b never actuated while authority was withheld');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = 'public.gate_b'::regclass AND status = 'failed'),
          0::bigint,
          'a withheld actuation is NOT recorded as failed (no self-amplifying breaker feedback)');

-- releasing the hold returns to automatic control, and gate_b can actuate
SELECT pgfc_govern.clear_forced_state();
SELECT ok(pgfc_govern.apply((SELECT id FROM _tk), 'public.gate_b'::regclass),
          'after clearing the operator hold, gate_b actuates');

-- ── Invariant 4: per-cycle cluster cap bounds one control cycle's blast radius ──────
CREATE TABLE public.gate_c (id int);
CREATE TABLE public.gate_d (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue'
 WHERE relid IN ('public.gate_c'::regclass, 'public.gate_d'::regclass);
UPDATE pgfc_govern.policy SET global_max_changes_per_cycle = 1 WHERE policy_name = 'default';
SELECT pgfc_govern.control_tick();                                -- new tick plans c, d
UPDATE _tk SET id = (SELECT max(tick_id) FROM pgfc_govern.tick_log);
SELECT pgfc_govern.clear_forced_state();                          -- ensure normal authority
SELECT ok(pgfc_govern.apply((SELECT id FROM _tk), 'public.gate_c'::regclass),
          'per-cycle cap: the first change in the cycle is allowed');
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.gate_d'::regclass),
          'per-cycle cap (=1): a second change in the same cycle is refused');

-- ── Invariant 4: per-day cluster cap bounds sustained mutation pressure ────────────
CREATE TABLE public.gate_e (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.gate_e'::regclass;
UPDATE pgfc_govern.policy
   SET global_max_changes_per_cycle = 50, daily_mutation_budget = 2 WHERE policy_name = 'default';
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, status, applied_at)
SELECT 888, 0::oid, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now()
FROM generate_series(1, 2);                                       -- spend the day's budget
SELECT pgfc_govern.control_tick();                                -- new tick plans gate_e
UPDATE _tk SET id = (SELECT max(tick_id) FROM pgfc_govern.tick_log);
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.gate_e'::regclass),
          'per-day budget reached: apply() refuses further mutations');

-- ── the mutation-budget circuit breaker (evaluate_health), degraded — never diagnostic ──
SELECT pgfc_govern.clear_forced_state();                          -- no operator floor
SELECT is(pgfc_govern.evaluate_health()::text, 'degraded',
          'spending the daily budget trips the breaker to degraded (a signal, not suspension)');
SELECT ok((SELECT reason LIKE '%mutation budget%' FROM pgfc_govern.governor_state),
          'governor_state reason names the mutation-budget breaker');

-- ── degraded still PERMITS actuation (it is "limited", not suspended) ──────────────
-- Raise the cap so the budget no longer refuses, but do NOT re-evaluate: the state stays
-- degraded, proving the authority gate lets degraded act (only diagnostic+ withholds).
CREATE TABLE public.gate_f (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.gate_f'::regclass;
SELECT pgfc_govern.control_tick();                                -- evaluate_health → degraded
UPDATE _tk SET id = (SELECT max(tick_id) FROM pgfc_govern.tick_log);
UPDATE pgfc_govern.policy SET daily_mutation_budget = 10000 WHERE policy_name = 'default';
SELECT is((SELECT state::text FROM pgfc_govern.governor_state), 'degraded',
          'the governor is in degraded health (budget breaker tripped)');
SELECT ok(pgfc_govern.apply((SELECT id FROM _tk), 'public.gate_f'::regclass),
          'degraded state still PERMITS actuation — limited, not suspended');

SELECT * FROM finish();
ROLLBACK;
