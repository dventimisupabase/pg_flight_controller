# pgfc_govern

Decide + Act for `pg_flight_controller` — the autovacuum governor's control loop. It
reads `pgfc_observe` (cross-schema, read-only), classifies each relation, estimates
its hidden maintenance state, and decides per-table autovacuum setpoints — moving
them toward per-class targets with minimal catalog mutation, and diagnosing (rather
than escalating) when an external inhibitor blocks progress.

Depends on **pgfc_observe** (install it first).

This is **Phase 1** of the governor: advisory by default. For the concepts and the
full guide set, see [`docs/`](../docs/index.md).

## Advisory by default

Every policy ships with `advisory_only = true`: the loop runs `classify → estimate →
plan → verify` and writes a complete `decision_log` / `diagnostics` trail, but
`apply()` never fires — no `ALTER TABLE`, no setting is ever changed. Active control
(Phase 2) is a single policy flip.

## Install

```sql
\i ../pgfc_observe/install.sql   -- dependency, first
\i install.sql                   -- re-runnable; also the upgrade path
```

Remove with `\i uninstall.sql` (`DROP SCHEMA ... CASCADE`); leaves pgfc_observe intact.

## Verify it works (advisory)

Run one fast loop and one control loop, then read what the governor *would* do —
with the default policy nothing is ever applied:

<!-- doctest -->

```sql
SELECT pgfc_govern.observe_tick();    -- observe + classify + estimate
SELECT pgfc_govern.control_tick();    -- plan + verify (advisory: apply() never fires)
SELECT relname, kind, decision, proposed_value
FROM pgfc_govern.governor_status
ORDER BY relname
LIMIT 5;
```

(A doctest — CI runs it against a fresh install on every PR.)

## What's here (Phase 1)

Functions: `observe_tick()` (observe + `classify` + `estimate`) and `control_tick()`
(`plan` + `apply`-if-not-advisory + `verify`), driven by pg_cron in production.
Core steps: `classify()`, `estimate()`, `plan()`, `apply()`, `verify()`, plus the
`removability`-aware diagnosis. Views: `governor_status`, `catalog_health`,
`active_diagnostics`. `retain()` prunes the append-only audit tables by time cutoff,
and `policy_history` records policy changes (kept indefinitely) — schedule `retain()`
daily with pg_cron alongside the loops.

Self-maintenance (S6): the audit/state tables carry **static** autovacuum reloptions,
`storage_budget()` reports per-relation bytes + dead tuples across **both** schemas,
and the one-row `self_health` view compares the whole-governor footprint to the
`storage_config.budget_bytes` cap (`over_budget`). `degrade()` enforces the cap by
shedding storage in a fixed order — raw → fine rollups → coarse rollups → diagnostics
→ actions — stopping once under budget; policy is never pruned, and with no cap
configured `degrade()` is a no-op.

### Deliberately deferred (so scope is explicit, not accidental)

- **Threshold lever and the analyze objective.** `plan()` moves the vacuum
  scale-factor lever only; the small-table threshold lever and the analyze-objective
  decision are follow-ups.
- **Actuation-economy gates** (per-relation / global / daily rate limits,
  sustained-deviation) — Phase 2, when `apply()` is enabled in earnest.
- **`verify()`** is a no-op in Phase 1 (nothing is applied to attribute); Phase 2
  expands it.
- **`apply()`** is implemented (single-actuator, with live no-op, ownership,
  baseline capture, 100 ms non-blocking lock, failure recording) but only ever runs
  when `advisory_only = false`.

### Recorded hazards to address when Phase 2 turns on active control

- **Loop ordering contract.** `control_tick()` plans against `max(snapshot_id)`, so
  `estimate()` for that snapshot must have completed before the control loop
  consumes it. The advisory lock serializes `control_tick()` against itself but
  **not** against `observe_tick()`; on two independent cron schedules a control
  cycle could read a snapshot whose estimate hasn't run yet (those relations are
  skipped via the LEFT JOIN, not mis-planned). Make the ordering explicit before
  actuation depends on it.
- **`apply()` stale-window downgrade is untested.** `apply()` re-reads live
  `pg_class.reloptions` and is the authoritative arbiter (can downgrade
  `adjust → no_op` when a human changed the value between observe and apply), but no
  test yet exercises the case where the live value differs from what `plan()` saw.
  Add it when `apply()` goes live.

## Tests

From the project root (installs both extensions, runs both suites):

```bash
./test.sh 17        # one version (fast)
./test.sh           # full matrix: PG 15, 16, 17, 18
```
