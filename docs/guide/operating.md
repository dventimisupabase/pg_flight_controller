# Operating the governor

Day-to-day use: express policy, read what the governor sees, act on diagnostics, and
— when you're ready — let it change settings.

## Express policy

Policy is *intent*, not parameters. The default policy is seeded for you; adjust it
rather than touching scale factors. The full column list is in the
[`pgfc_govern` reference](../reference/pgfc_govern.md); the knobs you'll reach for:

- **`aggressiveness`** — scales every class target. `> 1` keeps tables cleaner
  (lower dead-tuple targets); `< 1` tolerates more bloat to save maintenance I/O.
- **`advisory_only`** — `true` (default): plan and diagnose, never act. `false`:
  let `apply()` actuate.
- **`manage_user_owned`** — `false` (default): never overwrite a setting a human or
  another system set first; `true`: take ownership.
- **`freeze_posture`**, **`min_interval`**, **`global_max_changes_per_cycle`**,
  **`daily_mutation_budget`** — safety / actuation-economy limits.

<!-- doctest -->

```sql
-- Keep tables cleaner than the defaults, but stay advisory:
UPDATE pgfc_govern.policy
SET aggressiveness = 1.5
WHERE policy_name = 'default';

SELECT policy_name, aggressiveness, advisory_only, manage_user_owned
FROM pgfc_govern.policy
WHERE enabled;
```

Class targets are not edited directly — they come from the relation's class and the
policy. To override one relation's class, set it manually (the governor won't
auto-change a `manual` classification):

```sql
UPDATE pgfc_govern.relation_class
SET kind = 'queue', source = 'manual'
WHERE relid = 'public.my_job_queue'::regclass;
```

## Read what it sees

`governor_status` is the per-relation picture — class, target, observed state, and
the latest decision:

<!-- doctest -->

```sql
SELECT relname, kind, target_dead_fraction, vacuum_debt_ratio,
       decision, proposed_value, current_scale_factor
FROM pgfc_govern.governor_status
ORDER BY vacuum_debt_ratio DESC NULLS LAST
LIMIT 10;
```

`catalog_health` shows the governor's *own* footprint (how much DDL it has issued)
plus the live `pg_class` condition — so its catalog cost stays visible:

<!-- doctest -->

```sql
SELECT mutations_last_hour, mutations_last_day, failed_last_day,
       relations_changed_last_day, pg_class_n_dead_tup
FROM pgfc_govern.catalog_health;
```

## Diagnostics

When more aggressiveness can't help, the governor records a finding instead of
escalating. Read the open ones, worst first:

<!-- doctest -->

```sql
SELECT severity, inhibitor_class, recommendation
FROM pgfc_govern.active_diagnostics
LIMIT 20;
```

How to read `inhibitor_class`:

- **`autovacuum_not_running`** — debt is high but autovacuum hasn't run. Lowering
  thresholds won't help (the table is already overdue); check that autovacuum is
  enabled and keeping up.
- **`io_limited`** — vacuum keeps up effort but not pace. Consider more autovacuum
  workers or cost-limit headroom (governor support is a later phase).
- **`long_running_txn` / `replication_slot` / `prepared_xact` / `standby_feedback`**
  — something is pinning the xmin horizon so vacuum can reclaim nothing. The
  recommendation names the holder; clearing it (end the transaction, advance/drop the
  slot) is the fix. This is the case where a wraparound emergency is *not* solved by
  more vacuuming.

## Schedule

Run the two loops on separate cadences with `pg_cron` (observe often, act rarely):

