-- Phase 1.6 P2: the control logic now reads its constants THROUGH the registry accessors
-- (_param / _sf_grid / _class_target) instead of inline literals. The behaviour-identity of
-- that refactor is guarded by the existing estimate/classify/plan/loop/integration suites
-- (which pin concrete outcomes like queue target 0.02 and the freeze floor 0.005); this file
-- pins the accessors themselves — including the sf_grid type round-trip (text → float8[])
-- the single-sourcing introduced.
BEGIN;
SELECT plan(13);

SELECT has_function('pgfc_govern', '_param', ARRAY['text'], '_param(text) exists');
SELECT has_function('pgfc_govern', '_sf_grid', '_sf_grid() exists');
SELECT has_function('pgfc_govern', '_class_target', ARRAY['text'], '_class_target(text) exists');

SELECT is(pgfc_govern._param('sf_min'), '0.005', '_param reads sf_min');
SELECT is(pgfc_govern._param('freeze_thr'), '0.6', '_param reads freeze_thr');
SELECT throws_ok($$ SELECT pgfc_govern._param('no_such_param') $$, NULL,
                 '_param raises on an unknown parameter (no silent NULL)');

-- The grid round-trips text → float8[] intact and in order.
SELECT is(pgfc_govern._sf_grid(),
          ARRAY[0.005,0.01,0.02,0.05,0.10,0.20,0.30,0.50]::double precision[],
          '_sf_grid returns the canonical grid as a float8 array');

SELECT is(pgfc_govern._class_target('queue'),   0.02::double precision, '_class_target(queue) = 0.02');
SELECT is(pgfc_govern._class_target('archive'), 0.20::double precision, '_class_target(archive) = 0.20');
SELECT is(pgfc_govern._class_target('oltp'),    0.05::double precision, '_class_target(oltp) = 0.05');

-- snap_sf still snaps to the (now registry-sourced) grid. Non-equidistant inputs only,
-- so there is no tie-break ambiguity.
SELECT is(pgfc_govern.snap_sf(0.06),  0.05::double precision, 'snap_sf(0.06) → 0.05');
SELECT is(pgfc_govern.snap_sf(0.003), 0.005::double precision, 'snap_sf(0.003) → 0.005 (floor)');
SELECT is(pgfc_govern.snap_sf(0.9),   0.50::double precision, 'snap_sf(0.9) → 0.50 (ceiling)');

SELECT * FROM finish();
ROLLBACK;
