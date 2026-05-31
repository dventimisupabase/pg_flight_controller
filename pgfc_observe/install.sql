-- pgfc_observe — Observe + Orient (Phase 0; partition storage 1.5 S2; sparse 1.5 S3; rollups 1.5 S4; cardinality filters 1.5 S5)
--
-- Read-only telemetry for the pg_flight_controller autovacuum governor: periodic
-- snapshots of autovacuum-relevant state. Writes only to its own schema.
--
-- Re-running this file is safe and idempotent for the CURRENT schema
-- (CREATE ... IF NOT EXISTS / CREATE OR REPLACE throughout; the harness applies it
-- twice to prove this).
--
-- Schema evolution is additive-only (new NULLABLE columns; never drop/rename).
-- IMPORTANT: `CREATE TABLE IF NOT EXISTS` does NOT add a column to a table that
-- already exists, so it alone does not upgrade an older install. To add a column:
--   1. add it (nullable) to the CREATE TABLE below — for fresh installs; and
--   2. add a matching `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` in the
--      "Additive upgrades" section near the end — for existing installs on re-run.
--
-- S2 EXCEPTION to additive-only: snapshots/relation_samples are now daily RANGE
-- partitioned, which cannot be created in place from the Phase-0 ordinary tables.
-- Telemetry is disposable, so the "Destructive recreate" block below drops the old
-- (non-partitioned) shape ONCE. This is a deliberate, one-time exception (see the
-- design's "Migration stance"); it does NOT extend to pgfc_govern's audit tables.

CREATE SCHEMA IF NOT EXISTS pgfc_observe;
COMMENT ON SCHEMA pgfc_observe IS
  'pg_flight_controller telemetry: snapshots of autovacuum-relevant state (read-only).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Partition key helper  (Phase 1.5 S2)
-- ─────────────────────────────────────────────────────────────────────────────

-- Epoch day = whole days since 1970-01-01 UTC. This is the int4 RANGE partition key
-- for the high-volume telemetry tables: compact (4 bytes), monotonic, and — unlike
-- int4 epoch *seconds*, which overflow in 2038 — safe essentially forever. One
-- distinct value per UTC day, so a daily partition spans exactly [day, day+1).
-- STABLE (not IMMUTABLE): epoch from timestamptz is an absolute instant, but it is
-- only ever used to compute a value to store / a cutoff — never as an index or
-- partition expression — so STABLE is correct and sufficient.
CREATE OR REPLACE FUNCTION pgfc_observe._epoch_day(ts timestamptz)
RETURNS integer LANGUAGE sql STABLE AS $$
    SELECT floor(extract(epoch FROM ts) / 86400)::integer
$$;
COMMENT ON FUNCTION pgfc_observe._epoch_day(timestamptz) IS
  'Whole UTC days since 1970-01-01 — the int4 daily RANGE partition key.';

-- Epoch month = whole calendar months since 1970-01 UTC, as a single monotonic int4
-- (year*12 + month-1, rebased to 1970). The coarse rollup tiers (1h, 1d) are partitioned
-- by MONTH, not day: their retention windows (90 d / 365 d) would otherwise need 90–365
-- daily partitions, whereas a daily span on the fine 1m tier keeps its 7-day window tight.
-- One distinct value per UTC calendar month, so a monthly partition spans [month, month+1).
-- STABLE for the same reason as _epoch_day (used only to compute stored values / cutoffs).
CREATE OR REPLACE FUNCTION pgfc_observe._epoch_month(ts timestamptz)
RETURNS integer LANGUAGE sql STABLE AS $$
    SELECT (extract(year  FROM (ts AT TIME ZONE 'UTC'))::int - 1970) * 12
         + (extract(month FROM (ts AT TIME ZONE 'UTC'))::int - 1)
$$;
COMMENT ON FUNCTION pgfc_observe._epoch_month(timestamptz) IS
  'Whole UTC calendar months since 1970-01 — the int4 monthly RANGE partition key for coarse rollups.';

-- Inverse of _epoch_month: the UTC instant at the start of epoch-month k. Used to decode a
-- monthly partition''s int key back to its [start, end) range and to name the partition.
CREATE OR REPLACE FUNCTION pgfc_observe._month_start(k integer)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
    SELECT make_timestamptz(1970 + (k / 12), (k % 12) + 1, 1, 0, 0, 0, 'UTC')
$$;
COMMENT ON FUNCTION pgfc_observe._month_start(integer) IS
  'UTC instant at the start of epoch-month k (inverse of _epoch_month).';

-- Static autovacuum reloptions for the partitioned telemetry tables (S6). The
-- governor maintains its own schema with EXPLICIT, STATIC settings — it must not
-- govern itself (a control loop observing its own actuator). scale_factor=0 makes the
-- trigger a fixed row count rather than a fraction that drifts as the table grows, so
-- behavior is predictable regardless of size; the insert-vacuum knobs keep
-- append-only partitions frozen well inside the retention window (anti-wraparound
-- insurance on a high-txn cluster). The governor never samples or actuates these
-- tables anyway — S5's own-schema and extension-owned filters exclude them — so this
-- is purely about predictable self-maintenance, not defeating self-actuation.
-- One source of truth, used by _ensure_partition()/_ensure_part() (new partitions)
-- and the additive-upgrade backfill (existing partitions).
CREATE OR REPLACE FUNCTION pgfc_observe._telemetry_reloptions()
RETURNS text IMMUTABLE LANGUAGE sql AS $$
    SELECT 'autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_threshold=1000, '
         || 'autovacuum_analyze_scale_factor=0, autovacuum_analyze_threshold=1000, '
         || 'autovacuum_vacuum_insert_scale_factor=0, autovacuum_vacuum_insert_threshold=1000'
$$;
COMMENT ON FUNCTION pgfc_observe._telemetry_reloptions() IS
  'Static autovacuum reloptions string applied to every telemetry/rollup partition (S6).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Destructive recreate  (Phase 1.5 S2 — one-time; see header)
-- ─────────────────────────────────────────────────────────────────────────────
-- Phase 0 created snapshots/relation_samples as ordinary tables; S2 makes them
-- partitioned. A table cannot be ALTERed into a partitioned table in place, so drop
-- the old shape. Guarded on relkind <> 'p' so it fires at most once: on a fresh
-- install nothing exists; after S2 the tables are partitioned ('p') and are left
-- untouched, keeping this file idempotent. CASCADE also drops dependent cross-schema
-- views (notably pgfc_govern.catalog_health) — if pgfc_govern is installed, re-run
-- pgfc_govern/install.sql afterward to restore them.
DO $recreate$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = 'pgfc_observe' AND c.relname = 'relation_samples'
                 AND c.relkind <> 'p') THEN
        DROP TABLE pgfc_observe.relation_samples CASCADE;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = 'pgfc_observe' AND c.relname = 'snapshots'
                 AND c.relkind <> 'p') THEN
        DROP TABLE pgfc_observe.snapshots CASCADE;
    END IF;
END
$recreate$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Tables  (daily RANGE partitioned on collected_day — Phase 1.5 S2)
-- ─────────────────────────────────────────────────────────────────────────────