```sql
SELECT cron.schedule('pgfc_observe', '* * * * *',   $$SELECT pgfc_govern.observe_tick()$$);
SELECT cron.schedule('pgfc_control', '*/5 * * * *', $$SELECT pgfc_govern.control_tick()$$);

-- roll raw samples up into the long-range tiers BEFORE retain() truncates them:
SELECT cron.schedule('pgfc_observe_rollup', '2 3 * * *',   $$SELECT pgfc_observe.rollup()$$);

-- prune old data so neither schema grows without bound:
SELECT cron.schedule('pgfc_observe_retain', '7 3 * * *',   $$SELECT pgfc_observe.retain()$$);
SELECT cron.schedule('pgfc_observe_rollup_gc', '12 3 * * *', $$SELECT pgfc_observe.rollup_retain()$$);
SELECT cron.schedule('pgfc_observe_gc',     '23 4 1 * *',  $$SELECT pgfc_observe.drop_empty_partitions()$$);
SELECT cron.schedule('pgfc_govern_retain',  '17 3 * * *',  $$SELECT pgfc_govern.retain()$$);
```

The high-volume telemetry tables (`snapshots`, `relation_samples`) are **daily
`RANGE` partitioned** on an `int4` epoch-day key, and retention is whole-partition
rotation — never row-by-row `DELETE` — so it reclaims space instantly and leaves zero
dead tuples (the governor never becomes its own vacuum burden). Two tiers:

- `pgfc_observe.retain()` (nightly) `TRUNCATE`s partitions older than the window
  (default 3 days), keeping the empty shell.
- `pgfc_observe.drop_empty_partitions()` (monthly) `DROP`s the long-empty shells
  (default 30 days); it never drops a partition that still holds data.

`pgfc_observe.observe()` creates each day's partition on demand, so no partition
pre-creation job is needed. `pgfc_govern.retain()` prunes the low-volume audit tables
by time cutoff — decisions and actions (180 days), tick log (180 days), and resolved
diagnostics (365 days); `policy_history` is kept indefinitely. All windows are
arguments you can override. Inspect partitions with
`SELECT * FROM pgfc_observe._partition_inventory()`.

Raw samples rotate away within a couple of days, so long-range history lives in three
aggregate tiers — `rollup_1m`, `rollup_1h`, `rollup_1d` — built by
`pgfc_observe.rollup()`. It **must run before raw is truncated**, but the real
guarantee is the raw retention *window*, not cron ordering: as long as `rollup()` runs
at least once per window (run it daily), no raw bucket is lost — `rollup()` is
idempotent, so an extra run never double-counts. The tiers are partition-rotated like
raw, but the partition span tracks the tier (1m daily, 1h/1d monthly), and
`rollup_retain()` drops them on **cascading per-tier windows** (1m 7 days, 1h 90 days,
1d 365 days — all overridable). Because rollups are sparse like raw, query long-range
state with `pgfc_observe.current_rollup('1h')` (or `'1m'`/`'1d'`), which carries the
last known bucket forward so a quiet relation stays answerable after its raw samples
are gone. Inspect rollup partitions with
`SELECT * FROM pgfc_observe._rollup_inventory()`.

`observe()` also logs **sparsely**: it writes a `relation_samples` row only when a
relation's observed state changed since its last sample, so quiet relations cost
nothing per run. The per-relation last state lives in the `UNLOGGED`
`relation_last_state` side table — a rebuildable cache, so it is expected to be empty
after a crash (the next `observe()` re-samples every relation once and refills it).
Never query `relation_samples` directly for "the current state of every relation";
use `pgfc_observe.current_relation_state()` (or the `relation_health` /
`maintenance_debt` views built on it), which reconstructs the dense view from sparse
storage and recomputes freeze ages live.

## Enabling active control

> **Phase status.** Active control is **experimental** in this release. `apply()`
> implements the scale-factor lever with its full safety mechanics (live no-op check,
> ownership, rollback baseline, non-blocking locks, failure recording), but the
> actuation-economy rate limits, the small-table threshold lever, and the analyze
> objective land in Phase 2. Run advisory for a while first and review the decision
> trail.

When you're satisfied with what the governor proposes, let it act by flipping one
flag:

```sql
UPDATE pgfc_govern.policy SET advisory_only = false WHERE policy_name = 'default';
```

From the next `control_tick()`, approved `adjust` decisions are applied as batched
`ALTER TABLE` changes — each recorded in `action_history` and reversible. Everything
the governor changed can be rolled back; see the
[safety system](../../out/technical-design.md#safety-system) for the guarantees.
