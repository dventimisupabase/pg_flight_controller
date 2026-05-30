-- pgfc_observe — Observe + Orient (Phase 0)
--
-- Read-only telemetry for the pg_flight_controller autovacuum governor: periodic
-- snapshots of autovacuum-relevant state. Writes only to its own schema.
--
-- Re-runnable: this file is the upgrade path. Everything uses
-- CREATE SCHEMA IF NOT EXISTS / CREATE OR REPLACE / CREATE TABLE IF NOT EXISTS,
-- and schema changes are additive-only (new nullable columns; never drop/rename).

CREATE SCHEMA IF NOT EXISTS pgfc_observe;
COMMENT ON SCHEMA pgfc_observe IS
  'pg_flight_controller telemetry: snapshots of autovacuum-relevant state (read-only).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Tables
-- ─────────────────────────────────────────────────────────────────────────────

-- One row per observe() run: timestamp + cluster/GUC context, pg_class health,
-- and the xmin removability horizons, shared by all that run's relation samples.
CREATE TABLE IF NOT EXISTS pgfc_observe.snapshots (
    snapshot_id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
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
    oldest_catalog_xmin_owner text
);
COMMENT ON TABLE pgfc_observe.snapshots IS
  'Header row per observe() run: timestamp + cluster/GUC + pg_class health + xmin horizons.';

-- One row per relation per snapshot. Additive-only: new columns are nullable;
-- existing columns are never dropped or renamed.
CREATE TABLE IF NOT EXISTS pgfc_observe.relation_samples (
    snapshot_id          bigint NOT NULL
                         REFERENCES pgfc_observe.snapshots(snapshot_id) ON DELETE CASCADE,
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
    relfrozenxid_age     bigint,         -- age(relfrozenxid)
    relminmxid_age       bigint,         -- mxid_age(relminmxid)
    relation_size_bytes  bigint,
    total_size_bytes     bigint,
    -- rollback baseline for the governor: the table's explicit autovacuum reloptions
    reloptions           text[],
    PRIMARY KEY (snapshot_id, relid)
);
COMMENT ON TABLE pgfc_observe.relation_samples IS
  'Per-relation observed state for one snapshot. reloptions is the governor rollback baseline.';

CREATE INDEX IF NOT EXISTS relation_samples_relid_idx
    ON pgfc_observe.relation_samples (relid, snapshot_id DESC);

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
-- observe(): collect one snapshot (header + per-relation samples)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgfc_observe.observe()
RETURNS bigint   -- the new snapshot_id
LANGUAGE plpgsql AS $fn$
DECLARE
    v_snapshot_id bigint;
    v_tat_expr    text;   -- total_autovacuum_time: real column on PG18+, else NULL
BEGIN
    -- Snapshot header: GUC defaults + pg_class catalog health. (xmin horizons are
    -- populated by a later increment; they default NULL here.)
    INSERT INTO pgfc_observe.snapshots (
        server_version_num, def_vac_scale_factor, def_vac_threshold,
        def_ana_scale_factor, def_ana_threshold, def_vac_cost_limit,
        def_vac_cost_delay, def_freeze_max_age, def_mxid_freeze_max_age,
        autovacuum_max_workers, wal_bytes,
        pg_class_size_bytes, pg_class_n_dead_tup, pg_class_n_live_tup,
        pg_class_last_autovacuum,
        oldest_xmin_age, oldest_xmin_owner, oldest_xmin_owner_detail,
        oldest_catalog_xmin_age, oldest_catalog_xmin_owner)
    SELECT
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

    -- Per-relation samples. total_autovacuum_time exists only on PG18+, so the
    -- column reference is built per major version (one code path, not dynamic DML).
    v_tat_expr := CASE WHEN current_setting('server_version_num')::int >= 180000
                       THEN 's.total_autovacuum_time'
                       ELSE 'NULL::double precision' END;

    EXECUTE format($q$
        INSERT INTO pgfc_observe.relation_samples (
            snapshot_id, relid, schemaname, relname,
            n_live_tup, n_dead_tup, n_mod_since_analyze, n_ins_since_vacuum,
            n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
            last_autovacuum, last_autoanalyze,
            vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
            total_autovacuum_time,
            reltuples, relpages, relallvisible,
            relfrozenxid_age, relminmxid_age,
            relation_size_bytes, total_size_bytes, reloptions)
        SELECT
            $1, s.relid, s.schemaname, s.relname,
            s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze, s.n_ins_since_vacuum,
            s.n_tup_ins, s.n_tup_upd, s.n_tup_del, s.n_tup_hot_upd,
            s.last_autovacuum, s.last_autoanalyze,
            s.vacuum_count, s.autovacuum_count, s.analyze_count, s.autoanalyze_count,
            %s,
            c.reltuples, c.relpages, c.relallvisible,
            CASE WHEN c.relfrozenxid::text <> '0' THEN age(c.relfrozenxid) END,
            CASE WHEN c.relminmxid::text  <> '0' THEN mxid_age(c.relminmxid) END,
            pg_relation_size(s.relid), pg_total_relation_size(s.relid),
            c.reloptions
        FROM pg_stat_all_tables s
        JOIN pg_class c ON c.oid = s.relid
        WHERE s.schemaname NOT IN
              ('pg_catalog','information_schema','pgfc_observe','pgfc_govern')
          AND c.relkind IN ('r','m','p')
    $q$, v_tat_expr)
    USING v_snapshot_id;

    RETURN v_snapshot_id;
