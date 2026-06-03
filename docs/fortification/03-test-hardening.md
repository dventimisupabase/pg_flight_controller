# Phase 3 — Test hardening

**Status:** In progress (planning) — gap inventory built and the concurrent-lock feasibility
question settled (below); the gap-closing tests follow as their own increments.

Not "do the tests pass" but "do the tests exercise the paths that can hurt us." The suite already
had blind spots — two hazards (loop-ordering, stale-window) were recorded in the `pgfc_govern`
README and only tested when active control went live (F7), and the entire *upgrade* path was
untested until the FMEA-001 work added the `upgrade.sh` gate (which caught two real migration bugs
in review). This phase finds the rest before they bite.

## Method

- Coverage read of the dangerous paths surfaced in Phases 1–2: each `apply()` branch, every
  gate/budget tier, the exception handlers, the health-state transitions, the failure taxonomy.
- Map each Phase 1/2 finding and each traceability-spine row to the test that proves it; rows
  without a test are the gap list.
- Evaluate property / fuzz opportunities: `classify()` and `estimate()` over generated inputs,
  the scale-factor grid (`snap_sf`) boundaries, budget arithmetic at the edges.
- Assess negative-path and concurrency coverage (direct `apply()` calls, interleavings, real lock
  contention), not just happy-path.

## Feasibility settled: concurrent-lock contention is reproducible in-harness

Most deferred gaps below share one prerequisite — a *second session* must hold a lock while a
governor function runs, to trigger the real `lock_timeout` / skip path. pgTAP runs one session per
file, so the open question was whether Phase 3 is "write tests" or "build a concurrency test
framework." That had to be answered before planning, not assumed.

**Settled (spike, PG 17):** `dblink` is present in the test image, and a `dblink`-held
`ACCESS EXCLUSIVE` lock makes the main session's conflicting lock attempt raise `lock_not_available`
at a bounded `lock_timeout` — all inside one pgTAP file. So the concurrent-lock gaps are ordinary
pgTAP tests, **not** an infrastructure project.

**Proposed reusable pattern** (test-only — `CREATE EXTENSION dblink` lives in the test file, never
in `install.sql`):

1. open a named `dblink` connection; `BEGIN`; `LOCK TABLE <target> IN ACCESS EXCLUSIVE MODE` — the
   lock is held in that separate transaction;
2. in the test session, run the governor function (which sets its own bounded `lock_timeout`);
3. assert the contract — `apply()` records a `lock_timeout` `failed` action; a maintenance
   function *skips* the busy partition (no error, retried next run);
4. `ROLLBACK` + `dblink_disconnect` to release.

A small set-up/tear-down helper for the locker connection is the only new test scaffolding Phase 3
needs; the gap-closing tests then read like the existing pgTAP files.

## Coverage-gap inventory

| Gap | Source | Evidence | Test approach | Status |
|---|---|---|---|---|
| `apply()` live lock-timeout | Phase 1 (COR / `apply()`) | `apply()` takes a non-blocking ~100 ms lock; only *seeded* failure rows are tested — the live-contention path is the [01 doc's](01-security-correctness-apply.md) recorded Phase-3 gap | dblink holds a lock on a governed table; run a non-advisory `control_tick()`/`apply()`; assert a `lock_timeout` `failed` action is recorded (and the breaker / failure taxonomy light) | Open |
| Maintenance-DDL skip-under-contention (FMEA-004) | Phase 2 | `rotate_ring` / `_ensure_part` / `rollup_retain` set `_maintenance_lock_timeout` and skip a busy partition in a per-partition subtransaction — "exercised only by construction" | dblink locks a partition; assert the function skips it (return count / inventory reflects the skip) and does **not** error | Open |
| `rotate_ring` slot skip (FMEA-001) | Phase 2 | the non-current-slot skip on `lock_not_available` in `rotate_ring` | subset of the above: lock a stale slot, assert the sweep skips it (retried next run) | Open |
| Coverage read of the `apply()` path | Phase 1/2 | each `apply()` branch, gate, budget tier, exception handler; `evaluate_health` transitions; the failure taxonomy | map each branch to a test; add tests for the unmapped ones | Open |
| Finding → test traceability map | charter | every Phase 1/2 finding + spine row | build the map; rows without a test become explicit gaps | Open |
| Property / fuzz | stub Method | `classify`/`estimate` over generated inputs; `snap_sf` grid boundaries; budget arithmetic edges | property tests over generated inputs (an opportunity, not a known defect) | Open |
| True in-recovery replica (FMEA-002) | Phase 2 | `_is_standby()` end-to-end — "a true in-recovery replica is out of unit-test reach" | **not** dblink-reachable (it needs a real standby, not a lock). Candidate **accept-with-rationale**: the seam + both-direction stub tests (`14`/`26`) already prove the guard logic and its plan-cache propagation; the replica path is environment, out of pgTAP scope. A replica harness is possible but heavy. | Open (likely accept) |

## Findings

| ID | Sev | Conf | Evidence | Summary | Status | Link |
|---|---|---|---|---|---|---|
| *none yet* | | | | | | |

(Phase-3 findings are coverage gaps that, once a test is written, turn out to be real defects — or
gaps consciously accepted with a rationale.)

## Exit criteria

Per the charter — every identified coverage gap dispositioned (test added, or accepted with
rationale); every `Critical`/`High` finding from Phases 1–2 has a regression test (reaches
`Verified`). Concretely for this phase:

- [x] Concurrent-lock testing feasibility established (dblink; this doc).
- [ ] The live lock-timeout and skip-under-contention gaps closed with dblink-based tests.
- [ ] The `apply()`-path coverage read done and the finding → test map complete.
- [ ] The true-replica standby gap dispositioned (a replica harness, or accept-with-rationale).

Note: every Phase 1/2 finding that required a fix is already `Verified` *with* a regression test
(the one `High`, COR-001, plus the FMEA-001..006 / 008 fixes; FMEA-007 / 009 are by-design
Won't-fix), so the hard charter gate — `Critical`/`High` regression-tested — is met going in.
Phase 3 hardens the **negative-path and concurrency** coverage those tests do not reach.
