# Phase 1 — The problem and its value

**Status:** Complete · **Gate:** if the value question collapses here, the later phases
are moot.

This phase does no experiments. It writes down, precisely, *what problem
pg_flight_controller claims to solve*, and decides which part of that claim is settled prior
art and which part is genuinely open and worth an experiment.

## The problem chain

Work down from the mechanism to the claim. Each layer states what the layer below leaves
unsolved.

- **What vacuuming solves.** PostgreSQL's MVCC leaves dead tuples (old row versions) behind
  on every `UPDATE`/`DELETE`. Unreclaimed, they cause three distinct harms: **bloat** (wasted
  space, colder cache, slower scans), **transaction-ID / multixact wraparound** (the
  existential one — old xids must be frozen or the database forces a shutdown to avoid data
  loss), and **stale planner statistics** (handled by the coupled `ANALYZE`). `VACUUM`
  reclaims, freezes, and (via `ANALYZE`) re-measures.

- **What autovacuum solves.** Scheduling `VACUUM` by hand is toil and easy to get wrong.
  Autovacuum automates *when* to vacuum each table, firing when dead tuples cross a per-table
  threshold (`scale_factor * reltuples + threshold`, with analogous insert/freeze triggers).

- **What *operating* autovacuum solves (the pgfc claim).** Autovacuum's per-table knobs are
  static. Defaults are one-size-fits-all and often wrong for a specific table; tuning them is
  expert work, typically set-once-and-forgotten; and the right value **drifts** as the
  workload changes. pg_flight_controller claims to keep those setpoints continuously
  appropriate as the workload moves — without ongoing human tuning.

## The testable claim

> Under workloads that shift over time, continuous automated re-tuning of per-table
> autovacuum scale factors keeps a database healthier — measured by query latency,
> throughput, disk space, and wraparound headroom — than good static per-table tuning
> set once by an expert.

