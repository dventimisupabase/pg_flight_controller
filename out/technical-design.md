# pg_flight_controller — Technical Design (Phase I)

**Status:** Draft for implementation
**Scope:** Phase I — Autovacuum Governor MVP
**Audience:** Engineers building `pgfc_observe` and `pgfc_govern`
**Companion:** `pg_flight_controller.md` (vision/requirements). This document turns
that vision into concrete schemas, functions, views, state variables, algorithms,
and a phased build plan.

---

## 1. Design Frame

The single idea the rest of this document hangs on:

> The governor is an **outer control loop wrapped around autovacuum's own inner
> loop.** It never runs `VACUUM` or `ANALYZE` itself. It moves the **setpoints** —
> the per-table thresholds and scale factors — that decide *when* autovacuum's
> built-in controller fires and *how hard* it works.

Consequences that follow directly from this frame, and that shape every later
section:

- **All actuation is indirect.** We change a storage parameter; autovacuum decides
  what to do with it on its own schedule. We never get to act on the table
  directly.

- **There is actuation dead-time.** After we move a threshold, nothing observable
  happens until autovacuum next *evaluates* the table and then *runs*. That can be
  many ticks later. The control law must tolerate this delay or it will oscillate
  (Section 11).

- **The thing we regulate is the dead-tuple *fraction at trigger* — not the raw
  count, and deliberately not a "debt ratio."** Autovacuum fires when
  `dead_tuples > threshold + scale_factor * reltuples`, so the dead-tuple fraction
  *at the moment it fires* is `threshold/reltuples + scale_factor ≈ scale_factor`
  for any non-tiny table. That fraction — "how dirty we let the table get before
  cleanup" — is the quantity with real, near-unity gain on our actuator, and it
  maps straight onto policy intent ("low dead-tuple tolerance" = low fraction).
  A *debt ratio* `dead_tuples / threshold` is tempting but has **~zero steady-state
  gain**: when autovacuum keeps up, `dead_tuples` is a sawtooth running 0→threshold,
  so the ratio time-averages to ≈0.5 *regardless of the scale factor*. We therefore
  use the debt ratio only as an instantaneous **overdue indicator** (>1 = past
  trigger, waiting), never as a control setpoint. See §7.2 and §11.

- **Safety is a property of the inner loop we must never break.** We can make
  autovacuum more aggressive, but we must never configure a table such that
  anti-wraparound protection is delayed (Sections 12, 13).

- **Actuator movement has cost, so it is a second controlled variable.** Each
  actuator move is an `ALTER TABLE` with *three* costs: a **lock cost** (DDL takes a
  table-level lock that can fail, delay, or contend with maintenance — Appendix A), a
  **catalog cost** (it mutates `pg_class.reloptions`, and because catalogs are MVCC
  relations each change leaves dead tuples that can bloat `pg_class` — Appendix B),
  and an **opportunity cost** (the move may have *no effect at all* when an external
  inhibitor is preventing cleanup — Appendix C). The governor therefore regulates
  *two* things at once: (1) the maintenance state of each relation, and (2) the
  *frequency of its own actuator activity*. The optimal controller is not the one
  that hits the target fastest; it is the one that reaches convergence with the
  **minimum necessary catalog mutation**. This synergizes with the feedforward design
  (§7.2, §11): we compute a target, **quantize it to a coarse grid**, and hold it. It
  governs cadence (§14, §18), batching and locking (§12), quantization (§11), rate
  limits and a catalog-mutation budget (§16), catalog self-monitoring (§5, §15), and
  saturation/inhibitor diagnosis (§11.3).

- **The governor controls maintenance *progress*, not autovacuum (Appendix C).**
  "Vacuum ran" does not imply "cleanup happened" — vacuum can only remove tuples
  older than the cluster's xmin horizon, and an external inhibitor (a long-running
  transaction, a replication slot, a prepared transaction, hot-standby feedback) can
  pin that horizon so that vacuum runs and reclaims *nothing*. So the governor
  **measures outcomes, not commands**: when more actuator input stops producing
  maintenance progress (actuator saturation), it does not escalate further — it
  switches from control mode to **diagnosis mode**, attributes the inhibitor, and
  surfaces it (§11.3). More input ≠ more progress.

The operating doctrine, drawn from Appendices A–C: **Observe frequently. Estimate
continuously. Decide carefully. Mutate catalogs rarely. Diagnose before escalating.
Never wait.**

The autovacuum trigger formulas we are steering (PostgreSQL 15–18):

```text
vacuum threshold   = autovacuum_vacuum_threshold
                   + autovacuum_vacuum_scale_factor   * reltuples
analyze threshold  = autovacuum_analyze_threshold
                   + autovacuum_analyze_scale_factor  * reltuples
insert threshold   = autovacuum_vacuum_insert_threshold
                   + autovacuum_vacuum_insert_scale_factor * reltuples   (PG13+)

forced (anti-wraparound) vacuum when:
    age(relfrozenxid)        > autovacuum_freeze_max_age            (default 200M)
 or mxid_age(relminmxid)     > autovacuum_multixact_freeze_max_age  (default 400M)
```

Autovacuum fires a vacuum when `n_dead_tup > vacuum threshold`, an analyze when
`n_mod_since_analyze > analyze threshold`, and an insert-vacuum when
`n_ins_since_vacuum > insert threshold`. These are exactly the inequalities our
actuators move.

---

## 2. Architecture Decision: One Extension or Two?

`CLAUDE.md` pre-declares a two-extension split. The brief was to *revisit* that
decision rather than inherit it, so this section weighs it honestly and then
commits.

### 2.1 The two candidate boundaries

- **A — Single extension** (`pg_flight_controller`): one schema, one install, one
  version. `observe → classify → estimate → plan → apply → verify` all live
  together.

- **B — Two extensions** (`pgfc_observe`, `pgfc_govern`): telemetry/orientation in
  one, decision/actuation in the other; `pgfc_govern` depends on and reads
  `pgfc_observe` cross-schema, never writes to it.

### 2.2 Arguments examined

| Concern | Single (A) | Two (B) |
|---|---|---|
| Install / version simplicity | One unit, no cross-schema contract | Two units, dependency + additive contract to maintain |
| Coupling | Tightest possible | Loose; estimator reads observe snapshots only |
| Blast radius / trust | Telemetry and mutation share a trust boundary | Read-only telemetry deployable without ever granting actuation |
| Standalone value | All-or-nothing | `pgfc_observe` is a useful monitoring tool on its own |
| Upgrade cadence | Coupled | Observe schema evolves additively, independent of govern logic |

Two arguments that **do not survive scrutiny**, and which we explicitly drop:

- *"Deploy observe on replicas."* Standbys are read-only; `pgfc_observe` cannot
  write its snapshot tables there. This is not a reason for the split.

- *"Two extensions are inherently safer."* Schema separation alone is not a
  security boundary; both run in the same cluster. The real safety lever is
  Phase sequencing and the advisory-only mode (Section 18), not the package count.

### 2.3 Decision

**Adopt B (two extensions), for one argument that survives: trust/blast-radius
separation between read-only telemetry and setting mutation.** An operator can
install and run `pgfc_observe` everywhere with confidence that it touches nothing,
and only install `pgfc_govern` (and grant it actuation) where automated control is
wanted. The OODA mapping (Observe/Orient vs Decide/Act) is a pleasant alignment but
not the deciding factor.

The cost — a cross-schema contract — is bounded by making it **read-only and
additive-only** (Section 4). `pgfc_govern` declares `requires = 'pgfc_observe'`.

If during Phase 0 the observe schema proves not independently useful in practice,
collapsing to A is a mechanical merge; the reverse is not. Starting split keeps the
cheaper option open.

---

## 3. System Overview

```text
                pgfc_observe (Observe + Orient)
   ┌───────────────────────────────────────────────────┐
   │ observe()  → snapshots, relation_samples           │
   │ views: relation_health, maintenance_debt           │
   └───────────────────────────────┬───────────────────┘
                                    │ read-only, cross-schema
                                    ▼
                pgfc_govern (Decide + Act)
   ┌───────────────────────────────────────────────────┐
   │ FAST LOOP  observe_tick()  (pg_cron, ~1 min)       │
   │   classify() → relation_class                      │
   │   estimate() → relation_estimate (derived state)   │
   │                                                    │
   │ CONTROL LOOP  control_tick()  (pg_cron, ~5 min)    │
   │   plan()   → decision_log (proposed actions)       │
   │   apply()  → action_history, batched ALTER TABLE   │
   │             (≤1 change/relation/hour, 100ms lock)  │
   │   verify() → close the loop, mark outcomes         │
   │ views: governor_status                             │
   └───────────────────────────────────────────────────┘
                                    ▲
                      pg_cron: observe ~1 min · control ~5 min
```

Two entry points, two cadences (§14, §18): `observe_tick()` runs fast and never
acts; `control_tick()` runs slower and acts rarely. Observe frequently, act rarely.

---

## 4. Cross-Schema Contract

`pgfc_govern` reads `pgfc_observe` and never writes it. The contract is:

- **Read-only:** `pgfc_govern` has `SELECT` on observe tables/views, nothing more.

- **Additive-only:** observe may add nullable columns; it never removes or renames.
  Historical rows with `NULL` in a newer column mean "not collected then" — a valid
  value, not missing data. (Matches `CLAUDE.md` schema-evolution policy.)

- **Versioned read surface:** `pgfc_govern` reads through observe *views* where
  possible (`relation_health`, `maintenance_debt`), so the table layout can change
  underneath without breaking govern.

This is the entire coupling. Keeping it this thin is what makes the two-extension
split cheap.

---

## 5. Observable State (the inputs)

All observables come from system catalogs and cumulative stats views. Availability
notes matter because we test on PG 15–18 and the schema is additive.

### 5.1 Per-relation, from `pg_stat_all_tables`

| Column | Meaning | Notes |
|---|---|---|
| `n_live_tup`, `n_dead_tup` | live / dead tuple estimates | core signal |
| `n_mod_since_analyze` | mods since last analyze | drives analyze trigger |
| `n_ins_since_vacuum` | inserts since last vacuum | PG13+; insert-vacuum trigger |
| `n_tup_ins/upd/del` | cumulative DML counts | churn rate (deltas) |
| `n_tup_hot_upd` | HOT updates | cleanup-efficiency hint |
| `last_vacuum`, `last_autovacuum` | timestamps | dead-time / lag |
| `last_analyze`, `last_autoanalyze` | timestamps | analyze lag |
| `vacuum_count`, `autovacuum_count` | run counters | "did a vacuum happen since apply?" |
| `analyze_count`, `autoanalyze_count` | run counters | same, for analyze |
| `total_autovacuum_time` | cumulative ms in autovacuum | PG18+; burstiness/cost. Nullable on <18 |

### 5.2 Per-relation, from `pg_class`

| Source | Meaning |
|---|---|
| `reltuples`, `relpages` | row/page estimates (feed the trigger formula) |
| `relallvisible` | visibility-map coverage |
| `age(relfrozenxid)` | XID age → freeze debt |
| `mxid_age(relminmxid)` | MultiXact age → freeze debt |
| `reloptions` | **current explicit storage params** — the rollback baseline (Section 14) |
| `pg_relation_size`, `pg_total_relation_size` | bytes |

### 5.3 Cluster / GUC context (per snapshot)

- Effective global defaults for every actuator GUC (`current_setting(...)`), needed
  to compute thresholds for tables with no explicit reloption.
