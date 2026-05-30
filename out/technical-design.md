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

- **The thing we regulate is the dead-tuple _fraction at trigger_ — not the raw
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
   │ classify() → relation_class                        │
   │ estimate() → relation_estimate (derived state)     │
   │ plan()     → decision_log (proposed actions)       │
   │ apply()    → action_history, ALTER TABLE SET(...)  │
   │ verify()   → close the loop, mark outcomes         │
   │ tick()     → orchestrates one full cycle           │
   │ views: governor_status                             │
   └───────────────────────────────────────────────────┘
                                    ▲
                                pg_cron (every 1–5 min)
```

`tick()` is the only thing pg_cron calls. Everything else is a step it invokes.

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
    wal_bytes                numeric         -- cumulative; NULL if unavailable
);
COMMENT ON TABLE pgfc_observe.snapshots IS
  'Header row per observe() run: timestamp + cluster/GUC context shared by all samples.';

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
        autovacuum_max_workers, wal_bytes)
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
        (SELECT wal_bytes FROM pg_stat_wal)
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

-- Controlled variables (dead-tuple / mod fractions) plus overdue indicators.
CREATE OR REPLACE VIEW pgfc_observe.maintenance_debt AS
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
FROM ( /* latest sample + effective-threshold computation; see helper below */ ) e;
```

Effective thresholds are computed by a helper that prefers a relation's explicit
reloption and otherwise uses the snapshot's global default. This logic lives in one
place and is reused by the estimator (Section 9).

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

**Diagnostic estimator (logged, _not_ a control input).** We still record the
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
`verify()` to attribute outcomes and by the regime guard's K-cycle requirement
(§11.3), which must not declare `io_limited` before watching at least one cycle.

### 7.4 Cleanup efficiency and lag

```text
-- dead tuples cleared per autovacuum run, observed across a run boundary
cleanup_per_run = max(0, n_dead_tup_{t-1} - n_dead_tup_t)
                  when autovacuum_count increased between t-1 and t

maintenance_lag = now() - (first snapshot where vacuum_debt_ratio crossed 1.0
                           without a subsequent autovacuum)
```

`maintenance_lag` measures observed actuation dead-time and is the empirical bound
on how often we may safely re-correct.

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
N consecutive ticks (default N=3) — this prevents flapping. Manual overrides
(`source = 'manual'`) are never auto-changed.

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
    enabled            boolean NOT NULL DEFAULT true,
    advisory_only      boolean NOT NULL DEFAULT true            -- dry-run gate
);
COMMENT ON TABLE pgfc_govern.policy IS
  'Operator-expressed outcomes. advisory_only=true means plan but never apply.';

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
    -- indicators (logged; drive the regime guard, not the keeping-up move)
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
    decision       text NOT NULL,    -- 'hold' | 'adjust' | 'suppressed:<reason>'
    proposed_value text,
    applied        boolean NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- ── Audit: only the changes we actually made (revert source of truth) ────────
CREATE TABLE IF NOT EXISTS pgfc_govern.action_history (
    action_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    decision_id    bigint REFERENCES pgfc_govern.decision_log(decision_id),
    relid          oid NOT NULL,
    actuator       text NOT NULL,
    old_value      text,             -- effective value before
    new_value      text NOT NULL,
    revert_kind    text NOT NULL CHECK (revert_kind IN ('SET','RESET')),
    revert_value   text,             -- value to SET if revert_kind='SET'
    applied_at     timestamptz NOT NULL DEFAULT now(),
    reverted_at    timestamptz
);

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

For each relation and each controlled actuator, once per tick. The triad below
**is** the anti-oscillation mechanism (Principle 4) and is stated explicitly because
of the actuation dead-time established in Section 1.

### 11.1 The keeping-up move is feedforward

Loop gain is ≈1 — the scale factor *is* the dead fraction at trigger (§7.2) — so the
keeping-up regime needs no measure-and-converge: we know what a given `sf` produces,
so we compute it and set it. The target setting is feedforward from quantities known
at plan time:

```text
r          = effective_f                       target dead fraction (§10.1)
sf_target  = clamp(r - base/reltuples, sf_min, sf_max)
```