This is falsifiable: it fails if (a) the proxy (dead-tuple fraction) moves but the outcome
signals (latency, throughput, space, wraparound headroom) do not, or (b) the outcome
signals improve but not enough to justify the cost and risk of an autonomous catalog
actuator, or (c) the lever-movable population (tables whose health the scale factor can
actually influence) is too small relative to the inhibitor-bound population for actuation
to matter — see [PROB-001](#prob-001) below.

## The value question, split

### Settled: autovacuum mis-tuning is costly (cite, don't re-test)

That autovacuum mis-tuning causes real production harm is established community
knowledge. The costs fall into three categories:

**Bloat and performance degradation.** When autovacuum cannot keep up — whether from
default settings that are too conservative for a busy table, from worker starvation
across many tables, or from cost-delay throttling — dead tuples accumulate, tables and
indexes grow beyond their working-set size, the buffer cache becomes less effective, and
sequential scans slow. This is the most common failure mode: not a sudden outage but a
gradual, often unnoticed degradation until storage or query performance forces attention.
The community consensus, reflected across vendor documentation and practitioner guides,
is that default autovacuum settings are rarely optimal for production workloads.

**Transaction-ID wraparound.** PostgreSQL's 32-bit transaction ID counter wraps at
approximately 2 billion transactions. If autovacuum's freeze pass cannot keep up — because
it is disabled, blocked by a long-running transaction, or simply never reaches a table
that needs freezing — the database first warns (at ~1.6 billion), then forces increasingly
aggressive emergency vacuums, and ultimately refuses writes to prevent data loss. These
incidents are well-documented in the PostgreSQL community: they are not gradual
degradation but hard production outages, sometimes lasting hours, and they are
fundamentally a failure of vacuum scheduling.

**Operational toil.** At scale (hundreds to thousands of tables), per-table autovacuum
tuning becomes a recurring human task: identify the under-vacuumed tables, research the
right settings for each workload pattern, apply them, and then forget to revisit when the
workload changes. This toil is real, repeating, and error-prone — and it is the specific
gap pgfc targets.

### Open: does continuous re-tuning beat good static tuning under drift?

The settled part establishes that *bad* autovacuum settings are costly. It does **not**
establish that *continuously adjusting* settings is better than *setting them well once*.
A human expert who tunes each table's scale factor for its workload at time `t0` has
done real work; the pgfc-specific bet is that:

1. The right setting **drifts** as the workload changes (a table that was write-heavy
   becomes read-mostly; a queue table's throughput doubles; a batch job shifts from
   nightly to hourly).
2. A supervisory loop can **track** that drift better than a set-and-forget human.
3. The tracking produces **outcome** improvement (not just a tidier dead-tuple fraction)
   that justifies running an autonomous actuator against a live catalog.

Each of these is a genuine open question. Point 1 is the premise (workloads drift and
settings become stale); point 2 is the mechanism (the loop tracks drift); point 3 is the
payoff (outcomes improve, net of cost). The experiment in Phases 2–6 must test all three.

## Go/no-go on the open question

**Go** — conditioned on scope.

The open question is real, unresolved, and central to pgfc's reason for existing. The
RFC's own candid self-assessment confirms it: "active control is unproven end to end"
(RFC [§7, "What is unbuilt or unvalidated"](#what-is-unbuilt-or-unvalidated)); "the
parts that are demonstrably real today are observe, estimate, and diagnose; act is the
unproven claim" (RFC [§1](#1-abstract)). An unproven, central claim is precisely what
earns the experimental cost.

**But the experiment must be scoped to survive [PROB-001](#prob-001)** — the finding
that the lever-movable population may be a minority of unhealthy tables. The experiment
must include both lever-movable and inhibitor-bound tables, and the verdict must not
credit pgfc for tables no scale-factor lever could help. If 80% of unhealthy tables are
inhibitor-bound, the actuation value question survives only if the remaining 20% show
enough improvement to justify the system — or if the diagnostic value (identifying and
naming the inhibitors) is itself the product. The experiment design in Phases 3–4 must
be able to distinguish these outcomes.

## Findings

| ID | Statement | Evidence | Confidence | Bearing on verdict | Status | Link |
|---|---|---|---|---|---|---|
| PROB-001 | The scale-factor lever cannot remediate inhibitor-bound or I/O-limited tables; if those dominate the unhealthy population, pgfc's primary value is diagnosis, not actuation | RFC [§2.1](../rfc/README.md#21-autovacuum-settings-as-actuator-positions) ("strictly weaker lever"), [§2.5](../rfc/README.md#25-diagnose-dont-escalate) ("primary value is its diagnostics"), [§7](../rfc/README.md#premises-we-are-least-sure-about) ("controller or diagnostic?") | Strong | Qualifies — does not collapse the open question, but imposes a design constraint: fixtures must include both lever-movable and inhibitor-bound tables, and the verdict must separate actuation value from diagnostic value | Open | — |

### PROB-001 — The lever-movable population may be a minority

**Statement.** The scale-factor lever changes *when* autovacuum fires. It cannot help a
table that autovacuum already wants to vacuum but cannot finish (I/O-limited), cannot
help a table blocked by an external inhibitor (a long-running transaction or a
replication slot pinning the xmin horizon), and cannot help a table whose problem is
worker starvation or cost-delay throttling (those are global settings, not per-table
scale factors). The RFC acknowledges this directly:

- §2.1: "steering *when* autovacuum fires is a strictly weaker lever than steering
  *how* it runs... Is the scale factor the right control surface, a sufficient one, or
  merely the one that happens to be safe to touch?"
- §2.5: "if 'diagnose, don't escalate' is the right response to a large share of stuck
  tables, then the system's primary value is its diagnostics, not its actuation"
- §7: "the honest product may be the diagnostics, with actuation a minor adjunct"

**Bearing on the verdict.** This does not collapse the open question — it reframes it.
The experiment must be designed to answer two sub-questions, not one:

1. **Among tables the lever can move**, does continuous re-tuning improve outcomes vs.
   good static tuning under drift? (The actuation value question.)
2. **Among tables the lever cannot move**, does pgfc's diagnostic identification of the
   cause (inhibited, I/O-limited, config-not-firing) provide actionable value that
   alternatives (manual `pg_stat_activity` investigation, third-party monitoring) do not?
   (The diagnostic value question.)

The verdict must report both, and the overall "does pgfc solve the problem" answer must
be honest about which component delivers the value. A system whose actuation adds little
but whose diagnostics are genuinely useful is a real product — just not the one the
"control theory" framing implies.

**Design constraint for Phases 3–4.** The workload fixtures must include:

- Tables whose health the scale-factor lever can influence (the `config`-class
  saturation: autovacuum is not firing, or is firing too late, and a lower scale factor
  would help).
- Tables that are inhibitor-bound (a pinned xmin horizon) or I/O-limited (autovacuum
  runs but cannot keep up) — where the lever is inert and the value is diagnosis only.

The adequacy bar must be stated in a way that survives a split verdict: "pgfc closes
X% of the oracle gap on lever-movable tables, and provides actionable diagnostics on
Y% of inhibitor-bound tables, at Z cost."

## Exit criteria

- [x] The claim is stated as one testable sentence.
- [x] The value question is split into cited-settled and experimentally-open, with a
  go/no-go on the open part.
- [x] Problem-reframing findings recorded with evidence (PROB-001).