- `autovacuum_freeze_max_age`, `autovacuum_multixact_freeze_max_age` (denominators
  for freeze debt).
- `autovacuum_max_workers`, server version.
- `pg_stat_wal.wal_bytes` (cumulative) for WAL-generation context.
- **Catalog health (Appendix B):** `pg_class` size, live/dead tuples, and last
  autovacuum — the governor's own actuation mutates `pg_class.reloptions`, so it must
  watch the catalog it writes to. Sampled at the snapshot header, *not* into
  `relation_samples` (we never un-exclude `pg_catalog`; that would flood the table).
  The governor's *own* mutation rate is derived separately from `action_history`
  (§15), no extra storage.

### 5.3a Removability horizons (Appendix C — why cleanup may be impossible)

Vacuum can only remove a dead tuple older than the cluster's xmin horizon. An
external **inhibitor** can pin that horizon, so vacuum runs and reclaims nothing. The
six inhibitor classes of Appendix C are not six phenomena — they are different
*owners* of **two** horizons, which is how PostgreSQL actually computes removability.
We observe both, with the **age and the owning class** of whichever source is oldest:

- **`oldest_xmin` (data horizon)** = min xmin across: running transactions
  (`pg_stat_activity.backend_xmin`), replication slots (`pg_replication_slots.xmin`,
  including walsender slots that carry hot-standby feedback), and prepared
  transactions (`pg_prepared_xacts`). Owner class ∈ {long_running_txn,
  replication_slot, standby_feedback, prepared_xact}.
- **`oldest_catalog_xmin` (catalog horizon)** = min `catalog_xmin` across logical
  replication slots. A pinned catalog horizon is exactly the catalog bloat the
  Appendix B machinery *observes but cannot vacuum away* — Class 5 cross-links here.

These are cluster-level signals (snapshot header), the structural twins of the
catalog-health columns. Inhibitor **Class 6** (lock/interruption) is a *different*
mechanism — partial progress, not horizon pinning — and is already covered by
`lock_wait_outcome` / `vacuum_busy` (§12.2); it is not part of the horizon model.

### 5.4 Optional / best-effort

- `pg_stat_progress_vacuum` for in-flight vacuums. **Column layout changed in
  PG17** (`num_dead_tuples`/`max_dead_tuples` → byte-based counters). Observe it
  into nullable columns, version-guarded; do not make control depend on it in MVP.

---

## 6. `pgfc_observe` Schema (DDL)

```sql
CREATE SCHEMA IF NOT EXISTS pgfc_observe;

-- One row per collection run (a "tick" of observation).
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
    wal_bytes                numeric,        -- cumulative; NULL if unavailable
    -- catalog self-monitoring (Appendix B): cluster-level pg_class health.
    -- pg_catalog is NOT sampled into relation_samples (would flood it); we track
    -- just the catalog of concern here, at the snapshot header.
    pg_class_size_bytes      bigint,         -- pg_total_relation_size('pg_class')
    pg_class_n_dead_tup      bigint,         -- from pg_stat_all_tables for pg_class
    pg_class_n_live_tup      bigint,
    pg_class_last_autovacuum timestamptz,
    -- removability horizons (Appendix C): why cleanup may be impossible (§5.3a).
    oldest_xmin_age          bigint,         -- age() of the oldest DATA horizon
    oldest_xmin_owner        text,           -- class: long_running_txn | replication_slot
                                             --   | standby_feedback | prepared_xact | none
    oldest_xmin_owner_detail text,           -- pid / slot_name / gid for the operator
    oldest_catalog_xmin_age  bigint,         -- age() of the oldest CATALOG horizon
    oldest_catalog_xmin_owner text           -- usually a logical replication slot, else 'none'
);
COMMENT ON TABLE pgfc_observe.snapshots IS
  'Header row per observe() run: timestamp + cluster/GUC + pg_class health, shared by all samples.';

-- One row per relation per snapshot. Additive-only.
CREATE TABLE IF NOT EXISTS pgfc_observe.relation_samples (
    snapshot_id          bigint NOT NULL REFERENCES pgfc_observe.snapshots(snapshot_id) ON DELETE CASCADE,
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
    total_autovacuum_time double precision,   -- PG18+, nullable on older

    -- pg_class / derived sizes
    reltuples            real,
    relpages             integer,
    relallvisible        integer,
    relfrozenxid_age     bigint,         -- age(relfrozenxid)
    relminmxid_age       bigint,         -- mxid_age(relminmxid)
    relation_size_bytes  bigint,
    total_size_bytes     bigint,

    -- rollback baseline: the table's explicit autovacuum reloptions, if any
    reloptions           text[],

    PRIMARY KEY (snapshot_id, relid)
);
COMMENT ON TABLE pgfc_observe.relation_samples IS
  'Per-relation observed state for one snapshot. reloptions is the rollback baseline.';

CREATE INDEX IF NOT EXISTS relation_samples_relid_idx
    ON pgfc_observe.relation_samples (relid, snapshot_id DESC);
```

### 6.1 `observe()`

```sql
CREATE OR REPLACE FUNCTION pgfc_observe.observe()
RETURNS bigint   -- the new snapshot_id
LANGUAGE plpgsql AS $$
DECLARE
    v_snapshot_id bigint;
BEGIN
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
        current_setting('autovacuum_vacuum_cost_delay')::float8,
        current_setting('autovacuum_freeze_max_age')::bigint,
        current_setting('autovacuum_multixact_freeze_max_age')::bigint,
        current_setting('autovacuum_max_workers')::int,
        (SELECT wal_bytes FROM pg_stat_wal),
        pg_total_relation_size('pg_catalog.pg_class'::regclass),
        c.n_dead_tup, c.n_live_tup, c.last_autovacuum,
        h.oldest_xmin_age, h.oldest_xmin_owner, h.oldest_xmin_owner_detail,
        h.oldest_catalog_xmin_age, h.oldest_catalog_xmin_owner
    FROM pg_stat_all_tables c
    CROSS JOIN pgfc_observe.removability_horizons() h   -- §6.1a
    WHERE c.relid = 'pg_catalog.pg_class'::regclass
    RETURNING snapshot_id INTO v_snapshot_id;

    INSERT INTO pgfc_observe.relation_samples (
        snapshot_id, relid, schemaname, relname,
        n_live_tup, n_dead_tup, n_mod_since_analyze, n_ins_since_vacuum,
        n_tup_ins, n_tup_upd, n_tup_del, n_tup_hot_upd,
        last_autovacuum, last_autoanalyze,
        vacuum_count, autovacuum_count, analyze_count, autoanalyze_count,
        reltuples, relpages, relallvisible,
        relfrozenxid_age, relminmxid_age,
        relation_size_bytes, total_size_bytes, reloptions)
    SELECT
        v_snapshot_id, s.relid, s.schemaname, s.relname,
        s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze, s.n_ins_since_vacuum,
        s.n_tup_ins, s.n_tup_upd, s.n_tup_del, s.n_tup_hot_upd,
        s.last_autovacuum, s.last_autoanalyze,
        s.vacuum_count, s.autovacuum_count, s.analyze_count, s.autoanalyze_count,
        c.reltuples, c.relpages, c.relallvisible,
        age(c.relfrozenxid), mxid_age(c.relminmxid),
        pg_relation_size(s.relid), pg_total_relation_size(s.relid),
        c.reloptions
    FROM pg_stat_all_tables s
    JOIN pg_class c ON c.oid = s.relid
    WHERE s.schemaname NOT IN ('pg_catalog','information_schema',
                               'pgfc_observe','pgfc_govern')
      AND c.relkind IN ('r','m','p');   -- tables, matviews, partitioned

    RETURN v_snapshot_id;
END $$;
```

`total_autovacuum_time` (PG18+) is collected by a version-guarded variant; on older
servers the column stays `NULL`. Keep one code path simple per major version rather
than dynamic SQL where reasonable.

### 6.1a `removability_horizons()` — the inhibitor observable (Appendix C)

Computes the two horizons of §5.3a as one record: the oldest data-xmin and the
oldest catalog-xmin, each with the *age* and the *owning class* of the oldest source.
This is the single observable that explains why vacuum may reclaim nothing — and the
attributor the diagnostic logic (§11.3) keys on.

```sql
CREATE OR REPLACE FUNCTION pgfc_observe.removability_horizons()
RETURNS TABLE (oldest_xmin_age bigint, oldest_xmin_owner text,
               oldest_xmin_owner_detail text,
               oldest_catalog_xmin_age bigint, oldest_catalog_xmin_owner text)
LANGUAGE sql STABLE AS $$
WITH sources AS (   -- DATA horizon: each row is one candidate xmin and its owner
    SELECT backend_xmin AS x, 'long_running_txn' AS owner, pid::text AS detail
      FROM pg_stat_activity WHERE backend_xmin IS NOT NULL
    UNION ALL
    SELECT xmin, 'replication_slot', slot_name FROM pg_replication_slots
      WHERE xmin IS NOT NULL
    UNION ALL
    SELECT transaction::xid, 'prepared_xact', gid FROM pg_prepared_xacts
    -- standby_feedback surfaces as a walsender slot/backend xmin above; if a site
    -- runs hot_standby_feedback without a slot, add pg_stat_replication.backend_xmin.
), oldest AS (
    SELECT x, owner, detail, age(x) AS a FROM sources
    ORDER BY age(x) DESC LIMIT 1            -- oldest = largest age
), cat AS (   -- CATALOG horizon: logical slots pin catalog_xmin
    SELECT slot_name, age(catalog_xmin) AS a FROM pg_replication_slots
      WHERE catalog_xmin IS NOT NULL ORDER BY age(catalog_xmin) DESC LIMIT 1
)
SELECT (SELECT a FROM oldest), COALESCE((SELECT owner FROM oldest), 'none'),
       (SELECT detail FROM oldest),
       (SELECT a FROM cat),     COALESCE((SELECT slot_name FROM cat), 'none');
$$;
```

Cheap (a handful of small system views), `STABLE`, and the source columns should be
re-confirmed against pg_stat_activity / pg_replication_slots / pg_prepared_xacts at
scaffold time across PG 15–18.

### 6.2 Observe views

