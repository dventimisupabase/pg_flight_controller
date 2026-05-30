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
- **Documentation** — top-level `README.md`, the `docs/` guide set (getting started,
  concepts, operating), generated schema reference under `docs/reference/`, and the
  `out/technical-design.md` architecture narrative — including the decided
  **observation storage and self-maintenance** model (partition-rotation retention,
  sparse change-logging, rollups, governor self-maintenance) and the **Phase 1.5**
  storage increments (S1–S6), built before active control.
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

### Changed

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
