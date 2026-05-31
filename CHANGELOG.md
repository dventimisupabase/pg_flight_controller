# Changelog

All notable changes to pg_flight_controller are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Update the **Unreleased**
section in the same pull request as your change (this is a convention, not a CI gate).

## [Unreleased]

### Added

- **`pgfc_observe` (Phase 0)** — read-only autovacuum telemetry: `snapshots` and
  `relation_samples` tables, `observe()`, the `effective_reloption()` helper,
  `removability_horizons()`, the `relation_health` and `maintenance_debt` views, and
  a `retain()` retention function.
- **`pgfc_govern` (Phase 1, advisory)** — the control loop: `classify()`,
  `estimate()`, `plan()`, `verify()`, a gated `apply()`, the `observe_tick()` /
  `control_tick()` orchestrators, and the `governor_status`, `catalog_health`, and
  `active_diagnostics` views. Advisory by default (`advisory_only = true`): it plans
  and diagnoses but changes nothing.
- **Documentation** — top-level `README.md` and the `docs/` guide set (getting
  started, concepts, operating) plus the generated schema reference under
  `docs/reference/`. The concepts guide covers the **observation storage and
  self-maintenance** model (partition-rotation retention, sparse change-logging,
  rollups, governor self-maintenance) and the **Phase 1.5** storage increments
  (S1–S6), built before active control.
- **Test & docs tooling** — `test.sh` pgTAP suites across PostgreSQL 15–18; CI for
  the test matrix, markdown/shell lint, generated-reference staleness, documentation
  doctests, internal link integrity, and an advisory AI doc-drift reviewer. `main` is
  branch-protected with these checks required.

- **Storage Phase 1.5 — S1 (govern-audit retention).** A `pgfc_govern.retain()`
  function prunes the append-only audit tables by time cutoff (decisions/actions
  180 d, tick log 180 d, resolved diagnostics 365 d), closing the unbounded-growth
  gap; it respects the `action_history → decision_log` FK and never ages out an
  unresolved diagnostic. New `policy_history` table (with an `AFTER` trigger on
  `policy`) records human-owned policy changes and is retained indefinitely.

- **Storage Phase 1.5 — S2 (partition infrastructure + GC).** `pgfc_observe`'s
  high-volume tables (`snapshots`, `relation_samples`) are now **daily `RANGE`
  partitioned** on an `int4` epoch-day key (`collected_day`), with a bloat-free BRIN
  index. New `_ensure_partition()` (O(1), race-safe; called by `observe()`) and
  `_partition_inventory()` helpers. Retention is now whole-partition rotation —
  **zero dead tuples** — in two tiers: `retain()` `TRUNCATE`s out-of-window
  partitions (now default 3 days, was a 14-day `DELETE`) and the new
  `drop_empty_partitions()` `DROP`s the empty shells (default 30 days). The
  generated-reference script now lists partitioned parents once instead of flooding
  with child partitions.

- **Storage Phase 1.5 — S3 (sparse change-logging).** `observe()` now writes a
  `relation_samples` row only for relations whose observed state **changed** since
  their last sample; quiet relations produce no rows. A new `UNLOGGED`
  `relation_last_state` side table (HOT-friendly `fillfactor=70`, only the `relid`
  primary key, aggressive static autovacuum) gives the O(1) "did this change?"
  comparison and is self-healingly rebuilt from the catalogs after a crash. The
  globally-ticking `relfrozenxid_age`/`relminmxid_age` are deliberately excluded from
  the change signature; the **raw** `relfrozenxid`/`relminmxid` xids are stored
  instead, and a new `current_relation_state(p_as_of)` function reconstructs the dense
  "current state per relation" view from sparse storage with freeze ages computed
  **live** — so a quiet table's wraparound debt never goes stale. `relation_health`,
  `maintenance_debt`, and the `pgfc_govern` readers (`estimate()`, `classify()`,
  `plan()`, diagnostics) now reconcile through this function. Subsumes the reloptions
  data-minimization goal: the `reloptions` array is re-stored only when it changes.

