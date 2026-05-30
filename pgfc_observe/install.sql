-- pgfc_observe — Observe + Orient (Phase 0; partition storage 1.5 S2; sparse 1.5 S3)
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
-- horizons (Appendix C). Cheap, STABLE; owner is 'none' when nothing is pinning.
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
  'Oldest xmin data/catalog removability horizons with attributed owner class (Appendix C).';

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
            'PARTITION OF pgfc_observe.snapshots FOR VALUES FROM (%s) TO (%s)',
            v_suffix, p_day, p_day + 1);
    EXCEPTION WHEN duplicate_table THEN NULL;   -- concurrent run created it first
    END;
    BEGIN
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS pgfc_observe.relation_samples_p%s '
            'PARTITION OF pgfc_observe.relation_samples FOR VALUES FROM (%s) TO (%s)',
            v_suffix, p_day, p_day + 1);
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
        WITH cur AS (
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
                c.reloptions
            FROM pg_stat_all_tables s
            JOIN pg_class c ON c.oid = s.relid
            WHERE s.schemaname NOT IN
                  ('pg_catalog','information_schema','pgfc_observe','pgfc_govern')
              AND c.relkind IN ('r','m','p')
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
  'Collect one snapshot: header (always) + per-relation samples only for relations whose observed state changed (sparse change-logging, S3).';

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

-- ─────────────────────────────────────────────────────────────────────────────
-- Bootstrap: ensure the current day's partition exists so a fresh install accepts
-- inserts immediately (observe() re-ensures on every run). Idempotent.
-- ─────────────────────────────────────────────────────────────────────────────
SELECT pgfc_observe._ensure_partition();

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
