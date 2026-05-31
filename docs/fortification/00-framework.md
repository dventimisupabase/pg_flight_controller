# Fortification charter

The method every phase reuses. The goal of this phase is not new features; it is
**confidence in the system as built** — that an autonomous actuator mutating a live
catalog does only what it is meant to, fails safe when it cannot, and can be shown to.

## Principles

- **The code is ground truth.** Review the system *as built* at the reviewed
  baseline, not as designed. Where code and design diverge, the divergence is itself a
  finding (for the code or for the spec).
- **Safety before optimization.** A finding that an action could be unsafe outranks any
  finding about efficiency or style — the severity rubric encodes this.
- **Evidence, not assertion.** Every finding cites `file:line`. Every disposition
  ("safe") names the reason it is safe, not just that it was looked at.
- **Durable over ephemeral.** Analysis lives in these docs; actionable findings live as
  issues; fixes live as PRs. Nothing important lives only in a conversation.

## Scope and phase sequence

The phases run in order; each builds on the previous through the shared
[traceability spine](#traceability-spine).

1. **Security + correctness of the `apply()` path** — the actuation chain
   `control_tick() → plan() → apply()`. The narrowest, highest-stakes surface: the only
   place the system mutates the catalog.
2. **Failure theory (FMEA)** — what breaks, what happens then, and whether the system
   fails safe. Grounded in appendix F's theory of failure.
3. **Test hardening** — whether the suites actually exercise the dangerous paths, plus
   property/fuzz opportunities.
4. **Review process** — the standing discipline that outlives this phase.

Out of scope for this phase: new actuators, new objectives, performance *tuning*
(performance *review* is in scope as a failure/footprint concern).

## Finding schema

Each finding is one row in a phase doc's **Findings** table, with a stable ID:

- **ID** — `<AREA>-<NNN>`, zero-padded, never reused. Area prefixes: `SEC` (security),
  `COR` (correctness), `FMEA`, `TEST`, `PROC`.
- **Severity** — see the [rubric](#severity-rubric).
- **Confidence** — `Confirmed` / `Likely` / `Speculative` (how sure the finding is real,
  distinct from how bad it is).
- **Evidence** — `path:line` (or a range), the concrete locus.
- **Summary** — one line.
- **Status** — see the [lifecycle](#status-lifecycle).
- **Link** — the resolving issue/PR/commit, once one exists.

The full description and recommendation for a finding live in prose beneath the table
(keyed by ID); the table is the index.

## Severity rubric

Tuned to an autonomous actuator that mutates a live production catalog:

- **Critical** — can violate a [safety invariant](#traceability-spine), corrupt state,
  or lock/wedge the catalog; or lets the governor act when it must not. Fix before the
  phase closes.
- **High** — unsafe or incorrect actuation under *plausible* production conditions
  (concurrency, privilege, upgrade, stress), even if not yet observed.
- **Medium** — incorrect behavior under narrow/unlikely conditions, or a defense that is
  weaker than intended but currently backstopped by another.
- **Low** — correctness/robustness nit with no plausible safety consequence.
- **Info** — an observation, hardening idea, or documentation gap; not a defect.

## Status lifecycle

`Open → Triaged → {Accepted | Won't-fix} → Fixed → Verified`

- **Open** — recorded, not yet assessed.
- **Triaged** — severity/confidence assigned; disposition decided.
- **Accepted** — a real defect we will fix (→ issue filed). **Won't-fix** — understood
  and deliberately not changed (record *why* — that reasoning is the deliverable).
- **Fixed** — change merged.
- **Verified** — a test or observation proves the fix; the fix cannot silently regress.

`Critical`/`High` findings must reach **Verified** or **Won't-fix (with rationale)**
before a phase closes.

## Traceability spine

The thread that makes phases 2–4 build on phase 1 instead of starting cold: a matrix
linking **what must hold** to **the code that enforces it**, **the test that proves
it**, and **the findings that touch it**. The "what must hold" rows are the system's own
commitments:

- **Invariants 1–6** (appendix F): never wait on locks; never disable autovacuum; never
  reduce freeze safety; never exceed mutation budgets; never escalate without evidence;
  every action explainable.
- **Mechanisms F1–F7**: self-monitoring metrics; health-state machine; human override;
  authority gate + circuit breakers + Invariant-4 budget; oscillation detection; load
  shedding + failure taxonomy; active-control activation.

Each phase adds columns/rows to this spine rather than inventing its own structure:
security and correctness findings, FMEA failure modes, and test-coverage gaps all attach
to the same invariant/mechanism rows. The spine is maintained in the phase docs (Phase 1
seeds it for the `apply()` path; later phases extend it).

## Workflow and cadence

Per phase, mirroring the project's merge-then-branch discipline:

1. Branch from `main`.
2. Fill the phase doc: complete the inventory, work the checklist, record findings.
3. File an issue (label `fortification`) for each `Accepted` finding; link it in the
   table.
4. Fix via PRs; mark findings `Fixed`, then `Verified` once a test/observation backs it.
5. Confirm the phase's [exit criteria](#per-phase-exit-criteria); update the status
   table in [README](README.md) and the umbrella issue
   [#45](https://github.com/dventimisupabase/pg_flight_controller/issues/45).

## Per-phase exit criteria

A phase is **done** when:

- Every checklist item is dispositioned — either *verified safe* (with a cited reason)
  or *turned into a finding*.
- Every `Critical`/`High` finding is `Verified` or `Won't-fix` with recorded rationale.
- The phase's contribution to the [traceability spine](#traceability-spine) is complete
  for the surface it covers.
- The README status table and the umbrella issue reflect the outcome.