The measured dead fraction (`f_trigger_ewma`, §7.2) is **not** an input here — it is
a logged diagnostic, and a biased one. Feedback enters only through the regime guard
(§11.3). The analyze loop is identical:
`ana_sf_target = clamp(mod_target - ana_base/reltuples, …)`.

### 11.2 The triad (anti-oscillation — all inputs observable)

1. **Deadband on the actuator, not the measurement.** If
   `|sf_target − old_sf| ≤ tol_sf` (default `tol_sf = 0.01`), decision = `hold`.
   Because `sf_target` is computed from `r`, `base`, and `reltuples`, this gate is
   fully observable and free of the peak-hold sampling bias a `|y − r|` deadband
   would carry (§7.2). It fires a change only when policy or table size actually
   moved the target.

2. **Rate limit.** At most one change per (relation, actuator) per `min_interval`
   (default 1h; §16). Bounds how fast a slowly-drifting `reltuples` re-estimate can
   walk the setting, and prevents thrash. A second proposal inside the window is
   `suppressed:rate_limited`.

3. **Clamp + max step.** Step toward the target, bounding per-tick step and absolute
   range:

   ```text
   gain Kp = 0.5
   sf_step  = clamp(Kp * (sf_target - old_sf), -max_step, +max_step)   -- max_step = 0.05 (abs)
   new_sf   = clamp(old_sf + sf_step, sf_min, sf_max)
   ```

   Step-limiting is belt-and-suspenders for the feedforward move: a large `reltuples`
   re-estimate cannot yank the setting in one tick.

### 11.3 Regime guard — the only real feedback path

Feedforward sets the *trigger point*; it cannot tell whether autovacuum can *keep*
that point. That is what the overdue/overshoot indicators (§7.2) are for, and it is
the one regime where the measurement carries information the actuator did not already
determine:

```text
io_limited  ⇔  vacuum_debt_ratio > 1 persisting across K cycles
               (n_dead_tup stays above the effective threshold even though
                autovacuum_count keeps incrementing)
            OR n_dead_tup ≫ effective threshold at the instant a vacuum fires
```

When detected the table is **I/O-limited, not threshold-limited** — lowering `sf`
further does nothing, because the trigger is already always tripped. Emit decision =
`escalate:io_limited` (surfaced for the operator; resolved by Phase 3 cost actuators
or more workers) rather than a useless `sf` correction. The call requires at least K
observed vacuum cycles, so it is never made on a table the governor has not yet
watched through a cycle.

### 11.4 Actuator ranges (clamps)

| Actuator | min | max | notes |
|---|---|---|---|
| `autovacuum_vacuum_scale_factor` (`sf_min`/`sf_max`) | 0.01 | 0.50 | primary lever |
| `autovacuum_vacuum_threshold` | 50 | 100000 | floor for tiny tables |
| `autovacuum_analyze_scale_factor` | 0.01 | 0.50 | |
| `autovacuum_analyze_threshold` | 50 | 100000 | |

**Which lever, by table size.** The two terms of `f_trigger = base/reltuples + sf`
trade dominance with table size, and that directly picks the lever: when
`sf·reltuples ≫ base` (large table) the scale factor controls the fraction, so move
`sf` per §11.2; when `base ≳ sf·reltuples` (small table) the threshold controls it,
so move the threshold toward `base_target = r·reltuples` instead, with the same
deadband/rate-limit/step discipline. Exactly one lever is moved per relation per
tick, to keep each `action_history` row an attributable cause.

### 11.5 Safety override

Before any of the above: if `freeze_debt > freeze_action_threshold` (default 0.6) or
`mxid_freeze_debt > 0.6`, the relation is driven to its *cleanest* vacuum target
regardless of class (Section 13). Safety dominates (Principle 3).

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

### 12.2 `apply()` — mechanics that must be correct

