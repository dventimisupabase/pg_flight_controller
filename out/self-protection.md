# pg_flight_controller — Governor Self-Protection (Design)

**Status: design intent, not the as-built spec.** The `out/` waystation that transforms
`in/appendix_f.md` into an implementable design. One-way input to the implementation:
once it lands, the as-built spec lives in `docs/` + the code, which may drift from this
doc; it is then frozen and never referenced backward from the project. Its own file, so
the frozen Phase I design is not reopened.

**Lineage.** The health-state / circuit-breaker / load-shedding machinery is adapted from
`pg_flight_recorder`, which already ships a `set_mode()` (normal/light/emergency), a
circuit breaker (`circuit_breaker_threshold_ms` / `_window_minutes` / recent-trips →
"consider emergency mode"), and load shedding (`load_shedding_active_pct`). The key
adaptation: the recorder is a passive **collector** whose modes gate *how much it
samples*; this governor is an **actuator** whose health state gates *how much authority it
has to act*.

---

## Purpose

`in/appendix_f.md`: the governor has authority to modify PostgreSQL, so it must be treated
as a potentially hazardous component — "the governor must govern itself before it governs
PostgreSQL." An autonomous actuator needs an explicit theory of failure: limit its own
authority, detect unsafe conditions, degrade gracefully, fail safely, never become a
source of instability. Doctrine: *Observe aggressively. Diagnose thoroughly. Act
cautiously. Escalate slowly. Fail safely.* Prefer inaction over unsafe action.

## Why this is built before active control (and is not a P4-style deferral)

P4 correctly **deferred** the `parameter_override` table because its consumer was
*speculative*. Self-protection is the inverse, and the distinction must be stated so it is
not relitigated: in advisory mode the governor doesn't act, so circuit breakers / authority
limits / actuation-suspending states have nothing to bite on *today* — which superficially
looks like the same zero-consumer trap. It is not. Three discriminators all hold here where
they failed for the override table:

- **The consumer is certain and imminent** — `apply()`, the very next phase.
- **It is a safety prerequisite** — you do not enable a dangerous actuator without its
  safety net already built. "A governor that cannot safely govern itself cannot safely
  govern PostgreSQL."
- **It is testable now via injected state** — insert `failed` `action_history` rows, flip
  `advisory_only = false` in a test (as `05_loop` already does), and assert the breaker
  trips and `apply()` suppresses.

So self-protection is built now and **legitimately wires into `apply()`** — it is the gate
that must exist before active control, not a parallel framework that does nothing.

---

## What is already satisfied (bank it — cited, not re-proposed)

Much of appendix F's safety story is already built across the prior phases; the
implementation cites it rather than re-designing it.

| Appendix F | Already in the code |
|---|---|
| Invariant 1 — never wait on locks | `apply()` sets `lock_timeout` (single-sourced from the registry) and treats `lock_not_available` as a normal outcome |
| Invariant 2 — never disable autovacuum | the governor only moves the scale factor; it has no path that disables autovacuum |
| Invariant 3 — never reduce freeze safety | the freeze floor in `plan()` forces the cleanest scale factor under freeze stress |
| Invariant 5 — never escalate without evidence | `estimate()` sets `saturation_cause`; `plan()` escalates to diagnosis, not more DDL |
| Invariant 6 — every action explainable | `decision_log` / `action_history` / `diagnostics` |
| Self-monitoring (partial) | `catalog_health`, `self_health`, `tick_log`, `action_history` (failed attempts) |
| Config safety review | `validate_parameters()` (P4) |
| Primitive human override | `policy.advisory_only`, `policy.enabled` |

**Invariant 4 (mutation budgets)** is *designed* (the `policy` budget columns) but not
*enforced*; enforcement is entangled with `apply()` and is a placement call (see Open
Decisions), not new design.

## The genuinely new surface

Narrower than appendix F's 10-item list looks once the above is banked:

1. **Health-state model** — `normal → degraded → diagnostic → emergency → disabled`, each
   with defined capabilities; a single-row governor-state record + a transition-audit log.
2. **Self-monitoring metrics** — the signals the state is computed from (failed actions,
   lock timeouts, mutation count, observation lag, loop durations, storage footprint,
   retention backlog).
