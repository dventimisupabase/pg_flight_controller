# Concepts

The mental model behind the governor — enough to operate it and to read its
decisions. This page is self-contained; the [reference](../reference/pgfc_govern.md)
has the exhaustive table, view, and function lists. It describes the
[v0.1.0 release](https://github.com/dventimisupabase/pg_flight_controller/releases/tag/v0.1.0)
— the governor through Phase 1.7.

## Autovacuum settings are actuator positions

PostgreSQL's autovacuum is highly configurable but fundamentally static: you pick
scale factors and thresholds and hope they stay appropriate. pg_flight_controller
reframes those per-table settings as **actuator positions** that a supervisory loop
moves to hold a desired *outcome*. You express policy (how clean each kind of table
should be kept); the governor finds the settings that achieve it.

It never runs `VACUUM` itself. It is an **outer loop wrapped around autovacuum's own
inner loop** — it moves the setpoints that decide when autovacuum fires.

## The loop: observe → estimate → decide → act

The governor runs as two cadences:

- **Fast loop** (`observe_tick`, ~1 min): `observe()` snapshots the database,
  `classify()` assigns each relation a workload class, `estimate()` derives hidden
  state (write rates, cleanup effectiveness, saturation cause). It never changes
  anything.
- **Control loop** (`control_tick`, ~5 min): `plan()` decides setpoints, `apply()`
  acts **only if the policy is not advisory**, and `verify()` closes the loop.

Observing often does not mean acting often — that separation is deliberate.

## Workload classes

`classify()` puts each relation in one of six classes from its recent write mix —
the insert / update / delete deltas across the trailing snapshots. A relation needs
at least ~50 recent writes before it is classified on those fractions; below that
floor it keeps its current class. The first rule that matches wins:

| Class | Matches when (of recent `ins + upd + del`) | Typical table |
|---|---|---|
| `append_only` | inserts > 95% **and** deletes < 1% | event / audit log |
| `queue` | deletes > 30% **and** roughly balanced with inserts | job queue |
| `delete_heavy` | deletes > 30% | retention / pruning |
| `oltp` | updates > 30% | mutable business rows |
| `mixed` | none of the above | default |

A brand-new relation with no write history is `archive` if it is large (> ~100k
rows) and idle, otherwise `mixed`.

To stop classes from flapping, a newly computed class must persist for several cycles
(hysteresis, default 3) before it is committed. You can pin a relation's class by
hand (`source = 'manual'`); the governor never auto-changes a manual classification.

## What it steers: the dead-tuple fraction

The quantity the governor regulates is the **dead-tuple fraction at trigger** —
roughly, how dirty a table is allowed to get before autovacuum cleans it. That
fraction is essentially the scale factor, so the governor computes a target and moves
the scale factor to it (a *feedforward* move).

Each class has a target dead fraction:

| Class | Target dead fraction |
|---|---|
| `queue` | 0.05 |
| `delete_heavy` | 0.10 |
| `oltp` | 0.20 |
| `mixed` | 0.20 |
| `append_only` | 0.40 |
| `archive` | 0.50 |

One policy knob, **`aggressiveness`**, scales them all: the effective target is
`template / aggressiveness`, clamped to `[0.01, 0.50]`. `> 1` keeps every table
cleaner (lower targets); `< 1` tolerates more bloat to save maintenance I/O. You
never set scale factors directly.

## Movement has cost, so act rarely

Every change is an `ALTER TABLE`: it takes a lock and mutates `pg_class` (an MVCC
catalog write). So the governor treats *its own actuation frequency* as a second
controlled variable and converges with the **minimum necessary change**. The gates
that enforce this:

- **Quantization.** Targets snap to a small grid of allowed scale factors — `0.01,
  0.02, 0.05, 0.10, 0.20, 0.30, 0.50`. The grid spacing acts as a deadband: a target
  that rounds to the current value asks for no change.
- **No-op suppression.** If the snapped target equals the live setting, the decision
  is `hold` and nothing is written.
- **Ownership guard.** By default the governor will not overwrite a scale factor a
  human or another system set first (decision `suppressed:user_owned`);
  `manage_user_owned = true` opts in to taking ownership.
- **Rate limit + budget.** A per-relation minimum interval, a per-cycle cap, and a
  daily cluster-wide mutation budget bound how often the governor acts. These policy
  knobs are enforced at the single `apply()` chokepoint (Invariant 4), so they take
  effect the moment [active control](operating.md#enabling-active-control) is enabled.
  Under the default advisory policy nothing is applied at all; the three gates above
  are what hold the *planned* churn down.

## Diagnose, don't escalate

The governor controls *maintenance progress*, not autovacuum activity — and more
aggressiveness sometimes can't help. When debt stays high, `estimate()` records a
**saturation cause**, and `plan()` reacts to the cause instead of blindly lowering
the trigger:

- **`config`** — autovacuum is not running for the table at all. Lowering its trigger
  can't help (it's already overdue), so the governor **suppresses the change**
  (`suppressed:not_firing`) and raises a diagnostic.
- **`io_limited`** — vacuum runs and does reclaim, but churn outruns it. The
  scale-factor lever is exhausted, so the decision is `escalate:io_limited` (more
  workers / cost-limit headroom is a later phase), not a futile further lowering.
- **`inhibited`** — vacuum runs but reclaims nothing because the dead tuples aren't
  yet removable: an external holder is pinning the xmin horizon. No setting helps, so
  the decision is `escalate:inhibited:<owner>` and a `critical` diagnostic names the
  holder.

### Removability horizons

A dead tuple can only be vacuumed once it is older than the oldest snapshot any
session might still need — the **xmin horizon**. `observe()` records what is holding
that horizon back and attributes it to an owner class:

- **`long_running_txn`** — an old, still-open transaction.
- **`replication_slot`** — a lagging or inactive replication slot.
- **`prepared_xact`** — an uncommitted prepared (two-phase) transaction.
- **`standby_feedback`** — a standby pinning the horizon via `hot_standby_feedback`.
- **`none`** — nothing is pinning it.

This is the distinction between the high-level saturation cause (`config` /
`io_limited` / `inhibited`) and the specific inhibitor: when the cause is `inhibited`,
the `inhibitor_class` on the diagnostic is the owner above. It is why "more
vacuuming" is not always the answer, and why the governor surfaces an actionable
explanation instead of thrashing the actuator.

## Safety first

Anti-wraparound safety dominates everything. When a table's **freeze debt** is high —
its `relfrozenxid` (or multixact) age past ~60% of the wraparound limit — the governor
drives its scale factor to the cleanest grid value rather than ever relaxing cleanup,
and that freeze floor overrides the saturation suppressions above. It never disables
autovacuum and never raises a freeze-stressed table's trigger. If a freeze emergency
is itself blocked by a pinned horizon, it **diagnoses** (`escalate:inhibited:<owner>`)
rather than uselessly hammering the actuator. Every applied change captures a rollback
baseline and is ownership-checked, so it can be reverted to exactly the prior state.

## Advisory by default

With the default policy, `advisory_only = true`: the loop runs end to end and writes
a complete decision and diagnosis trail, but `apply()` never fires. You can watch
"what it would do" for as long as you like before granting it the ability to act —
which is a single policy flip. See [Operating the governor](operating.md).
