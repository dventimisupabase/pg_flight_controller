# Phase 5 — Harness and tooling

**Status:** Complete (design) · **Purpose:** specify the reproducible runner that executes
Phase 4's protocol and emits comparable datasets. Construction is deferred — the four
design phases (1–4) plus this specification are the durable design artifacts; building and
running is Phase 6.

**Note on exit criteria.** The stub's literal exit criteria ("a single command runs an arm
end to end") require working code. This phase delivers the design specification instead —
architecture, components, reuse points, and a construction plan — so the build can proceed
from a clear blueprint when ready. The literal criteria are met by Phase 6's first
increment (the smoke run).

## Architecture

The harness is a shell-orchestrated pipeline reusing the project's existing Docker
Compose infrastructure (`test.sh`, `docker-compose.yml`, and the extension-specific
compose files). Each run is a `(arm, scenario, seed)` triple producing a timestamped
output directory with raw metrics and computed results.

```
efficacy/
  run.sh                     # top-level orchestrator
  drivers/                   # per-class pgbench scripts + custom drivers
  config/                    # per-arm configuration (SQL setup scripts)
  analysis/                  # gap-closed computation + reporting
  results/                   # per-run output directories (gitignored)
```

### Pipeline stages (per run)

1. **Init** — start a fresh container from the project's Docker Compose; install both
   extensions; create the fixture tables; `ANALYZE`; take the baseline snapshot.
2. **Arm setup** — apply the arm's tuning regime (see below).
3. **Phase A (steady state)** — run the stationary driver; sample metrics at cadence;
   detect steady state (CV < 0.10 over 5 windows).
4. **Drift trigger** — switch to the drift variant driver.
5. **Phase B (drift)** — continue driving + sampling until `t_end`.
6. **Collect** — dump the final metric tables, pgfc telemetry, and driver latency logs
   into the run's output directory.
7. **Analyze** — compute gap-closed per table, aggregate, apply cost-ceiling gate,
   emit the verdict.

### Reuse points

| Component | Reuse from | Notes |
|---|---|---|
| Container lifecycle | `test.sh` / `docker-compose.yml` | Same `PG_VERSION` env, same healthcheck, same volume mounts |
| Extension install | `test.sh` pattern (apply install.sql twice for idempotency) | — |
| pgfc loops | `pg_cron` (or `\watch` for the smoke config) | Shortened cadence per Phase 4 acceleration |
| Stats flush | `pg_stat_force_next_flush()` (PG 16+); `pg_sleep(1)` on PG 15 | Learned in Phase 3 spot-check: required between writes and sampling |
| ANALYZE | Explicit before baseline snapshot | Learned in Phase 3: `reltuples = -1` pre-ANALYZE breaks `archive` classification |

## Workload drivers

### pgbench custom scripts

For the write patterns pgbench can express natively (parameterized INSERT/UPDATE/DELETE
with `\set` random variables):

| Fixture | pgbench script shape | Per-cycle counts |
|---|---|---|
| `append_only` | Pure `INSERT` | 200 ins |
| `queue` | `INSERT` + `DELETE` by ctid sample | 100 ins, 95 del |
| `oltp` | `UPDATE` by random PK + minor ins/del | 10 ins, 150 upd, 5 del |
| `mixed` | Balanced ins/upd/del | 40 ins, 20 upd, 15 del |

pgbench's `--log` flag emits per-transaction latency to a file — the source for the
p50/p95/p99 latency computation (Phase 2 correction: `pg_stat_statements` gives
mean/stddev but not percentiles).

### Custom drivers (thin shell + psql)

For patterns pgbench cannot express (batch delete from a preloaded pool, periodic
purge bursts, drift-variant switching at `t_shift`):

| Fixture | Why custom | Pattern |
|---|---|---|
| `delete_heavy` | Sustainable unbalanced delete needs a preloaded pool; periodic batch refill (FIX-001) | Loop: delete N from pool → insert M refill; refill batch sized below `append_only` threshold |
| `archive` | Near-silence + periodic purge burst | Sleep between cycles; the purge variant batch-deletes 10% + reloads |
| Drift switching | All drift variants | A wrapper that runs stationary driver for Phase A, then switches to the drift driver at `t_shift` |

Custom drivers record per-operation timestamps to a log file (same format as pgbench
`--log`) for latency computation.

