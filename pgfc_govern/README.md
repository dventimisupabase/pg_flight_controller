# pgfc_govern

Decide + Act for `pg_flight_controller` — the autovacuum governor's control loop. It
reads `pgfc_observe` (cross-schema, read-only), classifies each relation, estimates
its hidden maintenance state, and decides per-table autovacuum setpoints — moving
them toward per-class targets with minimal catalog mutation, and diagnosing (rather
than escalating) when an external inhibitor blocks progress.

Depends on **pgfc_observe** (install it first).

This is **Phase 1** of the design in [`out/technical-design.md`](../out/technical-design.md).

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

## Tests

From the project root (installs both extensions, runs both suites):

```bash
./test.sh 17        # one version (fast)
./test.sh           # full matrix: PG 15, 16, 17, 18
```
