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
   review + code review of the `apply()` path. *(detailed)*
2. **[02-failure-theory.md](02-failure-theory.md)** — failure-mode analysis (FMEA).
   *(stub — fleshed out when reached)*
3. **[03-test-hardening.md](03-test-hardening.md)** — test-suite adequacy. *(stub)*
4. **[04-review-process.md](04-review-process.md)** — the standing review process.
   *(stub)*

## Status

| Phase | Title | Status |
|---|---|---|
| 1 | Security + correctness — `apply()` path | **Complete** — COR-001 (High) / SEC-001 / SEC-002 Verified; COR-002 Won't-fix (by-design) |
| 2 | Failure theory (FMEA) | **Complete** — first + second pass (no Critical/High; decide/orient stages + environmental faults worked); FMEA-001..006 + 008 Verified (#79/#80/#84/#81/#82/#83/#96); FMEA-007 + 009 Won't-fix by-design (009 also divide-guarded) (#97) |
| 3 | Test hardening | **In progress** — gap inventory built; concurrent-lock testing shown feasible in-harness (dblink); the live `apply()` lock-timeout (`29_apply_lock_timeout`) and maintenance-DDL skip-under-contention (`16_maintenance_skip_under_contention`) tests landed; the `apply()`-path coverage read + finding→test map to follow |
| 4 | Review process | Not started |

## Where findings go

A *finding* is recorded in the relevant phase doc using the schema in the charter.
Findings that require a code change are filed as GitHub issues under the
[`fortification`](https://github.com/dventimisupabase/pg_flight_controller/labels/fortification)
label and resolved via PRs (the project's merge-then-branch discipline applies); the
phase doc holds the analysis and links the resolving issue/PR. The analysis stays
in-repo so it travels with the code and is reviewable through the same CI gates.
