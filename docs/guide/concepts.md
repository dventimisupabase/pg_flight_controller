# Concepts

The mental model behind the governor. For the full architecture and rationale, see
the [technical design](../../out/technical-design.md); this is the orientation.

## Autovacuum settings are actuator positions

PostgreSQL's autovacuum is highly configurable but fundamentally static: you pick
scale factors and thresholds and hope they stay appropriate. pg_flight_controller
reframes those per-table settings as **actuator positions** that a supervisory loop
moves to hold a desired *outcome*. You express policy (how clean each kind of table
should be kept); the governor finds the settings that achieve it.

It never runs `VACUUM` itself. It is an **outer loop wrapped around autovacuum's own
inner loop** — it moves the setpoints that decide when autovacuum fires.

## The loop: observe → estimate → decide → act

The governor runs as two cadences (see [scheduling](../../out/technical-design.md#scheduling)):

- **Fast loop** (`observe_tick`, ~1 min): `observe()` snapshots the database,
  `classify()` assigns each relation a workload class, `estimate()` derives hidden
  state (rates, effectiveness, saturation). It never changes anything.
- **Control loop** (`control_tick`, ~5 min): `plan()` decides setpoints, `apply()`
  acts **only if the policy is not advisory**, and `verify()` closes the loop.

Observing often does not mean acting often — that separation is deliberate.

## What it steers: the dead-tuple fraction

The quantity the governor regulates is the **dead-tuple fraction at trigger** —
roughly, how dirty a table is allowed to get before autovacuum cleans it. That
fraction is essentially the scale factor, so the governor computes a target and sets
the scale factor to it (a *feedforward* move), quantized to a small grid of allowed
values to keep catalog churn low. See the [control law](../../out/technical-design.md#control-law)
and [the gates](../../out/technical-design.md#the-gates).

Each [workload class](../../out/technical-design.md#relation-classification) gets a
target: a `queue` table is kept very clean, an `archive` table is left mostly alone,
`oltp` sits in between. You shift the whole posture with one policy knob,
`aggressiveness`; you never touch scale factors directly. See
[policy](../../out/technical-design.md#policy-desired-state-model).

## Movement has cost, so act rarely

Every change is an `ALTER TABLE`: it takes a lock and mutates `pg_class` (an MVCC
catalog write). So the governor treats *its own actuation frequency* as a second
controlled variable — it converges with the **minimum necessary change**: quantized
targets, no-op suppression, batching, short non-blocking locks, and (in active
control) rate limits and a catalog-mutation budget.

## Diagnose, don't escalate

The governor controls *maintenance progress*, not autovacuum activity — and more
aggressiveness sometimes can't help. When vacuum runs but debt stays high, it
classifies *why* before doing anything (see
[saturation diagnosis](../../out/technical-design.md#saturation-diagnosis)):

- **`config`** — autovacuum isn't even running for the table; lowering its trigger
  can't help (it's already overdue), so the governor **holds and raises a
  diagnostic** rather than making a futile change.
- **`io_limited`** — vacuum runs and does reclaim, but churn outruns it. The
  scale-factor lever is exhausted; escalate (more workers / cost limits are a later
  phase), don't keep lowering it.
- **`inhibited`** — vacuum runs but reclaims nothing because the tuples aren't
  removable: an external holder is pinning the xmin
  [horizon](../../out/technical-design.md#removability-horizons) (a long-running
  transaction, a replication slot, a prepared transaction). No setting helps — the
  fix is clearing the holder, so the governor emits a `critical` diagnostic naming it.

This is why "more vacuuming" is not always the answer, and why the governor surfaces
an actionable explanation instead of thrashing the actuator.

## Safety first

Anti-wraparound safety dominates everything (see
[safety system](../../out/technical-design.md#safety-system) and
[freeze safety](../../out/technical-design.md#freeze-safety-in-the-mvp)): the governor
never disables autovacuum, never reduces cleanup aggressiveness on a freeze-stressed
table, records every change for rollback, and — crucially — when a freeze emergency
is itself blocked by an inhibitor, it diagnoses rather than uselessly hammering the
actuator.

## Advisory by default

With the default policy, `advisory_only = true`: the loop runs end to end and writes
a complete decision and diagnosis trail, but `apply()` never fires. You can watch
"what it would do" for as long as you like before granting it the ability to act —
which is a single policy flip. See [Operating the governor](operating.md).