-- One row per observe() run: timestamp + cluster/GUC context, pg_class health,
-- and the xmin removability horizons, shared by all that run's relation samples.
CREATE TABLE IF NOT EXISTS pgfc_observe.snapshots (
    snapshot_id              bigint GENERATED ALWAYS AS IDENTITY,
    -- collected_day is the daily RANGE partition key and must be part of the PK.
    -- snapshot_id stays globally unique (single IDENTITY sequence), so views may
    -- still join on snapshot_id alone.
    collected_day            integer     NOT NULL DEFAULT pgfc_observe._epoch_day(now()),
    collected_at             timestamptz NOT NULL DEFAULT now(),
    datname                  name        NOT NULL DEFAULT current_database(),
    server_version_num       integer     NOT NULL,
    -- effective global actuator defaults at collection time
    def_vac_scale_factor     double precision,
    def_vac_threshold        bigint,
    def_ana_scale_factor     double precision,
    def_ana_threshold        bigint,
    def_vac_cost_limit       integer,
    def_vac_cost_delay       double precision,
    def_freeze_max_age       bigint,
    def_mxid_freeze_max_age  bigint,
    autovacuum_max_workers   integer,
    wal_bytes                numeric,
    -- catalog self-monitoring (the governor's actuation mutates pg_class.reloptions)
    pg_class_size_bytes      bigint,
    pg_class_n_dead_tup      bigint,
    pg_class_n_live_tup      bigint,
    pg_class_last_autovacuum timestamptz,
    -- removability horizons: why cleanup may be impossible
    oldest_xmin_age           bigint,
    oldest_xmin_owner         text,
    oldest_xmin_owner_detail  text,
    oldest_catalog_xmin_age   bigint,
    oldest_catalog_xmin_owner text,
    PRIMARY KEY (collected_day, snapshot_id)
) PARTITION BY RANGE (collected_day);
COMMENT ON TABLE pgfc_observe.snapshots IS
  'Header row per observe() run: timestamp + cluster/GUC + pg_class health + xmin horizons. Daily RANGE partitioned on collected_day.';

-- One row per relation per snapshot. Additive-only: new columns are nullable;
-- existing columns are never dropped or renamed.
-- No FK to snapshots: retention is whole-partition TRUNCATE/DROP (S2), and a
-- row-level ON DELETE CASCADE both goes unused by that and would block TRUNCATE of a
-- referenced partition. Integrity instead holds by construction — observe() writes
-- the header then its samples in one transaction. collected_day mirrors the parent
-- snapshot's day (set by observe()) and is the partition key, so it is in the PK.
CREATE TABLE IF NOT EXISTS pgfc_observe.relation_samples (
    snapshot_id          bigint NOT NULL,
    collected_day        integer NOT NULL DEFAULT pgfc_observe._epoch_day(now()),
    relid                oid    NOT NULL,
    schemaname           name   NOT NULL,
    relname              name   NOT NULL,
    -- pg_stat_all_tables
    n_live_tup           bigint,
    n_dead_tup           bigint,
    n_mod_since_analyze  bigint,
    n_ins_since_vacuum   bigint,         -- PG13+
    n_tup_ins            bigint,
    n_tup_upd            bigint,
    n_tup_del            bigint,
    n_tup_hot_upd        bigint,
    last_autovacuum      timestamptz,
    last_autoanalyze     timestamptz,
    vacuum_count         bigint,
    autovacuum_count     bigint,
    analyze_count        bigint,
    autoanalyze_count    bigint,
    total_autovacuum_time double precision,   -- PG18+, NULL on older
    -- pg_class / derived sizes
    reltuples            real,
    relpages             integer,
    relallvisible        integer,
    relfrozenxid_age     bigint,         -- age(relfrozenxid) at write time (legacy; readers recompute live)
    relminmxid_age       bigint,         -- mxid_age(relminmxid) at write time (legacy; readers recompute live)
    -- Raw frozen xids (S3). age()/mxid_age() tick up globally every minute, so the
    -- *_age columns above cannot be part of the change signature without making every
    -- relation look changed every run. The raw xids are stable until the table is
    -- frozen, so they ARE the signature key; readers compute the current age live from
    -- them (see current_relation_state()). Nullable: pre-S3 rows have only the ages.
    relfrozenxid         xid,
    relminmxid           xid,
    relation_size_bytes  bigint,
    total_size_bytes     bigint,
    -- rollback baseline for the governor: the table's explicit autovacuum reloptions
    reloptions           text[],
    PRIMARY KEY (collected_day, snapshot_id, relid)
) PARTITION BY RANGE (collected_day);
COMMENT ON TABLE pgfc_observe.relation_samples IS
  'Per-relation observed state for one snapshot. reloptions is the governor rollback baseline. Daily RANGE partitioned on collected_day.';

CREATE INDEX IF NOT EXISTS relation_samples_relid_idx
    ON pgfc_observe.relation_samples (relid, snapshot_id DESC);

-- BRIN (not btree) on the partition key. A btree on a high-insert telemetry table
-- bloats — exactly the failure mode this system exists to manage — whereas BRIN is
-- tiny and effectively bloat-free. Cross-partition time-range queries are served by
-- partition pruning; the BRIN backs ad-hoc range scans on the parent at near-zero
-- storage cost. Created on the partitioned parents, so every partition inherits it.
CREATE INDEX IF NOT EXISTS snapshots_collected_day_brin
    ON pgfc_observe.snapshots USING brin (collected_day);
CREATE INDEX IF NOT EXISTS relation_samples_collected_day_brin
    ON pgfc_observe.relation_samples USING brin (collected_day);

-- Last observed state per relation — the O(1) "did this change?" side table (S3).
-- One row per live relation, holding exactly the columns that form the change
-- signature (every event-driven observable, plus the raw frozen xids — never the
-- derived ages, which tick up globally). observe() upserts it every run and writes a
-- relation_samples row only where the current state differs from the stored row.
--   UNLOGGED: it is a cache that is exactly reconstructable from the catalogs, so it
--             need not survive a crash. After a crash it is empty and the next
--             observe() simply re-samples every relation once (a self-healing rebuild).
--   fillfactor=70 + only the relid PK (no index on the mutable columns): every update
--             is the same row's columns changing, so HOT updates keep it tiny and
--             effectively bloat-free between its own (aggressive, static) autovacuums.
CREATE UNLOGGED TABLE IF NOT EXISTS pgfc_observe.relation_last_state (
    relid                oid PRIMARY KEY,
    schemaname           name,
    relname              name,
    n_live_tup           bigint,
    n_dead_tup           bigint,
    n_mod_since_analyze  bigint,
    n_ins_since_vacuum   bigint,
    n_tup_ins            bigint,
    n_tup_upd            bigint,
    n_tup_del            bigint,
    n_tup_hot_upd        bigint,
    last_autovacuum      timestamptz,
    last_autoanalyze     timestamptz,
    vacuum_count         bigint,
    autovacuum_count     bigint,
    analyze_count        bigint,
    autoanalyze_count    bigint,
    total_autovacuum_time double precision,
    reltuples            real,
    relpages             integer,
    relallvisible        integer,
    relfrozenxid         xid,
    relminmxid           xid,
    relation_size_bytes  bigint,
    total_size_bytes     bigint,
    reloptions           text[]
) WITH (fillfactor = 70,
        autovacuum_vacuum_scale_factor   = 0.0, autovacuum_vacuum_threshold   = 50,
        autovacuum_analyze_scale_factor  = 0.0, autovacuum_analyze_threshold  = 50);
COMMENT ON TABLE pgfc_observe.relation_last_state IS
  'UNLOGGED last-observed state per relation: the change-signature cache for sparse logging (S3). Rebuilt from the catalogs after a crash.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Collection policy — cardinality filters  (Phase 1.5 S5)
-- ─────────────────────────────────────────────────────────────────────────────
-- Single-row config controlling WHICH relations observe() samples. S5 exists for
-- databases with thousands of relations, where sampling every relation every run is
-- itself the storage problem. The filters are applied SET-BASED inside observe()'s
-- collection query (never a per-row function — that would be N catalog lookups a
-- minute), so they stay cheap at high relation counts. Rollups and pgfc_govern's
-- readers inherit the filtered set automatically, because they read what observe()
-- wrote. System schemas are ALWAYS excluded regardless of this row; excluded_schemas
-- is additive on top, so config can never re-include pg_catalog.
CREATE TABLE IF NOT EXISTS pgfc_observe.collection_policy (
    -- Enforced singleton: the PK is a constant-true flag, so at most one row can exist.
    singleton                 boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    exclude_temp              boolean NOT NULL DEFAULT true,
    include_extension_owned   boolean NOT NULL DEFAULT false,
    min_partition_size_bytes  bigint  NOT NULL DEFAULT 0 CHECK (min_partition_size_bytes >= 0),
    excluded_schemas          name[]  NOT NULL DEFAULT '{}'
);
COMMENT ON TABLE pgfc_observe.collection_policy IS
  'Single-row cardinality filter config for observe() (S5): which relations are sampled. System schemas are always excluded.';
COMMENT ON COLUMN pgfc_observe.collection_policy.exclude_temp IS
  'Exclude temporary tables (relpersistence = ''t''). Default true.';
COMMENT ON COLUMN pgfc_observe.collection_policy.include_extension_owned IS
  'Include relations owned by an extension (pg_depend deptype ''e''). Default false (excluded).';
COMMENT ON COLUMN pgfc_observe.collection_policy.min_partition_size_bytes IS
  'Exclude CHILD partitions whose total size is below this many bytes. 0 disables the filter.';
COMMENT ON COLUMN pgfc_observe.collection_policy.excluded_schemas IS
  'Additional schemas to exclude, on top of the always-excluded system schemas.';

-- Seed the singleton with defaults so observe() always finds a policy row. Idempotent.
INSERT INTO pgfc_observe.collection_policy (singleton) VALUES (true)
ON CONFLICT (singleton) DO NOTHING;

-- ─────────────────────────────────────────────────────────────────────────────
-- Rollup tables  (Phase 1.5 S4 — long-range history after raw rotates away)
-- ─────────────────────────────────────────────────────────────────────────────
-- Raw samples are retained only 24–72 h (partition rotation, S2). Long-range trend
-- analysis reads these aggregate tiers instead, computed by rollup() (below) BEFORE the
-- raw partitions are truncated and kept far longer. Three tiers — 1-minute, 1-hour,
-- 1-day buckets — each a per-relation aggregate keyed (bucket_part, bucket_start, relid).
--
-- Like raw, retention is whole-partition rotation (zero dead tuples), but the partition
-- SPAN differs by tier so it stays between the bucket and the retention window: the fine
-- 1m tier (7 d) is partitioned DAILY; the coarse 1h/1d tiers (90 d / 365 d) MONTHLY.
--
-- Sparse-in, sparse-out: rollup() aggregates whatever raw rows exist in each bucket, so a
-- relation that was quiet for a bucket simply has no row there — exactly the raw sparsity
-- carried through. Readers carry forward the last known bucket (current_rollup(), below),
-- so a quiet relation is still answerable long after its last bucket.
--
-- Averages are SAMPLE-COUNT-WEIGHTED so a coarse tier built from a finer one matches what
-- it would have computed straight from raw. Cumulative counters (vacuum/analyze counts,
-- n_tup_*) are stored as the END-OF-BUCKET max; per-bucket deltas/rates are derived at read
-- (a counter delta across a gap or a first bucket is meaningless to bake in here).

-- One row per relation per 1-minute bucket. Daily RANGE partitioned (7-day window).
CREATE TABLE IF NOT EXISTS pgfc_observe.rollup_1m (
    bucket_part           integer     NOT NULL,   -- _epoch_day(bucket_start): daily partition key
    bucket_start          timestamptz NOT NULL,   -- start of the 1-minute bucket (UTC-aligned)
    relid                 oid         NOT NULL,
    schemaname            name        NOT NULL,
    relname               name        NOT NULL,
    sample_count          integer     NOT NULL,    -- raw samples folded into this bucket
    avg_dead_tup          double precision,
    max_dead_tup          bigint,
    avg_live_tup          double precision,
    max_live_tup          bigint,
    avg_mod_since_analyze double precision,
    max_mod_since_analyze bigint,
    avg_reltuples         double precision,        -- for dead/mod fraction at read time
    max_reltuples         bigint,
    max_relfrozenxid_age  bigint,                  -- max xid age over the bucket
    max_relminmxid_age    bigint,
    max_n_tup_ins         bigint,                  -- cumulative churn counters (end-of-bucket)
    max_n_tup_upd         bigint,
    max_n_tup_del         bigint,
    max_vacuum_count      bigint,                  -- cumulative (auto)vacuum/analyze counters
    max_autovacuum_count  bigint,
    max_analyze_count     bigint,
    max_autoanalyze_count bigint,
    avg_total_size_bytes  double precision,
    max_total_size_bytes  bigint,
    PRIMARY KEY (bucket_part, bucket_start, relid)
) PARTITION BY RANGE (bucket_part);
COMMENT ON TABLE pgfc_observe.rollup_1m IS
  'Per-relation 1-minute aggregate of raw samples (S4). Daily RANGE partitioned; ~7-day retention. Averages are sample-count-weighted; counters are end-of-bucket cumulative.';

-- One row per relation per 1-hour bucket. Monthly RANGE partitioned (~90-day window).
CREATE TABLE IF NOT EXISTS pgfc_observe.rollup_1h (
    bucket_part           integer     NOT NULL,   -- _epoch_month(bucket_start): monthly partition key
    bucket_start          timestamptz NOT NULL,   -- start of the 1-hour bucket (UTC-aligned)
    relid                 oid         NOT NULL,
    schemaname            name        NOT NULL,
    relname               name        NOT NULL,
    sample_count          integer     NOT NULL,
    avg_dead_tup          double precision,
    max_dead_tup          bigint,
    avg_live_tup          double precision,
    max_live_tup          bigint,
    avg_mod_since_analyze double precision,
    max_mod_since_analyze bigint,
    avg_reltuples         double precision,
    max_reltuples         bigint,
    max_relfrozenxid_age  bigint,
    max_relminmxid_age    bigint,
    max_n_tup_ins         bigint,
    max_n_tup_upd         bigint,
    max_n_tup_del         bigint,
    max_vacuum_count      bigint,
    max_autovacuum_count  bigint,
    max_analyze_count     bigint,
    max_autoanalyze_count bigint,
    avg_total_size_bytes  double precision,
    max_total_size_bytes  bigint,
    PRIMARY KEY (bucket_part, bucket_start, relid)
) PARTITION BY RANGE (bucket_part);
COMMENT ON TABLE pgfc_observe.rollup_1h IS
  'Per-relation 1-hour aggregate of the 1m tier (S4). Monthly RANGE partitioned; ~90-day retention.';

-- One row per relation per 1-day bucket. Monthly RANGE partitioned (~365-day window).
CREATE TABLE IF NOT EXISTS pgfc_observe.rollup_1d (
    bucket_part           integer     NOT NULL,   -- _epoch_month(bucket_start): monthly partition key
    bucket_start          timestamptz NOT NULL,   -- start of the 1-day bucket (UTC-aligned)
    relid                 oid         NOT NULL,
    schemaname            name        NOT NULL,
    relname               name        NOT NULL,
    sample_count          integer     NOT NULL,
    avg_dead_tup          double precision,
    max_dead_tup          bigint,
    avg_live_tup          double precision,
    max_live_tup          bigint,
    avg_mod_since_analyze double precision,
    max_mod_since_analyze bigint,
    avg_reltuples         double precision,
    max_reltuples         bigint,
    max_relfrozenxid_age  bigint,
    max_relminmxid_age    bigint,
    max_n_tup_ins         bigint,
    max_n_tup_upd         bigint,
    max_n_tup_del         bigint,
    max_vacuum_count      bigint,
    max_autovacuum_count  bigint,
    max_analyze_count     bigint,
    max_autoanalyze_count bigint,
    avg_total_size_bytes  double precision,
    max_total_size_bytes  bigint,
    PRIMARY KEY (bucket_part, bucket_start, relid)
) PARTITION BY RANGE (bucket_part);
COMMENT ON TABLE pgfc_observe.rollup_1d IS
  'Per-relation 1-day aggregate of the 1h tier (S4). Monthly RANGE partitioned; ~365-day retention.';

-- BRIN on the partition key (bloat-free range scans on the parent; see the raw tables for
-- the rationale) and a btree on (relid, bucket_start DESC) backing per-relation trend
-- queries and the carry-forward DISTINCT ON in current_rollup(). On the partitioned
-- parents, so every partition inherits both.
CREATE INDEX IF NOT EXISTS rollup_1m_bucket_part_brin ON pgfc_observe.rollup_1m USING brin (bucket_part);
CREATE INDEX IF NOT EXISTS rollup_1h_bucket_part_brin ON pgfc_observe.rollup_1h USING brin (bucket_part);
CREATE INDEX IF NOT EXISTS rollup_1d_bucket_part_brin ON pgfc_observe.rollup_1d USING brin (bucket_part);
CREATE INDEX IF NOT EXISTS rollup_1m_relid_idx ON pgfc_observe.rollup_1m (relid, bucket_start DESC);
CREATE INDEX IF NOT EXISTS rollup_1h_relid_idx ON pgfc_observe.rollup_1h (relid, bucket_start DESC);
CREATE INDEX IF NOT EXISTS rollup_1d_relid_idx ON pgfc_observe.rollup_1d (relid, bucket_start DESC);

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

-- Explicit per-table storage-parameter value if set, else NULL. Single source of
-- truth for "explicit reloption or fall back to the global default" (used by the
-- maintenance_debt view and, cross-schema, by the governor's estimator).
-- pg_options_to_table(NULL) yields no rows, so NULL reloptions => NULL result.
CREATE OR REPLACE FUNCTION pgfc_observe.effective_reloption(reloptions text[], opt text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT option_value
    FROM pg_options_to_table(reloptions)
    WHERE option_name = opt
$$;
COMMENT ON FUNCTION pgfc_observe.effective_reloption(text[], text) IS
  'Value of storage parameter opt in reloptions, or NULL if not explicitly set.';

-- The single observable that explains why vacuum may reclaim nothing: the oldest
-- xmin data horizon and the oldest catalog horizon, each with the age and owning
-- class of the oldest source. Inhibitor classes are different owners of these two
-- horizons. Cheap, STABLE; owner is 'none' when nothing is pinning.
-- The calling backend and non-client (e.g. autovacuum) backends are excluded so
-- the governor never attributes a pin to itself or to the cleaner.
CREATE OR REPLACE FUNCTION pgfc_observe.removability_horizons()
RETURNS TABLE (oldest_xmin_age bigint, oldest_xmin_owner text,
               oldest_xmin_owner_detail text,
               oldest_catalog_xmin_age bigint, oldest_catalog_xmin_owner text)
LANGUAGE sql STABLE AS $fn$
WITH sources AS (
    -- Class 1: long-running client transactions holding a snapshot (exclude self)
    SELECT backend_xmin AS x, 'long_running_txn'::text AS owner, pid::text AS detail
      FROM pg_stat_activity
     WHERE backend_xmin IS NOT NULL
       AND backend_type = 'client backend'
       AND pid <> pg_backend_pid()
    UNION ALL
    -- Class 2: replication slots pinning xmin
    SELECT xmin, 'replication_slot', slot_name
      FROM pg_replication_slots WHERE xmin IS NOT NULL
    UNION ALL
    -- Class 3: hot-standby feedback (walsender-reported xmin)
    SELECT backend_xmin, 'standby_feedback', application_name
      FROM pg_stat_replication WHERE backend_xmin IS NOT NULL
    UNION ALL
    -- Class 4: prepared (two-phase) transactions
    SELECT transaction, 'prepared_xact', gid
      FROM pg_prepared_xacts
), oldest AS (
    SELECT owner, detail, age(x) AS a
      FROM sources ORDER BY age(x) DESC LIMIT 1
), cat AS (   -- Class 5: catalog horizon pinned by logical replication slots
    SELECT slot_name, age(catalog_xmin) AS a
      FROM pg_replication_slots WHERE catalog_xmin IS NOT NULL
     ORDER BY age(catalog_xmin) DESC LIMIT 1
)
SELECT (SELECT a FROM oldest),
       COALESCE((SELECT owner FROM oldest), 'none'),
       (SELECT detail FROM oldest),
       (SELECT a FROM cat),
       COALESCE((SELECT slot_name FROM cat), 'none');
$fn$;
COMMENT ON FUNCTION pgfc_observe.removability_horizons() IS
  'Oldest xmin data/catalog removability horizons with attributed owner class.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Partition management  (Phase 1.5 S2)
-- ─────────────────────────────────────────────────────────────────────────────

-- Create the daily partition for p_day (default: today) on both telemetry tables if
-- it does not already exist. O(1): the partition name is derived deterministically
-- from the day, so this is a single catalog lookup + (at most) two CREATEs — no scan
-- of existing partitions. observe() calls it every run so the current day's partition
-- always exists before insert. Idempotent (IF NOT EXISTS); the duplicate_table catch
-- makes it race-safe if two observe() runs overlap at a day boundary.
CREATE OR REPLACE FUNCTION pgfc_observe._ensure_partition(
    p_day integer DEFAULT pgfc_observe._epoch_day(now()))
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    v_suffix text := to_char(to_timestamp(p_day * 86400) AT TIME ZONE 'UTC', 'YYYYMMDD');
BEGIN
    BEGIN
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS pgfc_observe.snapshots_p%s '
            'PARTITION OF pgfc_observe.snapshots FOR VALUES FROM (%s) TO (%s) '
            'WITH (%s)',
            v_suffix, p_day, p_day + 1, pgfc_observe._telemetry_reloptions());
    EXCEPTION WHEN duplicate_table THEN NULL;   -- concurrent run created it first
    END;
    BEGIN
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS pgfc_observe.relation_samples_p%s '
            'PARTITION OF pgfc_observe.relation_samples FOR VALUES FROM (%s) TO (%s) '
            'WITH (%s)',
            v_suffix, p_day, p_day + 1, pgfc_observe._telemetry_reloptions());
    EXCEPTION WHEN duplicate_table THEN NULL;
    END;
END
$fn$;
COMMENT ON FUNCTION pgfc_observe._ensure_partition(integer) IS
  'Create the daily partition for p_day (default today) on both telemetry tables if missing; O(1) and race-safe.';

-- One row per existing child partition of the telemetry tables, with its day, decoded
-- UTC range, estimated row count (pg_class.reltuples), and on-disk size. Backs the GC
-- functions and operator inspection. Reads pg_inherits, so it reflects live state.
CREATE OR REPLACE FUNCTION pgfc_observe._partition_inventory()
RETURNS TABLE (parent text, partition text, day integer,
               range_start timestamptz, range_end timestamptz,
               approx_rows bigint, size_bytes bigint)
LANGUAGE sql STABLE AS $fn$
    SELECT parent, partition, day,
           to_timestamp( day::bigint      * 86400) AS range_start,
           to_timestamp((day::bigint + 1) * 86400) AS range_end,
           approx_rows, size_bytes
    FROM (
        SELECT p.relname::text AS parent,
               c.relname::text AS partition,
               (regexp_match(pg_get_expr(c.relpartbound, c.oid),
                             'FROM \((\d+)\)'))[1]::integer AS day,
               GREATEST(c.reltuples, 0)::bigint AS approx_rows,
               pg_total_relation_size(c.oid)    AS size_bytes
        FROM pg_inherits i
        JOIN pg_class c     ON c.oid = i.inhrelid
        JOIN pg_class p     ON p.oid = i.inhparent
        JOIN pg_namespace n ON n.oid = p.relnamespace
        WHERE n.nspname = 'pgfc_observe'
          AND p.relname IN ('snapshots', 'relation_samples')
    ) s
    ORDER BY parent, day;
$fn$;
COMMENT ON FUNCTION pgfc_observe._partition_inventory() IS
  'Child partitions of the telemetry tables with day, decoded range, est. rows, and size.';

-- Generic single-partition ensure used by the rollup job (S4): create the partition of
-- p_parent covering int key p_key if missing. p_span ('day'|'month') only selects the
-- human-readable name suffix — the RANGE bound is always [p_key, p_key+1) in that span's
-- unit. Idempotent (IF NOT EXISTS) and race-safe (duplicate_table caught), matching
-- _ensure_partition. The raw tables keep their own _ensure_partition (called hot by
-- observe()); this serves the rollup parents, whose keys are days (1m) or months (1h/1d).
CREATE OR REPLACE FUNCTION pgfc_observe._ensure_part(
    p_parent text, p_key integer, p_span text)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
    v_suffix text := CASE p_span
        WHEN 'day'   THEN to_char(to_timestamp(p_key * 86400) AT TIME ZONE 'UTC', 'YYYYMMDD')
        WHEN 'month' THEN to_char(pgfc_observe._month_start(p_key) AT TIME ZONE 'UTC', 'YYYYMM')
    END;
BEGIN
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS pgfc_observe.%I PARTITION OF pgfc_observe.%I '
        'FOR VALUES FROM (%s) TO (%s) WITH (%s)',
        p_parent || '_p' || v_suffix, p_parent, p_key, p_key + 1,
        pgfc_observe._telemetry_reloptions());
