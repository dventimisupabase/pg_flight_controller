-- Fortification FMEA-006 (#83): the ownership guard at the ACTUATION point. COR-001 made
-- plan() recognize the governor's own prior actuation, but plan() runs against a snapshot a
-- cycle earlier; a human ALTER landing between plan() and apply() would still be overwritten,
-- because apply()'s no-op gate only matches an EXACTLY-equal human value. apply() now mirrors
-- COR-001 against the LIVE reloption: it refuses (silently) to overwrite an explicit value it
-- does not own, unless manage_user_owned. Tested with the direct-apply recipe (plan one
-- advisory cycle, then mutate the live catalog and call apply() directly).
BEGIN;
SELECT plan(10);

-- generous budgets so nothing is refused by Invariant-4 (we are isolating the ownership gate)
UPDATE pgfc_govern.policy
   SET global_max_changes_per_cycle = 50, daily_mutation_budget = 50 WHERE policy_name = 'default';

-- three real relations, each carrying the governor's own prior value (0.1) at observe time;
-- plus new_t, which has NO reloption and NO actuator_state row (a first-touch relation).
CREATE TABLE public.own_t  (id int);   ALTER TABLE public.own_t  SET (autovacuum_vacuum_scale_factor = 0.1);
CREATE TABLE public.race_t (id int);   ALTER TABLE public.race_t SET (autovacuum_vacuum_scale_factor = 0.1);
CREATE TABLE public.mgr_t  (id int);   ALTER TABLE public.mgr_t  SET (autovacuum_vacuum_scale_factor = 0.1);
CREATE TABLE public.new_t  (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue'
 WHERE relid IN ('public.own_t'::regclass, 'public.race_t'::regclass,
                 'public.mgr_t'::regclass, 'public.new_t'::regclass);

-- the governor set 0.1 last cycle and it is still 0.1 at plan time (governor-owned), so
-- plan() (COR-001) classifies an 'adjust' rather than suppressing — exactly the precondition
-- for the within-cycle race.
INSERT INTO pgfc_govern.actuator_state (relid, actuator, current_value, baseline_explicit, baseline_value)
SELECT relid, 'autovacuum_vacuum_scale_factor', '0.1', false, NULL
  FROM (VALUES ('public.own_t'::regclass), ('public.race_t'::regclass), ('public.mgr_t'::regclass)) v(relid);

SELECT pgfc_govern.control_tick();   -- advisory: plans an 'adjust' for each, applies nothing
CREATE TEMP TABLE _tk AS SELECT max(tick_id) AS id FROM pgfc_govern.tick_log;

SELECT is((SELECT decision FROM pgfc_govern.decision_log
            WHERE relid = 'public.race_t'::regclass ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'setup: the governor-owned relation planned an adjust (COR-001 did not suppress)');

-- ── A. within-cycle race: a human ALTERs the value AFTER plan(), differing from the proposal ──
-- plan() saw 0.1 (governor-owned) and proposed an adjust; now a human sets 0.3 live. apply()
-- must NOT overwrite it under the default manage_user_owned = false.
ALTER TABLE public.race_t SET (autovacuum_vacuum_scale_factor = 0.3);
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.race_t'::regclass),
          'within-cycle race: apply() refuses to overwrite the post-plan human value');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.race_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          '0.3', 'within-cycle race: the human value (0.3) is preserved, not clobbered');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = 'public.race_t'::regclass AND status = 'failed'),
          0::bigint, 'within-cycle race: the refusal is silent (no failed action_history row)');

-- ── C. continuous control: the governor still owns the live value (no human change) ──────────
-- own_t's live value is still the governor's 0.1 (== actuator_state.current_value), so apply()
-- must keep controlling it — the actuation-point guard does not break COR-001's continuous loop.
SELECT ok(pgfc_govern.apply((SELECT id FROM _tk), 'public.own_t'::regclass),
          'continuous control: the governor actuates a relation it still owns (not over-refused)');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.own_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          (SELECT proposed_value FROM pgfc_govern.decision_log
            WHERE relid = 'public.own_t'::regclass ORDER BY decision_id DESC LIMIT 1),
          'continuous control: the governor''s proposed value was applied');

-- ── B. manage_user_owned = true: the operator opted in, so the governor takes ownership ──────
ALTER TABLE public.mgr_t SET (autovacuum_vacuum_scale_factor = 0.3);   -- a human value, as in A
UPDATE pgfc_govern.policy SET manage_user_owned = true WHERE policy_name = 'default';
SELECT ok(pgfc_govern.apply((SELECT id FROM _tk), 'public.mgr_t'::regclass),
          'manage_user_owned=true: the governor overwrites the user value (opt-in honored)');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.mgr_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          (SELECT proposed_value FROM pgfc_govern.decision_log
            WHERE relid = 'public.mgr_t'::regclass ORDER BY decision_id DESC LIMIT 1),
          'manage_user_owned=true: the proposed value replaced the user value');

-- ── no actuator_state row (first-touch relation) + a human value mid-window ──────────────
-- new_t was planned as a first touch (no reloption, no governor history); a human then grabs
-- it before apply(). With no actuator_state row the governor cannot claim ownership, so it
-- must refuse under manage_user_owned = false — pinning the v_have_state = false branch (where
-- v_base_explicit is NULL, and SQL three-valued logic still resolves the gate to "refuse").
UPDATE pgfc_govern.policy SET manage_user_owned = false WHERE policy_name = 'default';
ALTER TABLE public.new_t SET (autovacuum_vacuum_scale_factor = 0.3);
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.new_t'::regclass),
          'first-touch race: a human value on a relation with no governor history is refused');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.new_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          '0.3', 'first-touch race: the human value is preserved');

SELECT * FROM finish();
ROLLBACK;
