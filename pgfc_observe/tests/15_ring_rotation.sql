-- FMEA-001: the raw telemetry tables (snapshots, relation_samples) recycle storage with a
-- FIXED TRUNCATE-rotated ring, not create/drop daily partitions. A constant number of
-- LIST-by-slot partitions is created ONCE at install; rotate_ring() advances by TRUNCATE-ing
-- the slot rolling off. This test is the finding's prover: ZERO steady-state catalog churn —
-- the partition set and the pg_inherits rows stay constant as the calendar advances
-- arbitrarily far, where the old daily-RANGE model created (and left) a new partition per day.
-- It also pins the three porting constraints: retention quantizes to (slots-1) days, and the
-- global snapshot_id sequence never resets across slot TRUNCATEs.
BEGIN;
SELECT plan(9);

SELECT has_function('pgfc_observe', '_ring_slots', '_ring_slots() exists');
SELECT has_function('pgfc_observe', 'rotate_ring', ARRAY['integer'],
                    'rotate_ring(integer) exists');

-- The ring is N fixed slots PER raw table, created once at install (no per-day CREATE).
SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory() WHERE parent = 'snapshots'),
          pgfc_observe._ring_slots()::bigint,
          'snapshots has exactly _ring_slots() slot partitions at install');
SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory() WHERE parent = 'relation_samples'),
          pgfc_observe._ring_slots()::bigint,
          'relation_samples has exactly _ring_slots() slot partitions at install');

-- Baseline the catalog footprint of the two parents' child partitions.
CREATE TEMP TABLE _churn_before AS
SELECT (SELECT count(*) FROM pg_inherits i
          JOIN pg_class p     ON p.oid = i.inhparent
          JOIN pg_namespace n ON n.oid = p.relnamespace
         WHERE n.nspname = 'pgfc_observe'
           AND p.relname IN ('snapshots', 'relation_samples')) AS inherits_rows,
       (SELECT count(*) FROM pgfc_observe._partition_inventory())                    AS parts;

-- Drive the calendar forward 3x the ring size, writing one synthetic snapshot + sample per
-- simulated day, rotating first each day. rotate_ring() recycles by TRUNCATE — it never
-- creates a partition — so the catalog footprint must not move. Capture the first and last
-- assigned snapshot_id to prove the IDENTITY sequence keeps climbing across the TRUNCATEs.
CREATE TEMP TABLE _ids (tag text PRIMARY KEY, id bigint);
DO $drive$
DECLARE
    d0   integer := pgfc_observe._epoch_day(now());
    n    integer := pgfc_observe._ring_slots();
    d    integer;
    v_id bigint;
BEGIN
    FOR d IN d0 .. d0 + 3 * n LOOP
        PERFORM pgfc_observe.rotate_ring(d);
        INSERT INTO pgfc_observe.snapshots
               (slot, collected_day, collected_at, server_version_num)
        VALUES ((d % n)::smallint, d, to_timestamp(d::bigint * 86400), 170000)
        RETURNING snapshot_id INTO v_id;
        INSERT INTO pgfc_observe.relation_samples
               (slot, snapshot_id, collected_day, relid, schemaname, relname)
        VALUES ((d % n)::smallint, v_id, d, 1::oid, 'public', 't');
        IF d = d0 THEN INSERT INTO _ids VALUES ('first', v_id); END IF;
    END LOOP;
    INSERT INTO _ids VALUES ('last', v_id);
END
$drive$;

-- THE PROVER: after advancing 3N days the partition set is exactly the same size — no
-- create/drop churn (the old daily-RANGE model would have ~3N+1 more partitions here).
SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory()),
          (SELECT parts FROM _churn_before),
          'partition count is unchanged after 3x ring-size days (zero create/drop churn)');
SELECT is((SELECT count(*) FROM pg_inherits i
             JOIN pg_class p     ON p.oid = i.inhparent
             JOIN pg_namespace n ON n.oid = p.relnamespace
            WHERE n.nspname = 'pgfc_observe'
              AND p.relname IN ('snapshots', 'relation_samples')),
          (SELECT inherits_rows FROM _churn_before),
          'pg_inherits rows unchanged after rotation — zero catalog churn');

-- Retention quantizes to (slots-1) days: every out-of-window day was swept by rotation,
-- and the most recent day is retained. Final simulated day is d0 + 3n.
SELECT is((SELECT count(*) FROM pgfc_observe.snapshots
           WHERE collected_day <= pgfc_observe._epoch_day(now()) + 3 * pgfc_observe._ring_slots()
                                  - pgfc_observe._ring_slots()),
          0::bigint,
          'rotate_ring swept every out-of-window day (raw window = (slots-1) days)');
SELECT is((SELECT count(*) FROM pgfc_observe.snapshots
           WHERE collected_day = pgfc_observe._epoch_day(now()) + 3 * pgfc_observe._ring_slots()),
          1::bigint,
          'the most recent simulated day is retained in the ring');

-- The global snapshot_id sequence does NOT reset across the slot TRUNCATEs (plain TRUNCATE,
-- never RESTART IDENTITY): ids climbed monotonically by one per simulated day.
SELECT is((SELECT id FROM _ids WHERE tag = 'last') - (SELECT id FROM _ids WHERE tag = 'first'),
          (3 * pgfc_observe._ring_slots())::bigint,
          'snapshot_id never resets across slot TRUNCATEs (monotonic IDENTITY on the parent)');

SELECT * FROM finish();
ROLLBACK;
