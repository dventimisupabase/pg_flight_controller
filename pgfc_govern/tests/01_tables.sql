-- Govern schema: the eight tables, the enum wiring, key defaults, and the seed policy.
BEGIN;
SELECT plan(17);

SELECT has_table('pgfc_govern', 'policy', 'policy table exists');
SELECT has_table('pgfc_govern', 'relation_class', 'relation_class table exists');
SELECT has_table('pgfc_govern', 'relation_estimate', 'relation_estimate table exists');
SELECT has_table('pgfc_govern', 'actuator_state', 'actuator_state table exists');
SELECT has_table('pgfc_govern', 'decision_log', 'decision_log table exists');
SELECT has_table('pgfc_govern', 'action_history', 'action_history table exists');
SELECT has_table('pgfc_govern', 'tick_log', 'tick_log table exists');
SELECT has_table('pgfc_govern', 'diagnostics', 'diagnostics table exists');

SELECT col_type_is('pgfc_govern', 'relation_class', 'kind', 'pgfc_govern.relation_kind',
                   'relation_class.kind uses the relation_kind enum');
SELECT col_is_pk('pgfc_govern', 'actuator_state', ARRAY['relid','actuator'],
                 'actuator_state PK is (relid, actuator)');
SELECT fk_ok('pgfc_govern', 'action_history', 'decision_id',
             'pgfc_govern', 'decision_log', 'decision_id',
             'action_history.decision_id references decision_log');

-- Appendix-driven columns present
SELECT has_column('pgfc_govern', 'relation_estimate', 'saturation_cause',
                  'relation_estimate has saturation_cause (App C)');
SELECT has_column('pgfc_govern', 'policy', 'daily_mutation_budget',
                  'policy has daily_mutation_budget (App B)');

-- Seed policy + advisory-by-default
SELECT is((SELECT advisory_only FROM pgfc_govern.policy WHERE policy_name = 'default'),
          true, 'default policy ships advisory_only');
SELECT is((SELECT count(*) FROM pgfc_govern.policy WHERE enabled), 1::bigint,
          'exactly one enabled policy out of the box');

-- action_history defaults (behavioral)
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value)
VALUES (1, 1, 'autovacuum_vacuum_scale_factor', '0.05');
SELECT is((SELECT budget_consumed FROM pgfc_govern.action_history WHERE batch_id = 1),
          false, 'budget_consumed defaults false (failed/unapplied never burns budget)');
SELECT is((SELECT status FROM pgfc_govern.action_history WHERE batch_id = 1),
          'applied', 'status defaults to applied');

SELECT * FROM finish();
ROLLBACK;
