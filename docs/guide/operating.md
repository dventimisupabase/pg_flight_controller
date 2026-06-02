# Operating the governor

Day-to-day use: express policy, read what the governor sees, act on diagnostics, and
— when you're ready — let it change settings. This guide describes the
[v0.1.0 release](https://github.com/dventimisupabase/pg_flight_controller/releases/tag/v0.1.0)
— the governor through Phase 1.7.

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

`governor_metrics` is the one-row self-monitoring substrate (Phase 1.7 F1) the
health-state machine reads — action outcomes over a window, observation lag, loop
durations, and the storage/retention footprint. It always returns one row (counts
`0`, freshness `NULL`) so it never vanishes when the governor is unhealthy:

<!-- doctest -->

```sql
SELECT applied_actions_last_hour, failed_actions_last_hour, lock_timeouts_last_hour,
       observation_lag, last_tick_duration, storage_bytes
FROM pgfc_govern.governor_metrics;
```

## Health state

Each control cycle the governor evaluates its own health (Phase 1.7 F2) from those
metrics and records it as a single state. The states, in order of increasing caution:

- **`normal`** — full operation; actuation permitted.
- **`degraded`** — mild trouble (telemetry going stale, a few failed actions, over the
  storage budget, or the daily mutation budget spent); observe/estimate/diagnose continue
  and actuation is still **permitted** — degraded is "limited," one breaker-step from
  suspension, not suspended.
- **`diagnostic`** — repeated failures, a lock-timeout storm, or control oscillation (a
  setting flapping); **actuation is suspended** (observation and diagnosis continue).
- **`emergency`** — the governor is effectively flying blind (observation badly stale);
  minimal observation and health reporting only, **no actuation**.
- **`disabled`** — nothing acts; history is preserved. Reached **only** via the operator
  override (`disable()`); the automatic evaluator never gets there.

A fresh governor with no observations is `normal`, not `emergency` — absence of data at
boot is not ill health. As of Phase 1.7 F4 the state is **load-bearing, not advisory**: it
is the authority gate `apply()` consults each cycle. When the governor is `diagnostic`,
`emergency`, or `disabled`, `apply()` refuses ordinary actuation; `normal` and `degraded`
permit it (subject to the mutation budget below). A withheld actuation is declined
silently — it is never recorded as a failed action, which would otherwise feed the
failed-action breaker and amplify itself. Refusing to *tighten* a setting never reduces
freeze safety: the prior setting and PostgreSQL's own anti-wraparound autovacuum remain in
place. The automatic evaluator reaches `emergency` via stale observation and `diagnostic`
via failed actions, lock timeouts, control oscillation, or load shedding under connection
pressure (all below).

### Control-oscillation detection (Phase 1.7 F5)

A scale factor that flaps — repeatedly increased, then decreased, then increased — is the
controller fighting itself, a *safety* failure rather than a tuning question. The governor
reads its own catalog-mutation audit (`action_history`, applied changes only) and, per
relation, counts **direction reversals** within a governed window (`oscillation_window`,
default 1 day). A relation with at least `oscillation_min_reversals` reversals (default 2 —
a full up-down-up flap) is flapping. When any relation flaps:

- the governor enters **`diagnostic`**, so the authority gate suspends actuation
  **cluster-wide** (not only for the flapping table) — preferring inaction to an unsafe,
  self-amplifying control loop;
- the flapping relation gets a **`critical` finding** in `active_diagnostics`
  (`inhibitor_class = 'control_oscillation'`) naming the reversal count and recent values;
- recovery is **automatic**: with actuation suspended, no new changes are recorded, so the
  flap ages out of `oscillation_window` and the governor returns to `normal` and resolves the
  finding. (Because the window must be several hours to observe a flap under the 1-hour
  `min_interval`, this suspension is intrinsically multi-hour. An operator who wants control
  back sooner should address the underlying instability — an automatic `diagnostic` cannot be
  forced down, only its cause removed; `clear_forced_state()` only releases *operator* holds.)

### Load shedding (Phase 1.7 F6)

When the database is under **connection pressure**, the governor sheds its *own* load: it
backs off so it stops competing for locks and consumes fewer resources just when the
database needs them most. The stress signal is `connection_pressure` — the count of client
backends divided by `max_connections`, captured on every `observe()` run and exposed in
`governor_metrics`. When it reaches `load_shed_connection_pct` (default `0.90`, a
born-governed registry parameter), the governor enters **`diagnostic`**, so the authority
gate suspends actuation **cluster-wide** — exactly the oscillation mechanism, on a
different signal.

Unlike oscillation, load shedding is **transient**: there is no cooldown window. As soon as
the next snapshot shows pressure has eased, the governor returns to `normal` and resumes. The
condition is surfaced through `governor_state.reason` and the `state_transitions` audit (the
reason names the pressure and backend counts), the same way the failed-action and
lock-timeout breakers are — no separate diagnostic finding. A snapshot from before F6 (or a
fresh governor with nothing observed) has a NULL `connection_pressure` and never sheds —
absence of data is not load.

<!-- doctest -->

```sql
SELECT client_backends, max_connections, connection_pressure
FROM pgfc_govern.governor_metrics;
```

### Mutation budget (Invariant 4)

The governor never performs unlimited corrective actions. Three caps, all enforced in
`apply()` and read live from the active policy:

- **`min_interval`** — at most one mutation per relation per interval (default 1 hour).
- **`global_max_changes_per_cycle`** — a cluster-wide cap on changes in one control cycle.
- **`daily_mutation_budget`** — a cluster-wide cap on changes per rolling day. Spending it
  also trips a `degraded`-level circuit breaker (visible in `governor_state.reason`) — a
  signal, not a suspension: the hard cap in `apply()` already holds the line, and the
  governor keeps acting up to the cap.

Read the current state and the transition history:

<!-- doctest -->

```sql
SELECT state, since, reason FROM pgfc_govern.governor_state;

SELECT transitioned_at, from_state, to_state, reason
FROM pgfc_govern.state_transitions
ORDER BY transition_id DESC
LIMIT 20;
```

## Human override

Operators retain ultimate authority (Phase 1.7 F3). You can force the governor into a
**more cautious** state and release the hold; every force and release is audited as a
state transition, and `governor_state.forced_by` / `forced_at` record who placed the hold
and when.

- **`pgfc_govern.disable(reason)`** — force `disabled`: all control activity ceases,
  history is preserved. The hardest stop. This forces the *health state*, distinct from
  `policy.enabled` (which only gates a policy row from driving the loop).
- **`pgfc_govern.suspend_actuation(reason)`** — force `diagnostic`: actuation is suspended
  but observation and diagnosis continue.
- **`pgfc_govern.force_state(state, reason)`** — force any more-cautious state
  (`degraded` / `diagnostic` / `emergency` / `disabled`). Forcing `normal` is rejected —
  release a hold instead.
- **`pgfc_govern.clear_forced_state(reason)`** — release the hold and return to fully
  automatic control.

The override is a caution **floor**, never a ceiling: the effective state is the *worst*
of the automatic state and the forced state. Forcing `degraded` while the automatic signals
demand `diagnostic` still yields `diagnostic` — a human can force more caution, never less.

<!-- doctest -->

```sql
-- stop the governor acting while you investigate, then resume:
SELECT pgfc_govern.suspend_actuation('investigating lock contention');
SELECT pgfc_govern.clear_forced_state('all clear');
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

### Failure taxonomy (Phase 1.7 F6)

Every failure the governor can experience belongs to one of five categories (appendix F):
**observation**, **decision**, **actuation**, **resource**, and **safety**. The
`failure_taxonomy` view is the whole picture in five rows — for each category,
`condition_present` is the live signal (drawn from the same `governor_metrics` substrate the
health-state machine reads) and `recorded_failures_last_day` counts the audited failures
stamped with that class:

<!-- doctest -->

```sql
SELECT failure_class, condition_present, recorded_failures_last_day, detail
FROM pgfc_govern.failure_taxonomy;
```

Each *recorded* failure in `action_history` also carries its category in `failure_class`,
mapped from `failure_reason` by `_failure_class()` (the single source of the mapping). Today
the governor records only **actuation** failures — a lock timeout or a permission error from
`apply()`; the other categories surface through their live signals (control oscillation →
safety, the storage-budget breach → resource, stale telemetry → observation, a cycle that
errored → decision) until later actuators add their own recorded failure sites.

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

`pgfc_govern.control_tick()` is the **sole sanctioned entrypoint** for a control cycle: it
takes the advisory lock, evaluates health, plans, and then actuates under the full safety
net. The functions beneath it — `plan()`, and especially `apply()` — are **internal** and
must not be called directly; calling `apply()` out of cycle would act on a stale health
state and bypass the serialization `control_tick()` provides.

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

In databases with thousands of relations you can bound *which* relations `observe()`
samples through the single-row `pgfc_observe.collection_policy` table. System schemas
(`pg_catalog`, `information_schema`, and the governor's own schemas) are always
excluded; the policy adds four further filters:

- `exclude_temp` (default `true`) — skip temporary tables.
- `include_extension_owned` (default `false`) — skip relations owned by an extension.
- `excluded_schemas` (default `{}`) — extra schemas to skip, *additive* to the system
  list (it can never re-include `pg_catalog`).
- `min_partition_size_bytes` (default `0`, disabled) — skip child partitions smaller
  than this, so a partition-heavy schema does not flood collection.

Change them in place, e.g.:

```sql
UPDATE pgfc_observe.collection_policy
   SET excluded_schemas = ARRAY['staging','scratch']::name[],
       min_partition_size_bytes = 10 * 1024 * 1024;   -- 10 MB
```

The filters apply at collection, so rollups and the `pgfc_govern` views inherit the
filtered set automatically.

### Which role runs the loop

`pg_cron` executes each job as the role that owns it (by default, whoever called
`cron.schedule`). The loop is not pure DML — it maintains its own storage with DDL:
`observe_tick()` runs `CREATE TABLE … PARTITION OF` for each new day, `retain()` runs
`TRUNCATE`, and `drop_empty_partitions()` runs `DROP TABLE`. Those need *ownership* of the
partitioned telemetry tables, not table grants.

- **Simplest (recommended): own the extension objects.** Run the cron jobs as the role that
  installed the extensions — it owns the `pgfc_observe`/`pgfc_govern` tables, so the partition
  DDL, all reads/writes, and `EXECUTE` on the functions are covered with no extra grants.
- **A more confined role** must additionally be granted `USAGE` on both schemas, `EXECUTE` on
  their functions, read/write (`SELECT`/`INSERT`/`UPDATE`) on their tables, **and ownership of
  the partitioned parent tables plus `TRUNCATE`** (for the `CREATE PARTITION OF` / `TRUNCATE` /
  `DROP` above) — otherwise the first partition roll or nightly `retain()` fails.
- For **active control** (`advisory_only = false`), the role additionally needs the right to
  run the `ALTER TABLE` that `apply()` issues — i.e. ownership of, or membership in the owning
  role of, each governed table.

`apply()` is `SECURITY INVOKER` by design: it mutates the catalog with the **caller's** own
rights, so it can never confer authority a direct `ALTER TABLE` would not. The practical
payoff is verifiable least privilege — revoke the cron role's `ALTER` on a table (`\dp`) and
the governor instantly and completely loses the ability to change it. (A `SECURITY DEFINER`
actuator would invert this, acting with the definer's rights regardless of the caller; if you
ever adopt that posture, confine it and keep the pinned `search_path` below.)

Every plpgsql function in both extensions pins an explicit `SET search_path` (`pgfc_govern,
pgfc_observe, pg_catalog` in `pgfc_govern`; `pgfc_observe, pg_catalog` in `pgfc_observe`), so
object resolution never depends on the caller's `search_path` — defense-in-depth that also
forecloses a `search_path` injection surface should any function later become
`SECURITY DEFINER`.

## Watch the governor's own footprint

A system that watches the database every minute is a storage liability of its own, so
it reports and bounds its own footprint. Every telemetry and rollup partition carries
**static** autovacuum reloptions (`scale_factor = 0` plus a fixed threshold) and the
`pgfc_govern` audit/state tables carry matching settings — the governor maintains its
own schema explicitly rather than governing itself. See it with:

```sql
-- per-relation bytes + dead tuples (dead tuples should stay near zero — the raw and
-- rollup tables rotate by TRUNCATE/DROP, never DELETE):
SELECT * FROM pgfc_observe.storage_budget();      -- observe schema only
SELECT * FROM pgfc_govern.storage_budget();       -- both schemas, tagged

-- one-row summaries:
SELECT * FROM pgfc_observe.self_health;            -- observe footprint + partition counts
SELECT * FROM pgfc_govern.self_health;             -- whole-governor footprint vs the cap
```

By default there is no cap and nothing is ever auto-pruned beyond the routine
retention above. To bound worst-case growth, set a total-bytes cap (across **both**
schemas) and let `degrade()` enforce it:

```sql
UPDATE pgfc_govern.storage_config SET budget_bytes = 2 * 1024 * 1024 * 1024;  -- 2 GB
SELECT * FROM pgfc_govern.degrade();   -- prunes only while over budget
```

`degrade()` sheds storage in a **fixed order, most disposable first** — raw
observations → fine (1m) rollups → coarse (1h/1d) rollups → resolved diagnostics →
decisions/actions — and stops the moment the footprint is back under budget; the
levels it never reached are reported as `skipped`. Policy and `policy_history` (the
human-owned record of intent) are **never** pruned. With no `budget_bytes` configured
`degrade()` does nothing, so it can never silently destroy telemetry. Drive it off the
`over_budget` flag, or schedule it after the routine retention jobs:

```sql
SELECT cron.schedule('pgfc_govern_degrade', '27 3 * * *', $$SELECT pgfc_govern.degrade()$$);
```

## Inspect the governed parameters

The governor replaces autovacuum folklore with a control framework, so it must not hide
folklore of its own: every governed constant — every threshold, bound, interval, ratio,
and target — is registered with its category, value, unit, rationale, owner, and
provenance, and is inspectable without reading source. The unified registry spans both
schemas:

<!-- doctest -->

```sql
SELECT schema_name, parameter_name, category, default_value, unit, override_allowed
FROM pgfc_govern.parameter_registry
ORDER BY schema_name, parameter_name;
```

Each row's `category` is one of `postgresql_derived`, `safety_bound`,
`empirical_default`, `operator_policy`, `adaptive_value`, or
`implementation_convenience`; `override_allowed` (independent of category) says whether an
operator may change it, and `config_ref` names where — e.g. `policy.aggressiveness`. Many
control values are honestly marked `MVP estimate — not yet benchmarked` in their
`source`: that is the validation backlog, made visible on purpose. (An observe-only
install reads `pgfc_observe._parameter_registry()` directly.)

To check that your *live* configuration is safe — without reading source —
`validate_parameters()` grades each operator-set value against the registry's safety
bounds:

<!-- doctest -->

```sql
SELECT parameter, status, message
FROM pgfc_govern.validate_parameters()
WHERE status <> 'OK';
```

`status` is `OK`, `WARNING`, or `CRITICAL`. It checks hard safety properties, not tuning
opinions: e.g. `aggressiveness <= 0` is `CRITICAL` (every class target is
`template / aggressiveness`), while `advisory_only = false`, a zero mutation budget, or
`n_sustain` below 1 are `WARNING`s. An empty result means nothing needs attention.

## Enabling active control

Active control is the supported `advisory_only = false` path. `apply()` implements the
scale-factor lever with its full safety mechanics (live no-op check, ownership, rollback
baseline, non-blocking locks, failure recording) under the Phase 1.7 self-protection layer
— the [health-state authority gate](#health-state) and the three-tier
[mutation budget](#mutation-budget-invariant-4). Only the scale-factor lever is wired to
actuation today; the small-table threshold lever and the analyze objective remain future
work. Run advisory for a while first and review the decision trail.

When you're satisfied with what the governor proposes, let it act by flipping one
flag:

```sql
UPDATE pgfc_govern.policy SET advisory_only = false WHERE policy_name = 'default';
```

From the next `control_tick()`, approved `adjust` decisions are applied as
`ALTER TABLE` changes — each recorded in `action_history` and reversible. Two guarantees
make this safe to turn on:

- **It plans against settled state.** `control_tick()` actuates only against the newest
  snapshot whose `estimate()` phase has completed, so it never acts on fresh observations
  paired with the prior cycle's hidden state — even when `observe_tick()` and
  `control_tick()` run on independent schedules.
- **The live catalog is the arbiter.** `apply()` re-reads `pg_class.reloptions` at the
  moment it acts; if a human changed the value to the proposal in the meantime, the adjust
  is silently downgraded to a no-op rather than re-applied.

Everything the governor changed can be rolled back; see
[Safety first](concepts.md#safety-first) for the guarantees.
