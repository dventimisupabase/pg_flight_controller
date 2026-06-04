-- Fortification Phase 3 (test hardening): the apply() relation-vanished branch. If a
-- relation is dropped between plan() and apply(), the pg_class lookup returns NULL relname
-- and apply() returns false silently — no action_history row, no error. This closes the
-- last cheaply-reproducible unmapped branch in the apply() path (the coverage map in
-- 03-test-hardening.md).
BEGIN;
SELECT plan(5);

-- ── setup: a relation with a planned 'adjust' ────────────────────────────────────────
CREATE TABLE public.vanish_t (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.vanish_t'::regclass;

UPDATE pgfc_govern.policy SET advisory_only = false WHERE policy_name = 'default';
SELECT pgfc_govern.control_tick();
CREATE TEMP TABLE _tk AS SELECT max(tick_id) AS id FROM pgfc_govern.tick_log;
CREATE TEMP TABLE _oid AS SELECT 'public.vanish_t'::regclass::oid AS relid;

SELECT is((SELECT decision FROM pgfc_govern.decision_log
            WHERE tick_id = (SELECT id FROM _tk)
              AND relid = (SELECT relid FROM _oid)
              AND decision = 'adjust'
            ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'setup: vanish_t has a planned adjust');

-- the first control_tick already applied it (advisory_only = false); clear the evidence
-- so the second apply() call below is unambiguous.
DELETE FROM pgfc_govern.action_history WHERE relid = (SELECT relid FROM _oid);
-- reset the live reloption so the no-op gate does not fire
ALTER TABLE public.vanish_t RESET (autovacuum_vacuum_scale_factor);
DELETE FROM pgfc_govern.actuator_state WHERE relid = (SELECT relid FROM _oid);

-- ── drop the table: the relation vanishes between plan() and apply() ──────────────────
DROP TABLE public.vanish_t;

-- ── apply() on the vanished relation: silent false ────────────────────────────────────
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), (SELECT relid FROM _oid)),
          'apply() returns false for a vanished relation');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = (SELECT relid FROM _oid)),
          0::bigint, 'no action_history row for the vanished relation (silent refusal)');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = (SELECT relid FROM _oid) AND status = 'failed'),
          0::bigint, 'no failed row — the refusal is silent, not recorded');
SELECT lives_ok(
    format('SELECT pgfc_govern.apply(%s, %s::oid)', (SELECT id FROM _tk), (SELECT relid FROM _oid)),
    'apply() does not throw on a vanished relation');

SELECT * FROM finish();
ROLLBACK;
