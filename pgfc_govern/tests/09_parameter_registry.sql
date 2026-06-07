-- Phase 1.6 P1: parameter registry (govern half + unified view). pgfc_govern's registry
-- is the canonical, provenance-carrying definition of the CONTROL-LOGIC constants the
-- governor steers with; the parameter_registry view unions both schemas into one
-- operator-facing surface (the storage_budget() layering). P1 is read-only — these tests
-- assert well-formedness, that representative values match the as-built code (the basis
-- for the later drift gate), correct override semantics, and the two-altitude hysteresis
-- distinction the provenance discipline surfaced (k vs n_sustain).
BEGIN;
SELECT plan(18);

SELECT has_function('pgfc_govern', '_parameter_registry', 'pgfc_govern._parameter_registry() exists');
SELECT has_view('pgfc_govern', 'parameter_registry', 'unified parameter_registry view exists');

SELECT ok((SELECT count(*) FROM pgfc_govern._parameter_registry()) > 0,
          'govern registry returns parameters');

SELECT is((SELECT count(*) FROM pgfc_govern._parameter_registry()
           WHERE category NOT IN ('postgresql_derived','safety_bound','empirical_default',
                                  'operator_policy','adaptive_value','implementation_convenience')),
          0::bigint, 'every govern parameter has a valid category');

SELECT is((SELECT count(*) FROM pgfc_govern._parameter_registry()
           WHERE parameter_name IS NULL OR parameter_name = ''
              OR category IS NULL OR category = ''
              OR default_value IS NULL
              OR unit IS NULL OR unit = ''
              OR rationale IS NULL OR rationale = ''
              OR source IS NULL OR source = ''
              OR owner IS NULL OR owner = ''
              OR override_allowed IS NULL),
          0::bigint, 'every govern parameter has complete provenance');

SELECT is((SELECT count(*) FROM pgfc_govern._parameter_registry()),
          (SELECT count(DISTINCT parameter_name) FROM pgfc_govern._parameter_registry()),
          'govern parameter names are unique');

-- Representative as-built control values (recorded by hand in P1; the P3 gate will be what
-- mechanically ties these to the code — these assertions only pin the recorded values).
SELECT is((SELECT default_value FROM pgfc_govern._parameter_registry() WHERE parameter_name='sf_min'),
          '0.01', 'sf_min records the as-built value');
SELECT is((SELECT default_value FROM pgfc_govern._parameter_registry() WHERE parameter_name='sf_max'),
          '0.50', 'sf_max records the as-built value');
SELECT is((SELECT default_value FROM pgfc_govern._parameter_registry() WHERE parameter_name='freeze_thr'),
          '0.6', 'freeze_thr records the as-built value');
SELECT is((SELECT default_value FROM pgfc_govern._parameter_registry() WHERE parameter_name='target_queue'),
          '0.02', 'target_queue records the as-built class target');
SELECT is((SELECT default_value FROM pgfc_govern._parameter_registry() WHERE parameter_name='sf_grid'),
          '{0.01,0.02,0.05,0.10,0.20,0.30,0.50}', 'sf_grid records the as-built grid');

-- Override semantics: orthogonal to category. An operator-tunable safety/policy value
-- names its config home; a fixed safety bound does not.
SELECT ok((SELECT override_allowed FROM pgfc_govern._parameter_registry() WHERE parameter_name='aggressiveness')
          AND (SELECT config_ref FROM pgfc_govern._parameter_registry() WHERE parameter_name='aggressiveness') = 'policy.aggressiveness',
          'aggressiveness is overridable and names policy.aggressiveness');
SELECT ok(NOT (SELECT override_allowed FROM pgfc_govern._parameter_registry() WHERE parameter_name='sf_min')
          AND (SELECT config_ref FROM pgfc_govern._parameter_registry() WHERE parameter_name='sf_min') IS NULL,
          'sf_min is a fixed code default (not overridable, no config_ref)');

-- The worked example the discipline surfaced: two distinct hysteresis parameters, kept
-- separate with distinct rationale (not one coincidental 3).
SELECT ok((SELECT count(*) FROM pgfc_govern._parameter_registry()
           WHERE parameter_name IN ('saturation_persistence_k','class_persistence_n_sustain')) = 2,
          'the two hysteresis parameters are registered distinctly');

-- Unified view spans BOTH schemas and is the sum of the two registries.
SELECT ok(EXISTS (SELECT 1 FROM pgfc_govern.parameter_registry WHERE schema_name='pgfc_observe'),
          'unified view includes pgfc_observe parameters');
SELECT ok(EXISTS (SELECT 1 FROM pgfc_govern.parameter_registry WHERE schema_name='pgfc_govern'),
          'unified view includes pgfc_govern parameters');
SELECT is((SELECT count(*) FROM pgfc_govern.parameter_registry),
          (SELECT count(*) FROM pgfc_observe._parameter_registry())
          + (SELECT count(*) FROM pgfc_govern._parameter_registry()),
          'unified view is exactly the union of both registries');

-- "Document all six categories" was a deliberate decision: assert every category is
-- represented across the system (adaptive_value is the per-relation scale factor).
SELECT is((SELECT count(DISTINCT category) FROM pgfc_govern.parameter_registry),
          6::bigint, 'all six parameter categories are represented across the registry');

SELECT * FROM finish();
ROLLBACK;
