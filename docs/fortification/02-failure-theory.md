# Phase 2 — Failure theory (FMEA)

**Status:** In progress (first pass complete) — modes enumerated and dispositioned, findings
filed. Closes when every `Critical`/`High` mode is `Verified`/`Won't-fix` and the actionable
findings have regression coverage (much of that is shared with Phase 3).

> **Headline.** No new `Critical`/`High`. The *mutation path fails safe*: `control_tick()` runs
> a whole cycle in one transaction, so a crash or uncaught error is all-or-nothing — the
> catalog `ALTER` and its audit writes commit together or not at all, and no torn multi-relation
> state is reachable. The findings below are about **observability, isolation, and
> environment** (a wedged loop the health model can't see; one poison relation denying the
> whole cycle; a standby; lock-wait on maintenance DDL; catalog churn), not unsafe actuation.

Appendix F asserts that an autonomous actuator must have an explicit theory of failure.
This phase turns that thesis into a structured **failure-mode and effects analysis**: for
each way the system can fail, what is the effect, does it fail safe, and what detects /
recovers it. It builds on Phase 1's traceability spine — each failure mode attaches to the
invariant or mechanism it stresses.

## Method

- Enumerate failure modes by stage of the loop (observe / estimate / plan / apply /
  verify) and by environmental fault (crash, restart, replica promotion, clock skew,
  `pg_cron` overlap or skew, upgrade re-run of `install.sql`, partition rotation races,
  privilege loss, catalog churn from outside).
- For each: **cause → effect → fail-safe? → detection → recovery**, with `file:line`
  evidence and a severity per the charter rubric.
- Cross-check against the five failure categories in the taxonomy
  (`_failure_class` / `failure_taxonomy`) and appendix F's mode definitions
  (normal/degraded/diagnostic/emergency/disabled).

## Seed list (worked below)

- Crash mid-`apply()` (between `ALTER TABLE` and the audit write).
- `pg_cron` schedules overlapping or drifting; `observe_tick` vs `control_tick` cadence.
- Upgrade: re-running `install.sql` across every increment; the additive-only rule and
  the destructive S2 exception.
- Replica promotion / failover; running on a standby.
- A `snapshots` row with NULL pressure/lag (boot / pre-feature).
- Partition rotation (`retain()`) racing a read or a write.
- Health-state transitions under conflicting signals (worst-of correctness).
- Within-cycle human-`ALTER` race (carried from Phase 1).

## Cited-safe modes

Modes worked and found to **fail safe** as built (the reassuring half of the analysis):

| Mode | Why it is safe | Evidence |
|---|---|---|
| **Crash mid-cycle** (process/backend dies between the `ALTER` and the audit writes) | `control_tick()` is one transaction with no intermediate `COMMIT`; the `ALTER`, `actuator_state`, `action_history`, and `decision_log.applied` writes commit together or roll back together. No torn catalog/audit state. | `pgfc_govern/install.sql:1143-1191` (single txn), `:1065`/`:1086`/`:1097`/`:1104` |
| **`apply()` `ALTER` failure** (lock timeout / no privilege) | The `BEGIN … EXCEPTION` block is a plpgsql implicit subtransaction: the failed `ALTER` rolls back, a `failed` row is recorded, the loop continues. Inv 1 + Inv 6. | `pgfc_govern/install.sql:1063-1083` |
| **`observe()` overlap** (two runs race — `observe_tick()` takes **no** advisory lock, so this is reachable) | Each run allocates its **own** globally-unique `snapshot_id` (`snapshots.snapshot_id` IDENTITY, `RETURNING` into `v_snapshot_id`), so concurrent runs write independent `snapshots`/`relation_samples` rows that cannot key-collide (PK `(collected_day, snapshot_id, relid)`). The only shared mutable point is the `relation_last_state` cache (`ON CONFLICT (relid) DO UPDATE`) — an unguarded last-writer-wins, but benign on an UNLOGGED rebuildable cache (worst case one redundant or skipped sample, re-derived next run); `_ensure_partition()` catches the duplicate-day `CREATE`. | `pgfc_observe/install.sql:120`, `:682`, `:208`, `:797`, `:820-852`, `:507-532` |
| **Upgrade re-run** (`install.sql` re-applied) | `CREATE TABLE IF NOT EXISTS` + additive `ALTER … ADD COLUMN IF NOT EXISTS`; the one-time S2 destructive recreate is guarded by `relkind <> 'p'` (fires once) and only discards disposable telemetry. | `pgfc_observe/install.sql:17-21`, `:98-111`; `pgfc_govern/install.sql:11-14` |
| **NULL snapshot fields** (boot / pre-feature columns) | `COALESCE` defaults throughout `estimate()`/`plan()`/`governor_metrics`; a NULL newest-estimate snapshot makes `plan()` plan nothing — safe. | `pgfc_govern/install.sql:~709-712`, `:1170` |
| **Health-state worst-of** (conflicting signals) | Candidate states ranked by the health enum's native order (`DESC` picks the most cautious); the operator force is a one-directional caution floor; serialized under the `control_tick` advisory lock. | `pgfc_govern/install.sql:~2223`, `:2226-2237` |
| **Partition `DROP` racing an `observe()` write** (data-loss angle) | Safe because `drop_empty_partitions()` targets ~30-day-empty partitions `observe()` is **not** writing — *window separation*, not the `EXISTS`+lock (the `AccessShare` probe and a concurrent `RowExclusive` insert are compatible, so the `EXISTS→DROP` TOCTOU exists but is unreachable). The *lock-wait* angle is a finding (FMEA-004). | `pgfc_observe/install.sql:~1397-1419` |

