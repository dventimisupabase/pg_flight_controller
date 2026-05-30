-- Harness sanity: install.sql ran and pgTAP works.
BEGIN;
SELECT plan(2);

SELECT has_schema('pgfc_observe', 'pgfc_observe schema is installed');
SELECT is(
    obj_description('pgfc_observe'::regnamespace, 'pg_namespace'),
    'pg_flight_controller telemetry: snapshots of autovacuum-relevant state (read-only).',
    'schema has its COMMENT'
);

SELECT * FROM finish();
ROLLBACK;