```sql
-- Latest sample per relation, with thresholds and debt computed for humans.
CREATE OR REPLACE VIEW pgfc_observe.relation_health AS
SELECT DISTINCT ON (rs.relid)
       rs.relid, rs.schemaname, rs.relname,
       rs.n_dead_tup, rs.n_live_tup, rs.reltuples,
       rs.relfrozenxid_age, rs.relminmxid_age,
       rs.last_autovacuum, rs.autovacuum_count,
       sn.collected_at
FROM pgfc_observe.relation_samples rs
JOIN pgfc_observe.snapshots sn USING (snapshot_id)
ORDER BY rs.relid, sn.collected_at DESC;

-- Effective-reloption helper: explicit per-table storage param if set, else NULL.
-- pg_options_to_table(NULL) yields no rows, so NULL reloptions → NULL result.
CREATE OR REPLACE FUNCTION pgfc_observe.effective_reloption(reloptions text[], opt text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT option_value
    FROM pg_options_to_table(reloptions)
    WHERE option_name = opt
$$;

-- Controlled variables (dead-tuple / mod fractions) plus overdue indicators.
-- Effective threshold = explicit reloption (this relation) ?? snapshot global default.
CREATE OR REPLACE VIEW pgfc_observe.maintenance_debt AS
WITH latest AS (
    SELECT DISTINCT ON (rs.relid) rs.*, sn.def_vac_threshold, sn.def_vac_scale_factor,
           sn.def_ana_threshold, sn.def_ana_scale_factor, sn.def_freeze_max_age
    FROM pgfc_observe.relation_samples rs
    JOIN pgfc_observe.snapshots sn USING (snapshot_id)
    ORDER BY rs.relid, sn.snapshot_id DESC
), eff AS (
    SELECT *,
      COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_threshold')::bigint,
               def_vac_threshold)
      + COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_scale_factor')::float8,
                 def_vac_scale_factor) * reltuples                          AS vacuum_threshold,
      COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_analyze_threshold')::bigint,
               def_ana_threshold)
      + COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_analyze_scale_factor')::float8,
                 def_ana_scale_factor) * reltuples                         AS analyze_threshold
    FROM latest
)
SELECT relid, schemaname, relname,
       n_dead_tup, n_mod_since_analyze, reltuples,
       vacuum_threshold, analyze_threshold,
       -- target-space quantities: fraction of the table that is dead / stale
       (n_dead_tup::float8          / NULLIF(reltuples,0))         AS dead_tuple_fraction,
       (n_mod_since_analyze::float8 / NULLIF(reltuples,0))         AS mod_fraction,
       -- overdue indicators only (>1 ⇒ past trigger, waiting): NOT control setpoints
       (n_dead_tup::float8          / NULLIF(vacuum_threshold,0))  AS vacuum_debt_ratio,
       (n_mod_since_analyze::float8 / NULLIF(analyze_threshold,0)) AS analyze_debt_ratio,
       relfrozenxid_age::float8 / NULLIF(def_freeze_max_age,0)      AS freeze_debt
FROM eff;
```

The `effective_reloption()` helper is the single source of truth for "explicit
per-table value or global default," reused by the estimator (Section 9). It must
compile and return correct values against a live PG 15–18 instance before §6 is
considered built — verify on first scaffold.

---

## 7. Derived State Variables (concrete formulas)

This is where "ready to build" is earned: every derived quantity is a formula over
observed columns, not a noun. All are computed by `estimate()` (Section 9) and
stored in `pgfc_govern.relation_estimate`.

Notation: subscripts `t` = current snapshot, `t-1` = previous; `Δs` = seconds
between them; `EWMA_α(x)` = `α·x + (1-α)·prev`, with `α = 1 - exp(-Δs/τ)` so the
smoothing is correct under irregular tick intervals (τ = configured time constant,
default 1 hour).

### 7.1 Effective thresholds (not stored; intermediate)

```text
vac_threshold  = effective(autovacuum_vacuum_threshold)
               + effective(autovacuum_vacuum_scale_factor)  * reltuples
ana_threshold  = effective(autovacuum_analyze_threshold)
               + effective(autovacuum_analyze_scale_factor) * reltuples
```

`effective(p)` = explicit reloption on the relation if present, else snapshot global
default.

### 7.2 Controlled variables and indicators

**The target is a dead-tuple fraction** (see §1 for why a debt ratio is the wrong
setpoint):

```text
dead_fraction   = n_dead_tup          / reltuples    -- instantaneous dirtiness
mod_fraction    = n_mod_since_analyze / reltuples    -- instantaneous staleness
```

Because autovacuum fires at `n_dead_tup > base + sf·reltuples`, the dead fraction at
trigger is `≈ base/reltuples + sf`, i.e. `≈ sf` for a large table. The scale factor
therefore has **near-unity gain** on the dead fraction — and that is precisely why
the keeping-up regime is controlled by *feedforward*, not measure-and-converge: we
know what a given `sf` produces, so the control law computes and sets it (§11). The
analyze loop treats `mod_fraction` vs `autovacuum_analyze_scale_factor` identically.

**Diagnostic estimator (logged, *not* a control input).** We still record the
realized dead fraction at trigger so `verify()` and operators can see what actually
happened:

```text
f_peak          = max over ticks since last autovacuum of dead_fraction   -- per cycle
f_trigger_ewma  = EWMA across cycles of f_peak, sampled when autovacuum_count++
```

This is **deliberately not fed to the control law.** `f_peak` is a peak-hold and is
biased low (and sampling-rate dependent): a whole vacuum cycle can occur between two
ticks — `n_dead_tup` sampled low before and after, `autovacuum_count` incremented,
peak never seen — and the bias is worst exactly for fast tables (`queue`, target
0.02–0.05) that vacuum near the tick interval. Using it as a setpoint would make the
most cleaning-sensitive tables drift dirtier. So it stays a diagnostic; feedback
comes from the overdue indicators below (§11.3).

**Indicators (observed, logged, but not control setpoints):**

```text
vacuum_debt_ratio   = n_dead_tup          / vac_threshold      -- >1 ⇒ overdue
analyze_debt_ratio  = n_mod_since_analyze / ana_threshold      -- >1 ⇒ overdue
freeze_debt         = relfrozenxid_age    / def_freeze_max_age  -- →1 ⇒ danger
mxid_freeze_debt    = relminmxid_age      / def_mxid_freeze_max_age
```

`vacuum_debt_ratio > 1` means the table is *past* its trigger and waiting on a
worker — a useful lag/overdue signal, but flat in steady state (§1), so it never
drives a correction. `freeze_debt` is observed and acted on for safety even though
freeze *parameters* are out of MVP scope (Section 13).

### 7.3 Rates and dynamics

```text
churn_rate      = EWMA_α( (Δn_tup_ins + Δn_tup_upd + Δn_tup_del) / Δs )   tuples/sec
dead_accum_rate = EWMA_α( Δn_dead_tup / Δs )                              tuples/sec
growth_rate     = EWMA_α( Δreltuples / Δs )                              tuples/sec

-- vacuum cycles observed since we last touched this table?
av_since_apply  = autovacuum_count_t - autovacuum_count_at_last_apply
```

`av_since_apply` counts completed vacuum cycles since our last change. It is **not** a
correction gate (the keeping-up move is feedforward, §11.1); it is consumed by
`verify()` to attribute outcomes and by the saturation-diagnosis K-cycle requirement
(§11.3), which must not declare a saturation cause before watching at least one cycle.

### 7.4 Cleanup efficiency, effectiveness, and lag

```text
-- dead tuples cleared per autovacuum run, observed across a run boundary
cleanup_per_run = max(0, n_dead_tup_{t-1} - n_dead_tup_t)
                  when autovacuum_count increased between t-1 and t

maintenance_lag = now() - (first snapshot where vacuum_debt_ratio crossed 1.0
                           without a subsequent autovacuum)
```

`maintenance_lag` measures observed actuation dead-time and is the empirical bound
on how often we may safely re-correct.

**Maintenance effectiveness (Appendix C) — the saturation discriminator.** Did a
vacuum that *ran* actually *remove* tuples? Directionally (Appendix C prefers
directional correctness over precision):

```text
-- per cycle in which autovacuum_count increased:
effective_cycle = (cleanup_per_run > ε) ? 1 : 0          -- did dead tuples drop?
effectiveness   = EWMA_α(effective_cycle)                -- smoothed over K cycles
```

Effectiveness is **smoothed, never judged off one cycle** — it inherits the exact
sampling-bias trap of `f_peak` (§7.2): a fast-churning `queue` table re-dirties in
the gap between 1-min observations, so a single before/after delta can read as low
effectiveness even when the vacuum worked. So we require *sustained* low
effectiveness before suspecting saturation, and treat the **xmin horizon (§5.3a) as
the dispositive attributor** — a horizon pinned old and not advancing is near
conclusive on its own; effectiveness just says "go look." Analogous freeze signal:
`freeze_progressing = (relfrozenxid_age dropped after a vacuum)`.

### 7.5 Burstiness

```text
burstiness = stddev(inter_autovacuum_intervals) / mean(inter_autovacuum_intervals)
```

Coefficient of variation of the gaps between autovacuum runs (derived from the
sequence of `last_autovacuum` changes across snapshots). High burstiness signals
threshold/scale settings that batch work into spikes — a smoothing target for later
phases.

---

## 8. Relation Classification

Tables are classified into `append_only`, `oltp`, `queue`, `delete_heavy`,
`archive`, `mixed`. Classification chooses the *desired-state template* (Section
10), so it must be stable — flapping classification would flap setpoints.

### 8.1 Signals (over a trailing window of snapshots)

```text
ins_frac = Σ n_tup_ins / Σ (n_tup_ins + n_tup_upd + n_tup_del)
upd_frac = Σ n_tup_upd / Σ (...)
del_frac = Σ n_tup_del / Σ (...)
write_rate = churn_rate
is_static  = write_rate ≈ 0 over the whole window
```

### 8.2 Rules (first match wins)

```text
is_static and size large                      → archive
ins_frac > 0.95 and del_frac < 0.01           → append_only
del_frac > 0.30 and del_frac ≈ ins_frac       → queue        (insert+delete churn)
del_frac > 0.30                               → delete_heavy
upd_frac > 0.30 and 0.05 < write_rate         → oltp
otherwise                                     → mixed
```

### 8.3 Hysteresis

A relation's class changes only after the rule has selected a *different* class for
N consecutive **observation cycles** (`classify()` runs in the 1-min fast loop, §14,
so N=3 ≈ 3 min) — this prevents flapping. Manual overrides (`source = 'manual'`) are
never auto-changed. Note the deliberate cadence asymmetry: reclassification settles
in minutes, but the actuator changes it implies are still gated by the control
loop's sustained-deviation and rate limits (§11.2), so a class flicker cannot
produce a DDL flurry.

```sql
CREATE TYPE pgfc_govern.relation_kind AS ENUM
  ('append_only','oltp','queue','delete_heavy','archive','mixed');
```

---

## 9. `pgfc_govern` Schema (DDL)