EXCEPTION WHEN duplicate_table THEN NULL;   -- concurrent run created it first
END
$fn$;
COMMENT ON FUNCTION pgfc_observe._ensure_part(text, integer, text) IS
  'Create the [p_key, p_key+1) RANGE partition of p_parent if missing (p_span day|month names it). Idempotent/race-safe; used by rollup() (S4).';

-- One row per existing child partition of the three rollup tables, with its int key, span,
-- decoded UTC range, est. rows, and size. Backs rollup_retain() and operator inspection.
-- The 1m tier is day-spanned, the 1h/1d tiers month-spanned, so the range decode branches.
CREATE OR REPLACE FUNCTION pgfc_observe._rollup_inventory()
RETURNS TABLE (parent text, partition text, part_key integer, span text,
               range_start timestamptz, range_end timestamptz,
               approx_rows bigint, size_bytes bigint)
LANGUAGE sql STABLE AS $fn$
    SELECT parent, partition, part_key, span,
           CASE span WHEN 'day'   THEN to_timestamp(part_key::bigint * 86400)
                     WHEN 'month' THEN pgfc_observe._month_start(part_key)        END,
           CASE span WHEN 'day'   THEN to_timestamp((part_key::bigint + 1) * 86400)
                     WHEN 'month' THEN pgfc_observe._month_start(part_key + 1)    END,
           approx_rows, size_bytes
    FROM (
        SELECT p.relname::text AS parent,
               c.relname::text AS partition,
               (regexp_match(pg_get_expr(c.relpartbound, c.oid),
                             'FROM \((\d+)\)'))[1]::integer AS part_key,
               CASE p.relname WHEN 'rollup_1m' THEN 'day' ELSE 'month' END AS span,
               GREATEST(c.reltuples, 0)::bigint AS approx_rows,
               pg_total_relation_size(c.oid)    AS size_bytes
        FROM pg_inherits i
        JOIN pg_class c     ON c.oid = i.inhrelid
        JOIN pg_class p     ON p.oid = i.inhparent
        JOIN pg_namespace n ON n.oid = p.relnamespace
        WHERE n.nspname = 'pgfc_observe'
          AND p.relname IN ('rollup_1m', 'rollup_1h', 'rollup_1d')
    ) s
    ORDER BY parent, part_key;
