# Phase 2 — Health rubric

**Status:** Not started · *(stub — fleshed out when reached)*

Make "healthy" and "unhealthy" operational: concrete signals, thresholds, and measurement
methods, so every later claim grades against a fixed rubric rather than an intuition. The
[charter](00-framework.md#the-health-rubric) defines the four signal families; this phase
turns them into measured quantities.

To be filled:

- **Proxy signals** — dead-tuple fraction and bloat: exact formulas, and `pgstattuple` as the
  bloat ground truth vs. cheaper estimators.
- **Outcome signals** — latency (p50/p95/p99), throughput, space, wraparound headroom:
  collection method (`pg_stat_statements`, size functions, `age(relfrozenxid)`), sampling
  cadence, and how each maps to "healthy."
- **Cost signals** — autovacuum frequency/duration/I/O and pgfc's own catalog-mutation rate.
- **The central question** — whether moving the proxy moves the outcome, and whether the six
  `empirical_default` per-class targets are right (or `RUBRIC-NNN` findings if not).
- **Healthy/unhealthy thresholds** per class, defined before runs.

## Exit criteria

- Every signal has a formula, a source, and a cadence.
- Healthy/unhealthy bands are fixed per class, ahead of any run.
- The proxy-vs-outcome test is specified as a concrete comparison.