## Metric samplers

A periodic `psql` script (run via `\watch` or a shell loop at the sampling cadence)
that captures the Phase 2 signals into a `metrics` table:

```sql
CREATE TABLE efficacy_metrics (
    sample_id    bigint GENERATED ALWAYS AS IDENTITY,
    sampled_at   timestamptz NOT NULL DEFAULT now(),
    arm          text NOT NULL,
    scenario     text NOT NULL,
    seed         int NOT NULL,
    relname      text NOT NULL,
    -- proxy
    dead_frac    double precision,
    -- outcome
    rel_size     bigint,          -- pg_total_relation_size
    xid_age      bigint,          -- age(relfrozenxid)
    mxid_age     bigint,          -- age(relminmxid)
    -- cost
    av_count     bigint,          -- autovacuum_count
    av_last      timestamptz,     -- last_autovacuum
    pgfc_applied bigint           -- count of applied action_history rows
);
```

Latency and throughput come from the driver logs (offline), not the sampler.
Bloat ground truth (`pgstattuple_approx`) is sampled at run checkpoints (start,
`t_shift`, end), not continuously.

## Arm configuration

Each arm is a SQL setup script applied after extension install and fixture creation:

| Arm | Setup |
|---|---|
| `defaults` | No changes — stock PostgreSQL settings |
| `expert-static` | Per-table `ALTER TABLE SET (autovacuum_vacuum_scale_factor = <class_target>)` per the Phase 4 tuning procedure; threshold cap for large tables |
| `pgfc-active` | `UPDATE pgfc_govern.policy SET advisory_only = false`; no other changes |
| `advisory` | No changes (default `advisory_only = true`); loops run but never actuate |
| `oracle` | Computed offline after the run; applied as a replay (per-window per-table ALTER sequence from the sweep result) on a separate identical instance |

The oracle arm requires a two-pass execution: (1) run the workload under defaults to
record the trace, (2) replay with the oracle schedule and re-measure. This is the most
complex component to build.

## Analysis pipeline

A SQL or shell script that:

1. Loads the per-run `efficacy_metrics` table and driver latency logs.
2. Computes per-table, per-window p50/p95/p99 latency from the driver logs.
3. Computes the Phase 2 proxy-vs-outcome rank correlation per table.
4. Computes `gap_closed` per table per window (Phase 4 formula).
5. Aggregates: per-table median across windows, then weighted median across tables.
6. Applies the cost-ceiling gate and safety-floor check.
7. Emits the verdict (pass / strong pass / fail) with the supporting numbers.

Output: a `results/<run-id>/verdict.json` (machine-readable) and a
`results/<run-id>/report.md` (human-readable).

## Construction plan (for Phase 6)

When ready to build, the recommended increment order:

1. **Scaffold** — `run.sh` skeleton with init/collect stages; one arm (defaults) on a
   smoke config (1000-row tables, 60s run, 10s windows). Proves the container lifecycle
   and metric sampler.
2. **Drivers** — pgbench scripts for 4 fixtures + custom drivers for 2; the drift
   wrapper. Proves the workload pipeline and latency logging.
3. **Arms** — expert-static and pgfc-active setup scripts. Proves multi-arm comparison.
4. **Oracle** — the offline sweep + replay. The hardest component; proves the headline
   metric is computable.
5. **Analysis** — gap-closed computation + verdict. Proves the full pipeline end to end.
6. **At-scale campaign** — run the Phase 4 protocol at production-representative scale
   (100M+ rows, hours-long runs, 3 seeds). This *is* Phase 6.

Each increment is one PR, verifiable independently.

## Findings

No new findings. The design reuses the Phase 3 learnings (stats flush, ANALYZE
requirement) and the Phase 4 protocol without modification.

## Exit criteria (design phase)

- [x] Harness architecture specified (pipeline stages, reuse points, directory layout).
- [x] Workload drivers specified per fixture (pgbench vs custom, per-cycle counts,
  latency logging).
- [x] Metric sampler schema defined (all Phase 2 signals covered).
- [x] Arm configuration specified per arm (setup scripts, oracle two-pass).
- [x] Analysis pipeline specified (gap-closed computation, verdict output).
- [x] Construction plan stated as ordered increments for Phase 6.