```sql
CREATE SCHEMA IF NOT EXISTS pgfc_govern;

-- ── Policy: operator intent, expressed as outcomes, not parameters ──────────
CREATE TABLE IF NOT EXISTS pgfc_govern.policy (
    policy_name        text PRIMARY KEY,
    description        text,
    -- target dead fractions per class are looked up from a template (Section 10),
    -- but a policy can scale aggressiveness and cap I/O globally:
    aggressiveness     double precision NOT NULL DEFAULT 1.0,  -- >1 = cleaner
    io_budget_fraction double precision,                       -- reserved (Phase 3)
    freeze_posture     text NOT NULL DEFAULT 'standard'        -- standard|conservative
                       CHECK (freeze_posture IN ('standard','conservative')),
    -- actuator-economy / catalog-mutation knobs (Appendix A & B, §11.2/§16)
    min_interval       interval NOT NULL DEFAULT '1 hour',     -- per-relation rate limit
    global_max_changes_per_cycle integer NOT NULL DEFAULT 50,  -- cluster cap / control cycle
    daily_mutation_budget integer NOT NULL DEFAULT 500,        -- cluster cap / day (App B)
    n_sustain          integer NOT NULL DEFAULT 3,             -- sustained-deviation cycles
    manage_user_owned  boolean NOT NULL DEFAULT false,         -- overwrite user-set reloptions?
    enabled            boolean NOT NULL DEFAULT true,
    advisory_only      boolean NOT NULL DEFAULT true            -- dry-run gate
);
COMMENT ON TABLE pgfc_govern.policy IS
  'Operator-expressed outcomes. advisory_only=true means plan but never apply.';
COMMENT ON COLUMN pgfc_govern.policy.manage_user_owned IS
  'false (default): never overwrite a reloption a user/other system set first '
  '(decision suppressed:user_owned). true: governor may take ownership.';

-- ── Classification ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pgfc_govern.relation_class (
    relid        oid PRIMARY KEY,
    schemaname   name NOT NULL,
    relname      name NOT NULL,
    kind         pgfc_govern.relation_kind NOT NULL,
    source       text NOT NULL DEFAULT 'auto' CHECK (source IN ('auto','manual')),
    candidate    pgfc_govern.relation_kind,        -- pending class (hysteresis)
    candidate_streak integer NOT NULL DEFAULT 0,
    classified_at timestamptz NOT NULL DEFAULT now()
);

-- ── Derived state (output of estimate()) ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS pgfc_govern.relation_estimate (
    relid               oid PRIMARY KEY,
    snapshot_id         bigint NOT NULL,
    -- realized-behavior diagnostics (§7.2): logged, NOT control inputs
    f_trigger_ewma      double precision,   -- realized dead fraction (≈ sf), peak-hold biased low
    mod_trigger_ewma    double precision,   -- realized mod fraction
    f_peak_current      double precision,   -- running peak this cycle
    -- indicators (logged; drive saturation diagnosis §11.3, not the keeping-up move)
    vacuum_debt_ratio   double precision,
    analyze_debt_ratio  double precision,
    freeze_debt         double precision,
    mxid_freeze_debt    double precision,
    -- rates / dynamics
    churn_rate          double precision,
    dead_accum_rate     double precision,
    growth_rate         double precision,
    cleanup_per_run     bigint,
    maintenance_lag     interval,
    burstiness          double precision,
    -- effectiveness & saturation (Appendix C, §7.4/§11.3)
    effectiveness       double precision,  -- EWMA: fraction of vacuums that cleaned
    freeze_progressing  boolean,           -- relfrozenxid advanced after recent vacuum?
    saturation_cause    text,              -- NULL | 'config' | 'io_limited' | 'inhibited'
    estimated_at        timestamptz NOT NULL DEFAULT now()
);

-- ── Actuator state: current value + rollback baseline ────────────────────────
CREATE TABLE IF NOT EXISTS pgfc_govern.actuator_state (
    relid              oid  NOT NULL,
    actuator           text NOT NULL,    -- e.g. 'autovacuum_vacuum_scale_factor'
    current_value      text,             -- value we last SET (NULL = never set)
    baseline_explicit  boolean NOT NULL, -- did the table have this reloption BEFORE us?
    baseline_value     text,             -- its value if baseline_explicit
    set_at_snapshot    bigint,           -- snapshot when we last applied
    av_count_at_apply  bigint,           -- autovacuum_count when applied (cycle counting: verify/regime)
    PRIMARY KEY (relid, actuator)
);
COMMENT ON COLUMN pgfc_govern.actuator_state.baseline_explicit IS
  'Rollback semantics: true ⇒ revert with SET to baseline_value; false ⇒ RESET.';

-- ── Audit: every decision, applied or not ────────────────────────────────────
CREATE TABLE IF NOT EXISTS pgfc_govern.decision_log (
    decision_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tick_id        bigint NOT NULL,
    relid          oid NOT NULL,
    actuator       text NOT NULL,
    observation    jsonb NOT NULL,   -- relevant observed values
    prev_state     jsonb NOT NULL,   -- relevant derived state
    desired_state  jsonb NOT NULL,   -- target setpoint(s)
    decision       text NOT NULL,    -- 'hold'|'adjust'|'suppressed:<reason>'
                                     -- |'escalate:io_limited'|'escalate:inhibited:<class>'
                                     -- suppressed reasons: rate_limited, daily_budget,
                                     -- user_owned, vacuum_busy, no_op, awaiting_sustain
    proposed_value text,             -- quantized grid value (§11.1)
    policy_rule    text,             -- which class/template/rule triggered this (App B)
    applied        boolean NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- ── Audit: attempted changes (revert source of truth, success AND failure) ───
-- One row per actuator. Actuators changed together in one ALTER TABLE share a
-- batch_id (and one applied_at) — see batching, §12.2. A row is written even when
-- the apply FAILS (status='failed'), capturing desired/attempted/reason/timestamp
-- per Appendix A "Actuator Failure Handling".
CREATE TABLE IF NOT EXISTS pgfc_govern.action_history (
    action_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id       bigint NOT NULL,  -- groups actuators applied in one DDL
    decision_id    bigint REFERENCES pgfc_govern.decision_log(decision_id),
    relid          oid NOT NULL,
    relname        text,             -- captured for audit even if relation later dropped
    actuator       text NOT NULL,
    old_value      text,             -- effective value before (read live, §12.2)
    new_value      text NOT NULL,    -- desired value (attempted, even if it failed)
    prev_reloptions text[],          -- full live pg_class.reloptions before the change (App B)
    revert_kind    text CHECK (revert_kind IN ('SET','RESET')),  -- NULL when status='failed'
    revert_value   text,             -- value to SET if revert_kind='SET'
    status         text NOT NULL DEFAULT 'applied'
                   CHECK (status IN ('applied','failed')),
    failure_reason text,             -- 'lock_timeout','insufficient_privilege',
                                     -- 'conflicting_maintenance','safety_restriction'
    lock_wait_outcome text,          -- 'acquired' | 'timeout' (App B logging list)
    -- budget_consumed: TRUE only for an applied, non-emergency catalog mutation.
    -- MUST be false for status='failed' (a lock-contention storm would otherwise
    -- burn the daily budget and self-inflict an outage) and for emergency overrides.
    budget_consumed boolean NOT NULL DEFAULT false,
    emergency_override boolean NOT NULL DEFAULT false, -- freeze bypass of budgets (App B)
    applied_at     timestamptz NOT NULL DEFAULT now(),
    reverted_at    timestamptz
);
COMMENT ON TABLE pgfc_govern.action_history IS
  'Every actuator attempt (applied or failed). revert() replays only status=applied '
  'after an ownership re-check against the live reloption (§12.3).';

-- ── Per-tick orchestration log ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS pgfc_govern.tick_log (
    tick_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    snapshot_id    bigint,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    n_relations    integer,
    n_decisions    integer,
    n_applied      integer,
    error          text
);

-- ── Diagnostic findings (Appendix C): saturation root-cause + recommendation ──
CREATE TABLE IF NOT EXISTS pgfc_govern.diagnostics (
    diagnostic_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    relid          oid,              -- NULL = cluster-level finding (e.g. pinned horizon)
    detected_at    timestamptz NOT NULL DEFAULT now(),
    severity       text NOT NULL DEFAULT 'warning'
                   CHECK (severity IN ('info','warning','critical')),
    inhibitor_class text,           -- long_running_txn|replication_slot|standby_feedback|
                                    --   prepared_xact|catalog_horizon|lock_conflict|io_limited
    evidence       jsonb NOT NULL,  -- the observations that triggered it (debt, av_count
                                    --   deltas, effectiveness, horizon age + owner detail)
    recommendation text,            -- templated, human-readable: "terminate PID 4242" etc.
    resolved_at    timestamptz      -- set when the condition clears (horizon advances)
);
COMMENT ON TABLE pgfc_govern.diagnostics IS
  'When control saturates, the cause + an actionable recommendation, not more DDL.';
```

---

## 10. Policy & Desired-State Model

A relation's **desired state** is a set of target setpoints, derived from its class
via a template, then scaled by policy `aggressiveness`.

### 10.1 Class → target dead-fraction template

The target is a **dead-tuple fraction** `f*` (§7.2). For a large table the scale
factor that achieves it is `sf ≈ f*`, so the column doubles as the scale-factor
target the control law converges to.

| Class | target dead fraction `f*` (vacuum) | target mod fraction (analyze) | freeze posture |
|---|---|---|---|
| `queue` | 0.02–0.05 (clean eagerly) | 0.05 | standard |
| `delete_heavy` | 0.05–0.10 | 0.10 | standard |
| `oltp` | 0.10–0.20 (≈ stock 0.2) | 0.10 | standard |
| `mixed` | 0.15–0.20 | 0.15 | standard |
| `append_only` | 0.20–0.40 (tolerate dead tuples) | 0.05 (stats matter for inserts) | watch freeze |
| `archive` | 0.40+ (minimal) | 0.40 | freeze-safety only |

A lower `f*` keeps the table cleaner than PostgreSQL's stock 0.2 scale factor; a
higher one tolerates more bloat to save maintenance I/O. The control law steers the
*observed* `f_trigger_ewma` toward `f*` by moving the scale factor (large tables) or
threshold (small tables, where the `base/reltuples` term dominates).

Policy scaling: `effective_f = template_f / aggressiveness`, clamped to the actuator
range `[0.01, 0.50]`. Higher aggressiveness ⇒ lower target fraction ⇒ cleaner
tables.

### 10.2 Why targets, not parameters

The operator sets `aggressiveness` and `freeze_posture`; they never touch a scale
factor. This is Principle 2 (Policy over Parameters) made concrete: policy selects
*targets*, the control law (Section 11) finds the *actuator values* that hold them.

---

## 11. Control Law

Evaluated once per **planning cycle** (§14, §18 — slower than observation), per
relation, per controlled objective. The gates below **are** the anti-oscillation
mechanism (Principle 4) *and* the enforcement of the second control objective —
minimum actuator activity (§1, Appendix A) — stated explicitly because of the
actuation dead-time established in Section 1.

### 11.1 The keeping-up move is feedforward, then quantized

Loop gain is ≈1 — the scale factor *is* the dead fraction at trigger (§7.2) — so the
keeping-up regime needs no measure-and-converge: we know what a given `sf` produces,
so we compute it and **snap it to a bounded grid**, then set it. The target setting
is feedforward from quantities known at plan time, then quantized:

```text
r          = effective_f                            target dead fraction (§10.1)
sf_cont    = clamp(r - base/reltuples, sf_min, sf_max)   continuous target
sf_target  = snap(sf_cont, SF_GRID)                 nearest allowed grid value (§11.4)
```

**Why quantize (Appendix B).** Each applied change mutates `pg_class.reloptions` —
an MVCC catalog write that creates dead tuples and risks catalog bloat. A continuous
target would drip endless tiny, unique per-table values into the catalog. Snapping to
a coarse grid bounds catalog entropy (most tables land on a handful of per-class
values) and makes `0.020→0.021` churn impossible by construction. It does not fight
feedforward — it *formalizes where feedforward already lands*: large tables have
`base/reltuples ≈ 0`, so `sf_cont ≈ r` = the class value and they already cluster at
a few values (§11.4); quantization just tightens an already-low entropy distribution
and gives the small-table threshold lever the same property.

The measured dead fraction (`f_trigger_ewma`, §7.2) is **not** an input here — it is
a logged diagnostic, and a biased one. Feedback enters only through saturation
diagnosis (§11.3). The analyze loop is identical:
`ana_sf_target = snap(clamp(mod_target - ana_base/reltuples, …), SF_GRID)`.

### 11.2 The gates (anti-oscillation + minimum catalog mutation)

A quantized proposal must clear three gates, in order, to become an applied change.
Because the target is already snapped to the grid (§11.1), there is **no continuous
deadband, gain (`Kp`), or per-cycle max-step** — the controller jumps directly to the
chosen grid value. (Those were artifacts of a continuous controller; with a quantized
feedforward target they would only manufacture off-grid intermediate values and turn
one logical correction into several catalog writes under the hourly limit — exactly
the churn Appendix B forbids. The grid spacing *is* the deadband and the
"minimum meaningful delta.")

