-- Schema: the two telemetry tables exist, are daily RANGE partitioned (S2), and
-- carry the expected shape.
BEGIN;
SELECT plan(17);

SELECT has_table('pgfc_observe', 'snapshots', 'snapshots table exists');
SELECT has_table('pgfc_observe', 'relation_samples', 'relation_samples table exists');

-- S2: both high-volume tables are partitioned parents (relkind 'p').
SELECT is((SELECT relkind::text FROM pg_class WHERE oid = 'pgfc_observe.snapshots'::regclass),
          'p', 'snapshots is a partitioned table');
SELECT is((SELECT relkind::text FROM pg_class WHERE oid = 'pgfc_observe.relation_samples'::regclass),
          'p', 'relation_samples is a partitioned table');

-- PKs lead with the partition key collected_day (required to be in every PK).
SELECT col_is_pk('pgfc_observe', 'snapshots', ARRAY['collected_day','snapshot_id'],
                 'snapshots PK is (collected_day, snapshot_id)');
SELECT col_is_pk('pgfc_observe', 'relation_samples',
                 ARRAY['collected_day','snapshot_id','relid'],
                 'relation_samples PK is (collected_day, snapshot_id, relid)');

-- The int4 epoch-day partition key on both tables.
SELECT has_column('pgfc_observe', 'snapshots', 'collected_day',
                  'snapshots has collected_day partition key');
SELECT col_type_is('pgfc_observe', 'snapshots', 'collected_day', 'integer',
                   'collected_day is int4');
SELECT has_column('pgfc_observe', 'relation_samples', 'collected_day',
                  'relation_samples has collected_day partition key');

-- representative columns from each Appendix-driven group
SELECT has_column('pgfc_observe', 'snapshots', 'pg_class_n_dead_tup',
                  'snapshots has catalog-health column (App B)');
SELECT has_column('pgfc_observe', 'snapshots', 'oldest_xmin_age',
                  'snapshots has xmin-horizon column (App C)');
SELECT has_column('pgfc_observe', 'relation_samples', 'reloptions',
                  'relation_samples captures reloptions (rollback baseline)');
SELECT col_type_is('pgfc_observe', 'relation_samples', 'reloptions', 'text[]',
                   'reloptions is text[]');
SELECT has_column('pgfc_observe', 'relation_samples', 'total_autovacuum_time',
                  'relation_samples has total_autovacuum_time (PG18+, nullable)');

-- Indexes: the relid lookup btree plus the bloat-free BRIN on the partition key.
SELECT has_index('pgfc_observe', 'relation_samples', 'relation_samples_relid_idx',
                 'relation_samples has the (relid, snapshot_id) lookup index');
SELECT has_index('pgfc_observe', 'snapshots', 'snapshots_collected_day_brin',
                 'snapshots has the BRIN index on collected_day');
SELECT has_index('pgfc_observe', 'relation_samples', 'relation_samples_collected_day_brin',
                 'relation_samples has the BRIN index on collected_day');

SELECT * FROM finish();
ROLLBACK;
