# Phase 4 — Experimental design

**Status:** Not started · *(stub — fleshed out when reached)*

Turn the [arms](00-framework.md#experimental-arms), [scenarios](00-framework.md#scenarios),
and [adequacy bar](00-framework.md#the-adequacy-bar) from the charter into a runnable
protocol with the statistics to back a verdict.

To be filled:

- **Arms** — defaults · expert-static · pgfc-active · oracle (+ advisory as instrumentation
  control). Define each precisely: how the expert-static tuning is chosen at `t0`, and how the
  oracle's omniscient re-tuning is computed (the upper bound is only as honest as its
  objective).
- **Scenarios** — steady-state sanity, and the non-stationary drift headline (the
  discriminating pairing: pgfc-adapts vs. expert-tunes-once, under a shifting workload).
- **Adequacy computation** — operationalize "fraction of the oracle gap closed" and the
  vacuum-cost ceiling on the rubric's outcome metrics.
- **Acceleration** — the compression (high churn, shortened thresholds) needed to make
  bloat/freeze observable in feasible time, and the bound on how much that distorts.
- **Statistics** — run count, warm-up handling, steady-state detection, variance, and the
  effect size that counts as "beat."
- **Threats to validity** — expand the charter [register](00-framework.md#threats-to-validity)
  into per-scenario mitigations; record `EXP-NNN` for unmitigated ones.

## Exit criteria

- A protocol another person could execute unattended.
- The adequacy bar reduced to a computable number per metric.
- Threats enumerated with mitigations or explicit caveats.