Gates 1–2 are decided *tentatively* in `plan()` from the snapshot, but the live-catalog
versions of gates 1 (no-op) and the ownership check are **authoritatively enforced in
`apply()` under the lock** (§12.2) — `plan()`'s view is advisory.

1. **No-op vs the live catalog.** Read the relation's **current** `pg_class.reloptions`
   (the live value, read in `apply()` under the lock — not the stale snapshot or
   `actuator_state`, §12.2). If the quantized `sf_target` equals the value already in
   effect, do nothing (`decision = 'hold'`/`no_op`). Crucially this compares against the
   *effective* value including the inherited default: if `sf_target` equals the
   current **global default** and the table has no explicit reloption, the move is
   `RESET`-or-skip, **never** `SET` (writing an explicit reloption equal to today's
   default is a pointless mutation that also stops the table tracking future default
   changes — Appendix B "compare inherited/default setting").

2. **Sustained deviation (hysteresis vs transients).** The quantized target must
   select the *same grid value* for `N_sustain` consecutive planning cycles
   (default 3) before acting — so a momentary `reltuples` re-estimate or load spike
   that briefly flips the nearest grid point does not trigger DDL. A proposal that
   reverses the last applied direction is held unless it clears *two* grid levels,
   killing the `0.02→0.03→0.02` flap (Appendix A).

3. **Rate limit (three-tier) + budget.** At most one change per relation per
   `min_interval` (1h), at most `global_max_changes_per_cycle` per planning cycle, and
   at most `daily_mutation_budget` catalog mutations per day (§16, Appendix B). A
   proposal exceeding any tier is `suppressed:rate_limited` (or
   `suppressed:daily_budget`). Only the freeze emergency (§11.5) bypasses these.

### 11.3 Saturation → diagnosis (the only real feedback path)

Feedforward sets the *trigger point*; it cannot tell whether autovacuum can *keep*
that point — that is the one place observation carries information the actuator did
not already determine, and it is where the governor must measure **maintenance
progress, not commands** (Appendix C). When debt stays high, the governor classifies
*why* before doing anything, using three observables it already has:

```text
                       autovacuum_count        cleanup effectiveness     →  cause
                       incrementing?           (§7.4, EWMA, sustained)
config (not firing)    NO                      —                         →  suppressed:not_firing
                                                                            (hold + diagnose;
                                                                            actuator has NO authority)
io_limited             YES                     OK (vacuums DO drop dead   →  escalate:io_limited
                                               tuples; refills faster)
inhibited              YES                     ≈ 0 (vacuums run, dead     →  diagnose: inhibitor
                                               tuples do NOT drop)
```

So: **`autovacuum_count` delta separates `config` (not firing) from the
running-but-stuck causes; effectiveness separates `io_limited` from `inhibited`; the
xmin horizon (§5.3a) attributes *which* inhibitor.** All require ≥ K observed vacuum
cycles, so no cause is declared on a table the governor has not yet watched through a
cycle.

**A pinned, non-advancing horizon is a *necessary* condition for `inhibited` — low
effectiveness alone is not enough.** This is the dangerous cell: a fast-churning
`queue` table re-dirties between 1-min observations and reads as effectiveness ≈ 0
*even though vacuum worked* (the §7.4 sampling-bias trap), while its horizon is
perfectly healthy. Classifying that as `inhibited` would suppress actuation on a
table that genuinely needs it — the worse error direction. So: sustained low
effectiveness **with a healthy horizon is treated as measurement noise**, never as an
inhibitor; it falls through to `io_limited` only if debt is genuinely and persistently
high. `inhibited` requires the horizon evidence.

- **`config` (not firing)** — debt is high but autovacuum has not run. Because
  `debt_high` means `n_dead_tup` is *already over* the trigger, the table is already
  eligible — lowering the threshold/scale cannot make it fire. The actuator has **no
  authority** here, so the response is **hold + diagnose** (`suppressed:not_firing`):
  surface that autovacuum is not keeping up (disabled? worker-starved? just crossed
  and imminent?) instead of issuing a futile change. The genuinely *under-triggered,
  fixable* case — where the current setting is laxer than the class target — is
  **not** `debt_high`; it is the ordinary `saturation_cause IS NULL` regime, where
  feedforward lowers `sf` toward `f*` (§11.1–11.2). That normal control is not a
  saturation cause and does not pass through here.

- **`io_limited`** — vacuum fires and *does* reclaim, but churn outruns it. Lowering
  `sf` further is futile (the trigger is already always tripped). Emit
  `escalate:io_limited`, write a `diagnostics` row (resolved by Phase 3 cost actuators
  or more workers), and stop pushing the actuator.

- **inhibited** — vacuum fires but reclaims nothing because tuples are not removable.
  The dispositive evidence is the **horizon**: if `oldest_xmin` (or
  `oldest_catalog_xmin`) is pinned old and not advancing, attribute the
  `oldest_xmin_owner` class, emit `escalate:inhibited:<class>`, write a `diagnostics`
  row naming the owner (`pid` / `slot_name` / `gid`) with a templated recommendation,
  and **suppress further actuation** on the affected tables. More aggressiveness
  cannot help — only the operator clearing the inhibitor can. *Diagnose, don't
  escalate* (Appendix C).

Effectiveness is the *trigger to look*; the horizon is the *attributor*. A pinned,
non-advancing horizon is near-conclusive on its own, which is why we never declare an
inhibitor off a single noisy effectiveness sample (§7.4).

### 11.4 Actuator ranges and quantization grids

| Actuator | min | max | grid (allowed values) |
|---|---|---|---|
| `autovacuum_vacuum_scale_factor` (`sf_min`/`sf_max`) | 0.01 | 0.50 | `SF_GRID` = {0.01, 0.02, 0.05, 0.10, 0.20, 0.30, 0.50} |
| `autovacuum_vacuum_threshold` | 50 | 1e7 | `THR_GRID` log-spaced: {50, 100, 200, 500, 1k, 2k, 5k, 10k, …} |
| `autovacuum_analyze_scale_factor` | 0.01 | 0.50 | `SF_GRID` |
| `autovacuum_analyze_threshold` | 50 | 1e7 | `THR_GRID` |

Every applied value is one of these grid points (§11.1). The grids are configurable;
they are coarse on purpose — the spacing is the unit of meaningful change and the
bound on catalog entropy (Appendix B). **The threshold lever is quantized too, on a
log-spaced grid:** `base_target = r·reltuples` is inherently per-table and
per-`reltuples`, so without quantization small tables would be the *worst*
catalog-churn source, not the safest. Log spacing matches how thresholds matter
(ratios, not absolute counts).

**Which lever, by table size.** The two terms of `f_trigger = base/reltuples + sf`
trade dominance with table size, and that directly picks the lever: when
`sf·reltuples ≫ base` (large table) the scale factor controls the fraction, so snap
and move `sf` per §11.2; when `base ≳ sf·reltuples` (small table) the threshold
controls it, so snap `base_target = r·reltuples` to `THR_GRID` and move that instead,
with the same gate discipline.

**One lever per objective; batch across objectives.** Within the *vacuum* objective
we move `sf` **or** threshold, never both — they are substitutes for the same dead
fraction, and moving both would confound attribution. The same holds within the
*analyze* objective. But vacuum and analyze are *independent* objectives (they target
`n_dead_tup`/`autovacuum_count` vs `n_mod_since_analyze`/`autoanalyze_count`), so when
both want to move in the same cycle their changes are **batched into a single
`ALTER TABLE`** (§12.2) — one lock, ≤2 parameters. `verify()` still attributes each
separately because their effects are independently observable. Attribution is not
traded for the lock saving.

### 11.5 Safety override (inhibitor-aware)

Before any of the above: if `freeze_debt > freeze_action_threshold` (default 0.6) or
`mxid_freeze_debt > 0.6`, the relation is driven to its *cleanest* vacuum target
regardless of class (Section 13). Safety dominates (Principle 3).

**But escalation must be inhibitor-aware (Appendix C), and this nuance is exact —
the obvious simplification is a wraparound hole:**

- Inhibitor-awareness suppresses *further escalation and catalog churn* — it does
  **not** relax the standing aggressive posture. The §13 guard ("never reduce
  cleanup aggressiveness on a freeze-stressed table") still **dominates**. "Inhibitor
  present" must never become "back off vacuum."
- When `freeze_debt` is rising **and** `oldest_xmin`/`oldest_catalog_xmin` is pinned
  old by an attributed inhibitor, freezing *cannot* advance `relfrozenxid` past that
  horizon — so additional actuation is futile and only burns the budget the emergency
  path otherwise bypasses. The governor therefore **holds at cleanest, stops pushing
  the actuator, and raises a `critical` diagnostic naming the owner**. Its real value
  in this emergency is *diagnosis*: the fix is a human clearing the slot/txn.
- PostgreSQL *itself* forces anti-wraparound vacuum regardless of our settings, which
  is exactly why the governor hammering the actuator here adds nothing but churn —
  reinforcing diagnose-don't-escalate.

---

## 12. Actuators & `apply()`

### 12.1 MVP actuators

The six actuators named in the vision doc, **but cost-based two are deferred** for a
mechanical reason:

| Actuator | MVP? | Reason |
|---|---|---|
| `autovacuum_vacuum_scale_factor` | ✅ | primary dead-fraction lever |
| `autovacuum_vacuum_threshold` | ✅ | dead-fraction lever for small tables |
| `autovacuum_analyze_scale_factor` | ✅ | analyze freshness |
| `autovacuum_analyze_threshold` | ✅ | analyze freshness |
| `autovacuum_vacuum_cost_limit` | ⛔ Phase 3 | see below |
| `autovacuum_vacuum_cost_delay` | ⛔ Phase 3 | see below |

**Why cost params are deferred:** setting a per-table
`autovacuum_vacuum_cost_limit`/`cost_delay` removes that table from autovacuum's
cross-worker cost *balancing*. The PostgreSQL docs (Routine Vacuuming → The
Autovacuum Daemon, identical wording across PG 15–18) state it directly:

> "any workers processing tables whose per-table `autovacuum_vacuum_cost_delay` or
> `autovacuum_vacuum_cost_limit` storage parameters have been set are not considered
> in the balancing algorithm."

So using these as the "global I/O budget" actuator (a stated policy goal) would
*break* the very balancing it is meant to honor: each governed table would carve out
an independent, unbalanced I/O allowance. I/O-budget control needs a coherent
cluster-wide model (Phase 3), not a per-table poke. Until then `io_budget_fraction`
is reserved and unused.

### 12.2 `apply()` — batched, non-blocking, failure-recording

`apply()` takes **all** approved actuator changes for one relation in a planning
cycle (≤2: at most one vacuum lever + one analyze lever, §11.4) and applies them in a
**single `ALTER TABLE`** — one lock acquisition per relation, never one per
parameter (Appendix A, Batching).

```sql
-- Pseudocode; runs one relation's batch of approved decisions.
-- Pre-checks (skip the whole batch if any fail; record per §17):
--   * policy.advisory_only = false             (else: log decision, do not apply)
--   * per-relation, per-cycle, AND per-day budgets OK (§16; freeze bypasses all)
--   * no autovacuum in progress on relid (pg_stat_progress_vacuum)

SET LOCAL lock_timeout = '100ms';        -- "Never wait" (Appendix A): fail fast.

BEGIN
    -- 1. Take the lock implicitly via the DDL; but FIRST, under that lock, read the
    --    LIVE catalog as ground truth (the snapshot is up to a minute stale and
    --    actuator_state is only what we *think* we set):
    --      live := pg_class.reloptions for relid   (one cheap row)
    --    From `live` decide, per actuator (Appendix B):
    --      * NO-OP  : quantized target == live effective value      → skip, decision=no_op
    --      * RESET  : target == global default AND no explicit reloption → RESET, not SET
    --      * OWNED? : explicit reloption present that the governor never set
    --                 (no governor baseline) → user-owned; skip unless
    --                 policy.manage_user_owned, decision=suppressed:user_owned
    --    Capture prev_reloptions := live (full array) for the audit row.
    --
    -- 2. relkind dictates DDL and actuability:
    --    'r' table → ALTER TABLE · 'm' matview → ALTER MATERIALIZED VIEW ·
    --    'p' partitioned parent → NOT actuable (plan() targets the leaves).
    --    pg_stat_progress_vacuum pre-check + the 100ms lock_timeout are
    --    COMPLEMENTARY: the check avoids attempting against a known-busy table; the
    --    timeout bounds the attempt for a vacuum that starts in the race window.
    --    ALTER ... SET (...) takes SHARE UPDATE EXCLUSIVE (conflicts with vacuum).
    EXECUTE format(
      'ALTER %s %s %s',                       -- batched: SET and/or RESET clauses
      CASE relkind WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
      relid::regclass,
      clauses);   -- e.g. "SET (a = .05, b = 2000)" and/or "RESET (c)", one DDL
    -- success: one action_history row per actuator, shared batch_id, status='applied',
    --          lock_wait_outcome='acquired', prev_reloptions=live
EXCEPTION
    WHEN lock_not_available THEN
        -- abandon, record, retry next cycle. NOT a system failure (Appendix A).
        -- per intended actuator: status='failed', failure_reason='lock_timeout',
        -- lock_wait_outcome='timeout', new_value=desired. Atomic batch ⇒ no partial.
    WHEN insufficient_privilege THEN  -- failure_reason='insufficient_privilege'
    WHEN OTHERS THEN                  -- failure_reason=SQLSTATE/message
END;
```

Operational notes:

- **Live catalog is the single ground truth, and `apply()` is its authoritative
  arbiter.** No-op detection, ownership detection, and revert-safety (§12.3) all read
  the relation's current `pg_class.reloptions` under the apply lock — never the
  snapshot or `actuator_state`, which can miss a human's intervening change. Division
  of labor: `plan()` runs in `control_tick` holding no lock and sees only the
  (possibly stale) snapshot, so it decides *tentatively* — it may pre-suppress
  no-ops and user-owned cases it can already see, to avoid queueing pointless work.
  But `apply()` performs the **authoritative live re-check under the lock** and is
  the final arbiter: it can downgrade a plan-time `adjust` to `suppressed:no_op` or
  `suppressed:user_owned` when the live catalog differs from what the snapshot
  implied. The gates live in `apply()`; `plan()`'s view is advisory. (Implementers:
  do not duplicate the authoritative check in `plan()`.)

