-- Phase 1.6 P4: validate_parameters() — the reviewability surface. It grades the LIVE
-- operator configuration against the registry's safety bounds (OK/WARNING/CRITICAL),
-- checking hard safety properties only. These tests assert the default seeded config is
-- safe, and that hazardous settings are surfaced.
BEGIN;
SELECT plan(8);

SELECT has_function('pgfc_govern', 'validate_parameters', 'validate_parameters() exists');

-- The default seeded policy is safe: nothing CRITICAL.
SELECT is((SELECT count(*) FROM pgfc_govern.validate_parameters() WHERE status = 'CRITICAL'),
          0::bigint, 'default configuration has no CRITICAL findings');
-- advisory_only defaults true → that check is OK (active control off).
SELECT is((SELECT status FROM pgfc_govern.validate_parameters() WHERE parameter = 'advisory_only'),
          'OK', 'advisory_only=true (the safe default) is OK');
SELECT is((SELECT status FROM pgfc_govern.validate_parameters() WHERE parameter = 'aggressiveness'),
          'OK', 'default aggressiveness is OK');

-- A non-positive aggressiveness is a divide-by-zero / sign inversion: CRITICAL.
UPDATE pgfc_govern.policy SET aggressiveness = 0 WHERE policy_name = 'default';
SELECT is((SELECT status FROM pgfc_govern.validate_parameters() WHERE parameter = 'aggressiveness'),
          'CRITICAL', 'aggressiveness = 0 is CRITICAL');

-- Enabling active control is flagged (experimental); disabling hysteresis risks flapping.
UPDATE pgfc_govern.policy SET advisory_only = false, n_sustain = 0 WHERE policy_name = 'default';
SELECT is((SELECT status FROM pgfc_govern.validate_parameters() WHERE parameter = 'advisory_only'),
          'WARNING', 'advisory_only=false is a WARNING (active control is experimental)');
SELECT is((SELECT status FROM pgfc_govern.validate_parameters() WHERE parameter = 'n_sustain'),
          'WARNING', 'n_sustain=0 (no hysteresis) is a WARNING');

-- A zero mutation budget means the governor can never act.
UPDATE pgfc_govern.policy SET daily_mutation_budget = 0 WHERE policy_name = 'default';
SELECT is((SELECT status FROM pgfc_govern.validate_parameters() WHERE parameter = 'daily_mutation_budget'),
          'WARNING', 'daily_mutation_budget=0 is a WARNING');

SELECT * FROM finish();
ROLLBACK;
