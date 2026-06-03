-- Fortification FMEA-008 (#96): plan() and the governor_status view divide by
-- policy.aggressiveness, which has no CHECK, so an operator-set aggressiveness <= 0 is a
-- division-by-zero — plan() wedges the control loop and governor_status throws on read.
-- The fix single-sources the divisor through _effective_aggressiveness() (raw if > 0, else
-- the registry default), so a misconfiguration can never throw; validate_parameters() still
-- flags <= 0 as CRITICAL, so the operator is still loudly warned. We assert the guard's
-- behavior (not just that it lives) and that BOTH divide sites stay up at aggressiveness = 0.
BEGIN;
SELECT plan(9);

-- ── the guard helper ─────────────────────────────────────────────────────────
SELECT has_function('pgfc_govern', '_effective_aggressiveness', ARRAY['double precision'],
                    '_effective_aggressiveness(double precision) exists');
SELECT is(pgfc_govern._effective_aggressiveness(2.0::float8), 2.0::float8,
          'a positive aggressiveness passes through unchanged');
SELECT is(pgfc_govern._effective_aggressiveness(0::float8),
          pgfc_govern._param('aggressiveness')::float8,
          'zero aggressiveness falls back to the registry default (no divide-by-zero)');
SELECT is(pgfc_govern._effective_aggressiveness(-3::float8),
          pgfc_govern._param('aggressiveness')::float8,
          'a negative aggressiveness falls back to the registry default');
SELECT is(pgfc_govern._effective_aggressiveness(NULL::float8),
          pgfc_govern._param('aggressiveness')::float8,
          'a NULL aggressiveness falls back to the registry default');

-- ── behavioral: both divide sites stay up at aggressiveness = 0 ────────────────
-- Run a real relation through the fast loop so it has class + estimate rows, then capture its
-- governor_status target at the default aggressiveness (1.0) before breaking the value.
CREATE TABLE public.aggr_t (id int);
SELECT pgfc_govern.observe_tick();   -- observe + classify + estimate
CREATE TEMP TABLE _t_default AS
  SELECT target_dead_fraction FROM pgfc_govern.governor_status WHERE relname = 'aggr_t';
SELECT is((SELECT count(*) FROM _t_default), 1::bigint,
          'aggr_t appears in governor_status at the default aggressiveness (test is meaningful)');

UPDATE pgfc_govern.policy SET aggressiveness = 0 WHERE enabled;

SELECT lives_ok($$ SELECT * FROM pgfc_govern.governor_status $$,
                'governor_status does not throw at aggressiveness = 0 (FMEA-008)');
SELECT is((SELECT target_dead_fraction FROM pgfc_govern.governor_status WHERE relname = 'aggr_t'),
          (SELECT target_dead_fraction FROM _t_default),
          'governor_status target at aggressiveness = 0 equals the default-1.0 result');
SELECT lives_ok($$ SELECT pgfc_govern.control_tick() $$,
                'control_tick (plan) does not throw at aggressiveness = 0 (FMEA-008)');

SELECT * FROM finish();
ROLLBACK;