- **Storage Phase 1.5 — S4 (rollups).** Three per-relation aggregate tiers —
  `rollup_1m`, `rollup_1h`, `rollup_1d` — let long-range trend analysis outlive the
  fast-rotating raw samples. A new `rollup()` job cascades raw → 1m → 1h → 1d
  (sample-count-weighted averages, end-of-bucket cumulative counters) and is
  idempotent (per-PK upsert); it must run at least once per raw-retention window, the
  real guarantee being the window, not nightly cron ordering. The tiers are
  partition-rotated like raw (zero dead tuples) but the partition **span tracks the
  tier**: the fine 1m tier is **daily** partitioned (7-day window), the coarse 1h/1d
  tiers **monthly** (90-/365-day windows) — added `_epoch_month()`/`_month_start()`
  keys, a generic `_ensure_part()`, and a `_rollup_inventory()`. `rollup_retain()`
  drops out-of-window rollup partitions with **cascading per-tier windows** (1m 7 d,
  1h 90 d, 1d 365 d). Rollups are sparse-in/sparse-out, so a new
  `current_rollup(tier, as_of)` carry-forward reader keeps a quiet relation answerable
  after its raw samples are gone.

- **Storage Phase 1.5 — S5 (cardinality filters).** A new single-row
  `pgfc_observe.collection_policy` table bounds *which* relations `observe()` samples,
  so the governor stays cheap in databases with thousands of relations. Four filters
  are applied set-based inside the collection query (never per-row): temporary tables
  (`exclude_temp`, default on), extension-owned relations
  (`include_extension_owned`, default off), additional schemas (`excluded_schemas`,
  additive to the always-excluded system schemas — config can never re-include
  `pg_catalog`), and child partitions below a size floor (`min_partition_size_bytes`,
  `0` disables). Rollups and `pgfc_govern`'s readers inherit the filtered set for free
  because they read what `observe()` wrote. No tiered cadence — sparse change-logging
  (S3) already handles cold tables.

- **Storage Phase 1.5 — S6 (storage budget + self-health).** The governor now bounds
  and reports its own footprint. Every telemetry/rollup partition is created with — and
  pre-S6 partitions are backfilled to — **static autovacuum reloptions**
  (`scale_factor = 0` + a fixed threshold, via a single `_telemetry_reloptions()`
  source of truth), and the `pgfc_govern` audit/state tables get matching static
  settings: the governor maintains its own schema explicitly rather than governing
  itself. New `storage_budget()` functions report per-relation on-disk bytes and dead
  tuples (`pgfc_observe`'s folds child partitions into their parent; `pgfc_govern`'s
  spans **both** schemas), and one-row `self_health` views summarize the footprint —
  `pgfc_govern.self_health` compares it to a configured cap and flags `over_budget`. A
  new single-row `pgfc_govern.storage_config(budget_bytes)` (default `NULL` = no cap)
  drives `pgfc_govern.degrade()`, which sheds storage in a **fixed graceful-degrade
  order** — raw → fine rollups → coarse rollups → diagnostics → actions → policy
  (**never** pruned) — stopping as soon as the footprint is back under budget. With no
  cap configured `degrade()` is a no-op, so it never silently destroys telemetry.

- **Parameter governance Phase 1.6 — P1 (parameter registry).** Every governed constant
  now has explicit provenance. A canonical `_parameter_registry()` function in each schema
  (the single-source-of-truth pattern) records each parameter's name, category (one of six:
  PostgreSQL-derived, safety bound, empirical default, operator policy, adaptive value,
  implementation convenience), value, unit, rationale, source, owner, `override_allowed`,
  and `config_ref`. A unified `pgfc_govern.parameter_registry` view spans both schemas as
  the operator-facing inspection surface. P1 is read-only and documents the as-built values
  (many honestly marked "MVP estimate — not yet benchmarked"); later increments make the
  control logic read from the registry and add a CI drift gate.

