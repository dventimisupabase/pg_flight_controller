# Phase 4 — Experimental design

**Status:** Complete · **Purpose:** turn the charter's arms, scenarios, and adequacy bar
into a runnable protocol with the statistics to back a verdict. Executable by another
person, unattended.

## Arms

Each arm runs the same workload fixtures (Phase 3) under different autovacuum-tuning
strategies. All arms share the same PostgreSQL version, hardware, and `pg_cron` cadence
(1 min observe, 5 min control); they differ only in how per-table `autovacuum_vacuum_scale_factor`
is managed.

### Defaults

Stock PostgreSQL autovacuum, untouched. `autovacuum_vacuum_scale_factor = 0.20` and
`autovacuum_vacuum_threshold = 50` (the global defaults). No per-table overrides. The
**floor** — if pgfc cannot beat this, it fails outright.

### Expert-static

Per-table knobs tuned once at `t0` for the workload's steady-state, then left alone.
The **honest competitor** — the charter forbids a strawman ("drift, not rescue").

**Tuning procedure (documented, reproducible):**

1. Run the stationary driver for each fixture until steady state (stable dead-tuple
   fraction, stable autovacuum cadence — at least 10 autovacuum cycles).
2. For each table, set `autovacuum_vacuum_scale_factor` to a hardcoded value based
   on expert consensus (Percona, EDB, AWS, Crunchy, pganalyze, Keith Fiske,
   Microsoft Azure): `oltp` = 0.02, `queue` = 0.005, `delete_heavy` = 0.01,
   `mixed` = 0.05, `append_only` = 0.20, `archive` = 0.20. These are independent
   of the pgfc governor's own registry — the expert arm represents what a skilled
   DBA would configure, not what the governor targets.
3. For large tables (≥ 100M rows), additionally set `autovacuum_vacuum_threshold` to
   cap the absolute dead-tuple count at a reasonable level (e.g. 100K), so the expert
   is not artificially naive about scale drift.
4. Freeze the settings. No further changes for the rest of the run.

This procedure is the strongest honest competitor: the expert knows the workload class
and the table size at `t0`, and tunes correctly for both — better than the defaults but
blind to future drift.

### pgfc-active

Continuous active control (`advisory_only = false`). The system under test. pgfc
observes, classifies, estimates, plans, and applies scale-factor changes under the full
self-protection net (health-state authority gate, mutation budget, ownership guard).
Default policy, default registry parameters — no pre-tuning.

### Advisory (instrumentation control)

`advisory_only = true` (the default). The loops run, telemetry is collected, decisions
are logged, but `apply()` never fires. This arm provides the clean dataset for the
Phase 2 proxy-vs-outcome correlation *without* the actuation confound — the proxy
moves (in the decision log) but no settings change, so any outcome movement is
attributable to workload change alone, not pgfc's actions.

### Oracle

The foreknowledge-optimal scale-factor schedule: what pgfc would set if it knew the
future workload perfectly.

**Same-lever constraint.** The oracle uses only the lever pgfc has — per-table
`autovacuum_vacuum_scale_factor`. It does not touch `cost_limit`, `max_workers`,
or issue manual `VACUUM`. If the oracle gets levers pgfc lacks, the denominator is
unreachable and pgfc is unfairly understated.

**Computation.** The oracle is computed offline, after the run, from the recorded
workload trace:

1. Replay the workload trace in simulation (or on a separate instance) with a
   candidate scale-factor schedule.
2. Sweep candidate schedules: for each table, at each measurement window, try every
   grid value (the 7 `snap_sf` grid points) and record the headline metric.
3. Select the per-table schedule that optimizes the headline metric over the full run.

The oracle is itself an approximation of the true upper bound — the grid is finite
and the sweep is per-window, not globally optimal. This is filed as EXP-001 below.

## Headline metric and adequacy formula

### Pre-declared headline: p95 latency under drift

RUBRIC-001 (expanded) showed that fractional targets create genuine conflicts between
space, vacuum cost, and latency/throughput — there is **no single "health" scalar**
that captures all outcomes. Rather than invent one, we pre-declare a single headline
metric and report the others as secondary signals:

- **Headline:** p95 query latency, measured from the workload driver's per-transaction
  log, aggregated per measurement window. This is "what operators feel" — the outcome
  most directly tied to user-facing performance.
- **Secondary:** space (total relation size), throughput (TPS), wraparound headroom
  (`age(relfrozenxid)`), and autovacuum cost (I/O, duration, frequency).

The headline is what the adequacy bar grades on; the secondary signals are reported
alongside and can qualify the verdict (e.g. "pgfc wins on latency but breaches the
cost ceiling" is a qualified pass, not a clean win).

### Adequacy formula

Per table, per measurement window, lower-is-better:

```
gap_closed = (expert_static − pgfc) / (expert_static − oracle)
```

- `= 1.0` → pgfc matches the oracle (perfect tracking)
- `= 0.0` → pgfc only matches expert-static (no adaptive benefit)
- `< 0.0` → pgfc *loses* to the honest competitor (a fail)

Reported as a per-table median across windows (robust to outliers), then aggregated
across tables as a weighted median (weighted by table activity — a quiet table's
gap-closed matters less than a busy one's).

**Cost-ceiling gate.** Any gap-closed number is voided if the arm breaches the cost
ceiling (≤ 2× the defaults arm's autovacuum I/O, from Phase 2). A win bought above
the cost ceiling is not adequacy.

### Verdict thresholds (fixed before runs)

- **Pass:** median gap-closed ≥ 0.0 on the headline metric (pgfc at least ties
  expert-static) AND no cost-ceiling breach AND safety floor holds (no wraparound
  emergency, no freeze regression).
- **Strong pass:** median gap-closed ≥ 0.25 (pgfc closes ≥ 25% of the oracle gap).
- **Fail:** median gap-closed < 0.0 (pgfc loses to expert-static), or any safety
  floor violation, or cost-ceiling breach with no headline gain.

## Scenarios

### Steady-state (sanity check)

Each fixture's stationary driver, no drift. Confirms the harness, the rubric, and
that pgfc does not regress when nothing is changing. Expected result: all arms roughly
tied (the expert tuned for exactly this workload). A pgfc regression here is a bug, not
a value question.

### Non-stationary drift (the headline)

The discriminating test. Two phases per run:

1. **Phase A (t0 → t\_shift):** stationary workload. Expert-static is correctly tuned.
   All arms should perform similarly.
2. **Phase B (t\_shift → t\_end):** the drift variant fires (from Phase 3 — rate shift,
   class transition, scale growth, write amplification). Expert-static settings are now
   stale. The question: does pgfc track the change, and by how much?

The measurement windows in Phase B are the ones that count for the headline gap-closed.
Phase A is the calibration baseline.

### PROB-001 overlay: inhibitor-bound scenario

Layer a long-running transaction (pinning the xmin horizon) onto one or more fixtures
during Phase B. The inhibited tables should:

- In the pgfc-active arm: be diagnosed (`saturation_cause = 'inhibited'`) and named
  (the `diagnostics` table identifies the holder). The scale-factor lever is inert —
  actuation adds no value; diagnostics is the value.
- In all arms: show the same outcome degradation (the inhibitor is the cause, not the
  tuning strategy).

This is not a separate run but a scenario overlay that lets the verdict split per
PROB-001: actuation value on lever-movable tables, diagnostic value on inhibited ones.

## Acceleration

Bloat and freeze play out over days; a single run must compress this into hours.

**Mechanism:**

- High churn: fixture drivers run at elevated rates (10–100× production cadence) so
  dead tuples accumulate in minutes, not days.
- Compressed thresholds: lower `autovacuum_freeze_max_age` (e.g. 10000 instead of
  200000000) so freeze behavior is observable in the run window.
- Shortened observation cadence: `observe_tick` every 10s (not 60s), `control_tick`
  every 30s (not 300s), to give the controller enough cycles to adapt.

**Bound on distortion (EXP-002):** acceleration compresses timescales but does not
change the *sequence* of events — the same drift, the same relative rates, the same
autovacuum behavior, just faster. The distortion is bounded by PostgreSQL's own
time-based behavior: cost-based throttling is real-time (so vacuum runs are real-time
slow even with compressed churn), and `clock_timestamp()` intervals in the governor's
rate calculations are real. The residual distortion: behavior at 100× churn may differ
from 1× churn in ways (I/O saturation, lock contention) that don't generalize. Filed
as EXP-002.

## Statistics

- **Run count:** 3 independent runs per (arm × scenario) combination (same config,
  different random seeds for the driver). Enough to detect gross variance; not a
  power analysis — this is an engineering evaluation, not a clinical trial.
- **Warm-up discard:** the first 20% of each run's measurement windows are discarded
  (caches cold, autovacuum not yet settled).
- **Steady-state detection (Phase A):** coefficient of variation (CV) of the headline
  metric across 5 consecutive windows < 0.10. If Phase A does not reach steady state,
  the run is extended (not discarded — the calibration baseline must be stable).
- **Effect size:** gap-closed is the effect measure; no minimum effect size is
  pre-declared because the adequacy bar (≥ 0.0 for pass, ≥ 0.25 for strong pass)
  already defines "how much counts."
- **Variance reporting:** per-table gap-closed values are reported as median ± IQR
  (interquartile range) across runs, not just the median — so a result with high
  variance is visible, not hidden.

## Threats to validity (expanded)

| Threat | From charter? | Mitigation | Residual | ID |
|---|---|---|---|---|
| Proxy-outcome gap | Yes | The Phase 2 proxy-vs-outcome correlation test runs per table; the verdict grades on outcome, not proxy | If the correlation is weak, the headline metric still works — it just means pgfc's proxy steering is cosmetic (a finding, not a methodological failure) | — |
| Vacuum-cost confounder | Yes | The cost ceiling (≤ 2× defaults I/O) gates the verdict; gains above the ceiling are voided | The ceiling is somewhat arbitrary; a different ceiling could flip a marginal result | — |
| Synthetic generalizability | Yes | Fixtures grounded in the real classifier predicates; drift variants modeled on real operational patterns (scale growth, class transition, rate shift) | Still synthetic; conclusions bounded by fixture realism | — |
| Compressed timescales | Yes | Acceleration mechanism above; same event sequence, compressed | Residual: I/O saturation at 100× churn may not generalize to 1× | EXP-002 |
| Non-stationarity realism | Yes | Drift variants are scripted — simple, not stochastic | A scripted shift can flatter or punish an adaptive controller; real drift is messier | — |
| Oracle definition | Yes | Same-lever constraint; offline sweep; stated as an approximation | The grid is finite and the sweep is per-window, not globally optimal | EXP-001 |
| Measurement noise | Yes | 3 runs, 20% warm-up discard, steady-state detection, IQR reporting | 3 runs is low for tight confidence intervals; engineering judgment, not statistical power | — |
| Multi-objective incoherence | New (RUBRIC-001) | Pre-declared headline metric; secondary signals reported; cost-ceiling gate | A result that wins on latency but loses on space is a qualified pass — the operator must judge whether the trade-off is acceptable | — |

## Findings

| ID | Statement | Evidence | Confidence | Bearing on verdict | Status | Link |
|---|---|---|---|---|---|---|
| EXP-001 | The oracle is an approximation: a per-window grid sweep, not a globally optimal schedule; the true upper bound may be higher | By construction (the grid has 7 points; per-window independence ignores cross-window interactions) | Strong | Qualifies — the gap-closed denominator is conservative (understates the achievable benefit, so pgfc's gap-closed may be overstated). Acceptable for an engineering evaluation | Open | — |
| EXP-002 | Accelerated timescales may distort I/O-related behavior (vacuum cost, lock contention) in ways that don't generalize to production cadence | By construction (100× churn compresses time but not I/O throughput) | Tentative | Qualifies — cost-signal comparisons across arms are valid (same distortion), but absolute cost numbers are not production-representative | Open | — |

## Exit criteria

- [x] A protocol another person could execute unattended.
- [x] The adequacy bar reduced to a computable number per metric (`gap_closed` formula,
  verdict thresholds, cost-ceiling gate).
- [x] Threats enumerated with mitigations or explicit caveats (7 charter + 1 new,
  2 filed as EXP-NNN).