$fn$;
COMMENT ON FUNCTION pgfc_observe._rollup_inventory() IS
  'Child partitions of the rollup tables with int key, span, decoded range, est. rows, and size.';

-- ─────────────────────────────────────────────────────────────────────────────
-- observe(): collect one snapshot (header + per-relation samples)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgfc_observe.observe()
RETURNS bigint   -- the new snapshot_id
LANGUAGE plpgsql AS $fn$
DECLARE
    v_snapshot_id bigint;
    v_day         integer := pgfc_observe._epoch_day(now());
    v_tat_expr    text;   -- total_autovacuum_time: real column on PG18+, else NULL
BEGIN
    -- Make sure today's partition exists before either insert (O(1), idempotent).
    PERFORM pgfc_observe._ensure_partition(v_day);

    -- Snapshot header: GUC defaults + pg_class catalog health. (xmin horizons are
    -- populated by a later increment; they default NULL here.)
    INSERT INTO pgfc_observe.snapshots (
        collected_day,
        server_version_num, def_vac_scale_factor, def_vac_threshold,
        def_ana_scale_factor, def_ana_threshold, def_vac_cost_limit,
        def_vac_cost_delay, def_freeze_max_age, def_mxid_freeze_max_age,
        autovacuum_max_workers, wal_bytes,
        pg_class_size_bytes, pg_class_n_dead_tup, pg_class_n_live_tup,
        pg_class_last_autovacuum,
        oldest_xmin_age, oldest_xmin_owner, oldest_xmin_owner_detail,
        oldest_catalog_xmin_age, oldest_catalog_xmin_owner)
    SELECT
        v_day,
        current_setting('server_version_num')::int,
        current_setting('autovacuum_vacuum_scale_factor')::float8,
        current_setting('autovacuum_vacuum_threshold')::bigint,
        current_setting('autovacuum_analyze_scale_factor')::float8,
        current_setting('autovacuum_analyze_threshold')::bigint,
        current_setting('autovacuum_vacuum_cost_limit')::int,
        -- cost_delay is a time-unit GUC ('2ms'); pg_settings.setting is unit-stripped
        (SELECT setting::float8 FROM pg_settings WHERE name = 'autovacuum_vacuum_cost_delay'),
        current_setting('autovacuum_freeze_max_age')::bigint,
        current_setting('autovacuum_multixact_freeze_max_age')::bigint,
        current_setting('autovacuum_max_workers')::int,
        (SELECT wal_bytes FROM pg_stat_wal),
        pg_total_relation_size('pg_catalog.pg_class'::regclass),
        c.n_dead_tup, c.n_live_tup, c.last_autovacuum,
        h.oldest_xmin_age, h.oldest_xmin_owner, h.oldest_xmin_owner_detail,
        h.oldest_catalog_xmin_age, h.oldest_catalog_xmin_owner
    FROM pg_stat_all_tables c
    CROSS JOIN pgfc_observe.removability_horizons() h
    WHERE c.relid = 'pg_catalog.pg_class'::regclass
    RETURNING snapshot_id INTO v_snapshot_id;

    -- Per-relation samples, sparse (S3): write a relation_samples row only where the
    -- current observed state differs from relation_last_state, then refresh the side
    -- table. One data-modifying statement: `cur` (current catalog state) is computed
    -- once and shared; `chg` diffs it against the PRIOR last_state (CTEs see the
    -- statement-start snapshot, so the upsert below does not perturb the diff); `ins`
    -- writes the changed rows; the trailing INSERT upserts last_state for EVERY current
    -- relation (data-modifying CTEs always run to completion even when unreferenced).
    -- The change signature is every event-driven observable plus the RAW frozen xids;
    -- the derived *_age columns are deliberately excluded (they tick up globally every
    -- run and would defeat sparsity), and are stored only for human/legacy reads —
    -- current_relation_state() recomputes them live. total_autovacuum_time is a PG18+
    -- column, so its source expression is built per major version.
    v_tat_expr := CASE WHEN current_setting('server_version_num')::int >= 180000
                       THEN 's.total_autovacuum_time'
                       ELSE 'NULL::double precision' END;

    EXECUTE format($q$
        WITH cfg AS (
            -- Collection policy (S5) as exactly one row, with safe defaults even if the
            -- singleton row was deleted (each scalar subquery yields at most one value, so
            -- a missing row reads as the default rather than collecting NOTHING). CROSS
            -- JOINed into relset so the filters read config without a join key.
            SELECT
                COALESCE((SELECT exclude_temp             FROM pgfc_observe.collection_policy WHERE singleton), true)         AS exclude_temp,
                COALESCE((SELECT include_extension_owned  FROM pgfc_observe.collection_policy WHERE singleton), false)        AS include_extension_owned,
                COALESCE((SELECT min_partition_size_bytes FROM pgfc_observe.collection_policy WHERE singleton), 0)            AS min_partition_size_bytes,
                COALESCE((SELECT excluded_schemas         FROM pgfc_observe.collection_policy WHERE singleton), '{}'::name[]) AS excluded_schemas
        ),
        relset AS (
            -- Candidate relations + observed state, after the non-size cardinality filters
            -- (S5). System schemas are ALWAYS excluded (literal list); excluded_schemas is
            -- additive on top so config can never re-include pg_catalog. The size threshold
            -- is applied one level out (cur) because it needs the computed total_size_bytes.
            SELECT
                s.relid, s.schemaname, s.relname,
                s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze, s.n_ins_since_vacuum,
                s.n_tup_ins, s.n_tup_upd, s.n_tup_del, s.n_tup_hot_upd,
                s.last_autovacuum, s.last_autoanalyze,
                s.vacuum_count, s.autovacuum_count, s.analyze_count, s.autoanalyze_count,
                %s                              AS total_autovacuum_time,
                c.reltuples, c.relpages, c.relallvisible,
                c.relfrozenxid, c.relminmxid,
                pg_relation_size(s.relid)       AS relation_size_bytes,
                pg_total_relation_size(s.relid) AS total_size_bytes,
                c.reloptions,
                c.relispartition                AS _relispartition,   -- filter helpers, not propagated
                cfg.min_partition_size_bytes    AS _min_part
            FROM pg_stat_all_tables s
            JOIN pg_class c ON c.oid = s.relid
            CROSS JOIN cfg
            WHERE s.schemaname NOT IN
                  ('pg_catalog','information_schema','pgfc_observe','pgfc_govern')
              AND c.relkind IN ('r','m','p')
              -- temporary tables: session-local churn, not the governor's concern. observe()
              -- runs in its own (cron) session and cannot see OTHER sessions' temp tables
              -- anyway, so this is cheap insurance against the caller's own pg_temp_N relations.
              AND (NOT cfg.exclude_temp OR c.relpersistence <> 't')
              -- additional operator-excluded schemas (additive to the system list above;
              -- <> ALL ('{}') is vacuously true, so an empty list excludes nothing extra)
              AND s.schemaname <> ALL (cfg.excluded_schemas)
              -- extension-owned relations (pg_depend deptype 'e') unless explicitly included
              AND (cfg.include_extension_owned
                   OR NOT EXISTS (SELECT 1 FROM pg_depend d
                                   WHERE d.classid     = 'pg_class'::regclass
                                     AND d.objid       = c.oid
                                     AND d.refclassid  = 'pg_extension'::regclass
                                     AND d.deptype     = 'e'))
        ),
        cur AS (
            -- Sub-threshold partition filter (S5): needs total_size_bytes from relset, so it
            -- is applied here rather than in relset's WHERE. Drop CHILD partitions
            -- (relispartition) smaller than the configured floor; 0 disables it; non-partition
            -- relations and partitioned parents are never size-filtered. The projection is
            -- exactly the dense per-relation signature (relset's helper columns are dropped),
            -- so chg/ins and the relation_last_state upsert below are unchanged.
            -- NOTE: a relation that still exists but is now EXCLUDED keeps its stale
            -- relation_last_state row — the end-of-observe() DELETE only purges VANISHED
            -- relids. Harmless and bounded by relation count; it re-samples correctly if
            -- later re-included. Deliberate (S5), not an oversight.
            SELECT
                relid, schemaname, relname,
                n_live_tup, n_dead_tup, n_mod_since_analyze, n_ins_since_vacuum,
                n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
                last_autovacuum, last_autoanalyze,
                vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
                total_autovacuum_time, reltuples, relpages, relallvisible,
                relfrozenxid, relminmxid, relation_size_bytes, total_size_bytes, reloptions
            FROM relset
            WHERE _min_part = 0 OR NOT _relispartition OR total_size_bytes >= _min_part
        ),
        chg AS (
            SELECT cur.* FROM cur
            LEFT JOIN pgfc_observe.relation_last_state ls ON ls.relid = cur.relid
            WHERE ls.relid IS NULL
               OR ROW(ls.schemaname, ls.relname,
                      ls.n_live_tup, ls.n_dead_tup, ls.n_mod_since_analyze, ls.n_ins_since_vacuum,
                      ls.n_tup_ins, ls.n_tup_upd, ls.n_tup_del, ls.n_tup_hot_upd,
                      ls.last_autovacuum, ls.last_autoanalyze,
                      ls.vacuum_count, ls.autovacuum_count, ls.analyze_count, ls.autoanalyze_count,
                      ls.total_autovacuum_time, ls.reltuples, ls.relpages, ls.relallvisible,
                      ls.relfrozenxid, ls.relminmxid,
                      ls.relation_size_bytes, ls.total_size_bytes, ls.reloptions)
                  IS DISTINCT FROM
                  ROW(cur.schemaname, cur.relname,
                      cur.n_live_tup, cur.n_dead_tup, cur.n_mod_since_analyze, cur.n_ins_since_vacuum,
                      cur.n_tup_ins, cur.n_tup_upd, cur.n_tup_del, cur.n_tup_hot_upd,
                      cur.last_autovacuum, cur.last_autoanalyze,
                      cur.vacuum_count, cur.autovacuum_count, cur.analyze_count, cur.autoanalyze_count,
                      cur.total_autovacuum_time, cur.reltuples, cur.relpages, cur.relallvisible,
                      cur.relfrozenxid, cur.relminmxid,
                      cur.relation_size_bytes, cur.total_size_bytes, cur.reloptions)
        ),
        ins AS (
            INSERT INTO pgfc_observe.relation_samples (
                snapshot_id, collected_day, relid, schemaname, relname,
                n_live_tup, n_dead_tup, n_mod_since_analyze, n_ins_since_vacuum,
                n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
                last_autovacuum, last_autoanalyze,
                vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
                total_autovacuum_time, reltuples, relpages, relallvisible,
                relfrozenxid_age, relminmxid_age, relfrozenxid, relminmxid,
                relation_size_bytes, total_size_bytes, reloptions)
            SELECT
                $1, $2, chg.relid, chg.schemaname, chg.relname,
                chg.n_live_tup, chg.n_dead_tup, chg.n_mod_since_analyze, chg.n_ins_since_vacuum,
                chg.n_tup_ins, chg.n_tup_upd, chg.n_tup_del, chg.n_tup_hot_upd,
                chg.last_autovacuum, chg.last_autoanalyze,
                chg.vacuum_count, chg.autovacuum_count, chg.analyze_count, chg.autoanalyze_count,
                chg.total_autovacuum_time, chg.reltuples, chg.relpages, chg.relallvisible,
                CASE WHEN chg.relfrozenxid::text <> '0' THEN age(chg.relfrozenxid) END,
                CASE WHEN chg.relminmxid::text  <> '0' THEN mxid_age(chg.relminmxid) END,
                chg.relfrozenxid, chg.relminmxid,
                chg.relation_size_bytes, chg.total_size_bytes, chg.reloptions
            FROM chg
            RETURNING 1
        )
        INSERT INTO pgfc_observe.relation_last_state AS ls (
            relid, schemaname, relname,
            n_live_tup, n_dead_tup, n_mod_since_analyze, n_ins_since_vacuum,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            last_autovacuum, last_autoanalyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            total_autovacuum_time, reltuples, relpages, relallvisible,
            relfrozenxid, relminmxid, relation_size_bytes, total_size_bytes, reloptions)
        SELECT
            cur.relid, cur.schemaname, cur.relname,
            cur.n_live_tup, cur.n_dead_tup, cur.n_mod_since_analyze, cur.n_ins_since_vacuum,
            cur.n_tup_ins, cur.n_tup_upd, cur.n_tup_del, cur.n_tup_hot_upd,
            cur.last_autovacuum, cur.last_autoanalyze,
            cur.vacuum_count, cur.autovacuum_count, cur.analyze_count, cur.autoanalyze_count,
            cur.total_autovacuum_time, cur.reltuples, cur.relpages, cur.relallvisible,
            cur.relfrozenxid, cur.relminmxid, cur.relation_size_bytes, cur.total_size_bytes, cur.reloptions
        FROM cur
        ON CONFLICT (relid) DO UPDATE SET
            schemaname = EXCLUDED.schemaname, relname = EXCLUDED.relname,
            n_live_tup = EXCLUDED.n_live_tup, n_dead_tup = EXCLUDED.n_dead_tup,
            n_mod_since_analyze = EXCLUDED.n_mod_since_analyze,
            n_ins_since_vacuum = EXCLUDED.n_ins_since_vacuum,
            n_tup_ins = EXCLUDED.n_tup_ins, n_tup_upd = EXCLUDED.n_tup_upd,
            n_tup_del = EXCLUDED.n_tup_del, n_tup_hot_upd = EXCLUDED.n_tup_hot_upd,
            last_autovacuum = EXCLUDED.last_autovacuum, last_autoanalyze = EXCLUDED.last_autoanalyze,
            vacuum_count = EXCLUDED.vacuum_count, autovacuum_count = EXCLUDED.autovacuum_count,
            analyze_count = EXCLUDED.analyze_count, autoanalyze_count = EXCLUDED.autoanalyze_count,
            total_autovacuum_time = EXCLUDED.total_autovacuum_time,
            reltuples = EXCLUDED.reltuples, relpages = EXCLUDED.relpages,
            relallvisible = EXCLUDED.relallvisible,
            relfrozenxid = EXCLUDED.relfrozenxid, relminmxid = EXCLUDED.relminmxid,
            relation_size_bytes = EXCLUDED.relation_size_bytes,
            total_size_bytes = EXCLUDED.total_size_bytes, reloptions = EXCLUDED.reloptions
    $q$, v_tat_expr)
    USING v_snapshot_id, v_day;

    -- Drop side-table entries for relations that no longer exist (dropped tables).
    -- Keeps last_state == the live relation set; a stale row is never a correctness
    -- bug (it can only match its own vanished relid), just unbounded growth over DDL.
    DELETE FROM pgfc_observe.relation_last_state ls
     WHERE NOT EXISTS (SELECT 1 FROM pg_class c WHERE c.oid = ls.relid);

    RETURN v_snapshot_id;
END
$fn$;
COMMENT ON FUNCTION pgfc_observe.observe() IS
  'Collect one snapshot: header (always) + per-relation samples for relations that pass collection_policy (S5) and whose observed state changed (sparse change-logging, S3).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Reader reconciliation  (Phase 1.5 S3)
-- ─────────────────────────────────────────────────────────────────────────────

-- The dense "current state of every relation as of snapshot p_as_of", reconstructed
-- from sparse storage. Sparse logging means a given snapshot only contains the
-- relations that CHANGED that run; the current state of a quiet relation is its most
-- recent earlier sample. So: DISTINCT ON (relid) the latest sample with
-- snapshot_id <= p_as_of (default: the newest snapshot).
--
-- Two reconciliations make the result equal to what dense collection would have stored
-- at p_as_of, so callers can swap `relation_samples WHERE snapshot_id = p` for this
-- function mechanically:
--   1. Live ages. relfrozenxid_age/relminmxid_age tick up globally every run and are
--      therefore not logged on change; recompute them live from the stored raw xids
--      (COALESCE back to the stored age for pre-S3 rows whose raw xid is NULL).
--   2. Stamp-as-of-p. The returned snapshot_id is p_as_of (not the older snapshot the
--      sample physically lives in), so a caller's `JOIN snapshots USING (snapshot_id)`
--      resolves the CURRENT cluster context (GUC defaults, horizons, collected_at) and
--      a `prev` query keyed on `snapshot_id < p` still finds the true prior sample —
--      a quiet relation then reads as delta 0 over a positive dt (rate 0), as intended.
CREATE OR REPLACE FUNCTION pgfc_observe.current_relation_state(p_as_of bigint DEFAULT NULL)
RETURNS TABLE (
    snapshot_id bigint, collected_day integer, relid oid, schemaname name, relname name,
    n_live_tup bigint, n_dead_tup bigint, n_mod_since_analyze bigint, n_ins_since_vacuum bigint,
    n_tup_ins bigint, n_tup_upd bigint, n_tup_del bigint, n_tup_hot_upd bigint,
    last_autovacuum timestamptz, last_autoanalyze timestamptz,
    vacuum_count bigint, autovacuum_count bigint, analyze_count bigint, autoanalyze_count bigint,
    total_autovacuum_time double precision, reltuples real, relpages integer, relallvisible integer,
    relfrozenxid_age bigint, relminmxid_age bigint,
    relation_size_bytes bigint, total_size_bytes bigint, reloptions text[])
LANGUAGE sql STABLE AS $fn$
    WITH target AS (
        SELECT COALESCE(p_as_of, (SELECT max(snapshot_id) FROM pgfc_observe.snapshots)) AS snap
    )
    SELECT DISTINCT ON (rs.relid)
        t.snap, rs.collected_day, rs.relid, rs.schemaname, rs.relname,
        rs.n_live_tup, rs.n_dead_tup, rs.n_mod_since_analyze, rs.n_ins_since_vacuum,
        rs.n_tup_ins, rs.n_tup_upd, rs.n_tup_del, rs.n_tup_hot_upd,
        rs.last_autovacuum, rs.last_autoanalyze,
        rs.vacuum_count, rs.autovacuum_count, rs.analyze_count, rs.autoanalyze_count,
        rs.total_autovacuum_time, rs.reltuples, rs.relpages, rs.relallvisible,
        COALESCE(age(NULLIF(rs.relfrozenxid, '0'::xid))::bigint, rs.relfrozenxid_age),
        COALESCE(mxid_age(NULLIF(rs.relminmxid, '0'::xid))::bigint, rs.relminmxid_age),
        rs.relation_size_bytes, rs.total_size_bytes, rs.reloptions
    FROM pgfc_observe.relation_samples rs, target t
    WHERE rs.snapshot_id <= t.snap
    ORDER BY rs.relid, rs.snapshot_id DESC
$fn$;
COMMENT ON FUNCTION pgfc_observe.current_relation_state(bigint) IS
  'Dense current state per relation as-of a snapshot, reconstructed from sparse storage with live-computed freeze ages (S3).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Rollups  (Phase 1.5 S4)
-- ─────────────────────────────────────────────────────────────────────────────

-- Roll raw samples up into the 1m/1h/1d aggregate tiers. Cascading: 1m is built from raw
-- relation_samples, 1h from 1m, 1d from 1h — each coarse average sample-count-weighted so
-- it equals what it would have computed straight from raw. Idempotent: every tier upserts
-- on its PK (recomputing a bucket overwrites it), so re-running is safe and late raw within
-- the window is absorbed.
--
-- MUST run before raw truncation — but the real guarantee is the raw RETENTION WINDOW, not
-- cron ordering: as long as rollup() runs at least once per raw-retention window (default
-- raw keep is 3 days; schedule rollup() daily), no raw bucket is lost. p_lookback bounds
-- the work to recent buckets and defaults to that window; the source cutoff is truncated to
-- each tier's unit so a partial coarse bucket is always recomputed in full.
CREATE OR REPLACE FUNCTION pgfc_observe.rollup(p_lookback interval DEFAULT '3 days')
RETURNS bigint   -- total rows upserted across the three tiers
LANGUAGE plpgsql AS $fn$
DECLARE
    v_total bigint := 0;
    v_n     bigint;
    d       integer;
    m       integer;
BEGIN
    -- Ensure the partitions covering the lookback window exist on every tier.
    FOR d IN SELECT generate_series(pgfc_observe._epoch_day(now() - p_lookback),
                                    pgfc_observe._epoch_day(now())) LOOP
        PERFORM pgfc_observe._ensure_part('rollup_1m', d, 'day');
    END LOOP;
    FOR m IN SELECT generate_series(pgfc_observe._epoch_month(now() - p_lookback),
                                    pgfc_observe._epoch_month(now())) LOOP
        PERFORM pgfc_observe._ensure_part('rollup_1h', m, 'month');
        PERFORM pgfc_observe._ensure_part('rollup_1d', m, 'month');
    END LOOP;

    -- Tier 1m ← raw relation_samples (UTC-aligned 1-minute buckets). Freeze ages are
    -- computed live from the raw xids here (rollup runs soon after collection), matching
    -- current_relation_state(); the legacy *_age columns are the pre-S3 fallback.
    INSERT INTO pgfc_observe.rollup_1m AS r (
        bucket_part, bucket_start, relid, schemaname, relname, sample_count,
        avg_dead_tup, max_dead_tup, avg_live_tup, max_live_tup,
        avg_mod_since_analyze, max_mod_since_analyze, avg_reltuples, max_reltuples,
        max_relfrozenxid_age, max_relminmxid_age,
        max_n_tup_ins, max_n_tup_upd, max_n_tup_del,
        max_vacuum_count, max_autovacuum_count, max_analyze_count, max_autoanalyze_count,
        avg_total_size_bytes, max_total_size_bytes)
    SELECT
        pgfc_observe._epoch_day(b.bucket_start), b.bucket_start, b.relid, b.schemaname, b.relname,
        b.sample_count,
        b.avg_dead_tup, b.max_dead_tup, b.avg_live_tup, b.max_live_tup,
        b.avg_mod_since_analyze, b.max_mod_since_analyze, b.avg_reltuples, b.max_reltuples,
        b.max_relfrozenxid_age, b.max_relminmxid_age,
        b.max_n_tup_ins, b.max_n_tup_upd, b.max_n_tup_del,
        b.max_vacuum_count, b.max_autovacuum_count, b.max_analyze_count, b.max_autoanalyze_count,
        b.avg_total_size_bytes, b.max_total_size_bytes
    FROM (
        SELECT rs.relid,
               date_trunc('minute', sn.collected_at, 'UTC') AS bucket_start,
               max(rs.schemaname) AS schemaname, max(rs.relname) AS relname,
               count(*)::integer  AS sample_count,
               avg(rs.n_dead_tup)::float8           AS avg_dead_tup,
               max(rs.n_dead_tup)                   AS max_dead_tup,
               avg(rs.n_live_tup)::float8           AS avg_live_tup,
               max(rs.n_live_tup)                   AS max_live_tup,
               avg(rs.n_mod_since_analyze)::float8  AS avg_mod_since_analyze,
               max(rs.n_mod_since_analyze)          AS max_mod_since_analyze,
               avg(GREATEST(rs.reltuples, 0))::float8         AS avg_reltuples,
               max(GREATEST(rs.reltuples, 0))::bigint         AS max_reltuples,
               max(COALESCE(age(NULLIF(rs.relfrozenxid, '0'::xid))::bigint, rs.relfrozenxid_age))   AS max_relfrozenxid_age,
               max(COALESCE(mxid_age(NULLIF(rs.relminmxid, '0'::xid))::bigint, rs.relminmxid_age))  AS max_relminmxid_age,
               max(rs.n_tup_ins) AS max_n_tup_ins,
               max(rs.n_tup_upd) AS max_n_tup_upd,
               max(rs.n_tup_del) AS max_n_tup_del,
               max(rs.vacuum_count)     AS max_vacuum_count,
               max(rs.autovacuum_count) AS max_autovacuum_count,
               max(rs.analyze_count)    AS max_analyze_count,
               max(rs.autoanalyze_count) AS max_autoanalyze_count,
               avg(rs.total_size_bytes)::float8 AS avg_total_size_bytes,
               max(rs.total_size_bytes)         AS max_total_size_bytes
        FROM pgfc_observe.relation_samples rs
        JOIN pgfc_observe.snapshots sn USING (snapshot_id)
        WHERE sn.collected_at >= now() - p_lookback
        GROUP BY rs.relid, date_trunc('minute', sn.collected_at, 'UTC')
    ) b
    ON CONFLICT (bucket_part, bucket_start, relid) DO UPDATE SET
        schemaname = EXCLUDED.schemaname, relname = EXCLUDED.relname,
        sample_count = EXCLUDED.sample_count,
        avg_dead_tup = EXCLUDED.avg_dead_tup, max_dead_tup = EXCLUDED.max_dead_tup,
        avg_live_tup = EXCLUDED.avg_live_tup, max_live_tup = EXCLUDED.max_live_tup,
        avg_mod_since_analyze = EXCLUDED.avg_mod_since_analyze,
        max_mod_since_analyze = EXCLUDED.max_mod_since_analyze,
        avg_reltuples = EXCLUDED.avg_reltuples, max_reltuples = EXCLUDED.max_reltuples,
        max_relfrozenxid_age = EXCLUDED.max_relfrozenxid_age,
        max_relminmxid_age = EXCLUDED.max_relminmxid_age,
        max_n_tup_ins = EXCLUDED.max_n_tup_ins, max_n_tup_upd = EXCLUDED.max_n_tup_upd,
        max_n_tup_del = EXCLUDED.max_n_tup_del,
        max_vacuum_count = EXCLUDED.max_vacuum_count,
        max_autovacuum_count = EXCLUDED.max_autovacuum_count,
        max_analyze_count = EXCLUDED.max_analyze_count,
        max_autoanalyze_count = EXCLUDED.max_autoanalyze_count,
        avg_total_size_bytes = EXCLUDED.avg_total_size_bytes,
        max_total_size_bytes = EXCLUDED.max_total_size_bytes;
    GET DIAGNOSTICS v_n = ROW_COUNT;  v_total := v_total + v_n;

    -- Tier 1h ← 1m, Tier 1d ← 1h. Same shape (monthly-partitioned, sample-count-weighted);
    -- only the source table and bucket unit differ, so they share one helper, which returns
    -- its own upsert count.
    SELECT pgfc_observe._rollup_coarsen('rollup_1h', 'rollup_1m', 'hour', p_lookback) INTO v_n;
    v_total := v_total + v_n;
    SELECT pgfc_observe._rollup_coarsen('rollup_1d', 'rollup_1h', 'day', p_lookback) INTO v_n;
    v_total := v_total + v_n;

    RETURN v_total;
END
$fn$;
COMMENT ON FUNCTION pgfc_observe.rollup(interval) IS
  'Cascade raw samples into the 1m/1h/1d rollup tiers (S4). Idempotent (per-PK upsert); run at least once per raw-retention window. Returns rows upserted.';

-- Coarsen one rollup tier into the next (1m→1h, 1h→1d). Aggregates p_src into p_dst on
-- UTC-aligned p_unit buckets, sample-count-weighting the averages and max-ing the rest, and
-- upserts on the destination PK. Returns the number of rows upserted (so rollup() can sum
-- it via ROW_COUNT). Kept as a helper because the two coarsen steps are identical bar the
-- source table, bucket unit, and partition-key function.
CREATE OR REPLACE FUNCTION pgfc_observe._rollup_coarsen(
    p_dst text, p_src text, p_unit text, p_lookback interval)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
    v_n bigint;
BEGIN
    EXECUTE format($q$
        INSERT INTO pgfc_observe.%I AS r (
            bucket_part, bucket_start, relid, schemaname, relname, sample_count,
            avg_dead_tup, max_dead_tup, avg_live_tup, max_live_tup,
            avg_mod_since_analyze, max_mod_since_analyze, avg_reltuples, max_reltuples,
            max_relfrozenxid_age, max_relminmxid_age,
            max_n_tup_ins, max_n_tup_upd, max_n_tup_del,
            max_vacuum_count, max_autovacuum_count, max_analyze_count, max_autoanalyze_count,
            avg_total_size_bytes, max_total_size_bytes)
        SELECT
            pgfc_observe._epoch_month(b.bucket_start), b.bucket_start, b.relid, b.schemaname, b.relname,
            b.sample_count,
            b.avg_dead_tup, b.max_dead_tup, b.avg_live_tup, b.max_live_tup,
            b.avg_mod_since_analyze, b.max_mod_since_analyze, b.avg_reltuples, b.max_reltuples,
            b.max_relfrozenxid_age, b.max_relminmxid_age,
            b.max_n_tup_ins, b.max_n_tup_upd, b.max_n_tup_del,
            b.max_vacuum_count, b.max_autovacuum_count, b.max_analyze_count, b.max_autoanalyze_count,
            b.avg_total_size_bytes, b.max_total_size_bytes
        FROM (
            SELECT s.relid,
                   date_trunc(%L, s.bucket_start, 'UTC') AS bucket_start,
                   max(s.schemaname) AS schemaname, max(s.relname) AS relname,
                   sum(s.sample_count)::integer AS sample_count,
                   sum(s.avg_dead_tup * s.sample_count) / NULLIF(sum(s.sample_count), 0)          AS avg_dead_tup,
                   max(s.max_dead_tup) AS max_dead_tup,
                   sum(s.avg_live_tup * s.sample_count) / NULLIF(sum(s.sample_count), 0)          AS avg_live_tup,
                   max(s.max_live_tup) AS max_live_tup,
                   sum(s.avg_mod_since_analyze * s.sample_count) / NULLIF(sum(s.sample_count), 0) AS avg_mod_since_analyze,
                   max(s.max_mod_since_analyze) AS max_mod_since_analyze,
                   sum(s.avg_reltuples * s.sample_count) / NULLIF(sum(s.sample_count), 0)         AS avg_reltuples,
                   max(s.max_reltuples) AS max_reltuples,
                   max(s.max_relfrozenxid_age) AS max_relfrozenxid_age,
                   max(s.max_relminmxid_age)   AS max_relminmxid_age,
                   max(s.max_n_tup_ins) AS max_n_tup_ins,
                   max(s.max_n_tup_upd) AS max_n_tup_upd,
                   max(s.max_n_tup_del) AS max_n_tup_del,
                   max(s.max_vacuum_count)     AS max_vacuum_count,
                   max(s.max_autovacuum_count) AS max_autovacuum_count,
                   max(s.max_analyze_count)    AS max_analyze_count,
                   max(s.max_autoanalyze_count) AS max_autoanalyze_count,
                   sum(s.avg_total_size_bytes * s.sample_count) / NULLIF(sum(s.sample_count), 0) AS avg_total_size_bytes,
                   max(s.max_total_size_bytes) AS max_total_size_bytes
            FROM pgfc_observe.%I s
            WHERE s.bucket_start >= date_trunc(%L, now() - $1, 'UTC')
            GROUP BY s.relid, date_trunc(%L, s.bucket_start, 'UTC')
        ) b
        ON CONFLICT (bucket_part, bucket_start, relid) DO UPDATE SET
            schemaname = EXCLUDED.schemaname, relname = EXCLUDED.relname,
            sample_count = EXCLUDED.sample_count,
            avg_dead_tup = EXCLUDED.avg_dead_tup, max_dead_tup = EXCLUDED.max_dead_tup,
            avg_live_tup = EXCLUDED.avg_live_tup, max_live_tup = EXCLUDED.max_live_tup,
            avg_mod_since_analyze = EXCLUDED.avg_mod_since_analyze,
            max_mod_since_analyze = EXCLUDED.max_mod_since_analyze,
            avg_reltuples = EXCLUDED.avg_reltuples, max_reltuples = EXCLUDED.max_reltuples,
            max_relfrozenxid_age = EXCLUDED.max_relfrozenxid_age,
            max_relminmxid_age = EXCLUDED.max_relminmxid_age,
            max_n_tup_ins = EXCLUDED.max_n_tup_ins, max_n_tup_upd = EXCLUDED.max_n_tup_upd,
            max_n_tup_del = EXCLUDED.max_n_tup_del,
            max_vacuum_count = EXCLUDED.max_vacuum_count,
            max_autovacuum_count = EXCLUDED.max_autovacuum_count,
            max_analyze_count = EXCLUDED.max_analyze_count,
            max_autoanalyze_count = EXCLUDED.max_autoanalyze_count,
            avg_total_size_bytes = EXCLUDED.avg_total_size_bytes,
            max_total_size_bytes = EXCLUDED.max_total_size_bytes
    $q$, p_dst, p_unit, p_src, p_unit, p_unit)
    USING p_lookback;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END
$fn$;
COMMENT ON FUNCTION pgfc_observe._rollup_coarsen(text, text, text, interval) IS
  'Aggregate one rollup tier into the next coarser one on UTC p_unit buckets (sample-count-weighted avgs); upsert into p_dst. Helper for rollup() (S4).';

-- Carry-forward reader: the latest known bucket per relation as-of p_as_of in tier p_tier
-- ('1m'|'1h'|'1d'). Mirrors current_relation_state() over the rollup tiers — sparse
-- storage means a quiet relation has no bucket for a given period, so DISTINCT ON (relid)
-- the most recent bucket at or before p_as_of. This is what makes a long-range query
-- answerable for a relation whose raw samples have long since rotated away.
CREATE OR REPLACE FUNCTION pgfc_observe.current_rollup(
    p_tier text DEFAULT '1m', p_as_of timestamptz DEFAULT now())
RETURNS TABLE (
    bucket_start timestamptz, relid oid, schemaname name, relname name, sample_count integer,
    avg_dead_tup double precision, max_dead_tup bigint,
    avg_live_tup double precision, max_live_tup bigint,
    avg_mod_since_analyze double precision, max_mod_since_analyze bigint,
    avg_reltuples double precision, max_reltuples bigint,
    max_relfrozenxid_age bigint, max_relminmxid_age bigint,
    max_n_tup_ins bigint, max_n_tup_upd bigint, max_n_tup_del bigint,
    max_vacuum_count bigint, max_autovacuum_count bigint,
    max_analyze_count bigint, max_autoanalyze_count bigint,
    avg_total_size_bytes double precision, max_total_size_bytes bigint)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_tbl text := CASE p_tier WHEN '1m' THEN 'rollup_1m'
                              WHEN '1h' THEN 'rollup_1h'
                              WHEN '1d' THEN 'rollup_1d' END;
BEGIN
    IF v_tbl IS NULL THEN
        RAISE EXCEPTION 'unknown rollup tier: %', p_tier
            USING HINT = 'use ''1m'', ''1h'', or ''1d''';
    END IF;
    RETURN QUERY EXECUTE format($q$
        SELECT DISTINCT ON (relid)
            bucket_start, relid, schemaname, relname, sample_count,
            avg_dead_tup, max_dead_tup, avg_live_tup, max_live_tup,
            avg_mod_since_analyze, max_mod_since_analyze, avg_reltuples, max_reltuples,
            max_relfrozenxid_age, max_relminmxid_age,
            max_n_tup_ins, max_n_tup_upd, max_n_tup_del,
            max_vacuum_count, max_autovacuum_count, max_analyze_count, max_autoanalyze_count,
            avg_total_size_bytes, max_total_size_bytes
        FROM pgfc_observe.%I
        WHERE bucket_start <= $1
        ORDER BY relid, bucket_start DESC
    $q$, v_tbl) USING p_as_of;
END
$fn$;
COMMENT ON FUNCTION pgfc_observe.current_rollup(text, timestamptz) IS
  'Carry-forward latest rollup bucket per relation as-of p_as_of in tier 1m|1h|1d (S4): answers long-range queries after raw rotates away.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Views (latest sample per relation; human-readable debt)
-- ─────────────────────────────────────────────────────────────────────────────

-- Latest observed state per relation (dense reconstruction over sparse storage).
CREATE OR REPLACE VIEW pgfc_observe.relation_health AS
SELECT rs.relid, rs.schemaname, rs.relname,
       rs.n_dead_tup, rs.n_live_tup, rs.reltuples,
       rs.relfrozenxid_age, rs.relminmxid_age,
       rs.last_autovacuum, rs.autovacuum_count,
       sn.collected_at
FROM pgfc_observe.current_relation_state() rs
JOIN pgfc_observe.snapshots sn USING (snapshot_id);

-- Target-space quantities (dead/stale fractions) and overdue indicators, using the
-- effective threshold = explicit reloption (this relation) ?? global default. The
-- defaults come from the LATEST snapshot (current_relation_state stamps snapshot_id =
-- newest), so a quiet relation's debt is computed against today's GUCs, not the stale
-- ones from whenever it last changed.
CREATE OR REPLACE VIEW pgfc_observe.maintenance_debt AS
WITH latest AS (
    SELECT rs.*, sn.def_vac_threshold, sn.def_vac_scale_factor,
           sn.def_ana_threshold, sn.def_ana_scale_factor, sn.def_freeze_max_age
    FROM pgfc_observe.current_relation_state() rs
    JOIN pgfc_observe.snapshots sn USING (snapshot_id)
), eff AS (
    -- reltuples is -1 for a never-analyzed table (PG14+); clamp to 0 so it reads as
    -- "unknown" (NULL fractions, threshold = base) rather than producing negatives.
    SELECT *,
      GREATEST(reltuples, 0) AS reltuples_est,
      COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_threshold')::bigint,
               def_vac_threshold)
      + COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_scale_factor')::float8,
                 def_vac_scale_factor) * GREATEST(reltuples, 0)              AS vacuum_threshold,
      COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_analyze_threshold')::bigint,
               def_ana_threshold)
      + COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_analyze_scale_factor')::float8,
                 def_ana_scale_factor) * GREATEST(reltuples, 0)             AS analyze_threshold
    FROM latest
)
SELECT relid, schemaname, relname,
       n_dead_tup, n_mod_since_analyze, reltuples,
       vacuum_threshold, analyze_threshold,
       -- target-space quantities: fraction of the table that is dead / stale
       (n_dead_tup::float8          / NULLIF(reltuples_est, 0))    AS dead_tuple_fraction,
       (n_mod_since_analyze::float8 / NULLIF(reltuples_est, 0))    AS mod_fraction,
       -- overdue indicators only (>1 => past trigger, waiting): not control setpoints
       (n_dead_tup::float8          / NULLIF(vacuum_threshold, 0)) AS vacuum_debt_ratio,
       (n_mod_since_analyze::float8 / NULLIF(analyze_threshold, 0)) AS analyze_debt_ratio,
       relfrozenxid_age::float8 / NULLIF(def_freeze_max_age, 0)     AS freeze_debt
