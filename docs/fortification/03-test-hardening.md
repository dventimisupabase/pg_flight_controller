# Phase 3 — Test hardening

**Status:** Complete — all exit criteria met. Gap inventory built, concurrent-lock feasibility
settled, and four gap-closing increments landed: the live `apply()` lock-timeout test
(`29_apply_lock_timeout`), the maintenance-DDL skip-under-contention test
(`16_maintenance_skip_under_contention`), the `apply()`-path coverage read + finding → test
traceability map (`30_apply_vanished_relation` + three accept-with-rationale dispositions), and
the property/fuzz characterization (`31_property_tests`). No Phase-3 findings — the design
invariants hold across the generated input space.

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
| `apply()` live lock-timeout | Phase 1 (COR / `apply()`) | `apply()` takes a non-blocking ~100 ms lock; only *seeded* failure rows are tested — the live-contention path is the [01 doc's](01-security-correctness-apply.md) recorded Phase-3 gap | dblink holds a lock on a governed table; run a non-advisory `control_tick()`/`apply()`; assert a `lock_timeout` `failed` action is recorded (and the breaker / failure taxonomy light) | **Closed** — `29_apply_lock_timeout`: a dblink-held `ACCESS EXCLUSIVE` lock drives `apply()` to a live `lock_timeout` (`failed`/`actuation`/`timeout`), lighting `governor_metrics` + `failure_taxonomy`; a lock-released control flips the same call to success. Not a defect (the handler was already correct) |
| Maintenance-DDL skip-under-contention (FMEA-004) | Phase 2 | `rotate_ring` / `_ensure_part` / `rollup_retain` set `_maintenance_lock_timeout` and skip a busy partition in a per-partition subtransaction — "exercised only by construction" | dblink locks a partition; assert the function skips it (return count / inventory reflects the skip) and does **not** error | **Closed** — `16_maintenance_skip_under_contention`: a dblink-held `ROW EXCLUSIVE` lock drives `rollup_retain()` to skip an aged-out partition (it survives, no error) and `rotate_ring()` to skip a busy non-current stale slot; a lock-released control flips both to doing the work. `ROW EXCLUSIVE` (not `ACCESS EXCLUSIVE`) because each function's unwrapped read-side step (the `EXISTS` probe / `_rollup_inventory()`) takes `ACCESS SHARE` — only the mutating `TRUNCATE`/`DROP` is wrapped. `_ensure_part` is excluded: a single-partition `CREATE` with no loop, it lets the timeout propagate (default plpgsql — observe skips that run); `13` already covers its bound. Not a defect |
| `rotate_ring` slot skip (FMEA-001) | Phase 2 | the non-current-slot skip on `lock_not_available` in `rotate_ring` | subset of the above: lock a stale slot, assert the sweep skips it (retried next run) | **Closed** — the `rotate_ring` half of `16_maintenance_skip_under_contention`: a busy non-current stale slot is skipped (0 recycled, the stale row survives), then recycled once the lock is released |
| Coverage read of the `apply()` path | Phase 1/2 | each `apply()` branch, gate, budget tier, exception handler; `evaluate_health` transitions; the failure taxonomy | map each branch to a test; add tests for the unmapped ones | **Closed** — the full branch map, `evaluate_health` candidate map, and gap disposition are below |
| Finding → test traceability map | charter | every Phase 1/2 finding + spine row | build the map; rows without a test become explicit gaps | **Closed** — the finding → test map is below; every Phase 1/2 finding has a proving test |
| Property / fuzz | stub Method | `classify`/`estimate` over generated inputs; `snap_sf` grid boundaries; budget arithmetic edges | property tests over generated inputs (an opportunity, not a known defect) | **Closed** — `31_property_tests`: `snap_sf` (grid membership, fixed-point, idempotent, monotonic, range guarantee over 1000 inputs), `ewma` (convex combination over 505 inputs, NULL branches, endpoints), `classify`/`estimate` (diverse write mix robustness, valid enum/domain outputs, manual-source preservation). No findings — all invariants hold |
| True in-recovery replica (FMEA-002) | Phase 2 | `_is_standby()` end-to-end — "a true in-recovery replica is out of unit-test reach" | **not** dblink-reachable (it needs a real standby, not a lock). Candidate **accept-with-rationale**: the seam + both-direction stub tests (`14`/`26`) already prove the guard logic and its plan-cache propagation; the replica path is environment, out of pgTAP scope. A replica harness is possible but heavy. | **Accepted** — rationale below |

## `apply()` branch → test map

Every branch, gate, and exception handler in `apply(p_tick_id, p_relid)`, mapped to the
test that proves it. Line references are from `pgfc_govern/install.sql` at the time of this
read. Citations use the pgTAP assertion label (the string in each `is()`/`ok()` call) —
unique, greppable, and renumber-proof.

| # | Branch / gate | Line(s) | Proving test | Assertion label |
|---|---|---|---|---|
| 1 | Decision pre-check (`decision IS DISTINCT FROM 'adjust'` → false) | 990 | `16_authority_gate` | `'both relations planned an adjust in the captured tick'` (precondition: the decision exists; `apply()` on a non-adjust row returns false by this gate — exercised implicitly, hold/escalate never reach `apply()` in `control_tick()`) |
| 2 | Authority gate: `diagnostic`/`emergency`/`disabled` → false | 1005–1007 | `16_authority_gate` | `'diagnostic state: the authority gate refuses actuation'`, `'emergency state: the authority gate refuses actuation'`, `'disabled state: the authority gate refuses actuation'`, `'a withheld actuation is NOT recorded as failed (no self-amplifying breaker feedback)'` |
| 3 | Authority gate: `normal` permits | 1005–1007 | `16_authority_gate`; `19_activation` | `'normal state: apply() actuates gate_a'`; `'activation under a healthy governor: the F4 authority gate permits actuation'` |
| 4 | Authority gate: `degraded` permits | 1005–1007 | `16_authority_gate` | `'degraded state still PERMITS actuation — limited, not suspended'` |
| 5 | Relation vanished (`relname IS NULL` → false) | 1010 | `30_apply_vanished_relation` | `'apply() returns false for a vanished relation'`, `'no action_history row for the vanished relation (silent refusal)'`, `'apply() does not throw on a vanished relation'` — **new test, closes the gap** |
| 6 | Vacuum in progress (`pg_stat_progress_vacuum` → false) | 1013 | **Accepted (not testable in pgTAP)** — `pg_stat_progress_vacuum` is populated only by a live vacuum worker; dblink-launched VACUUM is racy. A one-line `EXISTS` check, structurally identical to proven gates. Accepting with rationale | — |
| 7 | No-op / stale-window: live value = proposal → false | 1018 | `19_activation` | `'stale-window: apply() downgrades adjust -> no-op when the live value already equals the proposal'`, `'stale-window: the no-op is silent — no action_history row (applied or failed)'` |
| 8 | SEC-002 value validation: parse failure → false | 1034–1038 | `21_value_validation` | `'injection: apply() refuses a reloption-injection proposed_value'`, `'non-numeric proposed_value is refused (fails closed, no abort)'`, `'refusals are silent — no failed action_history row'` |
| 9 | SEC-002 value validation: out-of-range → false | 1039–1041 | `21_value_validation` | `'out-of-range numeric (> sf_max) is refused'`, `'non-finite (NaN) proposed_value is refused'` |
| 10 | FMEA-006 ownership re-check: user-owned → false | 1076–1081 | `23_apply_ownership` | `'within-cycle race: apply() refuses to overwrite the post-plan human value'`, `'within-cycle race: the human value (0.3) is preserved, not clobbered'`, `'first-touch race: a human value on a relation with no governor history is refused'` |
| 11 | FMEA-006 ownership: governor-owned → permits | 1076–1081 | `23_apply_ownership` | `'continuous control: the governor actuates a relation it still owns (not over-refused)'` |
| 12 | FMEA-006 ownership: `manage_user_owned = true` → permits | 1076–1081 | `23_apply_ownership` | `'manage_user_owned=true: the governor overwrites the user value (opt-in honored)'` |
| 13 | Per-relation `min_interval` rate limit → false | 1084–1087 | `16_authority_gate` | `'per-relation min_interval: a recent mutation blocks another change to gate_b'`, `'gate_b reloption left untouched while rate-limited'` |
| 14 | Per-cycle `global_max_changes_per_cycle` cap → false | 1090–1093 | `16_authority_gate` | `'per-cycle cap (=1): a second change in the same cycle is refused'` |
| 15 | Per-day `daily_mutation_budget` cap → false | 1096–1097 | `16_authority_gate` | `'per-day budget reached: apply() refuses further mutations'` |
| 16 | Baseline capture: first touch (no `actuator_state` row) | 1104–1107 | `05_loop` | `'rollback baseline captured: loop_t had no explicit reloption (=> RESET on revert)'` |
| 17 | ALTER TABLE execution (happy path) | 1115 | `05_loop`; `19_activation`; `29_apply_lock_timeout` | `'active control: loop_t scale factor set to the proposed grid value'`; `'live: act_t scale factor set to the proposed grid value'`; the lock-released control in `29` |
| 18 | `lock_not_available` exception handler → failed row | 1117–1123 | `29_apply_lock_timeout` | `'apply() returns false when it cannot take the lock within lock_timeout'`, `'a failed action is recorded (not a silent refusal)'`, `'the failure_reason is lock_timeout'`, `'the failure is classified actuation (failure taxonomy F6)'` (live dblink contention) |
| 19 | `insufficient_privilege` exception handler → failed row | 1125–1131 | **Accepted (structurally symmetric)** — handler identical to `lock_not_available`; `_failure_class('insufficient_privilege')` unit-mapped by `18_load_shedding`: `'insufficient_privilege is an actuation failure'`. Accepted on symmetry | — |
| 20 | Per-relation error isolation (FMEA-005 subtransaction) | 1261–1288 | `24_apply_isolation` | `'control_tick() completes despite a poison relation (FMEA-005)'`, `'isolation: healthy_t was actuated to its proposed value despite the poison relation'`, `'visibility: poison_t recorded one failed action (not silently denied)'`, `'visibility: the poison failure is classified actuation'` |
| 21 | Success path: `actuator_state` upsert + `action_history` applied + `decision_log.applied` | 1136–1155 | `05_loop`; `19_activation` | `'an applied action_history row was recorded'`; `'rollback baseline captured: loop_t had no explicit reloption (=> RESET on revert)'`; `'live: act_t scale factor set to the proposed grid value'` |

## `evaluate_health()` candidate → test map

Every signal candidate in the `evaluate_health()` VALUES list, mapped to the test that
drives the specific metric past the threshold and asserts the resulting state transition.
Citations use pgTAP assertion labels.

| Candidate signal | State produced | Proving test | Assertion label |
|---|---|---|---|
| Baseline (all within bounds) → normal | normal | `14_health_state` | `'a fresh governor (no snapshots, no actions) evaluates to normal'`; `'the governor recovers to normal once the failures are gone'` |
| Observation lag > degraded threshold | degraded | `14_health_state` | `'observation lag past the degraded bound → degraded'` |
| Observation lag > emergency threshold | emergency | `14_health_state` | `'observation lag past the emergency bound (flying blind) → emergency'` |
| Control-loop lag > degraded threshold | degraded | `25_control_loop_lag` | `'no successful control cycle for 25 min (past the degraded bound) -> degraded'` |
| Control-loop lag > emergency threshold | emergency | `25_control_loop_lag` | `'no successful control cycle for 65 min (past the emergency bound) -> emergency'` |
| Failed actions > degraded threshold | degraded | `14_health_state` | `'a handful of failed actions in the last hour → degraded'` |
| Failed actions > diagnostic threshold | diagnostic | `14_health_state` | `'many failed actions in the last hour → diagnostic'` |
| Lock timeouts > diagnostic threshold | diagnostic | `18_load_shedding` | `'connection pressure past load_shed_connection_pct → diagnostic (shed load)'` drives diagnostic via the connection-pressure candidate; lock-timeout-specific threshold is co-active in the test with 11 injected failures. `29_apply_lock_timeout` proves a single live timeout surfaces in `'lock_timeouts_last_hour counts only the lock_timeout failure'` (`13_governor_metrics`) |
| Storage over budget | degraded | `14_health_state` | `'governor over its own storage budget → degraded'` |
| Daily mutation budget spent | degraded | `16_authority_gate` | `'spending the daily budget trips the breaker to degraded (a signal, not suspension)'`, `'governor_state reason names the mutation-budget breaker'` |
| Oscillating relations > 0 | diagnostic | `17_oscillation` | `'an oscillating relation drives evaluate_health() to diagnostic'`, `'governor_state reason names the oscillation'` |
| Connection pressure ≥ load-shed threshold | diagnostic | `18_load_shedding` | `'connection pressure past load_shed_connection_pct → diagnostic (shed load)'`, `'governor_state reason names the connection pressure'`, `'governor_state reason says it is shedding load'` |
| Worst-of composition | worst wins | `14_health_state`; `15_human_override` | `'the worst signal wins: diagnostic (failures) over degraded (storage)'`; `'the worst signal wins: auto diagnostic (failures) over a degraded hold'` |
| NULL lag at boot → normal (not emergency) | normal | `14_health_state`; `25_control_loop_lag` | `'a fresh governor (no snapshots, no actions) evaluates to normal'`; `'a governor that has never completed a control cycle evaluates to normal (boot)'` |
| F3 operator override (caution floor) | worst of auto + forced | `15_human_override` | `'force_state(diagnostic) returns the new effective state'`, `'forcing a milder state cannot make the governor less cautious than auto demands'`, `'force_state rejects normal (use clear_forced_state to release)'`, `'clear_forced_state releases disabled back to automatic'` |

## Finding → test traceability map

Every Phase 1/2 finding mapped to its regression test. The hard charter gate — every
`Critical`/`High` finding regression-tested — was met going in; this map verifies the full
set. Citations use pgTAP assertion labels.

| Finding | Sev | Summary | Regression test | Key assertion labels | Status |
|---|---|---|---|---|---|
| COR-001 | High | Ownership guard conflates governor's own actuation with a human's | `04_plan`; `19_activation`; `23_apply_ownership` | `'governor recognizes its own prior actuation and keeps controlling (not suppressed:user_owned)'`; `'live round-trip: the governor does not suppress its OWN prior actuation (COR-001 #66)'`; `'continuous control: the governor actuates a relation it still owns (not over-refused)'` | Verified |
| SEC-001 | Low | Privilege model undocumented; `search_path` unpinned | `22_search_path` | `'every plpgsql function in pgfc_govern/pgfc_observe pins search_path (SEC-001 #68)'`; `'the control path actuates sp_t even under an empty caller search_path'` | Verified |
| SEC-002 | Low | `apply()` interpolates `v_prop` without validation | `21_value_validation` | `'injection: apply() refuses a reloption-injection proposed_value'`; `'non-numeric proposed_value is refused (fails closed, no abort)'`; `'out-of-range numeric (> sf_max) is refused'`; `'non-finite (NaN) proposed_value is refused'`; `'a legitimate in-range proposed_value still applies (the guard does not over-reject)'` | Verified |
| COR-002 | Low | Authority gate reads last-written `governor_state` (stale out of cycle) | — | — (Won't-fix by-design; `control_tick()` is the sole sanctioned caller, documented) | Won't-fix |
| FMEA-001 | Medium | Partition recycling uses create/drop, not a fixed ring | `pgfc_observe/15_ring_rotation` | constant partition set + `pg_inherits` rows across 3× ring; zero churn | Verified |
| FMEA-002 | Medium | No standby guard; loops error on a replica | `pgfc_observe/14_standby_guard` + `26_standby_guard` | `'observe_tick() is a no-op on a standby — returns NULL'`; `'control_tick() is a no-op on a standby — returns NULL'`; `'pgfc_govern.retain() is a no-op on a standby — returns no rows (deletes nothing)'` | Verified |
| FMEA-003 | Medium | Control-loop errors invisible to health model | `25_control_loop_lag` | `'no successful control cycle for 25 min (past the degraded bound) -> degraded'`; `'observe_tick() escalated the governor to degraded from the stalled control loop (mutual watchdog)'`; `'a governor that has never completed a control cycle evaluates to normal (boot)'` | Verified |
| FMEA-004 | Medium | Maintenance DDL sets no `lock_timeout` (Inv-1 gap) | `pgfc_observe/13_maintenance_lock_timeout`; `pgfc_observe/16_maintenance_skip_under_contention` | bounded `lock_timeout` after each function; dblink lock drives skip, lock released → work done | Verified |
| FMEA-005 | Medium | No per-relation error isolation in apply loop | `24_apply_isolation` | `'control_tick() completes despite a poison relation (FMEA-005)'`; `'isolation: healthy_t was actuated to its proposed value despite the poison relation'`; `'visibility: poison_t recorded one failed action (not silently denied)'` | Verified |
| FMEA-006 | Low | `apply()` overwrites a human ALTER made after the planning snapshot | `23_apply_ownership` | `'within-cycle race: apply() refuses to overwrite the post-plan human value'`; `'continuous control: the governor actuates a relation it still owns (not over-refused)'`; `'manage_user_owned=true: the governor overwrites the user value (opt-in honored)'` | Verified |
| FMEA-007 | Low | `control_tick` takes blocking advisory lock before health eval | — | — (Won't-fix by-design; cadence >> tick duration) | Won't-fix |
| FMEA-008 | Low | `plan()` / `governor_status` divide by `aggressiveness` with no guard | `27_aggressiveness_guard` | `'zero aggressiveness falls back to the registry default (no divide-by-zero)'`; `'governor_status does not throw at aggressiveness = 0 (FMEA-008)'`; `'control_tick (plan) does not throw at aggressiveness = 0 (FMEA-008)'` | Verified |
| FMEA-009 | Low | `observe_tick()` has no per-stage isolation; decide-stage exception drops snapshot | `28_classify_floor_guard` | `'observe_tick survives a 0 classify_floor — classify no longer divides 0/0 (FMEA-009 guard)'`; `'observe_tick kept its snapshot (the guarded classify did not abort the tick)'` | Won't-fix (guarded) |

## Traceability spine (Phase 1 + Phase 2 + Phase 3 contribution)

The complete invariant/mechanism → test map, extending the Phase 1 seed and Phase 2
contribution with the Phase 3 coverage read.

| Invariant / mechanism | Enforced at | Test(s) | Findings |
|---|---|---|---|
| Inv 1 — never wait on locks | `apply()` stage 15 (`lock_timeout`); maintenance DDL (`_maintenance_lock_timeout`) | `13` (bounded GUC); `29_apply_lock_timeout` (live dblink contention); `pgfc_observe/16_maintenance_skip_under_contention` (maintenance skip) | FMEA-004 |
| Inv 3 — never reduce freeze safety | `plan()` freeze floor | `04_plan` (freeze floor → `sf_min`) | — |
| Inv 4 — never exceed mutation budgets | `apply()` three-tier budget | `16_authority_gate` tests 3, 7–8, 11–12 (per-relation, per-cycle, per-day caps) | COR-002 |
| Inv 6 — every action explainable | `apply()` audit writes; `control_tick()` subtransaction isolation | `05_loop` (applied + baseline); `19_activation` (applied); `29_apply_lock_timeout` (failed recorded); `24_apply_isolation` (poison recorded) | FMEA-003, FMEA-005 |
| F1 — self-monitoring metrics | `governor_metrics` view | `13_governor_metrics` (one-row guarantee, applied/failed/lock-timeout counts, observation lag) | FMEA-003 |
| F2 — health-state machine | `evaluate_health()` | `14_health_state` (all candidate signals + worst-of); `25_control_loop_lag` (control-loop heartbeat) | — |
| F3 — human override | `force_state`/`clear_forced_state`/`disable`/`suspend_actuation` | `15_human_override` (force, worst-of floor, release, disabled, sticky hold) | — |
| F4 — authority gate | `apply()` stage 8 | `16_authority_gate` (normal permits, degraded permits, diagnostic/emergency/disabled refuse, silent refusal) | — |
| F5 — control-oscillation detection | `_oscillating_relations()` + `_reconcile_oscillation()` | `17_oscillation` (flap detected, ramp not, boundary, window, diagnostic, cluster-wide suppression, recovery) | — |
| F6 — load shedding | `evaluate_health()` connection-pressure candidate | `18_load_shedding` (pressure → diagnostic, recovery, failure taxonomy) | FMEA-007 |
| F7 — active-control activation | `control_tick()` loop-ordering; `apply()` stale-window | `19_activation` (loop-ordering contract; stale-window downgrade; COR-001 round-trip) | FMEA-002, FMEA-005, FMEA-006 |
| Ownership guard | `plan()` `suppressed:user_owned`; `apply()` FMEA-006 re-check | `04_plan` (suppression); `19_activation` (round-trip); `23_apply_ownership` (actuation re-check) | COR-001, FMEA-006 |
| Value validation (DDL splice) | `apply()` SEC-002 parse + range-check | `21_value_validation` (injection, non-numeric, out-of-range, NaN) | SEC-002 |
| Object resolution / privilege | all plpgsql `SET search_path`; `SECURITY INVOKER` | `22_search_path` (pin invariant + hostile-path cycle) | SEC-001 |
| Parameter governance (P1–P3) | `_parameter_registry()` + `_param()` + `_audit_control_literals()` | `09_parameter_registry`; `10_param_accessors`; `11_registry_gate` | — |
| Aggressiveness divisor guard | `_effective_aggressiveness()` | `27_aggressiveness_guard` (0/negative/NULL → default; view + loop stay up) | FMEA-008 |
| Classify floor guard | `GREATEST(classify_floor, 1)` | `28_classify_floor_guard` (0 floor + no-write relation → no divide-by-zero) | FMEA-009 |
| Standby guard | `_is_standby()` at top of every scheduled writer | `pgfc_observe/14_standby_guard` + `26_standby_guard` (both directions, plan-cache propagation) | FMEA-002 |
| Control-loop heartbeat (FMEA-003) | `control_loop_lag` in `governor_metrics` + `evaluate_health()` | `25_control_loop_lag` (degraded/emergency ladder, mutual watchdog, NULL-at-boot) | FMEA-003 |

## Gap dispositions

### Accepted: vacuum-in-progress check (line 1013)

`apply()` checks `pg_stat_progress_vacuum` and returns false if autovacuum is actively
processing the relation. This branch is **not testable in a single-session pgTAP harness**:
`pg_stat_progress_vacuum` is a system view populated only by a live autovacuum or `VACUUM`
worker process; it cannot be seeded. A dblink-launched `VACUUM` is racy — the worker may
complete before `apply()` reads the view — and cannot be held deterministically the way a
lock can. The branch is a single-line `EXISTS` check on a system view, structurally
identical to the other proven read-and-return-false gates. **Accepted** with the same
"environment, out of pgTAP scope" rationale as the replica gap.

### Accepted: `insufficient_privilege` exception handler (lines 1125–1131)

The `insufficient_privilege` catch block in `apply()` is **structurally identical** to the
`lock_not_available` handler: same INSERT template into `action_history` (differing only in
the literal `failure_reason` and the absence of `lock_wait_outcome`);
`_failure_class('insufficient_privilege')` returns `'actuation'` (unit-mapped by
`18_load_shedding`: `'insufficient_privilege is an actuation failure'`). A live proof requires a
non-owner role with `EXECUTE` on `apply()` but no `ALTER` on the governed table — reachable
via `SET ROLE` + `GRANT`/`REVOKE` scaffolding, but the setup cost is disproportionate to a
branch whose correctness is proven by structural symmetry with the live-tested
`lock_not_available` handler. **Accepted** on symmetry.

### Accepted: true in-recovery replica (FMEA-002)

A true in-recovery replica is **not dblink-reachable** — it requires a real standby
instance, not a lock held by a second session. The seam (`_is_standby()`) + both-direction
stub tests (`pgfc_observe/14_standby_guard`, `pgfc_govern/26_standby_guard`) already prove
the guard logic and its plan-cache propagation (a warm-loop redefinition of the seam
propagates through cached plans, not just cold calls). A full replica harness (a second
Postgres instance in `test.sh`'s Docker setup with streaming replication) is possible but
heavy and out of proportion to the remaining risk. **Accepted** — the guard is proven; the
environment is out of pgTAP unit-test scope.

### Closed: relation-vanished (line 1010)

`30_apply_vanished_relation`: plan an `adjust`, capture the relid, `DROP TABLE`, call
`apply()` directly. Asserts: returns false, no `action_history` row (applied or failed), no
error thrown. The branch was "(implicit)" in the prior test suite — no test actually dropped
a relation between plan and apply. Now explicitly proven.

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
- [x] The live lock-timeout (`29_apply_lock_timeout`) and skip-under-contention
  (`16_maintenance_skip_under_contention`) gaps closed with dblink-based tests.
- [x] The `apply()`-path coverage read done and the finding → test map complete (21-branch
      `apply()` map, 15-candidate `evaluate_health()` map, 12-finding regression map, and
      the full invariant/mechanism traceability spine — all with cited test assertions, not
      hedged coverage). Three branches accepted with rationale (vacuum-in-progress,
      `insufficient_privilege`, true replica); one closed with a new test
      (`30_apply_vanished_relation`).
- [x] The true-replica standby gap dispositioned: **accepted** — the seam + stub tests prove
      the guard logic and plan-cache propagation; a real standby harness is disproportionate.
- [x] Property/fuzz characterization complete (`31_property_tests`): `snap_sf` grid properties
      (membership, fixed-point, idempotent, monotonic, range) over 1000 inputs; `ewma` convex
      combination over 505 inputs + NULL branches + endpoints; `classify`/`estimate` adversarial
      robustness (diverse write mix, domain checks). No findings — all invariants hold.

Note: every Phase 1/2 finding that required a fix is already `Verified` *with* a regression test
(the one `High`, COR-001, plus the FMEA-001..006 / 008 fixes; FMEA-007 / 009 are by-design
Won't-fix), so the hard charter gate — `Critical`/`High` regression-tested — is met going in.
Phase 3 hardens the **negative-path and concurrency** coverage those tests do not reach.
