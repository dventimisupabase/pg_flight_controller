# Fortification

A phase of deep review of pg_flight_controller **as built** — hardening the system
that, once active control is enabled, autonomously issues `ALTER TABLE` against a live
production catalog. This directory is the system of record for that review.

> **Why now.** The code reached a tagged, self-consistent baseline at
> [v0.1.0](https://github.com/dventimisupabase/pg_flight_controller/releases/tag/v0.1.0)
> — a frozen "as-built" target worth reviewing before building further.

Umbrella tracking issue:
[#45](https://github.com/dventimisupabase/pg_flight_controller/issues/45).

## How this is organized

Read the charter first — it defines the method every phase reuses:

- **[00-framework.md](00-framework.md)** — the charter: scope, the finding schema, the
  severity rubric, the status lifecycle, the traceability spine, and per-phase exit
  criteria.

The four phases, in order (each builds on the one before via the shared traceability
spine):

1. **[01-security-correctness-apply.md](01-security-correctness-apply.md)** — security
   review + code review of the `apply()` path.
2. **[02-failure-theory.md](02-failure-theory.md)** — failure-mode analysis (FMEA).
3. **[03-test-hardening.md](03-test-hardening.md)** — test-suite adequacy +
   traceability.
4. **[04-review-process.md](04-review-process.md)** — the standing review process.

## Status

| Phase | Title | Status |
|---|---|---|
| 1 | Security + correctness — `apply()` path | **Complete** — COR-001 (High) / SEC-001 / SEC-002 Verified; COR-002 Won't-fix (by-design) |
| 2 | Failure theory (FMEA) | **Complete** — first + second pass (no Critical/High; decide/orient stages + environmental faults worked); FMEA-001..006 + 008 Verified; FMEA-007 + 009 Won't-fix by-design (009 also divide-guarded) |
| 3 | Test hardening | **Complete** — 21-branch `apply()` map, 15-candidate `evaluate_health()` map, 12-finding regression map, full traceability spine; tests `29`–`31` + three accept-with-rationale dispositions; no Phase-3 findings |
| 4 | Review process | **Complete** — actuation-path review checklist, CI-enforcement posture (existing gates sufficient), reusable assets catalogued |

## Where findings go

A *finding* is recorded in the relevant phase doc using the schema in the charter.
Findings that require a code change are filed as GitHub issues under the
[`fortification`](https://github.com/dventimisupabase/pg_flight_controller/labels/fortification)
label and resolved via PRs (the project's merge-then-branch discipline applies); the
phase doc holds the analysis and links the resolving issue/PR. The analysis stays
in-repo so it travels with the code and is reviewable through the same CI gates.
