# pgfc_observe

Observe + Orient for `pg_flight_controller` — read-only telemetry for the autovacuum
governor. It periodically snapshots autovacuum-relevant state (per-relation dead
tuples, churn, freeze age, sizes) plus cluster context (GUC defaults, `pg_class`
health, xmin removability horizons), and exposes derived views. It writes only to
its own `pgfc_observe` schema and never modifies database settings — useful on its
own as a monitoring tool.

This is **Phase 0** of the design in [`out/technical-design.md`](../out/technical-design.md).

## Install

```sql
\i install.sql        -- re-runnable; also the upgrade path
```

Remove with `\i uninstall.sql` (`DROP SCHEMA ... CASCADE`).

## Schema evolution

Additive-only: new columns are nullable; existing columns are never dropped or
renamed. Historical rows with `NULL` in a newer column mean "not collected then."
Re-running `install.sql` upgrades in place.

## Tests

From the project root:

```bash
./test.sh 17        # one version (fast)
./test.sh           # full matrix: PG 15, 16, 17, 18
```

Tests are pgTAP files under `tests/`, run with `pg_prove` inside a
postgres+pgTAP container.