3. **Governor-level self-diagnostics** — extend `diagnostics` from per-relation inhibitors
   to *governor-scope* findings (lagging, budget exceeded, can't acquire locks, oscillation).
4. **Control-oscillation detection** — a setting repeatedly flipped (from `action_history`)
   → diagnostic + suppression.
5. **Human-override surface** — beyond `advisory_only`/`enabled`: force a state (disable,
   suspend actuation, force diagnostic), audited.
6. **The `apply()` authority gate** — `apply()` consults the health state and reduces or
   refuses actuation when the governor is not `normal`.

(Load shedding and a full failure-classification taxonomy are appendix F items whose build
scope is a decision below — the `out/` doc captures the full vision regardless.)

---

## Health-state model (the default representation)

This has an obvious default (the recorder pattern), stated rather than asked:

- **`governor_state`** — a single-row record (enforced singleton) holding the current
  `state`, `since`, `reason`, and an `operator_forced` state (NULL = automatic).
- **`state_transitions`** — append-only audit: `from_state`, `to_state`, `reason`,
  `triggering_condition`, `at` (appendix F "Auditability"). Pruned by `retain()` like the
  other audit tables.
- The state is **computed**, never decorative: an evaluator function derives it from the
  self-monitoring metrics (and an operator-forced override always wins, downward only — a
  human can force *more* caution, never less). It runs in the observe/control tick.
- **Capabilities per state** (appendix F): `normal` = full; `degraded` = observe, estimate,
  diagnose, and *limited* actuation; `diagnostic` = observe, estimate, diagnose, with **no
  actuation** except permitted safety actions; `emergency` = minimal observation and health
  reporting, **no actuation**; `disabled` = nothing (history preserved).
- All transition thresholds (failure counts, windows, lag bounds, stress %) are **born
  governed** — registry parameters (`safety_bound` / `empirical_default`), gate-enforced.
  This is the concrete payoff of having sequenced Phase 1.6 first.

**The state must not be asserted before the thing that computes it exists** — so the
metrics (increment F1) land before or with the state machine (F2).

---

## Proposed increments

Each a separate PR through the existing gates, smallest-useful-first, sequenced so nothing
is asserted before its inputs exist.

- **F1 — Self-monitoring metrics.** A `governor_metrics` view (and/or function) over the
  existing tables: applied/failed actions and lock-timeouts over a window, mutation counts,
  observation lag (newest snapshot age), loop durations (`tick_log`), storage + retention
  backlog (`self_health`). Read-only; no behaviour change. The substrate everything else
  reads.
- **F2 — Health-state machine.** `governor_state` + `state_transitions` + the evaluator
  computing the state from F1 metrics against registry-param thresholds, recording every
  transition. Surfaced to operators. Still does not gate actuation (advisory).
- **F3 — Human-override surface.** Operator functions to force `disabled` /
  `suspend actuation` / `diagnostic`, audited as transitions; the evaluator honors them
  (downward only). Extends `advisory_only`/`enabled`.
- **F4 — The `apply()` authority gate + circuit breakers + the mutation budget (Inv 4).**
  `apply()` consults `governor_state` and refuses/limits when not `normal`; failure-driven
  transitions (too many failed actions / lock timeouts / mutations in a window →
  `degraded`/`diagnostic`) are the circuit breakers. **The three-tier mutation budget
  (Invariant 4) is enforced here** as part of authority limiting — so the budget thresholds
  are born governed and the breaker and budget share one health-state model. Tested via
  injected `action_history` + `advisory_only=false`. **This is the active-control gate.**
- **F5 — Oscillation detection.** Detect a relation's setting flapping from
  `action_history`; raise a governor-level diagnostic and transition to `diagnostic`,
  suppressing further changes to that target.
- **F6 — Load shedding + failure-classification taxonomy.** Stress-driven workload
  reduction (slower cadence / suspended actuation under DB stress — the recorder
  `load_shedding_active_pct` pattern, on a connection/stress signal) and the explicit
  failure categories (observation / decision / actuation / resource / safety) attached to
  recorded failures.
- **F7 — Active-control activation.** With the safety net built and proven, enable
  `apply()` to act live (the supported `advisory_only = false` path) under the health-state
  gate, for the existing scale-factor actuator. This is the culmination of Phase 1.7 (see
  Phasing) — not a separate phase.

---

## Appendix F MVP coverage

| # | Requirement | Where |
|---|---|---|
| 1 | Health states | F2 |
| 2 | Circuit breakers | F4 |
| 3 | Authority limits | F4 (+ Inv-4 budgets, placement TBD) |
| 4 | Load shedding | F6 (scope TBD) |
| 5 | Self-monitoring metrics | F1 |
| 6 | Failure classification | F5/F6 |
| 7 | Mode transitions | F2 (+ audit) |
| 8 | Operator override controls | F3 |
| 9 | Decision logging | already (`decision_log`/`action_history`) |
| 10 | Safety invariant enforcement | banked (1,2,3,5,6) + F4 (Inv 4) |

---

## Decisions (resolved)

1. **Build scope: full appendix F (F1–F6).** Load shedding and the failure-classification
   taxonomy (F6) are in scope, not deferred.
2. **Activation folds into Phase 1.7's tail (F7).** There is **no separate Phase 2**: once
   the safety net is built and proven, enabling live active control (`advisory_only = false`
   for the scale-factor actuator, under the health-state gate) is the final increment of
   Phase 1.7.
3. **Invariant-4 budget is enforced in F4** as part of authority limiting — born governed,
   sharing the health-state model with the circuit breakers.

## Phasing

Phase 1.7 absorbs what was previously sketched as "Phase 2 — active control": it builds the
self-protection framework (F1–F6) and then **activates** the existing scale-factor actuator
under it (F7). The broader actuator roadmap — the small-table threshold lever, the analyze
objective, cost/`io`-budget actuators, and the catalog-bloat braking loop — remains genuine
**future work** beyond Phase 1.7; folding *activation* in does not pull those forward.
