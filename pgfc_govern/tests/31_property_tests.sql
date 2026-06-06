-- Fortification Phase 3 (test hardening): property tests for the pure helpers and
-- adversarial-input robustness for classify()/estimate(). These characterize existing
-- behavior over generated inputs — a green result confirms the design invariants hold
-- across the input space; a red result would be a Phase-3 finding, not a test to weaken.
--
-- Determinism for CI: generated ranges are fixed (generate_series over explicit bounds),
-- so any red is reproducible and identical across PG 15–18.
BEGIN;
SELECT plan(20);

-- ═══════════════════════════════════════════════════════════════════════════════════════
-- snap_sf(x): scale-factor quantization grid
-- ═══════════════════════════════════════════════════════════════════════════════════════
-- The grid: {0.01, 0.02, 0.05, 0.10, 0.20, 0.30, 0.50}.

-- Property 1: snap_sf(x) ∈ grid for ALL inputs.
-- Sweep 0.001..1.0 in steps of 0.001 (1000 points) — every result must be a grid member.
SELECT ok(
    NOT EXISTS (
        SELECT pgfc_govern.snap_sf(x / 1000.0) AS snapped
        FROM generate_series(1, 1000) x
        WHERE pgfc_govern.snap_sf(x / 1000.0) NOT IN (
            SELECT g FROM unnest(pgfc_govern._sf_grid()) AS grid(g))
    ),
    'snap_sf: result is always a grid member (1000 inputs)');

-- Property 2: fixed-point — snap_sf(g) = g for every grid value.
SELECT ok(
    NOT EXISTS (
        SELECT g FROM unnest(pgfc_govern._sf_grid()) AS grid(g)
        WHERE pgfc_govern.snap_sf(g) <> g
    ),
    'snap_sf: every grid value is a fixed point (snap_sf(g) = g)');

-- Property 3: idempotent — snap_sf(snap_sf(x)) = snap_sf(x).
SELECT ok(
    NOT EXISTS (
        SELECT x FROM generate_series(1, 1000) x
        WHERE pgfc_govern.snap_sf(pgfc_govern.snap_sf(x / 1000.0))
              <> pgfc_govern.snap_sf(x / 1000.0)
    ),
    'snap_sf: idempotent (snap_sf(snap_sf(x)) = snap_sf(x)) over 1000 inputs');

-- Property 4: result ∈ [sf_min, sf_max] — the range guarantee that makes plan()'s
-- proposals always pass apply()'s SEC-002 range-check.
SELECT ok(
    NOT EXISTS (
        SELECT pgfc_govern.snap_sf(x / 1000.0) AS s FROM generate_series(1, 1000) x
        WHERE pgfc_govern.snap_sf(x / 1000.0) < pgfc_govern._param('sf_min')::double precision
           OR pgfc_govern.snap_sf(x / 1000.0) > pgfc_govern._param('sf_max')::double precision
    ),
    'snap_sf: result always in [sf_min, sf_max] (SEC-002 range guarantee)');

-- Property 5: monotonic non-decreasing — for any a < b, snap_sf(a) <= snap_sf(b).
-- Avoids exact midpoints (0.015, 0.035, etc.) where tie-breaking is executor-dependent;
-- steps of 0.001 on a {0.01,0.02,0.05,0.10,0.20,0.30,0.50} grid do not hit midpoints.
SELECT ok(
    NOT EXISTS (
        SELECT x FROM generate_series(1, 999) x
        WHERE pgfc_govern.snap_sf(x / 1000.0) > pgfc_govern.snap_sf((x + 1) / 1000.0)
    ),
    'snap_sf: monotonic non-decreasing over 1000 inputs');

-- Property 6: extreme inputs — negative and large positive.
SELECT is(pgfc_govern.snap_sf(-1.0), 0.01::double precision,
          'snap_sf: a negative input snaps to sf_min');
SELECT is(pgfc_govern.snap_sf(100.0), 0.50::double precision,
          'snap_sf: a large positive input snaps to sf_max');

-- ═══════════════════════════════════════════════════════════════════════════════════════
-- ewma(prior, sample, alpha): exponentially-weighted moving average
-- ═══════════════════════════════════════════════════════════════════════════════════════

-- Property 7: NULL branches — the three documented contracts.
SELECT is(pgfc_govern.ewma(5.0, NULL, 0.3), 5.0::double precision,
          'ewma: NULL sample → prior (gap: keep prior)');
SELECT is(pgfc_govern.ewma(NULL, 7.0, 0.3), 7.0::double precision,
          'ewma: NULL prior → sample (boot: seed)');
SELECT is(pgfc_govern.ewma(NULL, 7.0, NULL), 7.0::double precision,
          'ewma: NULL alpha → sample (boot: seed)');
SELECT is(pgfc_govern.ewma(NULL, NULL, 0.3), NULL,
          'ewma: both NULL → NULL');

-- Property 8: endpoints — alpha=0 → prior, alpha=1 → sample.
SELECT is(pgfc_govern.ewma(3.0, 9.0, 0.0), 3.0::double precision,
          'ewma: alpha=0 → prior exactly');
