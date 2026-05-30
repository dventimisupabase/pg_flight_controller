-- Schema: the two telemetry tables exist with the expected shape.
BEGIN;
SELECT plan(12);

SELECT has_table('pgfc_observe', 'snapshots', 'snapshots table exists');
SELECT has_table('pgfc_observe', 'relation_samples', 'relation_samples table exists');

SELECT col_is_pk('pgfc_observe', 'snapshots', 'snapshot_id', 'snapshots PK is snapshot_id');
SELECT col_is_pk('pgfc_observe', 'relation_samples', ARRAY['snapshot_id','relid'],
                 'relation_samples PK is (snapshot_id, relid)');

-- representative columns from each Appendix-driven group
SELECT has_column('pgfc_observe', 'snapshots', 'pg_class_n_dead_tup',
                  'snapshots has catalog-health column (App B)');
SELECT has_column('pgfc_observe', 'snapshots', 'oldest_xmin_age',
                  'snapshots has xmin-horizon column (App C)');
SELECT has_column('pgfc_observe', 'snapshots', 'oldest_xmin_owner',
                  'snapshots has horizon owner column (App C)');
SELECT has_column('pgfc_observe', 'relation_samples', 'reloptions',
                  'relation_samples captures reloptions (rollback baseline)');
SELECT col_type_is('pgfc_observe', 'relation_samples', 'reloptions', 'text[]',
                   'reloptions is text[]');
SELECT has_column('pgfc_observe', 'relation_samples', 'total_autovacuum_time',
                  'relation_samples has total_autovacuum_time (PG18+, nullable)');

-- FK + cascade wiring
SELECT fk_ok('pgfc_observe', 'relation_samples', 'snapshot_id',
             'pgfc_observe', 'snapshots', 'snapshot_id',
             'relation_samples.snapshot_id references snapshots');
SELECT has_index('pgfc_observe', 'relation_samples', 'relation_samples_relid_idx',
                 'relation_samples has the (relid, snapshot_id) lookup index');

SELECT * FROM finish();
ROLLBACK;
