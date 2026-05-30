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

## Verify it works

Collect one snapshot and look at the per-relation maintenance debt:

<!-- doctest -->

```sql
SELECT pgfc_observe.observe();                 -- returns the new snapshot_id
SELECT relname, dead_tuple_fraction, vacuum_debt_ratio, freeze_debt
FROM pgfc_observe.maintenance_debt
ORDER BY vacuum_debt_ratio DESC NULLS LAST
LIMIT 5;
```

(The example above is a doctest — CI runs it against a fresh install on every PR, so
it can't silently fall out of date.)

## Storage

`snapshots` and `relation_samples` are **daily `RANGE` partitioned** on an `int4`
epoch-day key (`collected_day`). `observe()` creates each day's partition on demand;
retention is whole-partition rotation, so it produces zero dead tuples:

- `retain()` (nightly) `TRUNCATE`s partitions older than its window (default 3 days).
- `drop_empty_partitions()` (monthly) `DROP`s the empty shells (default 30 days).

Inspect partitions with `SELECT * FROM pgfc_observe._partition_inventory()`.

Logging is also **sparse**: `observe()` writes a `relation_samples` row only when a
relation's observed state changed since its last sample (tracked in the `UNLOGGED`
`relation_last_state` side table), so quiet relations cost nothing per run. To read
"the current state of every relation," use `current_relation_state()` — or the
`relation_health` / `maintenance_debt` views built on it — which reconstructs the
dense view from sparse storage and recomputes the (globally-ticking) freeze ages live
from the stored raw `relfrozenxid` / `relminmxid`. `relation_last_state` is a
rebuildable cache, so it is empty after a crash until the next `observe()` refills it.

For large schemas, the single-row `collection_policy` table bounds *which* relations
`observe()` samples: it always skips the system schemas and adds optional filters for
temporary tables (`exclude_temp`), extension-owned relations
(`include_extension_owned`), extra schemas (`excluded_schemas`), and sub-threshold
child partitions (`min_partition_size_bytes`). Rollups and the `pgfc_govern` views
inherit the filtered set automatically.

Every partition is created with **static** autovacuum reloptions (`scale_factor = 0`
plus a fixed threshold) so the governor maintains its own schema explicitly rather
than governing itself. Report the footprint with `storage_budget()` (per-relation
bytes + dead tuples, child partitions folded into their parent) and the one-row
`self_health` view (totals + partition counts). Dead tuples should stay near zero —
the tables rotate by `TRUNCATE`/`DROP`, never `DELETE`. (A whole-system, cross-schema
budget plus a `degrade()` prune-order enforcer live in `pgfc_govern`.)

## Schema evolution

Additive-only: new columns are nullable; existing columns are never dropped or
renamed. Historical rows with `NULL` in a newer column mean "not collected then."
Re-running `install.sql` upgrades in place.

> **One-time exception (S2).** Adding partitioning could not be done in place, so
> re-running `install.sql` over a pre-S2 install **destructively recreates** the two
> telemetry tables (telemetry is disposable). This `DROP ... CASCADE` also drops
> dependent cross-schema views such as `pgfc_govern.catalog_health` — re-run
> `pgfc_govern/install.sql` afterward to restore them.

## Tests

From the project root:

```bash
./test.sh 17        # one version (fast)
./test.sh           # full matrix: PG 15, 16, 17, 18
```

Tests are pgTAP files under `tests/`, run with `pg_prove` inside a
postgres+pgTAP container.