END
$fn$;
COMMENT ON FUNCTION pgfc_observe.observe() IS
  'Collect one snapshot: header (GUC defaults + pg_class health) and per-relation samples.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Views (latest sample per relation; human-readable debt)
-- ─────────────────────────────────────────────────────────────────────────────

-- Latest observed state per relation.
CREATE OR REPLACE VIEW pgfc_observe.relation_health AS
SELECT DISTINCT ON (rs.relid)
       rs.relid, rs.schemaname, rs.relname,
       rs.n_dead_tup, rs.n_live_tup, rs.reltuples,
       rs.relfrozenxid_age, rs.relminmxid_age,
       rs.last_autovacuum, rs.autovacuum_count,
       sn.collected_at
FROM pgfc_observe.relation_samples rs
JOIN pgfc_observe.snapshots sn USING (snapshot_id)
ORDER BY rs.relid, sn.snapshot_id DESC;

-- Target-space quantities (dead/stale fractions) and overdue indicators, using the
-- effective threshold = explicit reloption (this relation) ?? snapshot global default.
CREATE OR REPLACE VIEW pgfc_observe.maintenance_debt AS
WITH latest AS (
    SELECT DISTINCT ON (rs.relid)
           rs.*, sn.def_vac_threshold, sn.def_vac_scale_factor,
           sn.def_ana_threshold, sn.def_ana_scale_factor, sn.def_freeze_max_age
    FROM pgfc_observe.relation_samples rs
    JOIN pgfc_observe.snapshots sn USING (snapshot_id)
    ORDER BY rs.relid, sn.snapshot_id DESC
), eff AS (
    SELECT *,
      COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_threshold')::bigint,
               def_vac_threshold)
      + COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_scale_factor')::float8,
                 def_vac_scale_factor) * reltuples                            AS vacuum_threshold,
      COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_analyze_threshold')::bigint,
               def_ana_threshold)
      + COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_analyze_scale_factor')::float8,
                 def_ana_scale_factor) * reltuples                           AS analyze_threshold
    FROM latest
)
SELECT relid, schemaname, relname,
       n_dead_tup, n_mod_since_analyze, reltuples,
       vacuum_threshold, analyze_threshold,
       -- target-space quantities: fraction of the table that is dead / stale
       (n_dead_tup::float8          / NULLIF(reltuples, 0))        AS dead_tuple_fraction,
       (n_mod_since_analyze::float8 / NULLIF(reltuples, 0))        AS mod_fraction,
       -- overdue indicators only (>1 => past trigger, waiting): not control setpoints
       (n_dead_tup::float8          / NULLIF(vacuum_threshold, 0)) AS vacuum_debt_ratio,
       (n_mod_since_analyze::float8 / NULLIF(analyze_threshold, 0)) AS analyze_debt_ratio,
       relfrozenxid_age::float8 / NULLIF(def_freeze_max_age, 0)     AS freeze_debt
FROM eff;

-- ─────────────────────────────────────────────────────────────────────────────
-- Retention
-- ─────────────────────────────────────────────────────────────────────────────

-- Delete snapshots (and, via ON DELETE CASCADE, their relation_samples) older than
-- `keep`. The 1-min observe() cadence writes ~relations*1440 sample rows/day, so a
-- daily call keeps the telemetry bounded. Schedule with pg_cron in production, e.g.:
--   SELECT cron.schedule('pgfc_observe_retain', '7 3 * * *',
--                        $$ SELECT pgfc_observe.retain() $$);
CREATE OR REPLACE FUNCTION pgfc_observe.retain(keep interval DEFAULT '14 days')
RETURNS bigint   -- number of snapshots deleted
LANGUAGE sql AS $$
    WITH del AS (
        DELETE FROM pgfc_observe.snapshots
        WHERE collected_at < now() - keep
        RETURNING 1
    )
    SELECT count(*) FROM del;
$$;
COMMENT ON FUNCTION pgfc_observe.retain(interval) IS
  'Delete snapshots older than keep (default 14 days); relation_samples cascade.';
