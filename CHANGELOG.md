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

### Notes

- No tagged releases yet; the project is pre-1.0 and active control (Phase 2) is in
  progress. Active control is **experimental** in the current code.
