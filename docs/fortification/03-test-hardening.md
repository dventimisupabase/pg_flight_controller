# Phase 3 — Test hardening

**Status:** Not started (stub — fleshed out when Phase 2 closes).

Not "do the tests pass" but "do the tests exercise the paths that can hurt us." The suite
already had blind spots — two hazards (loop-ordering, stale-window) were recorded in the
`pgfc_govern` README and only tested when active control went live (F7). This phase finds
the rest before they bite.

## Method (intended)

- Coverage read of the dangerous paths surfaced in Phases 1–2: each `apply()` branch,
  every gate/budget tier, the exception handlers, the health-state transitions, the
  failure taxonomy.
- Map each Phase 1/2 finding and each traceability-spine row to the test that proves it;
  rows without a test are the gap list.
- Evaluate property / fuzz opportunities: `classify()` and `estimate()` over generated
  inputs, the scale-factor grid (`snap_sf`) boundaries, budget arithmetic at the edges.
- Assess negative-path and concurrency coverage (direct `apply()` calls, interleavings),
  not just happy-path.

## Findings

| ID | Sev | Conf | Evidence | Summary | Status | Link |
|---|---|---|---|---|---|---|
| *none yet* | | | | | | |

## Exit criteria

Per the charter — every identified coverage gap dispositioned (test added or accepted
with rationale); every `Critical`/`High` finding from Phases 1–2 has a regression test
(reaches `Verified`).