- **Parameter governance Phase 1.6 — P2 (single-sourced control constants).** The
  `pgfc_govern` control logic now reads its constants **from** the registry instead of inline
  literals, via three accessors — `_param(name)`, `_sf_grid()`, and `_class_target(kind)`.
  `classify()`, `estimate()`, `plan()`, `snap_sf()`, `_findings()`, `governor_status`, and
  `apply()` (its `lock_timeout`, via `set_config`) were refactored to use them (including the
  `COALESCE` policy fallbacks for `aggressiveness`, `manage_user_owned`, `advisory_only`, and
  `n_sustain`), removing the duplicated class targets and freeze threshold previously copied
  across three call sites. Behaviour is
  identical — guarded by the existing estimate/classify/plan/loop/integration suites, which
  pin concrete outcomes. The registry/code tie is now real but not yet *enforced*; the
  "registry up to date" CI gate that makes divergence impossible lands in P3.

- **Parameter governance Phase 1.6 — P3 (drift gate).** The single-sourcing is now
  **enforced**. A new `pgfc_govern._audit_control_literals()` returns any numeric or interval
  literal that is not a structural constant (`0`/`1`/`0.0`/`1.0`) in the governor's control
  functions, and a pgTAP test asserts it is empty — so an inline magic number fails the build
  on every PostgreSQL version. It is **fail-closed**: it scans *every* `pgfc_govern` function
  by default (minus a small, documented exclusion set — the registry itself, this auditor,
  the operator-retention `retain`/`degrade`, reporting `storage_budget`, and the
  `_log_policy_change` trigger) plus `governor_status`, so a control function added in a later
  phase is enforced automatically — born governed — without anyone remembering to list it.
  Function bodies are pulled by name from the catalog (`pg_proc.prosrc` / `pg_get_viewdef`),
  not by line position, so the check cannot rot; intervals/quantities are scanned first-class
  (a quoted string beginning with a digit), while prose like "(Phase 3)" does not
  false-positive. Building it red-first surfaced one straggler P2 missed — the `interval
  '1 hour'` "autovacuum recently ran" window in `estimate()` — now registered as
  `av_running_window` and read via `_param`. **Not gate-enforced** (documented in the registry
  but may still drift): the excluded functions' `retain()`/`degrade()` signature defaults, the
  `policy` table-column defaults, and `catalog_health`'s reporting windows.

### Changed

- **`docs/` is now the self-contained, as-built spec.** The hand-written guides no
  longer link into `out/technical-design.md` for substance — `concepts.md` explains
  the workload classes, control law, gates, removability horizons, and safety
  guarantees directly. All backward references from the project into `in/`/`out/`
  (docs, READMEs, SQL/test comments, CHANGELOG) were removed; `in/`–`out/` are frozen
  design intent the implementation may diverge from. The doc-drift CI reviewer was
  repointed to treat the code as ground truth and `docs/` as the spec under review.

- **`pgfc_observe.retain(interval)` is no longer row-by-row `DELETE`** — it `TRUNCATE`s
  whole daily partitions, and its default window changed from 14 days to 3 days
  (raw-telemetry retention; long-range history is served by rollups in a later
  increment). The `relation_samples → snapshots` foreign key was removed (partition
  rotation makes a row-level cascade both unused and an obstacle to `TRUNCATE`).

### Removed

- The `relation_samples.snapshot_id → snapshots` foreign key (see Changed).

### Breaking

- **Upgrading `pgfc_observe` across S2 destructively recreates the telemetry tables.**
  Partitioning cannot be added in place, and telemetry is disposable, so re-running
  `pgfc_observe/install.sql` over a pre-S2 install drops and recreates `snapshots`
  and `relation_samples` (existing rows are discarded). The `DROP ... CASCADE` also
  drops dependent cross-schema views such as `pgfc_govern.catalog_health`; re-run
  `pgfc_govern/install.sql` afterward to restore them. This is a deliberate one-time
  exception to `pgfc_observe`'s additive-only rule and does not extend to
  `pgfc_govern`'s audit tables.

### Notes

- No tagged releases yet; the project is pre-1.0 and active control (Phase 2) is in
  progress. Active control is **experimental** in the current code.