```sql
-- Pseudocode; runs one approved decision.
-- Pre-checks:
--   * policy.advisory_only = false           (else: record, do not apply)
--   * rate limit not exceeded (Section 18)
--   * no autovacuum currently in progress on relid (pg_stat_progress_vacuum)
-- because ALTER TABLE ... SET (...) takes SHARE UPDATE EXCLUSIVE, which
-- CONFLICTS with an in-progress (auto)vacuum: apply would block, and must not
-- run mid-vacuum. If a vacuum is in progress, decision = suppressed:vacuum_busy.

-- relkind dictates the DDL and whether the relation is actuable at all:
--   'r' ordinary table     → ALTER TABLE ... SET (...)
--   'm' materialized view  → ALTER MATERIALIZED VIEW ... SET (...)
--   'p' partitioned parent → NOT actuable. Storage params on the parent do not
--       drive autovacuum (it runs per-leaf). plan() targets the leaf partitions
--       ('r') instead; the parent is observed but never actuated.
EXECUTE format(
  'ALTER %s %s SET (%I = %s)',
  CASE relkind WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
  relid::regclass, actuator, new_value);
```

Operational notes baked into the implementation:

- **Actuated set = relkind `'r'` and `'m'` only.** Partitioned parents (`'p'`) are
  excluded from actuation in `plan()` (still observed); their leaves are governed
  individually. This is the apply-side resolution of the partitioning open question
  (§21).

- Run `apply()` with a short `lock_timeout` (e.g. `SET LOCAL lock_timeout = '2s'`)
  so a contended `ALTER TABLE` fails fast and is retried next tick rather than
  blocking the governor.

- One actuator change per relation per tick (Section 11.4) keeps the
  `action_history` row a clean cause for the next observed effect.

### 12.3 Rollback baseline capture (the correctness trap)

Reverting is **not** "set it back to the number it had." It is:

- If, *before the governor first touched it*, the table had an **explicit**
  reloption (`baseline_explicit = true`): revert with
  `ALTER TABLE … SET (actuator = baseline_value)`.

- If it was **inheriting the global default** (`baseline_explicit = false`): revert
  with `ALTER TABLE … RESET (actuator)` — *not* by writing the resolved number,
  which would freeze a now-stale default into the table.

`baseline_explicit` / `baseline_value` are captured from `pg_class.reloptions` in
`actuator_state` the first time the governor touches each (relation, actuator), and
never overwritten afterward. This makes "every action reversible" (vision Safety
System) actually true.

---

## 13. Freeze Safety in the MVP

Freeze *actuators* (`freeze_min_age`, `freeze_table_age`, `freeze_max_age`) are
Phase 2+. But anti-wraparound dominates everything (Principle 3), so the MVP must
**observe and respond to freeze debt now** — using the actuators it already has.

- **Observe:** `freeze_debt = age(relfrozenxid)/autovacuum_freeze_max_age` and the
  MultiXact analogue are computed every tick (Section 7.2).

- **Respond:** when `freeze_debt` crosses `freeze_action_threshold` (default 0.6),
  the safety override (Section 11.5) drives the relation's vacuum target to its
  cleanest setting. A normal autovacuum advances `relfrozenxid` (it opportunistically
  freezes), so making ordinary vacuum more eager *is* a valid wraparound mitigation
  with only the MVP's threshold/scale levers.

- **Never:** the governor will not raise any threshold/scale factor on a relation
  whose `freeze_debt` is elevated, and (when freeze actuators arrive) will never set
  `freeze_max_age` upward past safe bounds. There is a hard guard in `plan()` that
  drops any proposed change that would *reduce* cleanup aggressiveness on a
  freeze-stressed table.

This way the doc neither pretends to tune freeze parameters in the MVP nor ignores
wraparound.

---

## 14. Control-Loop Functions

```sql
-- pgfc_govern.classify(snapshot_id) -> int   (relations (re)classified)
-- pgfc_govern.estimate(snapshot_id) -> int   (estimates written)
-- pgfc_govern.plan(tick_id, snapshot_id) -> int   (decisions logged)
-- pgfc_govern.apply(decision_id) -> bool     (one approved change)
-- pgfc_govern.verify(tick_id) -> int         (close loop on prior actions)
-- pgfc_govern.tick() -> bigint               (orchestrator; returns tick_id)
```

### 14.1 `tick()` orchestration

```text
tick():
  s   := pgfc_observe.observe()           -- fresh snapshot
  t   := open tick_log row (snapshot_id = s)
  classify(s)                              -- update relation_class (+ hysteresis)
  estimate(s)                              -- write relation_estimate
  n   := plan(t, s)                        -- write decision_log rows
  for each decision where decision='adjust' and policy.advisory_only=false:
        apply(decision_id)                 -- guarded; updates action_history
  verify(t)                                -- attribute outcomes of PAST actions
  close tick_log row (counts, finished_at)
  return t
```

