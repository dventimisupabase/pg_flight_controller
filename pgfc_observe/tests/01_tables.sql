-- Schema: the two telemetry tables exist, are LIST-partitioned into the fixed ring on slot
-- (S2 / FMEA-001), and carry the expected shape (slot partition key + collected_day plain
-- column + the observable groups + the relid/BRIN indexes).
BEGIN;
SELECT plan(22);

SELECT has_table('pgfc_observe', 'snapshots', 'snapshots table exists');
SELECT has_table('pgfc_observe', 'relation_samples', 'relation_samples table exists');

-- Both high-volume tables are partitioned parents (relkind 'p') ...
SELECT is((SELECT relkind::text FROM pg_class WHERE oid = 'pgfc_observe.snapshots'::regclass),
          'p', 'snapshots is a partitioned table');
SELECT is((SELECT relkind::text FROM pg_class WHERE oid = 'pgfc_observe.relation_samples'::regclass),
          'p', 'relation_samples is a partitioned table');

-- ... and specifically LIST-partitioned (the fixed ring, FMEA-001), not RANGE.
SELECT is((SELECT partstrat::text FROM pg_partitioned_table
           WHERE partrelid = 'pgfc_observe.snapshots'::regclass),
          'l', 'snapshots is LIST-partitioned (the fixed ring)');
SELECT is((SELECT partstrat::text FROM pg_partitioned_table
           WHERE partrelid = 'pgfc_observe.relation_samples'::regclass),
          'l', 'relation_samples is LIST-partitioned (the fixed ring)');

-- PKs lead with the slot partition key (required to be in every PK of a partitioned table).
SELECT col_is_pk('pgfc_observe', 'snapshots', ARRAY['slot','snapshot_id'],
                 'snapshots PK is (slot, snapshot_id)');
SELECT col_is_pk('pgfc_observe', 'relation_samples',
                 ARRAY['slot','snapshot_id','relid'],
                 'relation_samples PK is (slot, snapshot_id, relid)');

-- The smallint slot partition key on both tables.
SELECT has_column('pgfc_observe', 'snapshots', 'slot', 'snapshots has the slot partition key');
SELECT col_type_is('pgfc_observe', 'snapshots', 'slot', 'smallint', 'slot is smallint');
SELECT has_column('pgfc_observe', 'relation_samples', 'slot',
                  'relation_samples has the slot partition key');

-- collected_day stays as a plain column (BRIN index, rollup pruning, human reads).
SELECT has_column('pgfc_observe', 'snapshots', 'collected_day',
                  'snapshots keeps collected_day as a plain column');
SELECT col_type_is('pgfc_observe', 'snapshots', 'collected_day', 'integer',
                   'collected_day is int4');
SELECT has_column('pgfc_observe', 'relation_samples', 'collected_day',
                  'relation_samples keeps collected_day');

-- representative columns from each observable group
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

-- Indexes: the relid lookup btree plus the bloat-free BRIN on collected_day.
SELECT has_index('pgfc_observe', 'relation_samples', 'relation_samples_relid_idx',
                 'relation_samples has the (relid, snapshot_id) lookup index');
SELECT has_index('pgfc_observe', 'snapshots', 'snapshots_collected_day_brin',
                 'snapshots has the BRIN index on collected_day');
SELECT has_index('pgfc_observe', 'relation_samples', 'relation_samples_collected_day_brin',
                 'relation_samples has the BRIN index on collected_day');

SELECT * FROM finish();
ROLLBACK;
