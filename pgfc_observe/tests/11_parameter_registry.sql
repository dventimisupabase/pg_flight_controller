-- Phase 1.6 P1: parameter registry (observe half). _parameter_registry() is the single,
-- canonical, provenance-carrying definition of pgfc_observe's governed constants. P1 is
-- read-only (no control logic reads from it yet); these tests assert the registry is
-- well-formed: valid categories, complete provenance (Appendix-E requires name/meaning/
-- unit/rationale/owner/provenance for every parameter), unique names, and that a few
-- representative values match the as-built code.
BEGIN;
SELECT plan(9);

SELECT has_function('pgfc_observe', '_parameter_registry',
                    'pgfc_observe._parameter_registry() exists');

SELECT ok((SELECT count(*) FROM pgfc_observe._parameter_registry()) > 0,
          'registry returns at least one parameter');

-- Every category is one of the six Appendix-E categories.
SELECT is((SELECT count(*) FROM pgfc_observe._parameter_registry()
           WHERE category NOT IN ('postgresql_derived','safety_bound','empirical_default',
                                  'operator_policy','adaptive_value','implementation_convenience')),
          0::bigint, 'every parameter has a valid category');

-- Provenance is complete: none of the required fields is NULL or blank.
SELECT is((SELECT count(*) FROM pgfc_observe._parameter_registry()
           WHERE parameter_name IS NULL OR parameter_name = ''
              OR category IS NULL OR category = ''
              OR default_value IS NULL
              OR unit IS NULL OR unit = ''
              OR rationale IS NULL OR rationale = ''
              OR source IS NULL OR source = ''
              OR owner IS NULL OR owner = ''
              OR override_allowed IS NULL),
          0::bigint, 'every parameter has complete provenance (no missing fields)');

-- Parameter names are unique.
SELECT is((SELECT count(*) FROM pgfc_observe._parameter_registry()),
          (SELECT count(DISTINCT parameter_name) FROM pgfc_observe._parameter_registry()),
          'parameter names are unique');

-- Representative as-built values (will become the basis for the P3 drift gate).
SELECT is((SELECT default_value FROM pgfc_observe._parameter_registry()
           WHERE parameter_name = 'last_state_fillfactor'),
          '70', 'last_state_fillfactor matches the as-built reloption');
SELECT is((SELECT category FROM pgfc_observe._parameter_registry()
           WHERE parameter_name = 'telemetry_av_threshold'),
          'implementation_convenience', 'telemetry_av_threshold is categorised as implementation convenience');

-- Override semantics: the ring's slot count is a FIXED code constant (FMEA-001), not a
-- runtime override, and names its single-source home.
SELECT is((SELECT override_allowed FROM pgfc_observe._parameter_registry()
           WHERE parameter_name = 'ring_slots'),
          false, 'ring_slots is a fixed code constant, not operator-overridable');
SELECT is((SELECT config_ref FROM pgfc_observe._parameter_registry()
           WHERE parameter_name = 'ring_slots'),
          '_ring_slots()', 'ring_slots names its single-source home');

SELECT * FROM finish();
ROLLBACK;
