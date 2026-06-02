# Efficacy

A work stream that asks whether pg_flight_controller solves a **real problem** and
**actually works** — measured against live databases under realistic, moving workloads,
not for correctness but for *utility*. This directory is the system of record for that
question.

Umbrella tracking issue:
[#73](https://github.com/dventimisupabase/pg_flight_controller/issues/73).

> **Why this is separate from fortification.** The
> [fortification](../fortification/README.md) stream asks *"is the system safe and correct
> as built?"* — that an autonomous actuator does only what it is meant to and fails safe.
> Efficacy asks the question fortification structurally cannot: *"does the thing it does
> well do anything worth doing?"* A controller can be perfectly safe and correct and still
> steer toward the wrong target, or steer a setpoint that does not move the outcome. The two
> streams are complementary; neither subsumes the other.

## The spine — four gates

The stream is organized as the question every reviewer of the *premise* should ask, in
order. Each step is a **gate**: it must pass before the next earns the effort.

1. **Define the problem.** What does vacuuming solve; what does autovacuum solve; what does
   *operating* autovacuum solve — and so, precisely, what problem does pg_flight_controller
   claim to solve?
2. **Is it valuable?** Is that problem worth solving, and is the *pg_flight_controller-specific*
   part of it (continuous automated re-tuning vs. good static tuning) genuinely open?
3. **Does pgfc solve it?** Under realistic workloads, does active control move tables from
   unhealthy toward healthy — by an *outcome* measure, not just its own proxy?
4. **Adequately?** How much of the achievable benefit does it capture, at what cost, versus
   the alternatives — and how close is that to the happy path?

## How this is organized

Read the charter first — it defines the method, the rubric, and the bar every phase reuses:

- **[00-framework.md](00-framework.md)** — the charter: scope, the health rubric (proxy vs.
  outcome vs. cost), the adequacy bar, the experimental arms and scenarios, the
  threats-to-validity register, the result schema, and per-phase exit criteria.

The six phases, in order:

1. **[01-problem-and-value.md](01-problem-and-value.md)** — the problem chain and the value
   question. *(the cheap first gate)*
2. **[02-health-rubric.md](02-health-rubric.md)** — what healthy and unhealthy mean,
   operationally. *(stub)*
3. **[03-workload-fixtures.md](03-workload-fixtures.md)** — representative tables and drivers
   per workload class, with non-stationary variants. *(stub)*
4. **[04-experimental-design.md](04-experimental-design.md)** — arms, scenarios, the adequacy
   bar, acceleration, threats to validity. *(stub)*
5. **[05-harness-and-tooling.md](05-harness-and-tooling.md)** — the reproducible runner.
   *(stub)*
6. **[06-execution-and-verdict.md](06-execution-and-verdict.md)** — run, analyze, and the
   verdict. *(stub — execution-gated; see below)*

## Status

| Phase | Title | Status |
|---|---|---|
| 1 | Problem and value | Not started |
| 2 | Health rubric | Not started |
| 3 | Workload fixtures | Not started |
| 4 | Experimental design | Not started |
| 5 | Harness and tooling | Not started |
| 6 | Execution and verdict | Not started (execution-gated) |

**Planning is unblocked; execution is sequenced.** Phases 1–5 are design work and can be
done now. Phase 6 (running the experiment) should follow the relevant fortification fixes
landing — notably [COR-001](../fortification/01-security-correctness-apply.md#findings)
([#66](https://github.com/dventimisupabase/pg_flight_controller/issues/66)), because the
self-stabilizing-under-drift thesis can only be tested once continuous control actually
works. COR-001 is a **bug to be fixed, not a constraint to design around**: this stream
plans and measures the system *as it is meant to work*, not as a transient defect makes it
behave.

## Where results go

A *result* or *finding* is recorded in the relevant phase doc using the schema in the
charter, each tied to a reproducible run or a citation. Findings that imply a change to
pg_flight_controller (e.g. a workload class whose `empirical_default` target proves wrong,
or evidence the scale factor is the wrong lever) are filed as GitHub issues and linked from
the phase doc; the analysis and datasets stay in-repo so they travel with the code and are
reviewable through the same CI gates.