FROM eff;

-- ─────────────────────────────────────────────────────────────────────────────
-- Storage budget + self-health  (Phase 1.5 S6)
-- ─────────────────────────────────────────────────────────────────────────────
-- The governor that watches the database every minute is a storage problem of its
-- own; these two surfaces make that footprint observable so it can be bounded.
--   storage_budget(): on-disk bytes and dead tuples per logical relation in this
--     schema. pg_partition_tree folds every child partition into its parent, so a
--     daily-partitioned table reports once (summed), not once per day. dead_tuples
--     should stay near zero by construction — raw/rollup tables rotate by
--     TRUNCATE/DROP, never DELETE — so a rising count is the signal that something is
--     wrong (the cross-schema pgfc_govern.degrade() reads bytes to enforce a cap).
CREATE OR REPLACE FUNCTION pgfc_observe.storage_budget()
RETURNS TABLE(relation text, bytes bigint, dead_tuples bigint)
LANGUAGE sql STABLE AS $fn$
    SELECT top.relname::text,
           COALESCE(sum(pg_total_relation_size(m.relid)), 0)::bigint,
           COALESCE(sum(st.n_dead_tup), 0)::bigint
    FROM pg_class top
    JOIN pg_namespace n ON n.oid = top.relnamespace
    -- The relation itself, plus its child partitions when partitioned. (pg_partition_tree
    -- returns NO rows for a plain table, so it cannot stand alone here — we always seed
    -- with top.oid and add only the descendant partitions.)
    CROSS JOIN LATERAL (
        SELECT top.oid AS relid
        UNION
        SELECT pt.relid FROM pg_partition_tree(top.oid) pt WHERE pt.relid <> top.oid
    ) m
    LEFT JOIN pg_stat_all_tables st ON st.relid = m.relid
    WHERE n.nspname = 'pgfc_observe'
      AND top.relkind IN ('r', 'p')      -- ordinary + partitioned parents
      AND NOT top.relispartition          -- children folded in via the tree
    GROUP BY top.relname
    ORDER BY top.relname;
