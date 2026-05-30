-- Harness sanity: govern installed alongside observe, and the cross-schema read works.
BEGIN;
SELECT plan(3);

SELECT has_schema('pgfc_govern', 'pgfc_govern schema is installed');
SELECT has_type('pgfc_govern', 'relation_kind', 'relation_kind enum exists');
SELECT lives_ok($$ SELECT count(*) FROM pgfc_observe.snapshots $$,
                'pgfc_govern can read pgfc_observe cross-schema (dependency present)');

SELECT * FROM finish();
ROLLBACK;
