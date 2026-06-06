# Phase 2 — Health rubric

**Status:** Complete · **Purpose:** make "healthy" and "unhealthy" operational — concrete
signals, formulas, sources, and thresholds so every later claim grades against a fixed
rubric rather than an intuition.

The [charter](00-framework.md#the-health-rubric) defines four signal families: proxy,
outcome, cost, and safety. This phase turns each into a measured quantity with a formula,
a source, a sampling cadence, and a healthy/unhealthy band. The central discipline:
**proxy and outcome are kept distinct** — the gap between them is the central object of
study, not an assumption to elide.

## Signal definitions

### Proxy signals (what pgfc steers — not what we grade it on)

| Signal | Formula | Source | Cadence | Notes |
|---|---|---|---|---|
| Dead-tuple fraction | `n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0)` | `pg_stat_user_tables` | Per observe tick (~1 min) | The controller's steering variable. Continuous, cheap, but a proxy — moving it does not *necessarily* move the outcome |
| Table bloat ratio | `table_len / (tuple_len + dead_tuple_len + free_space)` or the `approx_` variant | `pgstattuple(rel)` / `pgstattuple_approx(rel)` | Sampled (expensive; per-run checkpoints, not continuous) | Ground truth for space waste. `pgstattuple` does a full sequential scan; `pgstattuple_approx` uses the visibility map and is much cheaper but approximate. Both require the `pgstattuple` extension |
| Index bloat ratio | `avg_leaf_density` / expected density, or `pgstatindex` | `pgstatindex(idx)` | Sampled (per-run checkpoints) | Index-specific; `pgstatindex` is a full B-tree scan |

### Outcome signals (what actually matters — what we grade on)

| Signal | Formula | Source | Cadence | Notes |
|---|---|---|---|---|
| Query latency (p50, p95, p99) | Percentile from the per-transaction latency log | Workload driver log (e.g. `pgbench --log`) | Per-transaction during run, aggregated per window | `pg_stat_statements` exposes mean/stddev/min/max but **not percentiles**; the charter's "p50/p95/p99 via `pg_stat_statements`" is corrected here. Percentiles are computed offline from the driver's per-transaction log. `pg_stat_statements` mean/stddev serve as a cross-check |
| Throughput (TPS) | Committed transactions / elapsed seconds | Workload driver or `pg_stat_database.xact_commit` delta | Per window (e.g. 10 s buckets) | Measures the database's useful work rate under the workload |
| Space (table + index bytes) | `pg_total_relation_size(relid)` | `pg_class` (via `pg_total_relation_size`) | Per observe tick or per window | Total on-disk footprint including indexes, TOAST, and free-space-map overhead. The outcome counterpart of the bloat proxy |
| Wraparound headroom | `age(relfrozenxid)`, `age(relminmxid)` | `pg_class` | Per observe tick | Distance from the wraparound limit. The safety-critical outcome; measured in transactions, not time |

### Cost signals (the price of health)

| Signal | Formula | Source | Cadence | Notes |
|---|---|---|---|---|
| Autovacuum frequency | Count of autovacuum runs per table per window | `pg_stat_user_tables.autovacuum_count` delta; autovacuum log (`log_autovacuum_min_duration = 0`) | Per observe tick | More runs = more I/O cost; the cost of the proxy improvement |
| Autovacuum duration | Wall-clock time per autovacuum run | Autovacuum log | Per run | Long runs indicate I/O saturation or large tables |
| Autovacuum I/O | Pages read/written per run | Autovacuum log (`DETAIL` line) | Per run | The I/O budget consumed by vacuum; the direct resource cost |
| pgfc catalog mutations | Applied `action_history` rows per window | `pgfc_govern.action_history` | Per control tick | The system's own cost — catalog `ALTER TABLE` writes |

### Safety signals (the floor — pass/fail)

| Signal | Condition | Threshold |
|---|---|---|
| No wraparound emergency | `age(relfrozenxid) < autovacuum_freeze_max_age` | Must hold for every table at every measurement point. Violation is an immediate fail regardless of other signals |
| No freeze regression | `relfrozenxid` never moves backward (except after a `pg_resetwal`, which is out of scope) | Monotonic freeze progress per table across checkpoints |

## Healthy/unhealthy bands

Fixed before any run. The bands define what "healthy" and "unhealthy" mean per signal
class — the ruler later phases measure against.

### Proxy bands (per-class, matching the six `empirical_default` targets)

The system's own targets, committed at design time. These are the proxy goals, not the
grading criteria:

| Class | Target dead-tuple fraction | "Healthy" proxy band | "Unhealthy" proxy band |
|---|---|---|---|
| queue | 0.05 | ≤ 0.10 | > 0.20 |
| delete_heavy | 0.10 | ≤ 0.15 | > 0.30 |
| oltp | 0.20 | ≤ 0.25 | > 0.40 |
| mixed | 0.20 | ≤ 0.25 | > 0.40 |
| append_only | 0.40 | ≤ 0.45 | > 0.60 |
| archive | 0.50 | ≤ 0.55 | > 0.70 |

The "healthy" band is target + 5pp headroom (the snap\_sf grid spacing is the deadband);
"unhealthy" is target × 2, where the gap between intent and reality is clearly a
problem.

### Outcome bands (comparative — arm-relative)

Latency and throughput bands are workload-relative: an absolute "p95 < 10ms" is
meaningless without knowing the workload. The bands are therefore **comparative**,
measured against each arm's own baseline at `t0` and against the defaults arm:

| Signal | Healthy | Unhealthy |
|---|---|---|
| Latency (p95) | ≤ 10% regression from the arm's own `t0` baseline | > 25% regression from `t0`, or worse than the defaults arm |
| Throughput | ≤ 10% drop from the arm's `t0` baseline | > 25% drop from `t0`, or worse than defaults |
| Space | ≤ 20% growth beyond the "ideal" (live tuples × avg row width × index overhead) | > 50% growth beyond ideal, sustained |
| Wraparound headroom | `age(relfrozenxid)` ≤ 50% of `autovacuum_freeze_max_age` | > 75% of `autovacuum_freeze_max_age` |

### Cost ceiling

An outcome gain bought above this cost ceiling does not count as adequacy:

- Autovacuum I/O: ≤ 2× the defaults arm's autovacuum I/O for the same workload.
- pgfc catalog mutations: ≤ the `daily_mutation_budget` (default 500/day).

## The proxy-vs-outcome comparison

The central question: does moving the proxy move the outcome? This is not an assumption —
it is a concrete test the experiment must run:

**Method.** For each table in each arm, across the run:

1. Compute the per-window Δ(dead-tuple fraction) — the proxy movement.
2. Compute the per-window Δ(p95 latency) and Δ(space) — the outcome movement.
3. For each (table, arm), correlate proxy movement against outcome movement (rank
   correlation, since the relationship may be nonlinear).

**Possible results and their bearing:**

- **Proxy moves, outcome moves with it** — the lever works; the system is steering
  something real. The experiment proceeds to the adequacy question.
- **Proxy moves, outcome does not** — the lever is cosmetic. A dead-tuple fraction
  improvement that produces no latency, throughput, or space improvement means the
  controller is optimizing a metric that does not matter. This would be a **RUBRIC
  finding** that reframes the verdict: the system may still have diagnostic value
  (PROB-001), but its actuation adds cost without outcome benefit.
- **Proxy does not move** — the controller failed to steer even its own variable.
  A different kind of failure (mechanism, not relevance).

This comparison runs per-table, not globally — a global average can hide tables where the
proxy moves but the outcome doesn't (small tables where bloat is noise) behind tables
where both move (large tables). The per-table view is what survives the PROB-001 split.

## Findings

| ID | Statement | Evidence | Confidence | Bearing on verdict | Status | Link |
|---|---|---|---|---|---|---|
| RUBRIC-001 | Fixed fractional targets can degrade the space outcome purely from table growth (scale drift), even when the proxy is "healthy" | Phase 1 scale-drift analysis; the 1M→1B example (0.20 fraction = 200M dead tuples at 1B rows, ruinous as space) | Strong | Qualifies — the space band needs a growth-aware component, not just a fractional threshold; the per-class targets may need an absolute dead-tuple-count cap for large tables | Open | — |

### RUBRIC-001 — Fractional targets are scale-blind

The six per-class targets are dead-tuple *fractions*. At 1M rows, a 0.20 fraction (the
`oltp` / `mixed` target) means 200K dead tuples — negligible space. At 1B rows, the same
0.20 fraction means 200M dead tuples — potentially gigabytes of wasted space, even though
the proxy says "healthy."

This is a concrete instance of the proxy-outcome gap: the proxy (fraction) is within band,
but the outcome (space) is degraded. It also connects directly to the Phase 1 scale-drift
observation — table growth makes a correct fractional target produce an incorrect space
outcome.

**Bearing on the experiment.** The space outcome band (above) is defined in terms of
percentage growth beyond the ideal, which is growth-aware by construction — a table that
is 50% over its ideal size is unhealthy regardless of its dead-tuple fraction. But the
*per-class proxy targets* (the system's own steering goals) are purely fractional. This
means the system can steer the proxy into its "healthy" band while the space outcome is in
its "unhealthy" band, on a large enough table.

**Design constraint for Phase 4.** The fixtures must include at least one large table
(≥ 100M rows) per active class, so the experiment can observe whether the fractional
target produces a space-outcome regression at scale. If it does, that is evidence the
targets need an absolute dead-tuple-count component — a `RESULT` finding, not something
to fix before the run.

## Exit criteria

- [x] Every signal has a formula, a source, and a cadence.
- [x] Healthy/unhealthy bands are fixed per class, ahead of any run.
- [x] The proxy-vs-outcome test is specified as a concrete comparison.
