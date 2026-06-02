-- Fortification SEC-002 (#69): defense-in-depth on the value apply() splices into the
-- ALTER TABLE. v_prop is governor-computed (snap_sf()'s bounded grid output, written as
-- decision_log.proposed_value), but decision_log is a writable table — a hand-inserted or
-- corrupted 'adjust' row could carry non-numeric or out-of-range text that format('%s')
-- would interpolate verbatim into the DDL (a reloption injection). apply() now parses
-- proposed_value to a number and range-checks it against [sf_min, sf_max], refusing closed
-- — silently, exactly like the other pre-mutation gates (the decision_log row is the audit
-- trail) — otherwise. Tested per the design's recipe: plan one advisory cycle, overwrite
-- the planned proposal with a crafted payload, then call apply() directly.
BEGIN;
SELECT plan(11);

-- setup: a relation the loop plans an 'adjust' for, governor in normal health.
CREATE TABLE public.val_t (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.val_t'::regclass;
SELECT pgfc_govern.control_tick();   -- advisory: plans an adjust, never applies
CREATE TEMP TABLE _tk AS SELECT max(tick_id) AS id FROM pgfc_govern.tick_log;

SELECT is((SELECT decision FROM pgfc_govern.decision_log
            WHERE relid = 'public.val_t'::regclass ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'setup: val_t planned an adjust');

-- ── reloption injection ────────────────────────────────────────────────────────────
-- A crafted proposed_value that is DDL-valid but smuggles a SECOND reloption. Pre-fix,
-- format('%s') splices it and apply() actually runs
--   ALTER TABLE public.val_t SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_enabled = false)
-- silently disabling autovacuum on the table. The fix must refuse it outright.
UPDATE pgfc_govern.decision_log SET proposed_value = '0.05, autovacuum_enabled = false'
 WHERE decision_id = (SELECT max(decision_id) FROM pgfc_govern.decision_log
                       WHERE relid = 'public.val_t'::regclass);
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.val_t'::regclass),
          'injection: apply() refuses a reloption-injection proposed_value');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.val_t'::regclass),
              'autovacuum_enabled'),
          NULL, 'injection: the smuggled autovacuum_enabled reloption was NOT set');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.val_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          NULL, 'injection: nothing was applied to val_t at all');

-- ── non-numeric garbage ──────────────────────────────────────────────────────────────
UPDATE pgfc_govern.decision_log SET proposed_value = 'not_a_number'
 WHERE decision_id = (SELECT max(decision_id) FROM pgfc_govern.decision_log
                       WHERE relid = 'public.val_t'::regclass);
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.val_t'::regclass),
          'non-numeric proposed_value is refused (fails closed, no abort)');

-- ── numeric but out of the [sf_min, sf_max] safety band (sf_max default 0.50) ─────────
UPDATE pgfc_govern.decision_log SET proposed_value = '0.99'
 WHERE decision_id = (SELECT max(decision_id) FROM pgfc_govern.decision_log
                       WHERE relid = 'public.val_t'::regclass);
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.val_t'::regclass),
          'out-of-range numeric (> sf_max) is refused');

-- ── non-finite: NaN sorts above every real, so it fails the upper bound ───────────────
UPDATE pgfc_govern.decision_log SET proposed_value = 'NaN'
 WHERE decision_id = (SELECT max(decision_id) FROM pgfc_govern.decision_log
                       WHERE relid = 'public.val_t'::regclass);
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.val_t'::regclass),
          'non-finite (NaN) proposed_value is refused');

-- across every refused payload: nothing was actuated, and nothing was recorded as failed
-- (a silent refuse, like the authority/budget gates — must not feed the failed-action breaker).
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.val_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          NULL, 'val_t never actuated across all refused payloads');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = 'public.val_t'::regclass AND status = 'failed'),
          0::bigint, 'refusals are silent — no failed action_history row');

-- ── control: a legitimate, in-range grid value still applies (no false-positive) ──────
UPDATE pgfc_govern.decision_log SET proposed_value = '0.05'
 WHERE decision_id = (SELECT max(decision_id) FROM pgfc_govern.decision_log
                       WHERE relid = 'public.val_t'::regclass);
SELECT ok(pgfc_govern.apply((SELECT id FROM _tk), 'public.val_t'::regclass),
          'a legitimate in-range proposed_value still applies (the guard does not over-reject)');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.val_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          '0.05', 'the legitimate value was actually set');

SELECT * FROM finish();
ROLLBACK;
