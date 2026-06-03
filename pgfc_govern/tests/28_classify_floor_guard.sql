-- Fortification FMEA-009 (#97): observe_tick() runs observe()+classify()+estimate() in one
-- transaction with no per-stage isolation, so an uncaught classify()/estimate() exception
-- discards the just-collected snapshot. The only in-code trigger is classify dividing 0/0 when
-- classify_floor = 0 on a no-write relation. classify_floor is a code constant (default 50, read
-- from the registry — not settable at runtime), so we inject the pathological value by stubbing
-- the single-sourced accessor, the same way the standby tests stub _is_standby(). The guard makes
-- the effective floor >= 1, so the write-fraction is never computed over zero writes.
--
-- The RESIDUAL "any future classify/estimate exception drops the snapshot" is Won't-fix by design
-- (see 02-failure-theory.md FMEA-009): today's atomicity gives LOUD detection — a stage exception
-- rolls the snapshot back and observation_lag escalates to emergency — whereas isolate-and-swallow
-- would silence a persistent failure (classify/estimate run only here, with no estimate-freshness
-- signal), a detection regression. So this file tests the guard, not an isolation behavior.
BEGIN;
SELECT plan(2);

-- Inject classify_floor = 0 (delegate every other parameter to the real registry).
CREATE OR REPLACE FUNCTION pgfc_govern._param(p_name text) RETURNS text
    LANGUAGE sql IMMUTABLE SET search_path = pgfc_govern, pgfc_observe, pg_catalog AS $stub$
    SELECT CASE WHEN p_name = 'classify_floor' THEN '0'
                ELSE (SELECT default_value FROM pgfc_govern._parameter_registry()
                       WHERE parameter_name = p_name) END
$stub$;

-- A relation with no write history: on the first observe it has no prior sample, so classify's
-- din+dupd+ddel = 0 — and with floor = 0 the write-fraction divide would be 0/0.
CREATE TABLE public.cls0_t (id int);
CREATE TEMP TABLE _snap_before AS SELECT count(*) AS n FROM pgfc_observe.snapshots;

SELECT lives_ok($$ SELECT pgfc_govern.observe_tick() $$,
    'observe_tick survives a 0 classify_floor — classify no longer divides 0/0 (FMEA-009 guard)');
SELECT cmp_ok((SELECT count(*) FROM pgfc_observe.snapshots), '>', (SELECT n FROM _snap_before),
    'observe_tick kept its snapshot (the guarded classify did not abort the tick)');

SELECT * FROM finish();
ROLLBACK;