- **Atomic batch.** A single `ALTER TABLE` either sets all listed params or none, so
  there is no partial-apply state to reconcile — the batch shares one `batch_id` and
  one `applied_at`, and on failure every intended actuator gets a `status='failed'`
  row.

- **Actuated set = relkind `'r'` and `'m'` only.** Partitioned parents (`'p'`) are
  excluded from actuation in `plan()` (still observed); their leaves are governed
  individually — the apply-side resolution of the partitioning open question (§21).

- **Never block.** With `lock_timeout = 100ms` a contended `ALTER TABLE` fails fast,
  is recorded, and is retried in a future cycle. The governor never joins a lock
  queue (Appendix A: "never become a contributor to lock queues").

### 12.3 Rollback baseline capture (the correctness trap)

Reverting is **not** "set it back to the number it had." It is:

- If, *before the governor first touched it*, the table had an **explicit**
  reloption (`baseline_explicit = true`): revert with
  `ALTER TABLE … SET (actuator = baseline_value)`.

- If it was **inheriting the global default** (`baseline_explicit = false`): revert
  with `ALTER TABLE … RESET (actuator)` — *not* by writing the resolved number,
  which would freeze a now-stale default into the table.

`baseline_explicit` / `baseline_value` are captured from `pg_class.reloptions` in
`actuator_state` **the first time the governor *successfully* changes** each
(relation, actuator), and never overwritten afterward. A failed `ALTER TABLE`
touched nothing, so it must not record a baseline (and its `action_history` row has
`revert_kind = NULL`). This makes "every action reversible" (vision Safety System)
actually true.

`revert()` replays `action_history` rows with `status='applied'` only (failed
attempts changed nothing, so there is nothing to undo). Reverting a relation batches
its actuators back into one `ALTER TABLE` mixing `SET` and `RESET` per actuator —
one lock, consistent with §12.2.

**Revert is ownership-checked, not blind (Appendix B).** Before reverting an
actuator, `revert()` reads the **live** `pg_class.reloptions` and confirms the
current value still equals what the governor last applied. If it diverged — a human
or another system changed it after the governor did — revert **skips that actuator
and flags it** rather than clobbering the newer value. Blindly restoring an old value
over an intervening human change would itself be an unwanted mutation.

### 12.4 Actuator cost model (future, Phase 3)

The MVP treats every actuator move as having the same (high) cost and minimizes
moves via §11.2. A later phase may model cost explicitly — lock-acquisition risk, DDL
frequency, operational disruption, rollback complexity — and let `plan()` choose
between **(A)** changing storage parameters and **(B)** issuing one targeted
`VACUUM`/`ANALYZE` when that is cheaper for the expected benefit (Appendix A,
Actuator Cost Model). Option B is a different actuator class (an imperative command,
not a setpoint move) and is explicitly out of MVP scope; the two-objective framing
(§1) is what makes it expressible later.

---

## 13. Freeze Safety in the MVP

Freeze *actuators* (`freeze_min_age`, `freeze_table_age`, `freeze_max_age`) are
Phase 2+. But anti-wraparound dominates everything (Principle 3), so the MVP must
**observe and respond to freeze debt now** — using the actuators it already has.

- **Observe:** `freeze_debt = age(relfrozenxid)/autovacuum_freeze_max_age` and the
  MultiXact analogue are computed every observation cycle (Section 7.2).

- **Respond:** when `freeze_debt` crosses `freeze_action_threshold` (default 0.6),
  the safety override (Section 11.5) drives the relation's vacuum target to its
  cleanest setting. A normal autovacuum advances `relfrozenxid` (it opportunistically
  freezes), so making ordinary vacuum more eager *is* a valid wraparound mitigation
  with only the MVP's threshold/scale levers.

- **Inhibitor-aware (Appendix C):** if freeze debt rises while the xmin horizon is
  pinned old by an inhibitor (§5.3a), freezing cannot advance `relfrozenxid` — so the
  governor holds at cleanest, stops escalating, and raises a `critical` diagnostic
  naming the owner (§11.5). This does **not** relax aggressiveness; it stops *futile*
  escalation. A replication slot or long-running transaction driving a table toward
  wraparound is a real incident whose fix is clearing the inhibitor, not more vacuum.

- **Never:** the governor will not raise any threshold/scale factor on a relation
  whose `freeze_debt` is elevated, and (when freeze actuators arrive) will never set
  `freeze_max_age` upward past safe bounds. There is a hard guard in `plan()` that
  drops any proposed change that would *reduce* cleanup aggressiveness on a
  freeze-stressed table.

This way the doc neither pretends to tune freeze parameters in the MVP, ignores
wraparound, nor hammers a futile actuator when an inhibitor is the real cause.

---

## 14. Control-Loop Functions (multi-rate)

Appendix A mandates that observation run much faster than actuation. The loop is
therefore split into **two entry points on two cadences**, not one `tick()`:

```sql
-- Fast loop (observe + orient) — every ~1 min:
-- pgfc_observe.observe()        -> bigint  (fresh snapshot)
-- pgfc_govern.classify(snap)    -> int     (relations (re)classified, hysteresis)
-- pgfc_govern.estimate(snap)    -> int     (derived state written)
-- pgfc_govern.observe_tick()    -> bigint  (orchestrates the above; returns snap)

-- Control loop (decide + act + verify) — every ~5 min:
-- pgfc_govern.plan(cycle)       -> int     (decisions logged, reads latest estimate)
-- pgfc_govern.apply(cycle,relid)-> int     (one relation's batched change)
-- pgfc_govern.verify(cycle)     -> int     (attribute outcomes of PAST actions)
-- pgfc_govern.control_tick()    -> bigint  (orchestrates the above; returns cycle)
```

### 14.1 Fast loop: `observe_tick()` (every ~1 min)

```text
observe_tick():
  s := pgfc_observe.observe()    -- fresh snapshot (incl. xmin horizons, §6.1a)
  classify(s)                    -- update relation_class (+ hysteresis, §8.3)
  estimate(s)                    -- relation_estimate: EWMA, f_peak, indicators,
                                 --   effectiveness, freeze_progressing, saturation_cause
  return s
```

Cheap and read-only-to-the-database (writes only pgfc tables). Running it often
keeps rate estimates, `f_peak` peak-holds, and effectiveness EWMAs sharp, and —
crucially — **observing often does not mean acting often**: this loop never calls
`apply()`. `estimate()` also computes `saturation_cause` (config / io_limited /
inhibited, §11.3) so `plan()` can act on it; the attribution itself uses the
snapshot's horizon columns.

### 14.2 Control loop: `control_tick()` (every ~5 min)

```text
control_tick():
  c := open tick_log row
  n := plan(c)                   -- evaluate control law (§11) against latest estimate;
                                 --   if saturation_cause set: route to diagnosis
                                 --   (escalate:io_limited / escalate:inhibited:<class>,
                                 --   write diagnostics row, suppress actuation) instead
                                 --   of a futile move; else quantize → no-op(vs live
                                 --   catalog) → sustained → rate-limit/budget; log rows
  if not advisory_only:
    -- service order (caps, §16): freeze-emergency relations first (uncapped),
    -- then non-freeze ordered by actuator-delta (grid levels) desc, FIFO on ties,
    -- up to global_max_changes_per_cycle and the remaining daily_mutation_budget.
    -- Unserved relations are NOT dropped — their decision rows persist and they
    -- compete again next cycle (no starvation).
    for each relation in service order:
        apply(c, relid)          -- ONE batched ALTER TABLE per relation (§12.2)
  verify(c)                      -- attribute outcomes of PAST actions
  close tick_log row (counts, finished_at)
  return c
```

`plan()` reads the most recent `relation_estimate` (produced by the fast loop) — it
does not collect its own snapshot, so decision and observation cadences are
genuinely decoupled. The per-relation rate limit (≤1 change/hour) means most control
cycles apply *nothing*; that is the intended "Act Rarely" steady state.

`verify()` looks at actions applied in earlier cycles whose effect should now be
observable (`av_since_apply ≥ 1`) and checks the **overdue indicators**: did
`vacuum_debt_ratio` settle and the realized dead fraction move toward the class
target after the change? It logs the realized `f_trigger_ewma` as a diagnostic
(noting its peak-hold bias) and feeds `maintenance_lag`, effectiveness, and
saturation detection. It is the "Verify" step of the vision's control loop and the
basis for explainability — but it does not feed a correction back into the
feedforward move (§11.1); persistent failure to converge surfaces as a saturation
diagnosis — `escalate:io_limited` or `escalate:inhibited:<class>` (§11.3).

