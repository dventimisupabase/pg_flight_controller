-- Fortification FMEA-005 (#82): per-relation error isolation in the apply loop. control_tick()
-- runs the whole cycle in one transaction; apply() catches only lock_not_available /
-- insufficient_privilege. Any OTHER uncaught error (a corrupted lock_timeout making set_config
-- throw; a future actuator's DDL error) used to abort the whole control_tick — rolling back
-- EVERY relation's change, deterministically every cycle and (per FMEA-003) invisibly. The apply
-- loop now wraps each apply() in a BEGIN … EXCEPTION WHEN others subtransaction: a poison
-- relation's error rolls back only that relation's attempt, is recorded as a failed (actuation)
-- action, and the loop continues — so one bad relation cannot deny actuation to all.
--
-- The poison is a per-relation DDL failure modeled with an event trigger that RAISEs at
-- ddl_command_end for ONE relation only (object_identity guard), exactly the "future actuator's
-- DDL error" the finding names. P0001 (RAISE's default SQLSTATE) is neither lock_not_available
-- nor insufficient_privilege, so apply()'s inner handler does not catch it.
BEGIN;
SELECT plan(8);

-- Generous Invariant-4 budgets so nothing is refused by the rate/blast-radius caps — we are
-- isolating the error-isolation behavior, not the budget gates.
UPDATE pgfc_govern.policy
   SET global_max_changes_per_cycle = 50, daily_mutation_budget = 50 WHERE policy_name = 'default';

-- Two real relations the loop will plan an 'adjust' for (queue class, no reloption => target
-- differs from current). poison_t's ALTER will throw; healthy_t's must still succeed.
CREATE TABLE public.poison_t  (id int);
CREATE TABLE public.healthy_t (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue'
 WHERE relid IN ('public.poison_t'::regclass, 'public.healthy_t'::regclass);

-- Active control: the apply loop only runs when not advisory_only.
UPDATE pgfc_govern.policy SET advisory_only = false WHERE policy_name = 'default';

-- The poison: a DDL failure scoped to ONE relation. Fires at ddl_command_end for every
-- ALTER TABLE but only RAISEs for public.poison_t (object_identity guard), so healthy_t's
-- actuation passes straight through. RAISE's default SQLSTATE is P0001 — uncaught by apply().
CREATE OR REPLACE FUNCTION public._pgfc_poison_t() RETURNS event_trigger
LANGUAGE plpgsql AS $et$
DECLARE r record;
BEGIN
    FOR r IN SELECT object_identity FROM pg_event_trigger_ddl_commands() LOOP
        IF r.object_identity = 'public.poison_t' THEN
            RAISE EXCEPTION 'simulated actuator DDL failure on %', r.object_identity;
        END IF;
    END LOOP;
END
$et$;
CREATE EVENT TRIGGER _pgfc_poison_t ON ddl_command_end
    WHEN TAG IN ('ALTER TABLE') EXECUTE FUNCTION public._pgfc_poison_t();

-- THE PROVER. Pre-fix, poison_t's P0001 propagates out of apply() and aborts the whole
-- control_tick (red). Post-fix, the per-relation subtransaction isolates it and the cycle
-- completes (green).
SELECT lives_ok($$ SELECT pgfc_govern.control_tick() $$,
                'control_tick() completes despite a poison relation (FMEA-005)');

-- Both relations entered the apply loop (plan proposed an 'adjust' for each).
SELECT is((SELECT decision FROM pgfc_govern.decision_log
            WHERE relid = 'public.poison_t'::regclass ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'precondition: poison_t was planned an adjust (it entered the loop)');
SELECT is((SELECT decision FROM pgfc_govern.decision_log
            WHERE relid = 'public.healthy_t'::regclass ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'precondition: healthy_t was planned an adjust (it entered the loop)');

-- Isolation payoff: the healthy relation actuated even though the poison relation threw.
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.healthy_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          (SELECT proposed_value FROM pgfc_govern.decision_log
            WHERE relid = 'public.healthy_t'::regclass AND decision = 'adjust'
            ORDER BY decision_id DESC LIMIT 1),
          'isolation: healthy_t was actuated to its proposed value despite the poison relation');
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = 'public.healthy_t'::regclass AND status = 'applied'),
          1::bigint, 'isolation: healthy_t recorded one applied action');

-- Visibility: the poison relation's failure is RECORDED (not the silent total denial of
-- FMEA-003) and classified as an actuation failure.
SELECT is((SELECT count(*) FROM pgfc_govern.action_history
            WHERE relid = 'public.poison_t'::regclass AND status = 'failed'),
          1::bigint, 'visibility: poison_t recorded one failed action (not silently denied)');
SELECT is((SELECT failure_class FROM pgfc_govern.action_history
            WHERE relid = 'public.poison_t'::regclass AND status = 'failed'
            ORDER BY action_id DESC LIMIT 1),
          'actuation', 'visibility: the poison failure is classified actuation');

-- The poison relation's ALTER rolled back with its subtransaction: its catalog is untouched.
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.poison_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
          NULL, 'poison_t''s reloption is untouched (its apply() attempt rolled back cleanly)');

SELECT * FROM finish();
ROLLBACK;
