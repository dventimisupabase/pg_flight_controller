# Efficacy charter

The method every phase reuses. The goal of this stream is not new features and not
correctness; it is an **evidence-based verdict** on one question:

> Does *continuous, automated* re-tuning of per-table autovacuum setpoints keep a database
> healthier than *good static* tuning does — under workloads that move — and by enough to
> justify running an autonomous actuator against a live catalog?

Everything below exists to answer that without flattering the system into a "yes."

## Principles

- **Outcomes over proxies.** pg_flight_controller steers a *proxy* — the dead-tuple fraction
  — toward six per-class targets, every one of which carries `empirical_default` provenance
  (i.e. a guess; see [§2.3](../rfc/README.md#23-policy-as-outcomes-workload-classes-and-the-control-law)).
  Health is not the proxy. Health is **latency, throughput, space, and wraparound headroom**.
  Every phase must ask whether moving the proxy moves the outcome, and whether the six
  targets are even right.
- **Drift, not rescue.** The discriminating test is a workload that *shifts*, not a
  deliberately broken config the system then "fixes." Designing the easy win — bad settings →
  pgfc rescues — is leading the witness; the same discipline applied to the
  [RFC](../rfc/README.md) applies here.
- **A bar fixed before the run.** "Adequate" is defined *before* any data exists (see
  [the adequacy bar](#the-adequacy-bar)), so a result cannot be rationalized after the fact.
- **Evidence, not assertion; reproducible.** Every claim cites a reproducible run (config +
  workload + seed) or external prior art. A verdict names the runs that support it.
- **Durable over ephemeral.** Analysis lives in these phase docs; the harness and fixtures
  live in-repo; datasets are committed or referenced by a stable handle. Nothing important
  lives only in a conversation or a local notebook.

## Scope

**In scope.**

- The pg_flight_controller-specific value question: continuous re-tuning vs. good static
  per-table tuning, under non-stationary load.
- The six workload classes the system defines — `queue`, `delete_heavy`, `oltp`, `mixed`,
  `append_only`, `archive` — and whether their `empirical_default` targets are right.
- Active *continuous* control as the system is meant to work, compared against PG defaults,
  expert-static tuning, and an omniscient oracle.

**Out of scope.**

- *Re-litigating that autovacuum mis-tuning is costly.* Bloat, transaction-ID-wraparound
  emergencies, and expert toil are established; Phase 1 cites prior art rather than rebuilding
  it with a harness.
- *Correctness.* That is the pgTAP suites and the [fortification](../fortification/README.md)
  stream.
- *The COR-001 bug itself.* Fortification owns it
  ([#66](https://github.com/dventimisupabase/pg_flight_controller/issues/66)); this stream
  measures the intended post-fix behavior and sequences execution after it.

## The spine, as gates

Each step must pass before the next earns the effort:

1. **Define the problem** — the *vacuum → autovacuum → operating autovacuum* chain, ending in
   a precise statement of what pg_flight_controller claims to solve. (Phase 1)
2. **Is it valuable** — narrowed to the open part: does continuous re-tuning beat good static
   tuning? If the value question collapses here, later phases are moot. (Phase 1)
3. **Does it solve it** — under realistic load, does active control move tables toward health
   on an *outcome* measure? (Phases 2–6)
4. **Adequately** — how much of the achievable benefit, at what cost, vs. the alternatives.
   (Phases 4–6)

## The health rubric

Four families of signal. Proxy and outcome are kept distinct on purpose — the gap between
them is the central object of study.

- **Proxy signals (what pgfc steers):** dead-tuple fraction
  (`n_dead_tup / (n_live_tup + n_dead_tup)`); estimated and measured bloat (table and index;
  `pgstattuple` for ground truth). These are what the controller optimizes — not what we
  grade it on.
- **Outcome signals (what actually matters):** query **latency** (p50/p95/p99 of the
  workload, via `pg_stat_statements`); **throughput** (TPS); **space** (table + index bytes
  over time); **wraparound headroom** (`age(relfrozenxid)`, `age(relminmxid)`).
- **Cost signals (what it costs to get there):** autovacuum frequency, duration, and I/O;
  the catalog-mutation rate pgfc itself adds. A controller that buys outcome health with
  ruinous vacuum I/O has not won.
- **Safety signals (the floor):** never a wraparound emergency; never a freeze regression.
  These are pass/fail, not optimized.

Sources: `pg_stat_user_tables`, `pg_statio_user_tables`, `pg_class`, `pgstattuple`,
`pg_stat_statements`, autovacuum logging (`log_autovacuum_min_duration = 0`), and
pg_flight_controller's own telemetry (cross-checked against the above).

## The adequacy bar

Defined now, before any run. "Solves the problem adequately" means, in order:

- **Floor — must beat PG defaults.** If active pgfc does not beat stock autovacuum on the
  outcome signals, it fails outright.
- **Bar — should tie or beat expert-static tuning.** The honest competitor is a human who
  tuned the per-table knobs well *once*. Beating defaults is necessary; matching or beating a
  one-time expert is the real claim, under load that moves.
- **Headline metric — fraction of the oracle gap closed.** An **oracle** arm — per-table
  setpoints re-tuned continuously with omniscient foreknowledge — defines the achievable
  upper bound. "The gap" is oracle minus expert-static on the chosen outcome metric; the
  headline number is the fraction of that gap active pgfc closes.
- **Ceiling — within a vacuum-cost budget.** Any outcome gain is reported net of its cost;
  gains bought above a stated vacuum-I/O ceiling do not count as adequacy.

## Experimental arms

- **Defaults** — stock PostgreSQL autovacuum, untouched. The floor.
- **Expert-static** — per-table knobs tuned once by an expert for the workload at `t0`, then
  left alone. The honest competitor.
- **pgfc-active** — continuous active control (the system under test).
- **Oracle** — continuous, omniscient re-tuning. The upper bound that gives "adequate" a
  denominator.
- *(Advisory pgfc — observation-only — serves as an instrumentation control: same telemetry,
  no actuation.)*

## Scenarios

- **Steady-state (sanity).** A stationary workload per class; confirms the harness, the
  rubric, and that nothing regresses when nothing is changing.
- **Non-stationary drift (the headline).** A tuning correct at `t0`, then a workload that
  *shifts* (rate, mix, or class). The discriminating question: does pgfc track the change
  while expert-static degrades, and how much of the oracle's tracking does it recover?

## Result schema

Each result or finding is one row in a phase doc's table, with a stable ID:

- **ID** — `<AREA>-<NNN>`, zero-padded, never reused. Areas: `PROB` (problem/value),
  `RUBRIC`, `FIX` (fixtures), `EXP` (experimental design / threats), `RESULT` (empirical
  outcome or verdict).
- **Statement** — one line: the claim or finding.
- **Evidence** — a reproducible run handle (config + workload + seed + dataset) or an
  external citation. No evidence, no result.
- **Confidence** — `Strong` / `Tentative` / `Anecdotal`.
- **Bearing on the verdict** — does this support, weaken, or qualify "pgfc solves the
  problem"?
- **Status** — see the [lifecycle](#status-lifecycle).
- **Link** — resolving issue/PR, where the finding implies a change.

## Threats to validity

A standing register every result is checked against; expanded in
[Phase 4](04-experimental-design.md).

- **Proxy–outcome gap.** Moving the dead-tuple fraction may not move latency/throughput/space.
  This is a hypothesis to test, not an assumption — and it is exactly the attribution the
  system's stubbed `verify()` does not perform.
- **Vacuum-cost confounder.** More aggressive vacuuming costs I/O; under an I/O ceiling the
  net effect of "act more" can be negative.
- **Synthetic generalizability.** pgbench-shaped and custom-driven workloads are not
  production; conclusions are bounded by fixture realism.
- **Compressed timescales.** Bloat and freeze play out over days; acceleration (high churn,
  compressed thresholds) is necessary and is itself a distortion to bound.
- **Non-stationarity realism.** A scripted "shift" is a caricature of how real workloads
  drift; the shape of the shift can flatter or punish an adaptive controller.
- **Oracle definition.** The upper bound is only as honest as the oracle's objective; a
  poorly specified oracle makes "fraction of gap closed" meaningless.
- **Measurement noise.** Warm-up, steady-state detection, and run-to-run variance must be
  handled or results are coin flips.

## Status lifecycle

`Open → Designed → Ready → Run → Concluded`

- **Open** — identified, not yet designed.
- **Designed** — fixture/scenario/metric defined; not yet runnable.
- **Ready** — runnable and reproducible, awaiting the execution gate.
- **Run** — data collected.
- **Concluded** — analyzed; a result recorded with evidence and a bearing on the verdict.

## Workflow and cadence

Mirroring the project's merge-then-branch discipline:

1. Branch from `main`.
2. Fill the phase doc: design, then (once unblocked) run and record results.
3. File an issue (linked from the table) for any finding that implies a change to
   pg_flight_controller.
4. Keep fixtures, harness, and datasets in-repo and reproducible.
5. Update the status table in [README](README.md) as phases progress.

## Per-phase exit criteria

A phase is **done** when:

- Its design questions are answered or explicitly deferred with a reason.
- Every result carries evidence (a reproducible run or a citation) and a bearing on the
  verdict.
- Threats to validity touching the phase are listed and, where possible, mitigated.
- The README status table reflects the outcome.