$fn$;
COMMENT ON FUNCTION pgfc_observe.storage_budget() IS
  'Per-logical-relation on-disk bytes + dead tuples for the pgfc_observe schema (S6); child partitions folded into their parent.';

-- Single-row self-maintenance summary: is the storage model holding? total footprint,
-- aggregate dead tuples (should be ~0 — rotation, not DELETE), and partition counts /
-- oldest raw partition so an operator sees rotation is actually happening.
CREATE OR REPLACE VIEW pgfc_observe.self_health AS
SELECT
    (SELECT COALESCE(sum(bytes), 0)       FROM pgfc_observe.storage_budget()) AS total_bytes,
    (SELECT COALESCE(sum(dead_tuples), 0) FROM pgfc_observe.storage_budget()) AS total_dead_tuples,
    (SELECT count(*)        FROM pgfc_observe._partition_inventory())          AS raw_partitions,
    (SELECT count(*)        FROM pgfc_observe._rollup_inventory())             AS rollup_partitions,
    (SELECT min(range_start) FROM pgfc_observe._partition_inventory())         AS oldest_raw_partition;
COMMENT ON VIEW pgfc_observe.self_health IS
  'One-row self-maintenance summary for pgfc_observe (S6): total bytes, aggregate dead tuples, partition counts, oldest raw partition.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Parameter registry  (Phase 1.6 — parameter governance, P1)