### 14.3 Advisory-only mode

`policy.advisory_only = true` (the default) runs both loops in full *including*
`plan()`, writing complete `decision_log` entries, but **never calls `apply()`**.
This is the safe default and the recommended Phase-1 operating mode: the governor
produces an auditable stream of "what I would do" with zero mutation. Flipping to
active control is a single policy change.

---

## 15. Views

```sql
-- One-stop operator view: per relation, current class, target, observed debt,
-- last decision, and whether we're actively controlling it.
CREATE OR REPLACE VIEW pgfc_govern.governor_status AS
SELECT rc.relid, rc.schemaname, rc.relname, rc.kind,
       re.f_trigger_ewma AS observed_dead_fraction,   -- diagnostic (peak-hold, biased low)
       /* effective_f from template×policy */ NULL::float8 AS target_dead_fraction,
       re.vacuum_debt_ratio, re.freeze_debt,           -- indicators (feedback signal)
       d.decision, d.proposed_value, d.applied, d.created_at AS last_decision_at,
       a.current_value AS current_scale_factor
FROM pgfc_govern.relation_class rc
LEFT JOIN pgfc_govern.relation_estimate re USING (relid)
LEFT JOIN LATERAL (
    SELECT * FROM pgfc_govern.decision_log dl
    WHERE dl.relid = rc.relid ORDER BY dl.created_at DESC LIMIT 1
) d ON true
LEFT JOIN pgfc_govern.actuator_state a
       ON a.relid = rc.relid
      AND a.actuator = 'autovacuum_vacuum_scale_factor';

-- Catalog-mutation health (Appendix B): the governor's own DDL footprint plus the
-- live pg_class condition. Mutation rates are a pure view over action_history — no
-- new storage; pg_class health comes from the latest snapshot header.
CREATE OR REPLACE VIEW pgfc_govern.catalog_health AS
SELECT
    (SELECT count(*) FROM pgfc_govern.action_history
      WHERE status='applied' AND applied_at > now() - interval '1 hour')   AS mutations_last_hour,
    (SELECT count(*) FROM pgfc_govern.action_history
      WHERE status='applied' AND applied_at > now() - interval '1 day')    AS mutations_last_day,
    (SELECT count(*) FROM pgfc_govern.action_history
      WHERE status='failed'  AND applied_at > now() - interval '1 day')    AS failed_last_day,
    (SELECT count(DISTINCT relid) FROM pgfc_govern.action_history
      WHERE status='applied' AND applied_at > now() - interval '1 day')    AS relations_changed_last_day,
    sn.pg_class_size_bytes, sn.pg_class_n_dead_tup, sn.pg_class_n_live_tup,
    sn.pg_class_last_autovacuum, sn.collected_at
FROM pgfc_observe.snapshots sn
ORDER BY sn.snapshot_id DESC
LIMIT 1;

-- Maintenance inhibitors / saturation findings the operator should act on
-- (Appendix C): unresolved diagnostics, newest first, with the actionable text.
CREATE OR REPLACE VIEW pgfc_govern.active_diagnostics AS
SELECT diagnostic_id, detected_at, severity, relid::regclass AS relation,
       inhibitor_class, recommendation, evidence
FROM pgfc_govern.diagnostics
WHERE resolved_at IS NULL
ORDER BY (severity = 'critical') DESC, detected_at DESC;
```

Plus the observe-side `relation_health` and `maintenance_debt` (Section 6.2).

**MVP surfaces catalog health; it does not yet brake on it.** A closed loop —
"`pg_class` dead tuples / size rising → tighten the mutation budget or pause
non-emergency actuation" — is a clean **Phase 2** addition but is deliberately out of
the MVP to avoid scope creep. The MVP's catalog protections are the *open-loop* ones:
quantization, no-op suppression, and the three-tier budget (§11, §16).

---

## 16. Safety System

Hard constraints, enforced in `plan()`/`apply()` (never disabled, vision Safety):

- **Never disable autovacuum.** The governor cannot set
  `autovacuum_enabled = false`; that GUC/reloption is not in the actuator set, and
  `apply()` rejects it defensively.

- **Never exceed freeze safety.** Section 13 guard; no change may reduce cleanup
  aggressiveness on a freeze-stressed relation.

- **Catalog-mutation budget — three tiers (Appendix B).** Per-relation: **max 1
  change per relation per `min_interval`** (1h). Per-cycle: **max
  `global_max_changes_per_cycle`** (thundering-herd guard). Per-day: **max
  `daily_mutation_budget`** catalog mutations cluster-wide. All tiers count only
  rows with `budget_consumed = true` (applied, non-emergency) — failed attempts and
  emergency overrides never consume budget, so lock contention cannot self-inflict an
  actuation outage by exhausting the day's allowance. When demand exceeds a
  cap, service order is **freeze-emergency first (uncapped), then non-freeze by
  largest actuator delta in grid levels, FIFO on ties**; unserved relations keep
  their decision rows and compete next cycle, so none starves. When the **daily cap
  itself halts actuation**, that is logged (decision `suppressed:daily_budget`) so
  "why is nothing happening?" is answerable. These are in addition to the §11.2
  gates. **Only the freeze emergency (§13) bypasses all three** — and when it does,
  the action is written with `emergency_override = true` and `budget_consumed =
  false` (Appendix B emergency logging).

- **No no-op DDL.** Never issue `ALTER TABLE` when the quantized target already
  equals the live effective value; if it equals the global default and no explicit
  reloption exists, `RESET`/skip rather than `SET` (§11.2, §12.2).

- **Respect setting ownership.** A relation whose reloption was set by a user or
  another system *before* the governor first touched it (`actuator_state` has no
  governor baseline for it) is **user-owned**; the governor will not overwrite it
  unless `policy.manage_user_owned = true`. Otherwise the decision is
  `suppressed:user_owned`. Governor-owned, inherited-default, and emergency-override
  states are tracked distinctly (Appendix B "Setting Ownership").

- **Diagnose, don't escalate (Appendix C).** When `saturation_cause` is set (§11.3),
  the governor stops spending actuator budget — `io_limited` and especially
  `inhibited` mean more DDL cannot produce maintenance progress (its third cost,
  opportunity cost, §1). It writes a `diagnostics` finding and suppresses actuation on
  the affected relations instead of repeatedly increasing aggressiveness. This even
  governs the freeze emergency path (§11.5): futile escalation under a pinned horizon
  is replaced by a `critical` diagnostic.

- **No conflicting actions.** One lever per *objective* per cycle (§11.4); vacuum and
  analyze levers may move together but are combined into one atomic `ALTER TABLE`
  (§12.2) — no two levers for the *same* objective ever move together.

- **Actuator failure is not system failure.** A failed apply (lock timeout,
  privilege, conflict) is recorded in `action_history` with `status='failed'`,
  `failure_reason`, and `lock_wait_outcome`, then retried in a future cycle
  (Appendix A). It never aborts the cycle or leaves a partial change (the batch DDL
  is atomic, §12.2).

