-- Orchestrators + views + the Phase 1 guarantee: advisory_only never actuates,
-- and apply() really does actuate once advisory_only is turned off.
BEGIN;
SELECT plan(14);

SELECT has_view('pgfc_govern', 'governor_status', 'governor_status view exists');
SELECT has_view('pgfc_govern', 'catalog_health', 'catalog_health view exists');
SELECT has_view('pgfc_govern', 'active_diagnostics', 'active_diagnostics view exists');

-- A real table the loop will observe and (later) actuate.
CREATE TABLE public.loop_t (id int);

-- Fast loop: observe + classify + estimate.
SELECT isnt(pgfc_govern.observe_tick(), NULL, 'observe_tick() returns a snapshot id');
SELECT is((SELECT count(*) FROM pgfc_govern.relation_estimate
            WHERE relid = 'public.loop_t'::regclass),
          1::bigint, 'estimate() produced a row for loop_t');

-- Force a non-trivial target: classify loop_t as queue (f* = 0.05 vs default 0.20).
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.loop_t'::regclass;

-- Control loop, advisory (default): plans, never applies.
SELECT isnt(pgfc_govern.control_tick(), NULL, 'control_tick() returns a tick id');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history), 0::bigint,
          'advisory_only: nothing is ever applied (no action_history)');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.loop_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          NULL, 'advisory_only: loop_t reloptions left untouched');
SELECT is((SELECT decision FROM pgfc_govern.decision_log
            WHERE relid = 'public.loop_t'::regclass ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'plan still proposed an adjust (only apply is gated)');

-- control_tick() self-checks its health first (Phase 1.7 F2): evaluate_health() ran.
SELECT isnt((SELECT evaluated_at FROM pgfc_govern.governor_state), NULL,
            'control_tick() evaluated the governor health state (evaluated_at set)');

-- Flip to active control and run again: now apply() actuates.
UPDATE pgfc_govern.policy SET advisory_only = false WHERE policy_name = 'default';
SELECT pgfc_govern.control_tick();

-- apply() must set exactly what plan() proposed (a valid SF_GRID value).
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.loop_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          (SELECT proposed_value FROM pgfc_govern.decision_log
            WHERE relid = 'public.loop_t'::regclass AND decision = 'adjust'
            ORDER BY decision_id DESC LIMIT 1),
          'active control: loop_t scale factor set to the proposed grid value');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = 'public.loop_t'::regclass AND status = 'applied'),
          1::bigint, 'an applied action_history row was recorded');
SELECT is((SELECT baseline_explicit FROM pgfc_govern.actuator_state
            WHERE relid = 'public.loop_t'::regclass
              AND actuator = 'autovacuum_vacuum_scale_factor'),
          false, 'rollback baseline captured: loop_t had no explicit reloption (=> RESET on revert)');

SELECT lives_ok($$ SELECT * FROM pgfc_govern.governor_status $$, 'governor_status resolves');

SELECT * FROM finish();
ROLLBACK;