-- ─────────────────────────────────────────────────────────────────────────────
-- The governor must not replace autovacuum folklore with folklore of its own: every
-- governed constant has a name, meaning, unit, rationale, owner, and provenance, and is
-- inspectable without reading source. This function is the canonical PROVENANCE registry
-- for pgfc_observe's governed constants. In P1 the control logic still defines and reads
-- its own literals — this is a separate, hand-maintained record of them. Making the code
-- READ from this function (the _profile_settings() pattern from pg_flight_recorder, which
-- makes code and registry unable to disagree) and the CI drift gate that enforces it
-- arrive in later increments (P2/P3).
-- category is one of: postgresql_derived | safety_bound | empirical_default |
-- operator_policy | adaptive_value | implementation_convenience.
-- override_allowed is orthogonal to category; config_ref names the override home
-- (NULL = a fixed code default). Values here MUST match the live code until the
-- single-sourcing increment removes the duplication.
CREATE OR REPLACE FUNCTION pgfc_observe._parameter_registry()
RETURNS TABLE(
    parameter_name   text,
    category         text,
    default_value    text,
    unit             text,
    rationale        text,
    source           text,
    owner            text,
    override_allowed boolean,
    config_ref       text)
LANGUAGE sql IMMUTABLE AS $fn$
VALUES
  ('epoch_day_seconds', 'postgresql_derived', '86400', 'seconds',
   'Seconds per day; the int4 daily RANGE partition key is whole days since 1970.',
   'calendar / PostgreSQL time math', 'maintainer', false, NULL),
  ('epoch_base_year', 'postgresql_derived', '1970', 'year',
   'Unix epoch base for the day/month partition keys.',
   'calendar / PostgreSQL time math', 'maintainer', false, NULL),
  ('telemetry_av_threshold', 'implementation_convenience', '1000', 'rows',
   'Static autovacuum vacuum/analyze/insert threshold on telemetry + rollup partitions (scale_factor 0).',
   'design review (S6)', 'maintainer', false, NULL),
  ('last_state_av_threshold', 'implementation_convenience', '50', 'rows',
   'Static, aggressive autovacuum threshold on the UNLOGGED relation_last_state cache.',
   'design review (S3)', 'maintainer', false, NULL),
  ('last_state_fillfactor', 'implementation_convenience', '70', 'percent',
   'fillfactor on relation_last_state so its per-minute updates stay HOT.',
   'design review (S3)', 'maintainer', false, NULL),
  ('retain_raw_days', 'operator_policy', '3', 'days',
   'Default raw-telemetry retention window before partitions are truncated.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'retain() argument'),
  ('drop_empty_partition_days', 'operator_policy', '30', 'days',
   'Default age before empty (truncated) partition shells are dropped.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'drop_empty_partitions() argument'),
  ('rollup_lookback', 'operator_policy', '3 days', 'interval',
   'Default rollup() lookback window; must cover at least one raw-retention window.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'rollup() argument'),
  ('retain_rollup_1m_days', 'operator_policy', '7', 'days',
   'Default retention for the fine (1m) rollup tier.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'rollup_retain() argument'),
  ('retain_rollup_1h_days', 'operator_policy', '90', 'days',
   'Default retention for the 1h rollup tier.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'rollup_retain() argument'),
  ('retain_rollup_1d_days', 'operator_policy', '365', 'days',
   'Default retention for the 1d rollup tier.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'rollup_retain() argument'),
  ('exclude_temp', 'operator_policy', 'true', 'boolean',
   'Whether observe() skips temporary tables.',
   'design review (S5)', 'operator', true, 'collection_policy.exclude_temp'),
  ('min_partition_size_bytes', 'operator_policy', '0', 'bytes',
   'Cardinality floor: child partitions below this size are not sampled (0 = disabled).',
   'MVP estimate — not yet benchmarked', 'operator', true, 'collection_policy.min_partition_size_bytes')
$fn$;
COMMENT ON FUNCTION pgfc_observe._parameter_registry() IS
  'Canonical provenance registry of pgfc_observe governed constants (Phase 1.6 P1). Documents the as-built values; the control logic does not yet read from it (single-sourcing + drift gate land in P2/P3). pgfc_govern.parameter_registry unions it into the operator-facing view.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Retention — two-tier partition GC  (Phase 1.5 S2)
-- ─────────────────────────────────────────────────────────────────────────────
-- Retention is whole-partition rotation, never row-by-row DELETE: that produces zero
-- dead tuples and zero bloat, so the governor never becomes its own vacuum burden.
--   Tier 1 — retain()                : nightly TRUNCATE of out-of-window partitions
--                                      (instant space reclaim; the empty shell stays)
--   Tier 2 — drop_empty_partitions() : monthly DROP of the long-empty shells
-- Two tiers because TRUNCATE reclaims space cheaply and often, while DROP changes the
-- partition set (briefly locks the parent), so it is batched rarely. Schedule e.g.:
--   SELECT cron.schedule('pgfc_observe_retain', '7 3 * * *',
--                        $$ SELECT pgfc_observe.retain() $$);
--   SELECT cron.schedule('pgfc_observe_gc', '23 4 1 * *',
--                        $$ SELECT pgfc_observe.drop_empty_partitions() $$);

-- Tier 1: TRUNCATE every partition whose whole day is older than `keep`. Truncating an
-- already-empty shell is skipped, so the count reflects partitions that held data.
CREATE OR REPLACE FUNCTION pgfc_observe.retain(keep interval DEFAULT '3 days')
RETURNS bigint   -- number of partitions truncated (that had data)
LANGUAGE plpgsql AS $fn$
DECLARE
    v_cutoff integer := pgfc_observe._epoch_day(now() - keep);
    v_count  bigint := 0;
    v_has    boolean;
    r        record;
BEGIN
    FOR r IN SELECT partition, day FROM pgfc_observe._partition_inventory()
             WHERE day < v_cutoff LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM pgfc_observe.%I)', r.partition)
            INTO v_has;
        IF v_has THEN
            EXECUTE format('TRUNCATE TABLE pgfc_observe.%I', r.partition);
            v_count := v_count + 1;
        END IF;
    END LOOP;
    RETURN v_count;
END
$fn$;
COMMENT ON FUNCTION pgfc_observe.retain(interval) IS
  'Tier-1 GC: TRUNCATE telemetry partitions older than keep (default 3 days). Returns partitions truncated.';

-- Tier 2: DROP partitions older than `keep` that are already empty (so a DROP never
-- destroys live data — a not-yet-truncated old partition is left for retain()).
CREATE OR REPLACE FUNCTION pgfc_observe.drop_empty_partitions(keep interval DEFAULT '30 days')
RETURNS bigint   -- number of empty partitions dropped
LANGUAGE plpgsql AS $fn$
DECLARE
    v_cutoff integer := pgfc_observe._epoch_day(now() - keep);
    v_count  bigint := 0;
    v_has    boolean;
    r        record;
BEGIN
    FOR r IN SELECT partition, day FROM pgfc_observe._partition_inventory()
             WHERE day < v_cutoff LOOP
        EXECUTE format('SELECT EXISTS (SELECT 1 FROM pgfc_observe.%I)', r.partition)
            INTO v_has;
        IF NOT v_has THEN
            EXECUTE format('DROP TABLE pgfc_observe.%I', r.partition);
            v_count := v_count + 1;
        END IF;
    END LOOP;
    RETURN v_count;
END
$fn$;
COMMENT ON FUNCTION pgfc_observe.drop_empty_partitions(interval) IS
  'Tier-2 GC: DROP empty telemetry partitions older than keep (default 30 days). Returns partitions dropped.';

-- Rollup retention (S4): cascading per-tier windows — the finer the tier, the shorter it
-- lives (1m 7 d, 1h 90 d, 1d 365 d; all overridable). Whole-partition DROP, never row-by-row
-- DELETE, so it stays zero-bloat like the raw tiers. Rollup partition counts are small
-- (≤7 daily for 1m; a handful of monthly for 1h/1d), so a single direct DROP of a partition
-- whose entire range is out of window is simpler than the raw tables' two-tier
-- truncate-then-drop. A partition is droppable only when its range_end is at/under the
-- cutoff, so a still-in-window partition is never dropped.
CREATE OR REPLACE FUNCTION pgfc_observe.rollup_retain(
    keep_1m interval DEFAULT '7 days',
    keep_1h interval DEFAULT '90 days',
    keep_1d interval DEFAULT '365 days')
RETURNS bigint   -- number of rollup partitions dropped
LANGUAGE plpgsql AS $fn$
DECLARE
    v_count bigint := 0;
    r       record;
    v_keep  interval;
BEGIN
    FOR r IN SELECT parent, partition, range_end FROM pgfc_observe._rollup_inventory() LOOP
        v_keep := CASE r.parent WHEN 'rollup_1m' THEN keep_1m
                                WHEN 'rollup_1h' THEN keep_1h
                                WHEN 'rollup_1d' THEN keep_1d END;
        IF r.range_end <= now() - v_keep THEN
            EXECUTE format('DROP TABLE pgfc_observe.%I', r.partition);
            v_count := v_count + 1;
        END IF;
    END LOOP;
    RETURN v_count;
END
$fn$;
COMMENT ON FUNCTION pgfc_observe.rollup_retain(interval, interval, interval) IS
  'Cascading rollup GC (S4): DROP rollup partitions past their per-tier window (1m 7d / 1h 90d / 1d 365d). Returns partitions dropped.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Bootstrap: ensure the current day's partition exists so a fresh install accepts
-- inserts immediately (observe() re-ensures on every run). Idempotent.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT pgfc_observe._ensure_partition();

-- Bootstrap the current rollup partitions too (S4), so a fresh install can rollup()
-- immediately; rollup() re-ensures the lookback window on every run. Idempotent.
SELECT pgfc_observe._ensure_part('rollup_1m', pgfc_observe._epoch_day(now()),   'day');
SELECT pgfc_observe._ensure_part('rollup_1h', pgfc_observe._epoch_month(now()), 'month');
SELECT pgfc_observe._ensure_part('rollup_1d', pgfc_observe._epoch_month(now()), 'month');

-- ─────────────────────────────────────────────────────────────────────────────
-- Additive upgrades  (see header)
-- ─────────────────────────────────────────────────────────────────────────────
-- When a future version adds a column, add an idempotent ALTER here so existing
-- installs gain it on re-run, e.g.:
--   ALTER TABLE pgfc_observe.relation_samples
--       ADD COLUMN IF NOT EXISTS n_tup_newpage_upd bigint;   -- PG16+, v0.0.2

-- S3: raw frozen xids backing the change signature + live age reconciliation. On an
-- existing (already-partitioned) install these add the columns; on a fresh install the
-- CREATE TABLE above already has them and these are no-ops. relation_last_state is
-- created by its CREATE UNLOGGED TABLE IF NOT EXISTS above, so it needs no ALTER here.
ALTER TABLE pgfc_observe.relation_samples ADD COLUMN IF NOT EXISTS relfrozenxid xid;
ALTER TABLE pgfc_observe.relation_samples ADD COLUMN IF NOT EXISTS relminmxid  xid;

-- S6: static autovacuum reloptions. New partitions get them in their WITH clause
-- (via _telemetry_reloptions in _ensure_partition/_ensure_part), but partitions
-- created before S6 won't — parent reloptions never propagate to children. Backfill
-- every existing raw and rollup partition idempotently (ALTER SET is a no-op when the
-- options already match). The partitioned parents themselves have no storage, so they
-- are skipped; the bootstrapped current-day partitions below are created with the
-- options already set.
DO $reloptions$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT partition FROM pgfc_observe._partition_inventory()
             UNION ALL
             SELECT partition FROM pgfc_observe._rollup_inventory() LOOP
        EXECUTE format('ALTER TABLE pgfc_observe.%I SET (%s)',
                       r.partition, pgfc_observe._telemetry_reloptions());
    END LOOP;
END
$reloptions$;