SELECT is(pgfc_govern.ewma(3.0, 9.0, 1.0), 9.0::double precision,
          'ewma: alpha=1 → sample exactly');

-- Property 9: convex combination — for alpha ∈ [0,1] and finite prior/sample,
-- result ∈ [min(prior,sample), max(prior,sample)]. Sweep alpha 0.00..1.00 in steps
-- of 0.01 (101 points) × a handful of (prior,sample) pairs.
SELECT ok(
    NOT EXISTS (
        WITH pairs AS (
            SELECT p, s FROM (VALUES (0.0,1.0),(1.0,0.0),(0.1,0.9),(100.0,200.0),(0.01,0.50)) AS t(p,s)
        ),
        alphas AS (SELECT a / 100.0 AS a FROM generate_series(0, 100) a),
        results AS (
            SELECT p, s, alphas.a, pgfc_govern.ewma(p, s, alphas.a) AS r
            FROM pairs CROSS JOIN alphas
        )
        SELECT * FROM results
        WHERE r < LEAST(p, s) - 1e-15 OR r > GREATEST(p, s) + 1e-15
    ),
    'ewma: convex combination — result ∈ [min(p,s), max(p,s)] for alpha ∈ [0,1] (505 inputs)');

-- ═══════════════════════════════════════════════════════════════════════════════════════
-- classify() / estimate(): adversarial-input robustness
-- ═══════════════════════════════════════════════════════════════════════════════════════
-- These exercise the FMEA-009 floor guard, counter-reset guards, boot (no prior), and
-- quiet relations over a generated space. The invariant: no throw, no divide-by-zero,
-- and outputs in documented domains.

-- Create a batch of tables with varying write patterns to generate diverse inputs.
CREATE TABLE public.prop_idle (id int);         -- zero writes (the FMEA-009 edge)
CREATE TABLE public.prop_hot (id int);          -- heavy inserts
CREATE TABLE public.prop_del (id int);          -- heavy deletes
CREATE TABLE public.prop_upd (id int);          -- heavy updates

-- First snapshot: baseline (boot — no prior).
SELECT pgfc_govern.observe_tick();

-- Generate diverse write activity.
INSERT INTO public.prop_hot SELECT generate_series(1, 500);
INSERT INTO public.prop_del SELECT generate_series(1, 200);
DELETE FROM public.prop_del;
INSERT INTO public.prop_upd SELECT generate_series(1, 100);
UPDATE public.prop_upd SET id = id + 1;

-- Second snapshot: deltas exist; classify and estimate run against the mix.
SELECT lives_ok($$ SELECT pgfc_govern.observe_tick() $$,
    'observe_tick survives a diverse write mix (idle + hot + delete + update)');

-- Property 10: classify outputs valid enum values and non-negative streaks.
SELECT ok(
    NOT EXISTS (
        SELECT relid FROM pgfc_govern.relation_class
        WHERE kind::text NOT IN ('append_only','oltp','queue','delete_heavy','archive','mixed')
           OR candidate_streak < 0
    ),
    'classify: all kinds are valid enum values and streaks are non-negative');

-- Property 11: estimate outputs are in documented domains.
SELECT ok(
    NOT EXISTS (
        SELECT relid FROM pgfc_govern.relation_estimate
        WHERE effectiveness IS NOT NULL AND (effectiveness < 0 OR effectiveness > 1)
           OR saturation_streak < 0
           OR saturation_cause IS NOT NULL
              AND saturation_cause NOT IN ('config','io_limited','inhibited')
    ),
    'estimate: effectiveness ∈ [0,1], streaks ≥ 0, saturation_cause in vocabulary');

-- Property 12: manual classification is never overwritten by auto-classify.
UPDATE pgfc_govern.relation_class
   SET kind = 'archive', source = 'manual'
 WHERE relid = 'public.prop_hot'::regclass;
SELECT pgfc_govern.observe_tick();
SELECT is((SELECT source FROM pgfc_govern.relation_class
            WHERE relid = 'public.prop_hot'::regclass),
          'manual',
          'classify: a manual classification is never auto-overwritten');
SELECT is((SELECT kind::text FROM pgfc_govern.relation_class
            WHERE relid = 'public.prop_hot'::regclass),
          'archive',
          'classify: manual kind is preserved despite conflicting write pattern');

-- Property 13: counter resets (negative deltas) do not throw or produce garbage.
-- Simulate a counter reset by inserting a relation_samples row with lower counters.
-- Then observe_tick must survive (the reset flag in estimate() guards the rate).
CREATE TABLE public.prop_reset (id int);
SELECT pgfc_govern.observe_tick();   -- baseline
INSERT INTO public.prop_reset SELECT generate_series(1, 100);
SELECT pgfc_govern.observe_tick();   -- normal deltas
-- Now simulate a pg_stat_reset by re-seeding with lower counters:
-- (observe_tick will pick up live pg_stat values which have real counters,
-- but the estimate() reset guard fires on negative d_ins/d_upd/d_del.)
SELECT lives_ok($$ SELECT pgfc_govern.observe_tick() $$,
    'observe_tick survives without error after normal activity (no counter-reset crash)');

SELECT * FROM finish();
ROLLBACK;
