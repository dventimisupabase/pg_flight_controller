# Getting started

This walks you from a clean database to a running, **advisory** governor — one that
tells you what it *would* do without changing anything.

## Prerequisites

- PostgreSQL 15, 16, 17, or 18.
- Privileges to create schemas and read the statistics views (a superuser or a role
  with the right grants).
- For scheduling, the [`pg_cron`](https://github.com/citusdata/pg_cron) extension
  (optional — you can also call the loop functions by hand).

## Install

`pgfc_govern` depends on `pgfc_observe`, so install observe first:

```sql
\i pgfc_observe/install.sql
\i pgfc_govern/install.sql
```

Both scripts are idempotent — re-running them is the upgrade path.

## Observe

`pgfc_observe` collects a *snapshot* of autovacuum-relevant state. Take one and look
at the per-relation maintenance debt:

<!-- doctest -->

```sql
SELECT pgfc_observe.observe();        -- returns the new snapshot_id

SELECT relname, dead_tuple_fraction, vacuum_debt_ratio, freeze_debt
FROM pgfc_observe.maintenance_debt
ORDER BY vacuum_debt_ratio DESC NULLS LAST
LIMIT 10;
```

- `dead_tuple_fraction` — how much of the table is dead tuples right now.
- `vacuum_debt_ratio` — `n_dead_tup / trigger`; `> 1` means the table is past its
  autovacuum trigger and waiting.
- `freeze_debt` — `relfrozenxid` age as a fraction of the wraparound limit.

Every column is described in the [`pgfc_observe` reference](../reference/pgfc_observe.md).

## Run the governor (advisory)

`pgfc_govern` adds the control loop. With the default policy it is **advisory**:
`apply()` never fires, so no setting changes.

<!-- doctest -->

```sql
SELECT pgfc_govern.observe_tick();    -- observe + classify + estimate
SELECT pgfc_govern.control_tick();    -- plan + verify

SELECT relname, kind, target_dead_fraction, decision, proposed_value
FROM pgfc_govern.governor_status
ORDER BY relname
LIMIT 10;
```

`decision` is what the governor *would* do for each relation:

- `hold` — already at target (or nothing to change).
- `adjust` — it would set `autovacuum_vacuum_scale_factor` to `proposed_value`.
- `escalate:io_limited` / `escalate:inhibited:<owner>` — more aggressiveness can't
  help; see [diagnostics](operating.md#diagnostics).
- `suppressed:*` — a guard declined (e.g. a user-owned setting).

Nothing has been applied. To understand *why* the governor decides as it does, read
[Concepts](concepts.md); to configure it and (eventually) let it act, read
[Operating the governor](operating.md).

## Schedule it

In production the two loops run on separate cadences — observe frequently, act rarely:

```sql
SELECT cron.schedule('pgfc_observe', '* * * * *',   $$SELECT pgfc_govern.observe_tick()$$);
SELECT cron.schedule('pgfc_control', '*/5 * * * *', $$SELECT pgfc_govern.control_tick()$$);
```

(`pg_cron` runs in one database; install the governor there.)