- **Reversible, with an ownership re-check.** Section 12.3; `action_history` carries
  `revert_kind` / `revert_value` for every applied change. `pgfc_govern.revert()` /
  `revert_all()` replay only `status='applied'` rows **and only when the live
  reloption still matches what the governor last set** — if a human changed it since,
  revert skips and flags rather than clobbering (Appendix B "Rollback
  Considerations").

- **Fail safe.** `control_tick()` wraps work so any error closes the tick_log row
  with `error` set and leaves settings untouched; a crashed cycle never
  half-applies.

---

## 17. Decision Logging & Auditability

Every control cycle writes, per relation considered, a `decision_log` row capturing
the six elements the vision requires: **observation, previous state, desired state,
decision, action, outcome.** Mapping:

- observation → `observation` jsonb (raw values used)
- previous/derived state → `prev_state` jsonb
- desired state → `desired_state` jsonb (target setpoint)
- decision → `decision` + `proposed_value` + `policy_rule` (incl. `suppressed:*`,
  `escalate:io_limited`)
- action → `action_history` (applied *or* failed)
- outcome → filled later by `verify()` (linked via `decision_id`)

For every **catalog-mutating** action, `action_history` additionally records the
full Appendix B logging list: relation OID + `relname`, `prev_reloptions` (live,
pre-change) and `new_value`/`revert_*`, `failure_reason`, `lock_wait_outcome`,
`budget_consumed`, `emergency_override`, and `applied_at`. Together with
`decision_log.policy_rule` this gives the complete "what / why / how it went" trail
Appendix B requires.

Because advisory-only mode still writes the full chain, the audit trail is complete
*before* any mutation is ever enabled — operators can review weeks of "what it would
have done" before granting actuation.

---

## 18. Scheduling (multi-rate)

`pg_cron` drives the two loops on **separate cadences** (Appendix A: "observation
cadence significantly faster than actuation cadence"):

```sql
-- Fast loop: observe + estimate, every 1 minute
SELECT cron.schedule('pgfc_observe', '* * * * *',
                     $$SELECT pgfc_govern.observe_tick()$$);

-- Control loop: plan + apply + verify, every 5 minutes
SELECT cron.schedule('pgfc_control', '*/5 * * * *',
                     $$SELECT pgfc_govern.control_tick()$$);
```

The cadence ladder (matches Appendix A):

| Stage | Cadence | Acts? |
|---|---|---|
| Observation, estimation, classification | 1 min | no |
| Planning (decisions logged) | 5 min | no |
| Actuation (`apply()`) | ≤ 1 per relation per hour | rarely |

- **Decoupled by design.** `control_tick()` reads the latest `relation_estimate`
  rather than collecting its own snapshot, so observing 60×/hour while acting ≤1×/hour
  per relation is the normal state — exactly "Observe frequently, Act rarely."

- **Non-overlapping.** Each loop takes a session advisory lock at entry so a slow run
  never overlaps the next cron firing; a missed control cycle is harmless (the next
  one re-reads current state).

- **Snapshot retention (consequence of 1-min cadence).** Observation now writes
  `relations × 1440/day` sample rows. Phase 0 must ship a retention job — e.g. a
  daily `pg_cron` task that deletes `pgfc_observe.snapshots` older than a configurable
  window (default 14 days; cascades to `relation_samples`), optionally downsampling
  older data — so the observe tables stay bounded. Do not let the mandated cadence
  silently grow an unbounded table.

---

## 19. Phased Implementation Plan

Sequenced so risk rises only after the prior layer is trustworthy.

### Phase 0 — `pgfc_observe` (read-only telemetry)

- `snapshots` (incl. `pg_class` catalog-health **and xmin-horizon** header columns,
  §5.3/§5.3a/§6), `relation_samples`, `effective_reloption()`,
  `removability_horizons()`, `observe()`, `relation_health`, `maintenance_debt`,
  **and the retention job** (§18).
- pg_cron schedule for `observe()` at 1-min cadence + daily retention.
- **Exit:** snapshots accumulate correctly on PG 15–18; debt views match
  hand-computed values; `pg_class` health and the data/catalog horizons are captured
  (a held-open txn / slot moves `oldest_xmin_age`); retention keeps the tables
  bounded; zero writes outside `pgfc_observe`. Independently useful as a monitoring
  tool (this validates the two-extension split — Section 2).

### Phase 1 — `pgfc_govern` advisory (decide, never act)

- All govern tables (incl. `diagnostics`); `classify()`, `estimate()` (with
  effectiveness + `saturation_cause`), `observe_tick()`, `plan()`, `verify()`,
  `control_tick()` — both loops on their cadences (§14, §18).
- `apply()` exists but is gated off by `advisory_only = true` (default).
- `governor_status`, `catalog_health`, `active_diagnostics` views.
- **Exit:** decision_log shows sensible, stable proposals on real workloads; no
  classification flapping; the multi-rate split runs cleanly; **saturation is
  correctly classified** (a held-open txn produces an `inhibited` diagnostic naming
  the owner, not endless `adjust` proposals); no `apply()` ever fires.

### Phase 2 — Active vacuum/analyze control

- Enable `apply()` for the four threshold/scale actuators behind
  `advisory_only = false`, with **quantized targets, batched DDL + 100ms locks**
  (§11, §12.2).
- Full safety system: quantization + no-op suppression, sustained-deviation,
  three-tier catalog budget, setting-ownership guard, **saturation→diagnosis with
  action suppression**, **inhibitor-aware freeze override** (§11.3, §11.5), freeze
  override (bypasses budgets, logged as `emergency_override`), failure recording,
  ownership-checked `revert()`.
- Surface `catalog_health` and `active_diagnostics` (§15); the bloat-driven *braking*
  loop is deferred to a later Phase-2 increment (open-loop protections ship first).
- **Exit:** on a soak workload, controlled relations converge to their (quantized)
  target dead fractions without oscillation; **catalog mutation is rare** (most
  cycles apply nothing; no no-op DDL; values stay on-grid); user-owned settings are
  untouched unless policy allows; saturated tables are **diagnosed, not escalated**
  (`io_limited` flagged; inhibitor pins produce a `critical` finding naming the owner
  and suppress actuation, including on the freeze path); failed applies are recorded
  and retried, never blocking; every change is logged and ownership-checked-reversible;
  freeze debt never worsens.

### Phase 3 — I/O budget, cost actuators & catalog braking

- Resolve the cost-balancing tradeoff (Section 12.1); introduce a cluster-wide I/O
  model before touching `cost_limit`/`cost_delay`.
- Close the catalog loop: rising `pg_class` bloat tightens the mutation budget /
  pauses non-emergency actuation (§15).
- Begin freeze-parameter actuators under conservative bounds.

### Phase 4+ — per vision Future Directions

- Richer estimation (optionally a scalar Kalman filter per debt signal), adaptive
  policies, then the broader Maintenance Governor / control plane.

---

## 20. Testing Strategy

pgTAP, run via `./test.sh` on PG 15/16/17/18 (matches `CLAUDE.md`).

- **`pgfc_observe/tests/`:** `observe()` populates one snapshot + N samples;
  reloptions captured verbatim; debt views match hand-computed thresholds; version
  guards (e.g. `total_autovacuum_time` NULL on <18, populated on 18); excludes
  catalog/own schemas; **retention** deletes snapshots past the window and cascades
  to `relation_samples`; **`removability_horizons()`** — opening a transaction that
  holds a snapshot moves `oldest_xmin_age` and attributes `owner='long_running_txn'`
  with the right pid; a replication slot attributes `replication_slot`; no inhibitor
  → owner `'none'`.

- **`pgfc_govern/tests/`:** classification rules + hysteresis (no flap over N
  cycles); `estimate()` formulas on synthetic snapshot pairs (known deltas →
  expected EWMA); **feedforward + quantization** — `sf_cont = clamp(r − base/reltuples,…)`
  then `snap()` lands on the expected `SF_GRID`/`THR_GRID` value for large vs small
  tables; **sustained-deviation** holds until the same grid value is selected
  `n_sustain` cycles, and a one-level reversal is suppressed (no `0.02→0.03→0.02`
  flap); **three-tier budget** — per-relation suppresses a second change inside
  `min_interval`, per-cycle suppresses the (N+1)th, per-day suppresses past
  `daily_mutation_budget` (`suppressed:rate_limited` / `suppressed:daily_budget`);
  **freeze emergency bypasses all three** and writes `emergency_override=true`,
  `budget_consumed=false`; freeze override forces cleanest target; partitioned parent
  never actuated; matview uses `ALTER MATERIALIZED VIEW`; advisory_only never writes a
  reloption. (Saturation/inhibitor diagnosis has its own bullet below.)

- **No-op & ownership (`pgfc_govern/tests/`):** target == live value → no DDL,
  `decision='hold'`/`no_op`; target == global default with no explicit reloption →
  `RESET`/skip, never `SET`; a user-set reloption (no governor baseline) is not
  overwritten when `manage_user_owned=false` (`suppressed:user_owned`) but is when
  `true`; rollback baseline (explicit→SET, inherited→RESET); `revert()` skips and
  flags an actuator whose live value diverged from the governor's last-applied
  (intervening human change), and ignores `status='failed'` rows.

- **Batching & failure (`pgfc_govern/tests/`):** when both vacuum and analyze levers
  move in one cycle, exactly **one** `ALTER TABLE` is issued with both params (assert
  one `batch_id`, shared `applied_at`); a simulated lock contention yields
  `status='failed'`, `failure_reason='lock_timeout'`, `lock_wait_outcome='timeout'`,
  **no reloption changed**, and a retry on the next cycle.

- **Catalog accounting (`pgfc_govern/tests/`):** `catalog_health` mutation counts
  match the `action_history` rows in window; `pg_class` header columns populate in
  snapshots; daily-budget exhaustion produces `suppressed:daily_budget` (so "nothing
  is happening" is explained).

- **Integration — keeping-up regime:** seed a table, run several `control_tick()`s
  with `advisory_only=false`, assert the scale factor **jumps directly to its grid
  value** and then *holds* across subsequent cycles (no further DDL — Act Rarely),
  that most cycles apply nothing, and that the overdue indicator `vacuum_debt_ratio`
  stays bounded. The realized dead fraction is logged but **not asserted as the
  success criterion** — it is a biased peak-hold (§7.2); convergence is judged by the
  actuator reaching its grid target and the indicator staying healthy.

- **Saturation classification (`pgfc_govern/tests/`, Appendix C):** the three-way
  discriminator (§11.3) — (a) debt high with `autovacuum_count` *not* incrementing →
  `config` (hold + diagnose, never lowers threshold); (b) incrementing with
  `cleanup_per_run > 0` but debt refilling → `io_limited`; (c) incrementing with
  effectiveness ≈ 0 and a pinned `oldest_xmin` → `inhibited`. Effectiveness is judged over K cycles, never
  one; no cause is declared before K observed cycles.

- **Inhibitor diagnosis & freeze interaction (`pgfc_govern/tests/`):** with an
  open held-snapshot transaction, a churning table that vacuums but does not clean
  produces `escalate:inhibited:long_running_txn`, a `diagnostics` row naming the pid,
  and **suppressed actuation** (no further DDL). Critically: a *freeze-stressed* table
  under the same pin **holds at cleanest, does not escalate, and raises a `critical`
  diagnostic** — and the §13 guard still blocks any aggressiveness *reduction*
  (inhibitor-awareness must not become back-off). When the transaction ends and the
  horizon advances, the diagnostic is marked `resolved_at`.

- **Integration — falling-behind regime:** drive churn faster than autovacuum can
  keep up (low `cost_limit` / heavy write load, no inhibitor); assert the governor
  stops lowering `sf` and emits `escalate:io_limited` — *not* `inhibited` (the horizon
  is healthy). This is the test the earlier "dead fraction ≈ sf" check would have
  missed, and it must distinguish `io_limited` from `inhibited`.

- **Mid-vacuum guard:** simulate an in-progress vacuum (or assert the
  `pg_stat_progress_vacuum` precheck path) so `apply()` yields
  `suppressed:vacuum_busy` rather than blocking.

---

## 21. Open Questions

- **Effective-threshold helper:** *resolved* — `pgfc_observe.effective_reloption()`
  and the `maintenance_debt` CTE (§6.2) compute it observe-side; govern reuses the
  function. (Left here only as a pointer; it is a Phase 0 deliverable, not an open
  question.) Revisit only if it ever forces a non-additive observe change.

- **Grid spacing and `τ` defaults:** the quantization grids (`SF_GRID`, `THR_GRID`,
  §11.4) and EWMA time constant (`τ=1h`) are the tunables now that the continuous
  gain `Kp`/max-step are retired (§11.2). Coarser grids = less catalog mutation but
  blunter control — Phase 2 soak data should tune the trade-off; consider per-class
  grids.

- **Partitioned tables:** leaf partitions are classified and controlled
  individually; the parent is observed but never actuated (§12.2). Open: whether a
  policy set on the parent should *inherit* to its leaves — a later refinement.

- **Catalog braking (deferred):** the MVP only *surfaces* `pg_class` health (§15) and
  protects the catalog open-loop (quantize / no-op / budget). A closed loop that
  tightens the budget or pauses non-emergency actuation as `pg_class` bloat rises is
  a Phase-2/3 increment, named here so it is a deliberate choice, not an omission.

- **Statistics reset:** cumulative counters reset (crash, `pg_stat_reset`) produce
  negative deltas; `estimate()` must detect counter regressions and skip the rate
  for that interval rather than emit garbage.

- **Inhibitor Class 6 (lock/interruption) detection:** the MVP covers horizon-based
  inhibitors (Classes 1/2/4/5) via `removability_horizons()`, and partial-progress
  lock conflicts surface through `lock_wait_outcome`/`vacuum_busy`. Dedicated
  detection of *repeated vacuum interruption* (distinct from horizon pinning) is
  deferred — it needs progress-tracking across `pg_stat_progress_vacuum` runs.

- **Recommendation actions stay advisory:** `diagnostics.recommendation` is
  human-readable text ("terminate pid 4242", "drop/advance slot X"). The governor
  never itself kills a backend or drops a slot — those are operator actions, out of
  scope by design (the governor's actuator surface is autovacuum settings only).

- **MultiXact inhibitor attribution unmodeled:** `removability_horizons()` (§6.1a)
  models the xid data/catalog horizons only. A `mxid_freeze_debt` stall pinned by the
  oldest *MultiXact* horizon would escalate without an owner to name. Narrower and
  rarer than xid wraparound; attributing it is deferred.

- **Self/background backends in the horizon scan:** `removability_horizons()` reads
  `pg_stat_activity`, which includes the governor's own session and autovacuum
  workers. Usually harmless (observe() is quick), but at scaffold time confirm
  whether to filter the calling pid / non-client `backend_type` so the governor never
  attributes a pin to itself.

## 22. Out of Scope (Phase I)

Per the vision: the MVP does not control checkpointer, bgwriter, WAL settings,
shared buffers, work_mem, or replication. It *may observe* WAL generation
(`pg_stat_wal.wal_bytes`), `pg_class` catalog health, and the xmin removability
horizons (§5.3a) as context only. Cost-based autovacuum actuators are deferred to
Phase 3 for the balancing reason in Section 12.1. Catalog-bloat *braking* (closed
loop) and Option-B targeted `VACUUM`/`ANALYZE` actuators (§12.4) are likewise out of
the MVP — the MVP protects the catalog open-loop via quantization, no-op suppression,
and the three-tier mutation budget. For maintenance inhibitors (Appendix C) the MVP
**detects, diagnoses, and surfaces** (suppressing futile actuation) but never
**remediates**: it will not terminate backends or drop replication slots — clearing
an inhibitor is an operator action.