`verify()` looks at actions applied in earlier ticks whose effect should now be
observable (`av_since_apply ≥ 1`) and checks the **overdue indicators**: did
`vacuum_debt_ratio` settle and the realized dead fraction move toward the class
target after the change? It logs the realized `f_trigger_ewma` as a diagnostic
(noting its peak-hold bias) and feeds `maintenance_lag` and `io_limited` detection.
It is the "Verify" step of the vision's control loop and the basis for
explainability — but it does not feed a correction back into the feedforward move
(§11.1); persistent failure to converge surfaces as `escalate:io_limited` (§11.3).

### 14.2 Advisory-only mode

`policy.advisory_only = true` (the default) runs the entire loop *including*
`plan()`, writing full `decision_log` entries, but **never calls `apply()`**. This
is the safe default and the recommended Phase-1 operating mode: the governor
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
```

Plus the observe-side `relation_health` and `maintenance_debt` (Section 6.2).

---

## 16. Safety System

Hard constraints, enforced in `plan()`/`apply()` (never disabled, vision Safety):

- **Never disable autovacuum.** The governor cannot set
  `autovacuum_enabled = false`; that GUC/reloption is not in the actuator set, and
  `apply()` rejects it defensively.

- **Never exceed freeze safety.** Section 13 guard; no change may reduce cleanup
  aggressiveness on a freeze-stressed relation.

- **No rapid repeated adjustments.** Rate limit: **max 1 change per (relation,
  actuator) per `min_interval`** (default 1h; Section 11.2), plus the actuator-side
  deadband and per-tick max-step. Enforced by checking
  `actuator_state.set_at_snapshot`.

- **No conflicting actions.** One actuator per relation per tick (Section 11.4); the
  size heuristic ensures threshold and scale are never moved in the same tick.

- **Everything reversible.** Section 12.3; `action_history` carries `revert_kind` /
  `revert_value` for every change. A `pgfc_govern.revert(action_id)` /
  `revert_all()` function replays them.

- **Fail safe.** `tick()` wraps work so that any error closes the tick_log row with
  `error` set and leaves settings untouched; a crashed tick never half-applies.

---

## 17. Decision Logging & Auditability

Every tick writes, per relation considered, a `decision_log` row capturing the six
elements the vision requires: **observation, previous state, desired state,
decision, action, outcome.** Mapping:

- observation → `observation` jsonb (raw values used)
- previous/derived state → `prev_state` jsonb
- desired state → `desired_state` jsonb (target setpoint)
- decision → `decision` + `proposed_value`
- action → `action_history` (if applied)
- outcome → filled later by `verify()` (linked via `decision_id`)

Because advisory-only mode still writes the full chain, the audit trail is complete
*before* any mutation is ever enabled — operators can review weeks of "what it would
have done" before granting actuation.

---

## 18. Scheduling

`pg_cron` calls `pgfc_govern.tick()` on a fixed cadence:

```sql
SELECT cron.schedule('pgfc_tick', '*/2 * * * *', $$SELECT pgfc_govern.tick()$$);
```

- Recommended cadence: **2 minutes** (within the vision's 1–5 min). Observation is
  cheap; the per-actuator rate limit and deadband mean a fast tick does *not* mean
  fast actuation — a setting changes at most once per `min_interval` and only when
  its target actually moved.

- `tick()` must be cheap and non-overlapping. Take a session advisory lock at the
  top of `tick()` so a long run never overlaps the next cron firing.

- `observe()` may be scheduled more frequently than the full `tick()` later, to get
  finer rate estimates without more actuation. Not needed for MVP.

---

## 19. Phased Implementation Plan

Sequenced so risk rises only after the prior layer is trustworthy.

### Phase 0 — `pgfc_observe` (read-only telemetry)

- `snapshots`, `relation_samples`, `observe()`, `relation_health`,
  `maintenance_debt`.
- pg_cron schedule for `observe()` alone.
- **Exit:** snapshots accumulate correctly on PG 15–18; debt views match
  hand-computed values; zero writes outside `pgfc_observe`. Independently useful as
  a monitoring tool (this validates the two-extension split — Section 2).

### Phase 1 — `pgfc_govern` advisory (decide, never act)

- All govern tables; `classify()`, `estimate()`, `plan()`, `verify()`, `tick()`.
- `apply()` exists but is gated off by `advisory_only = true` (default).
- `governor_status` view.
- **Exit:** decision_log shows sensible, stable proposals on real workloads; no
  classification flapping; no `apply()` ever fires.

### Phase 2 — Active vacuum/analyze control

- Enable `apply()` for the four threshold/scale actuators behind
  `advisory_only = false`.
- Full safety system: rate limit, actuator deadband, regime guard, freeze override,
  reversibility, `revert()`.
- **Exit:** on a soak workload, controlled relations converge to their target dead
  fractions without oscillation; I/O-limited tables are flagged `escalate:io_limited`
  rather than chased; every change is logged and reversible; freeze debt never
  worsens under control.

### Phase 3 — I/O budget & cost actuators

- Resolve the cost-balancing tradeoff (Section 12.1); introduce a cluster-wide I/O
  model before touching `cost_limit`/`cost_delay`.
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
  catalog/own schemas.

- **`pgfc_govern/tests/`:** classification rules + hysteresis (no flap over N
  ticks); `estimate()` formulas on synthetic snapshot pairs (known deltas →
  expected EWMA); **feedforward move** — `sf_target = clamp(r − base/reltuples, …)`
  computed correctly for large vs small tables; deadband holds when
  `|sf_target − old_sf| ≤ tol_sf`; max-step + range clamp; rate limit suppresses a
  second change inside `min_interval` (`suppressed:rate_limited`); **regime guard**
  emits `escalate:io_limited` only after K cycles of `vacuum_debt_ratio > 1` despite
  `autovacuum_count` incrementing (and never before one observed cycle); rollback
  baseline (explicit→SET, inherited→RESET); freeze override forces cleanest target;
  partitioned parent never actuated; matview uses `ALTER MATERIALIZED VIEW`;
  advisory_only never writes a reloption.

- **Integration — keeping-up regime:** seed a table, run several `tick()`s with
  `advisory_only=false`, assert the scale factor reaches `sf_target` in step-limited
  moves and then *holds* (deadband), and that the overdue indicator
  `vacuum_debt_ratio` stays bounded (no runaway). The realized dead fraction is
  logged for inspection but **not asserted as the success criterion** — it is a
  biased peak-hold (§7.2); convergence is judged by the actuator reaching target and
  the indicator staying healthy.

- **Integration — falling-behind regime:** drive churn faster than autovacuum can
  keep up (low `cost_limit` / heavy write load); assert the governor stops lowering
  `sf` and instead emits `escalate:io_limited` rather than chasing an unreachable
  target. This is the test the earlier "dead fraction ≈ sf" check would have missed.

- **Mid-vacuum guard:** simulate an in-progress vacuum (or assert the
  `pg_stat_progress_vacuum` precheck path) so `apply()` yields
  `suppressed:vacuum_busy` rather than blocking.

---

## 21. Open Questions

- **Effective-threshold helper placement:** observe-side (so `maintenance_debt`
  shows it) vs govern-side (so it tracks policy). Current plan: a stable SQL helper
  in `pgfc_observe` returning effective thresholds; govern reuses it. Revisit if it
  forces non-additive observe changes.

- **Gain (`Kp`) and time constant (`τ`) defaults:** start at `Kp=0.5` (the
  near-unity loop gain tolerates it), `τ=1h`; Phase 2 soak data should tune them.
  Consider per-class gains.

- **Partitioned tables:** leaf partitions are classified and controlled
  individually; the parent is observed but never actuated (§12.2). Open: whether a
  policy set on the parent should *inherit* to its leaves — a later refinement.

- **Statistics reset:** cumulative counters reset (crash, `pg_stat_reset`) produce
  negative deltas; `estimate()` must detect counter regressions and skip the rate
  for that interval rather than emit garbage.

---

## 22. Out of Scope (Phase I)

Per the vision: the MVP does not control checkpointer, bgwriter, WAL settings,
shared buffers, work_mem, or replication. It *may observe* WAL generation
(`pg_stat_wal.wal_bytes`) as context only. Cost-based autovacuum actuators are
deferred to Phase 3 for the balancing reason in Section 12.1.
