-- Phase 1.7 F7: active-control activation. With the self-protection net built and proven
-- (F1–F6), the supported advisory_only = false path goes live. This suite exercises that
-- path end to end and closes the two hazards the project recorded against turning actuation
-- on (pgfc_govern/README.md "Recorded hazards"):
--   1. Loop-ordering contract. control_tick() must plan against the newest snapshot whose
--      estimate phase has completed — not merely the newest observed one — so it never
--      actuates fresh observations against the prior cycle's hidden state.
--   2. apply() stale-window downgrade. apply() re-reads the live reloption and is the
--      authoritative arbiter: it downgrades a planned adjust to a silent no-op when a human
--      changed the value to the proposal between observe and apply.
-- Plus: activation is now a supported state, not "experimental" — validate_parameters() says so.
BEGIN;
SELECT plan(10);

-- ── live path: the flag flip actuates under the full F1–F6 safety net ───────────────
CREATE TABLE public.act_t (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.act_t'::regclass;

-- Activate: the supported advisory_only = false path (operating.md "Enabling active control").
UPDATE pgfc_govern.policy SET advisory_only = false WHERE policy_name = 'default';
SELECT pgfc_govern.control_tick();

SELECT is((SELECT state::text FROM pgfc_govern.governor_state), 'normal',
          'activation under a healthy governor: the F4 authority gate permits actuation');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.act_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          (SELECT proposed_value FROM pgfc_govern.decision_log
            WHERE relid = 'public.act_t'::regclass AND decision = 'adjust'
            ORDER BY decision_id DESC LIMIT 1),
          'live: act_t scale factor set to the proposed grid value');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = 'public.act_t'::regclass AND status = 'applied'),
          1::bigint, 'live: an applied action_history row was recorded');

-- COR-001 (#66): the ownership guard end-to-end, through the real cross-cycle round-trip.
-- plan() reads reloptions from the observed snapshot, not the live catalog, so the bug
-- only bites a CYCLE LATER: actuate now (real ALTER TABLE above), then a fresh observe
-- captures the governor-set reloption into a new snapshot, and the next plan() would —
-- pre-fix — suppress the governor's OWN prior change as if a human had made it, degrading
-- active control to one touch per relation. The fix recognizes it via actuator_state
-- (current_value equals what the catalog now reads back), so the decision must NOT be
-- suppressed:user_owned. (cur == target after the actuation, so the right decision is hold.)
SELECT pgfc_govern.observe_tick();   -- new snapshot now captures act_t's governor-set reloption
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.act_t'::regclass;
SELECT pgfc_govern.plan(
    (SELECT max(tick_id) FROM pgfc_govern.tick_log),
    (SELECT max(snapshot_id) FROM pgfc_govern.relation_estimate));
SELECT isnt((SELECT decision FROM pgfc_govern.decision_log
              WHERE relid = 'public.act_t'::regclass ORDER BY decision_id DESC LIMIT 1),
            'suppressed:user_owned',
            'live round-trip: the governor does not suppress its OWN prior actuation (COR-001 #66)');

-- ── apply() stale-window downgrade (recorded hazard, earmarked "add it when apply() goes live") ──
-- plan() proposes an adjust; before apply runs, a human sets the live reloption to exactly
-- that proposal. apply() re-reads the catalog, finds nothing to do, and downgrades to a
-- silent no-op — not a failure (a failure would feed the circuit breaker).
CREATE TABLE public.stale_t (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.stale_t'::regclass;
SELECT pgfc_govern.control_tick();
CREATE TEMP TABLE _tk AS SELECT max(tick_id) AS id FROM pgfc_govern.tick_log;

SELECT is((SELECT decision FROM pgfc_govern.decision_log
            WHERE relid = 'public.stale_t'::regclass ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'stale-window: plan() did propose an adjust — so the no-op below is a genuine downgrade');

-- the human change between observe and apply: set the live value to the proposal
DO $$
DECLARE v text;
BEGIN
    SELECT proposed_value INTO v FROM pgfc_govern.decision_log
     WHERE relid = 'public.stale_t'::regclass AND decision = 'adjust'
     ORDER BY decision_id DESC LIMIT 1;
    EXECUTE format('ALTER TABLE public.stale_t SET (autovacuum_vacuum_scale_factor = %s)', v);
END $$;
-- clear the live-path action recorded above so the count below is unambiguous
DELETE FROM pgfc_govern.action_history WHERE relid = 'public.stale_t'::regclass;

SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.stale_t'::regclass),
          'stale-window: apply() downgrades adjust -> no-op when the live value already equals the proposal');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history WHERE relid = 'public.stale_t'::regclass),
          0::bigint, 'stale-window: the no-op is silent — no action_history row (applied or failed)');

-- ── loop-ordering contract (recorded hazard: "make the ordering explicit before actuation depends on it") ──
-- Simulate the race: a newer snapshot is OBSERVED (observe(), as a separate cron would)
-- but its estimate phase has not run. control_tick() must plan against the newest ESTIMATED
-- snapshot, never the newer observed one — actuating stale hidden state is exactly the hazard.
CREATE TABLE public.order_t (id int);
SELECT pgfc_govern.observe_tick();   -- snapshot N: observed AND estimated
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.order_t'::regclass;
SELECT pgfc_observe.observe();       -- snapshot N+1: observed only (no classify/estimate)

SELECT cmp_ok((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), '>',
              (SELECT max(snapshot_id) FROM pgfc_govern.relation_estimate),
              'setup: an observed-but-unestimated snapshot is ahead of the newest estimated one');
SELECT pgfc_govern.control_tick();
SELECT is((SELECT snapshot_id FROM pgfc_govern.tick_log ORDER BY tick_id DESC LIMIT 1),
          (SELECT max(snapshot_id) FROM pgfc_govern.relation_estimate),
          'loop-ordering: control_tick() planned against the newest ESTIMATED snapshot, not the newer observed one');

-- ── the path is supported, not experimental ────────────────────────────────────────
SELECT ok((SELECT message NOT LIKE '%experimental%'
             FROM pgfc_govern.validate_parameters() WHERE parameter = 'advisory_only'),
          'validate_parameters() no longer frames active control as experimental');

SELECT * FROM finish();
ROLLBACK;