## Findings

| ID | Sev | Conf | Evidence | Summary | Status | Link |
|---|---|---|---|---|---|---|
| FMEA-001 | Medium | Confirmed | `pgfc_observe/install.sql:~509`, `:~1397` | Telemetry uses create/drop daily partitions, churning the system catalogs, where the lineage used a fixed `TRUNCATE` ring (zero churn). | Accepted (adopt the ring) | [#79](https://github.com/dventimisupabase/pg_flight_controller/issues/79) |
| FMEA-002 | Medium | Confirmed | both `install.sql` (no `pg_is_in_recovery`) | No standby guard: the loops error every tick on a read-only replica; fail-safe but noisy and a post-failover footgun. | Accepted | [#80](https://github.com/dventimisupabase/pg_flight_controller/issues/80) |
| FMEA-003 | Medium | Confirmed | `pgfc_govern/install.sql:2025`, `:1171`, `:1143-1191` | Control-loop errors are invisible: `tick_log.error` is never written and a hard error rolls the tick row back, so the tick-error breaker is structurally dead and a wedged `control_tick` keeps the governor `normal`. | Accepted | [#84](https://github.com/dventimisupabase/pg_flight_controller/issues/84) |
| FMEA-004 | Medium | Confirmed | `pgfc_observe/install.sql` (`retain`/`drop_empty_partitions`/`_ensure_partition`, no `lock_timeout`) | Storage-maintenance DDL took `ACCESS EXCLUSIVE` with no bounded `lock_timeout` — an Invariant-1 gap outside the `apply()` path. | Verified | [#81](https://github.com/dventimisupabase/pg_flight_controller/issues/81) |
| FMEA-005 | Medium | Confirmed | `pgfc_govern/install.sql:1176-1180`, `:1143-1191` | No per-relation error isolation: one uncaught error in `apply()` aborted the whole cycle (all relations rolled back), deterministically and — per FMEA-003 — invisibly. | Verified | [#82](https://github.com/dventimisupabase/pg_flight_controller/issues/82) |
| FMEA-006 | Low | Confirmed | `pgfc_govern/install.sql:993-994` | `apply()` overwrote a human `ALTER` (made after the planning snapshot) whose value differs from the proposal — it re-checked neither `actuator_state` nor `manage_user_owned`. | Verified | [#83](https://github.com/dventimisupabase/pg_flight_controller/issues/83) |
| FMEA-007 | Low | Confirmed | `pgfc_govern/install.sql:1150` | `control_tick` takes a **blocking** advisory lock (not `try`) *before* `evaluate_health()`, so under cadence pressure ticks queue (each holding a backend) and F6 load-shedding cannot shed them. | Won't-fix (by-design) | — |

### FMEA-001 — Partition recycling uses create/drop, not a fixed `TRUNCATE` ring

**Severity:** Medium · **Confidence:** Confirmed · **Status:** Accepted — adopt the ring ([#79](https://github.com/dventimisupabase/pg_flight_controller/issues/79))

**What.** `pgfc_observe` bounds its high-volume telemetry (`relation_samples`,
`snapshots`) with daily `RANGE` partitions: `_ensure_partition()` issues
`CREATE TABLE … PARTITION OF` for each new day (`pgfc_observe/install.sql:~509`),
`retain()` `TRUNCATE`s expired daily partitions, and `drop_empty_partitions()` `DROP`s
long-empty shells (`:~1397`). The `TRUNCATE` eliminates *row* bloat, but the routine
`CREATE`/`DROP` churns the system catalogs (`pg_class`, `pg_attribute`, `pg_inherits`,
`pg_depend`, `pg_type`) — reintroducing *catalog* bloat in a system whose stated goal is
"zero bloat by construction." It fights bloat with bloat at the catalog layer.

**The lineage solved this differently.** `pg_flight_recorder` — the direct ancestor of
this storage model — recycles its high-volume sample tables with a **fixed ring**:
`rotate_ring()` keeps `num_slots` `LIST`-partitioned slots created **once at install**, and
rotation merely advances a pointer and `TRUNCATE`s the slot rolling off ("zero bloat, no
dead tuples, no GC needed"). No `CREATE`, no `DROP` in steady state → zero catalog churn.

**Cause → effect → fail-safe? → detection → recovery.** Cause: routine calendar-partition
create/drop. Effect: slow catalog bloat on the governor's own infrastructure. Fail-safe:
yes — no incorrect actuation, no data loss; the catalog dead tuples are backstopped by
autovacuum on the catalogs. Detection: not self-monitored (catalog size is not a governor
metric). Recovery: autovacuum; or the ring removes the cause.

**Genuinely different for this project (weigh before adopting the ring):** the read path
(`current_relation_state`, `rollup`) leans on `RANGE` pruning and would need slot-aware
reader views; sparse carry-forward must survive a slot `TRUNCATE`; the global `snapshot_id`
sequence must **not** reset; the retention window quantizes to `(slots−1) × rotation_period`.

**Disposition (author's call): adopt the fixed ring** (`#79`), accepting the porting cost
for zero steady-state catalog churn and consistency with the lineage. `Medium` — a
principle-and-lineage inconsistency, no safety consequence.

### FMEA-002 — No standby guard; the loops error every tick on a replica

**Severity:** Medium · **Confidence:** Confirmed · **Status:** Accepted ([#80](https://github.com/dventimisupabase/pg_flight_controller/issues/80))

Neither extension checks `pg_is_in_recovery()`. `observe_tick()` and `control_tick()` both
write, so on a read-only standby every cron tick raises `cannot execute … in a read-only
transaction`. **Fail-safe** (a standby physically cannot mutate the catalog), but the errors
are continuous, invisible to the governor's own health model (FMEA-003), and a post-failover
footgun: the demoted old primary errors forever while a promoted standby that carries the
cron jobs silently begins actuating. **Recovery/recommendation:** an early
`pg_is_in_recovery()` no-op guard so the loops idle on a standby and resume on promotion.

### FMEA-003 — Control-loop errors are invisible to the health model

**Severity:** Medium · **Confidence:** Confirmed · **Status:** Accepted ([#84](https://github.com/dventimisupabase/pg_flight_controller/issues/84))

`governor_metrics.tick_errors_last_day` counts `tick_log` rows with `error IS NOT NULL`
(`pgfc_govern/install.sql:2025`), and `evaluate_health()` has a breaker that reads it — but
**no code path ever writes `tick_log.error`**, and `control_tick()` is a single transaction
with no `EXCEPTION` handler, so a hard error aborts the txn and **rolls the `tick_log` row
back entirely** (the `INSERT` at `:1171`). The metric is structurally always 0; the breaker
is dead. And because `observe_tick()` is a *separate* cron job, `observation_lag` stays low
while `control_tick()` is wedged — the governor remains `normal` and silently stops
actuating. **Backstop:** pg_cron records the failure in `cron.job_run_details` (external).
**Recommendation note:** a single-txn function cannot record-and-reraise (rollback erases the
row) and plpgsql has no autonomous transactions, so the fix is *not* "just populate `error`";
candidates are a `last_successful_tick` heartbeat distinct from `observation_lag`, or
swallow-and-record (trading off pg_cron's own retry/alerting).

### FMEA-004 — Storage-maintenance DDL sets no `lock_timeout` (Invariant-1 gap)

**Severity:** Medium · **Confidence:** Confirmed · **Status:** Verified (mechanism) — fixed in [#81](https://github.com/dventimisupabase/pg_flight_controller/issues/81)

Invariant 1 requires *all* lock-acquiring operations to use bounded timeouts. `apply()`
honors it; the observe-side maintenance functions did not — `retain()` (`TRUNCATE`),
`drop_empty_partitions()` (`DROP`), and `_ensure_partition()` (`CREATE … PARTITION OF`) take
`ACCESS EXCLUSIVE` and would **wait unboundedly** behind a long reader/writer on a telemetry
partition (no `lock_timeout`/`set_config` anywhere in `pgfc_observe/install.sql`). **Low blast
radius** (the governor's own low-contention tables), but a stated hard invariant was unenforced
on these paths.

**Resolution.** A single helper `pgfc_observe._maintenance_lock_timeout()` (mirrors
`_telemetry_reloptions`, so observe stays independent of `pgfc_govern`'s registry) single-sources
a bounded value (`5s` — generous next to `apply()`'s `100ms`, since off-peak GC can wait a
couple of seconds for a transient reader of the governor's own tables, where user-facing
actuation cannot). Every recurring maintenance function — `_ensure_partition`, `_ensure_part`,
`retain`, `drop_empty_partitions`, `rollup_retain` — sets it txn-local at the top of its body.
The three **looping** GC functions additionally wrap each partition's work (the `EXISTS` probe
*and* the `TRUNCATE`/`DROP`, since both acquire locks) in a per-partition subtransaction that
catches `lock_not_available` and **skips** that partition (retried next run) rather than
aborting the whole run's truncates; `_ensure_partition` lets a timeout propagate (observe skips
that run, retries next minute).

**Scope.** Inv 1 governs the *autonomous cron* path. The install-time DDL — the S2 destructive
recreate and the `DO $reloptions$` per-partition backfill — is deliberately **not** bounded:
re-running `install.sql` is the supervised upgrade path, where a human-run migration may block.

**Verification.** `pgfc_observe/tests/13_maintenance_lock_timeout.sql` asserts each function
leaves a *bounded* `lock_timeout` (baseline the GUC to `0` = unbounded, call, assert it changed)
— the deterministic mechanism. The per-partition **skip-under-contention** path is exercised
only by construction; an end-to-end concurrent-lock test is **Phase-3 coverage** (the same shape
as the `apply()` live-lock-timeout gap).

### FMEA-005 — No per-relation error isolation in the apply loop

**Severity:** Medium · **Confidence:** Confirmed · **Status:** Verified (fixed in [#82](https://github.com/dventimisupabase/pg_flight_controller/issues/82))

The apply loop (`pgfc_govern/install.sql:1176-1180`) wrapped each `apply()` in no
subtransaction, and `apply()` catches only `lock_not_available`/`insufficient_privilege`. Any
*other* uncaught error (a corrupted `lock_timeout` registry value making `set_config` throw; a
future actuator's DDL error) aborted the whole single-transaction cycle — rolling back **all**
relations' changes, deterministically every cycle, and invisibly (FMEA-003). This is the flip
side of the (good) all-or-nothing atomicity: atomicity is right for a *multi-actuator batch*,
but the per-relation loop had no isolation, so one poison relation denied actuation to all.

**Resolution.** The apply loop now wraps each `apply()` in its own `BEGIN … EXCEPTION WHEN
others` subtransaction. A poison relation's uncaught error rolls back only that relation's
attempt — including a half-completed `apply()` whose inner `ALTER` block already released its
own savepoint, so only a savepoint taken *before* the `apply()` call can unwind it — then the
loop records the failure and continues, so one bad relation can no longer deny actuation to
all. The failure is recorded as a `failed` `action_history` row stamped `failure_class =
'actuation'` (the category is structural — the error arose in the actuation loop — not derivable
from open-ended error text), carrying the `SQLSTATE`/message as `failure_reason`: now **visible**
(vs the silent total denial above), surfaced in `failure_taxonomy`, and feeding the failed-action
breaker exactly like a `lock_timeout` — a genuine, repeating actuation failure trips it visibly,
and because the breaker's diagnostic state short-circuits `apply()`'s authority gate before this
error path, it cannot self-amplify. The recording `INSERT` itself can never throw (it runs with
no savepoint beneath it), so it cannot re-wedge the cycle. Regression test
`pgfc_govern/tests/24_apply_isolation.sql`: a per-relation DDL failure (an event trigger that
raises for one relation) is isolated and recorded while a healthy relation in the same cycle
still actuates — red pre-fix.

### FMEA-006 — `apply()` can overwrite a human `ALTER` made after the planning snapshot

**Severity:** Low · **Confidence:** Confirmed · **Status:** Verified (fixed in [#83](https://github.com/dventimisupabase/pg_flight_controller/issues/83))

Carried from the Phase 1 Concurrency disposition. `apply()`'s no-op gate returned false only
when the live value **equals** the proposal (`v_cur IS NOT DISTINCT FROM v_prop`,
`pgfc_govern/install.sql:993-994`); it re-checked neither `actuator_state` nor
`manage_user_owned`. A human value set after the snapshot `plan()` planned against — anywhere
in the **observe → apply** window (snapshot age + control cadence, i.e. minutes, not the
sub-second `plan → apply` gap), on a relation `plan()` classified `adjust` — was overwritten
that cycle; COR-001's guard (in `plan()`) only protected it the *next* cycle.

**Resolution.** `apply()` now mirrors COR-001's `sf_user_set` predicate against the **live**
reloption, just before the budget tiers: the governor owns the live value only when it has a
baseline row, *introduced* the option (`baseline_explicit = false`), and the live value still
equals what it last set (`current_value`). Any other explicit live value is user-owned and —
unless `manage_user_owned` — refused **silently** (the same posture as the other pre-mutation
gates). The `actuator_state` read is shared with the baseline capture, preserving the
never-overwrite-baseline semantics. Regression test `pgfc_govern/tests/23_apply_ownership.sql`:
a post-plan human change is refused and preserved (the prover — red pre-fix), while a
governor-owned relation still actuates (continuous control) and `manage_user_owned = true`
still takes ownership.

### FMEA-007 — `control_tick` takes a blocking advisory lock before evaluating health

**Severity:** Low · **Confidence:** Confirmed · **Status:** Won't-fix (by-design)

`control_tick()` calls `pg_advisory_xact_lock` (blocking, not `_try_`) at `:1150`, *before*
`evaluate_health()` at `:1156`. pg_cron does not serialize its own jobs, so a slow/blocked
tick makes the next cron invocation **wait** (not skip), queueing backends — and because the
wait precedes health evaluation, F6 load-shedding cannot shed them. **Disposition: Won't-fix
(by-design).** The control cadence (default 5 min) is far longer than a tick, so queueing is
not a realistic steady-state pressure; a `pg_try_advisory_xact_lock` that skips when a tick is
already running is the documented alternative if this ever bites. Recorded per the charter
rather than filed.

## Traceability (Phase 2 contribution)

Failure modes attach to the invariants/mechanisms they stress (extends the Phase 1 spine):

| Invariant / mechanism | Stressed by | Disposition |
|---|---|---|
| Inv 1 — never wait on locks | FMEA-004 (maintenance DDL, no `lock_timeout`) | FMEA-004 **Verified** (#81); skip-under-contention → Phase 3 |
| Inv 4 — never exceed mutation budgets | crash mid-cycle | Cited-safe (single-txn atomicity) |
| Inv 6 — every action explainable | FMEA-003 (loop errors unrecorded), FMEA-005 (silent total denial) | FMEA-005 **Verified** (#82); FMEA-003 → #84 |
| F1 — self-monitoring metrics | FMEA-003 (`tick_errors_last_day` structurally 0) | Finding |
| F2 — health-state machine | worst-of under conflicting signals | Cited-safe |
| F6 — load shedding | FMEA-007 (lock wait precedes health eval) | Won't-fix |
| F7 — active-control activation | FMEA-002 (standby), FMEA-005 (poison relation), FMEA-006 (post-snapshot human race) | FMEA-005/006 **Verified** (#82/#83); 002 open |

## Exit criteria

Per the charter — every enumerated mode dispositioned, all `Critical`/`High` modes
`Verified`/`Won't-fix`, spine contribution complete. **First-pass status:**

- [x] **Worked this pass:** the `apply()` / `control_tick()` path and the observe-storage
      path (crash, overlap, upgrade, partition rotation, standby, NULL fields, health worst-of,
      the lock/isolation/visibility findings) — each dispositioned cited-safe or as a finding.
- [ ] **Deferred to the next pass:** per-stage failure treatment of `estimate()` / `classify()`
      / `plan()` / `verify()`, and the environmental faults still unworked from the Method list
      (clock skew, crash-restart/recovery, privilege loss mid-operation).
- [x] No `Critical`/`High` modes found in the worked surface (the mutation path fails safe) —
      the hard exit gate is met for what has been analyzed.
- [x] Findings filed: FMEA-001 ([#79](https://github.com/dventimisupabase/pg_flight_controller/issues/79)),
      002 ([#80](https://github.com/dventimisupabase/pg_flight_controller/issues/80)),
      003 ([#84](https://github.com/dventimisupabase/pg_flight_controller/issues/84)),
      004 ([#81](https://github.com/dventimisupabase/pg_flight_controller/issues/81)),
      005 ([#82](https://github.com/dventimisupabase/pg_flight_controller/issues/82)),
      006 ([#83](https://github.com/dventimisupabase/pg_flight_controller/issues/83));
      FMEA-007 Won't-fix.
- [ ] The `Medium` findings reach `Fixed`/`Verified` (regression coverage shared with Phase 3).
