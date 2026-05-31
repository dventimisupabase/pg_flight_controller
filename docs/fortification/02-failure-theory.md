# Phase 2 — Failure theory (FMEA)

**Status:** Not started (stub — fleshed out when Phase 1 closes).

Appendix F asserts that an autonomous actuator must have an explicit theory of failure.
This phase turns that thesis into a structured **failure-mode and effects analysis**: for
each way the system can fail, what is the effect, does it fail safe, and what detects /
recovers it. It builds on Phase 1's traceability spine — each failure mode attaches to the
invariant or mechanism it stresses.

## Method (intended)

- Enumerate failure modes by stage of the loop (observe / estimate / plan / apply /
  verify) and by environmental fault (crash, restart, replica promotion, clock skew,
  `pg_cron` overlap or skew, upgrade re-run of `install.sql`, partition rotation races,
  privilege loss, catalog churn from outside).
- For each: **cause → effect → fail-safe? → detection → recovery**, with `file:line`
  evidence and a severity per the charter rubric.
- Cross-check against the five failure categories in the taxonomy
  (`_failure_class` / `failure_taxonomy`) and appendix F's mode definitions
  (normal/degraded/diagnostic/emergency/disabled).

## Seed list (to expand)

- Crash mid-`apply()` (between `ALTER TABLE` and the audit write).
- `pg_cron` schedules overlapping or drifting; `observe_tick` vs `control_tick` cadence.
- Upgrade: re-running `install.sql` across every increment; the additive-only rule and
  the destructive S2 exception.
- Replica promotion / failover; running on a standby.
- A `snapshots` row with NULL pressure/lag (boot / pre-feature).
- Partition rotation (`retain()`) racing a read or a write.
- Health-state transitions under conflicting signals (worst-of correctness).

## Findings

| ID | Sev | Conf | Evidence | Summary | Status | Link |
|---|---|---|---|---|---|---|
| *none yet* | | | | | | |

## Exit criteria

Per the charter — every enumerated mode dispositioned, all `Critical`/`High` modes
`Verified`/`Won't-fix`, spine contribution complete.
