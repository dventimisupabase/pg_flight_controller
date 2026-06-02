# Phase 5 — Harness and tooling

**Status:** Not started · *(stub — fleshed out when reached)*

The reproducible runner that executes [Phase 4](04-experimental-design.md)'s protocol across
arms and scenarios and emits comparable datasets. Reuse the project's existing infrastructure
where possible rather than inventing a parallel one.

To be filled:

- **Database** — containerized PostgreSQL across the supported majors (15–18), reusing the
  `test.sh` / docker-compose infrastructure where it fits.
- **Workload driver** — pgbench custom scripts for the patterns it expresses (oltp, queue,
  counters) plus a thin custom driver for time-series / retention / drift patterns it cannot;
  seeded and parameterized.
- **Metric samplers** — periodic capture of the rubric signals
  ([Phase 2](02-health-rubric.md)) into a tidy, per-run time series.
- **Arm orchestration** — spin each arm (defaults / expert-static / pgfc-active / oracle)
  from a clean, identical starting state; apply the arm's tuning regime; drive the workload;
  sample.
- **Analysis & reporting** — turn per-run time series into the arm-vs-arm comparisons and the
  adequacy numbers; outputs committed or referenced by stable handle.

## Exit criteria

- A single command (or documented sequence) runs an arm × scenario end to end.
- Runs are reproducible from config + seed.
- Output is a comparable, durable dataset, not a transient log.
