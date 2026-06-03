# Phase 2 — Failure theory (FMEA)

**Status:** In progress (first + second pass complete) — modes enumerated and dispositioned, findings
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
| **Ring `TRUNCATE` racing an `observe()` write** (data-loss angle) | Safe by construction (FMEA-001): `rotate_ring()` runs **inside** `observe()`, in the same transaction and before the insert, and `TRUNCATE`s only a slot whose data is out-of-window (`collected_day < p_day-(slots-1)`) — the day being written is never truncated from under the write. A separate caller's `rotate_ring()` touches only out-of-window slots no in-progress `observe()` is writing. The *lock-wait* angle is bounded by FMEA-004's `_maintenance_lock_timeout`. | `pgfc_observe/install.sql` (`rotate_ring`) |
| **Decide/orient arithmetic & NULL** (`estimate()`/`classify()`: boot, counter reset, quiet relations, zero/NULL denominators) — *second pass* | Each stage is a single multi-CTE `INSERT … ON CONFLICT` (atomic). Denominators are guarded — `NULLIF(def_mxid_freeze_max_age,0)`, `GREATEST(reltuples,1)`; `dt <= 0` yields a NULL rate (the EWMA holds its prior) and the cycle boundary is the **monotonic** `autovacuum_count`; `ewma()` is NULL-safe (NULL sample → prior, NULL prior/alpha → sample); a missing prior trips the `boot` flag and a counter `reset` is detected and skips the rate. The one ungated divide — `classify` when `classify_floor = 0` (a code-constant, default 50) — is FMEA-009's trigger. | `pgfc_govern/install.sql:432-503` (estimate), `:591-617` (classify) |
| **Decide-stage overlap & re-run** (two `observe_tick`/`control_tick` runs race; a tick re-runs) — *second pass* | `relation_estimate`/`relation_class` upsert `ON CONFLICT (relid) DO UPDATE` — last-writer-wins, benign and idempotent (re-derived next tick); the diagnostics reconciler dedups open findings (`NOT EXISTS`) and resolves cleared ones, so a re-run neither duplicates nor churns. Extends the first-pass `observe()`-overlap row. | `pgfc_govern/install.sql:531-548`, `:656-663`, `:868-895` |
| **`verify()`** (close-the-loop stage) — *second pass* | A Phase-1 no-op (`SELECT 0`): no state, no failure surface. Its failure modes are analysed when it is implemented (product Phase 2). | `pgfc_govern/install.sql:1145-1148` |
| **Clock skew** (NTP step, backward or forward) — *second pass* | Rates use `dt = collected_at − prev`; a backward step (`dt <= 0`) yields a NULL rate (hold), and the cycle boundary is the **monotonic** `autovacuum_count`, immune to the clock. A backward step makes `observation_lag`/`control_loop_lag` negative → below threshold → no false alarm; a forward step inflates them → at worst a spurious `emergency` (caution direction, self-heals). The mutation economy stays bounded: a forward step can soften the rolling-day budget, but `global_max_changes_per_cycle` counts within one cycle (clock-independent) and **every** mutation is independently no-op/ownership re-checked (COR-001/FMEA-006) — skew can never produce a *wrong* or unbounded change, only a bounded rate wobble. | `pgfc_govern/install.sql:440`, `:463`; `apply()` budget gates |
| **Crash-restart / recovery** — *second pass* | Extends "crash mid-cycle": both loops are single transactions (atomic), so recovery finds no torn state. The `UNLOGGED` `relation_last_state` is empty after a crash and self-heals (the next `observe()` re-samples once); logged audit/state tables and the IDENTITY sequences survive. `control_loop_lag` is stale at restart → the first `observe_tick` records a degraded/emergency transition then `normal` once a cycle completes — the same honest, self-healing pair as FMEA-002's repromotion edge. | `pgfc_govern/install.sql:1143-1191`; `relation_last_state` (UNLOGGED) |
| **Privilege loss mid-operation** (cron role loses `ALTER`/table rights) — *second pass* | `apply()`'s `ALTER` failure is caught as `insufficient_privilege` → a recorded `failed` action (cited-safe `apply()`-failure + FMEA-005 isolation). Losing write rights on a govern/observe table instead makes the stage throw → the loop aborts and rolls back (no torn state), and the gap is detected via `observation_lag`/`control_loop_lag` (→ emergency). No silent wrong actuation. | `pgfc_govern/install.sql` (`apply()` catch); detection via the F1/FMEA-003 lags |

## Findings

| ID | Sev | Conf | Evidence | Summary | Status | Link |
|---|---|---|---|---|---|---|
| FMEA-001 | Medium | Confirmed | `pgfc_observe/install.sql:~509`, `:~1397` | Telemetry uses create/drop daily partitions, churning the system catalogs, where the lineage used a fixed `TRUNCATE` ring (zero churn). | Verified | [#79](https://github.com/dventimisupabase/pg_flight_controller/issues/79) |
| FMEA-002 | Medium | Confirmed | both `install.sql` (no `pg_is_in_recovery`) | No standby guard: the loops error every tick on a read-only replica; fail-safe but noisy and a post-failover footgun. | Verified | [#80](https://github.com/dventimisupabase/pg_flight_controller/issues/80) |
| FMEA-003 | Medium | Confirmed | `pgfc_govern/install.sql:2025`, `:1171`, `:1143-1191` | Control-loop errors are invisible: `tick_log.error` is never written and a hard error rolls the tick row back, so the tick-error breaker is structurally dead and a wedged `control_tick` keeps the governor `normal`. | Verified | [#84](https://github.com/dventimisupabase/pg_flight_controller/issues/84) |
| FMEA-004 | Medium | Confirmed | `pgfc_observe/install.sql` (`retain`/`drop_empty_partitions`/`_ensure_partition`, no `lock_timeout`) | Storage-maintenance DDL took `ACCESS EXCLUSIVE` with no bounded `lock_timeout` — an Invariant-1 gap outside the `apply()` path. | Verified | [#81](https://github.com/dventimisupabase/pg_flight_controller/issues/81) |
| FMEA-005 | Medium | Confirmed | `pgfc_govern/install.sql:1176-1180`, `:1143-1191` | No per-relation error isolation: one uncaught error in `apply()` aborted the whole cycle (all relations rolled back), deterministically and — per FMEA-003 — invisibly. | Verified | [#82](https://github.com/dventimisupabase/pg_flight_controller/issues/82) |
| FMEA-006 | Low | Confirmed | `pgfc_govern/install.sql:993-994` | `apply()` overwrote a human `ALTER` (made after the planning snapshot) whose value differs from the proposal — it re-checked neither `actuator_state` nor `manage_user_owned`. | Verified | [#83](https://github.com/dventimisupabase/pg_flight_controller/issues/83) |
| FMEA-007 | Low | Confirmed | `pgfc_govern/install.sql:1150` | `control_tick` takes a **blocking** advisory lock (not `try`) *before* `evaluate_health()`, so under cadence pressure ticks queue (each holding a backend) and F6 load-shedding cannot shed them. | Won't-fix (by-design) | — |
| FMEA-008 | Low | Confirmed | `pgfc_govern/install.sql:~762`, `:1296` | `plan()` and the `governor_status` view divide by `policy.aggressiveness` (no `CHECK`); an operator-set `aggressiveness ≤ 0` (advisorily flagged `CRITICAL` by `validate_parameters`, not enforced) is a division-by-zero — `plan()` wedges the control loop, `governor_status` throws on read. | Open | [#96](https://github.com/dventimisupabase/pg_flight_controller/issues/96) |
| FMEA-009 | Low | Confirmed | `pgfc_govern/install.sql:1167-1169` | `observe_tick()` runs `observe()`+`classify()`+`estimate()` in one txn with no per-stage isolation; an uncaught `classify()`/`estimate()` exception discards the just-collected snapshot — inconsistent with FMEA-003's subtransaction protection of the same observation. | Open | [#97](https://github.com/dventimisupabase/pg_flight_controller/issues/97) |

### FMEA-001 — Partition recycling uses create/drop, not a fixed `TRUNCATE` ring

**Severity:** Medium · **Confidence:** Confirmed · **Status:** Verified (fixed in [#79](https://github.com/dventimisupabase/pg_flight_controller/issues/79))

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

**Resolution.** Adopted the fixed ring. `snapshots`/`relation_samples` are now `LIST`-partitioned
on `slot smallint = collected_day % _ring_slots()` — a constant set of `_ring_slots()` (8) slot
partitions created **once** at install; `collected_day` stays a plain column (the BRIN index,
`rollup()` time-pruning, and human reads still use it). A single `rotate_ring(p_day)` replaces
`_ensure_partition` / `retain` / `drop_empty_partitions`: it `TRUNCATE`s any slot holding
out-of-window data (`collected_day < p_day - (slots-1)`), and `observe()` calls it before every
insert — so recycling is **inline** and there is no `CREATE`/`DROP` in steady state. That is the
finding's goal: zero dead tuples *and* zero catalog churn. The raw window quantizes to
`(_ring_slots()-1)` = 7 days — ≥ the prior `retain('3 days')` contract (the governor's control
memory never shrinks) and aligned with `rollup_1m`'s 7-day tier, leaving margin for `rollup()` to
aggregate a day before its slot recycles. The four porting constraints are met: the readers join
on `snapshot_id` and scan the parent, so they did **not** need to become slot-aware (the finding
over-stated this); sparse carry-forward survives because the window is ≥ the prior one; the global
`snapshot_id` IDENTITY lives on the parent and a partition `TRUNCATE` never resets it; and
retention quantizes as noted. Inv-1 lock discipline is preserved — `rotate_ring` sets the bounded
`_maintenance_lock_timeout`, lets the **current** slot's `TRUNCATE` *propagate* a timeout (so
`observe()` skips the run rather than mix two days in one slot) and skips a busy non-current slot
in a subtransaction (retried next run). The upgrade is a one-time destructive recreate (telemetry
is disposable) guarded on partition strategy (drop unless already `LIST`), so it fires once on the
Phase-0/`RANGE`→ring transition and is idempotent thereafter. Cross-schema, `pgfc_govern.degrade()`
becomes a force-sweep at the raw tier — the ring is bounded by construction, so its `keep_raw`
argument was removed and a budget below the raw floor is now unsatisfiable (documented). Regression
test `pgfc_observe/tests/15_ring_rotation.sql` is the prover: it drives the calendar 3× the ring
size and asserts the partition set and `pg_inherits` rows stay constant — zero churn, red on the
old create/drop model — plus the `(slots-1)`-day retention boundary and the non-resetting
`snapshot_id`.

### FMEA-002 — No standby guard; the loops error every tick on a replica

**Severity:** Medium · **Confidence:** Confirmed · **Status:** Verified (fixed in [#80](https://github.com/dventimisupabase/pg_flight_controller/issues/80))

Neither extension checks `pg_is_in_recovery()`. `observe_tick()` and `control_tick()` both
write, so on a read-only standby every cron tick raises `cannot execute … in a read-only
transaction`. **Fail-safe** (a standby physically cannot mutate the catalog), but the errors
are continuous, invisible to the governor's own health model (FMEA-003), and a post-failover
footgun: the demoted old primary errors forever while a promoted standby that carries the
cron jobs silently begins actuating. **Recovery/recommendation:** an early
`pg_is_in_recovery()` no-op guard so the loops idle on a standby and resume on promotion.

**Resolution.** A single base-layer seam, `pgfc_observe._is_standby()` (wraps
`pg_catalog.pg_is_in_recovery()`), is now the **first statement** of `observe()`,
`observe_tick()`, and `control_tick()`: `IF pgfc_observe._is_standby() THEN RETURN NULL; END
IF;`. In `observe()` it sits ahead of `_ensure_partition()`'s DDL; in `control_tick()` ahead of
even the advisory lock — so a standby takes no lock and writes nothing, and the loops resume
automatically on promotion. The check is single-sourced in `pgfc_observe` (the independent base
layer) so an observe-only install is covered and `pgfc_govern` reuses it cross-schema — the same
"small helper, single-sourced" move as FMEA-004's `_maintenance_lock_timeout()`. The original
fix scoped only the three high-frequency loops; a follow-up extends the same `_is_standby()`
guard to the daily maintenance writers (`rollup` / `rollup_retain` / `govern.retain` /
`degrade`), which otherwise error on a standby once a day — so every scheduled writer in both
extensions now idles on a replica and resumes on promotion.

**Interaction with the FMEA-003 heartbeat.** On a steady standby both loops no-op, so
`evaluate_health()` never runs and `control_loop_lag` is never evaluated — no false alarm; a
never-primary standby has an empty `tick_log` (NULL lag) regardless. The one edge is a
*demoted-then-repromoted* node: its `control_loop_lag` is stale at promotion, so the first
post-promotion `observe_tick()` writes an `emergency` transition, then a `normal` one once the
first control cycle completes (≤ one control cadence later). That `emergency → normal` pair is
honest and self-healing — a just-promoted node genuinely has not run a cycle yet, and caution is
the safe direction — not flapping. Recorded here so a reader of `state_transitions` does not
mistake it for one.

**Testability.** The seam lets a test simulate a standby without a real replica:
`CREATE OR REPLACE FUNCTION pgfc_observe._is_standby() … SELECT true` inside a rolled-back
transaction, then assert each loop returns `NULL` and writes nothing (and runs normally with the
seam at its default). `pgfc_observe/tests/14_standby_guard.sql` and
`pgfc_govern/tests/26_standby_guard.sql` assert **both** directions in one file — because earlier
tests in the session have already warmed the loops' plans, the standby direction proves a
redefinition of the inlined seam propagates through the plan cache, not just that a cold call
returns the stub. Red pre-fix (no guard → the loops run and return an id). A true in-recovery
replica is out of unit-test reach; that end-to-end path is Phase-3 / harness coverage.

### FMEA-003 — Control-loop errors are invisible to the health model

**Severity:** Medium · **Confidence:** Confirmed · **Status:** Verified (fixed in [#84](https://github.com/dventimisupabase/pg_flight_controller/issues/84))

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

**Resolution.** The fix is the heartbeat candidate, framed as the missing half of a *mutual
watchdog*: `control_tick()`'s `evaluate_health()` already reads `observation_lag`, so control
watches observe's liveness — but nothing watched control. `governor_metrics` now exposes
`control_loop_lag` (`= now() - max(tick_log.finished_at)`); because `finished_at` is set only
after `verify()` succeeds and a hard error rolls the whole tick row back, `max(finished_at)` is
a faithful "last fully-completed cycle" with **no schema change**. `evaluate_health()` gains a
control-loop-lag candidate mirroring the observation-lag ladder (degraded → emergency, on the
born-governed thresholds `health_control_lag_{degraded,emergency}_secs`); NULL lag (boot, or a
control loop never scheduled) is `normal`, and the signal stays fresh under
`advisory_only`/`disabled` (both still run the cycle), so only a genuine wedge or a stopped
control cron ages it. The **load-bearing** change is that `observe_tick()` now also refreshes
the health state — isolated in a subtransaction so a health-eval hiccup can never lose the
observation: a wedged `control_tick()` *cannot evaluate its own health* (`evaluate_health()`
runs inside it), so detection must come from the independent fast loop. With observe watching
control, a stalled control loop escalates to degraded/emergency even while `observation_lag`
stays low — the exact scenario above. The one wedge cause this *cannot* catch is a broken
`evaluate_health()` itself (then both loops' evaluators throw and `governor_state` freezes at
its last value); `cron.job_run_details` remains the external backstop for that.

Two corrections to the finding as filed. (1) `evaluate_health()` did **not** have a breaker
reading `tick_errors_last_day` — there was no such candidate; the only consumer was
`failure_taxonomy.decision`. This fix *adds* the missing breaker (the heartbeat); it does not
revive an existing one. (2) On the dead `tick_log.error` column: it stays **unwritten in-band
by design**. In-band recording would force `control_tick()` to swallow the error (rollback
erases any row written in the same txn), blinding pg_cron's own retry/alerting — a worse trade
than keeping the loop loud. So `tick_errors_last_day` remains a *latent out-of-band hook* (an
external recorder that fills `error` still lights the category), and `failure_taxonomy.decision`
now ORs it with the live `control_loop_lag` signal — the production path that was previously
undetectable. Regression test `pgfc_govern/tests/25_control_loop_lag.sql` proves a stalled
control loop with *fresh observation* escalates via `observe_tick()` (the prover — red pre-fix,
when `observe_tick` never evaluated health and `evaluate_health` had no control-lag signal),
plus the degraded/emergency ladder, the NULL-at-boot contract, and the no-flap-at-one-cadence
guard.

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

### FMEA-008 — `plan()` / `governor_status` divide by `policy.aggressiveness` with no guard

**Severity:** Low · **Confidence:** Confirmed · **Status:** Open ([#96](https://github.com/dventimisupabase/pg_flight_controller/issues/96))

`policy.aggressiveness` is `double precision NOT NULL DEFAULT 1.0` with **no `CHECK`**, so an
operator can `UPDATE pgfc_govern.policy SET aggressiveness = 0` at runtime. `plan()` derives the
class target as `f_template / v_aggr` (`:~762`) and the `governor_status` view divides by
`COALESCE(aggressiveness, …)` (`:1296`) — both unguarded. **Cause → effect:** `aggressiveness = 0`
→ division-by-zero. In `plan()` it aborts `control_tick()` (one transaction) → the control loop
wedges and makes no change; per FMEA-003 the stall is **detected** as `control_loop_lag` grows
(degraded → emergency). In `governor_status` it throws on read — so the operator's primary status
view fails exactly when they reach for it to explain the now-quiet governor (the sharper edge).
**Fail-safe:** yes, by *refusal* (no actuation), and already **advisorily flagged** —
`validate_parameters()` grades `aggressiveness <= 0` `CRITICAL` ("divide-by-zero / sign
inversion"). **Detection:** the heartbeat plus `validate_parameters`. **Recovery:** the operator
restores a positive value. (Negative values don't divide-by-zero — `GREATEST(…, sf_min)` clamps
them — but `validate_parameters` flags them for the sign inversion.)

**Disposition (filed — maintainer's call).** Not fixed in this pass: the design deliberately
chose *advisory* validation over enforcement, and reversing that is a decision for the
maintainer, not an FMEA-pass default. Candidate fixes — a `CHECK (aggressiveness > 0)` on
`policy` (reject at config time), or `NULLIF`/clamp guards in `plan()` and `governor_status`
(fail soft). `Low`: operator-reachable, self-inflicted, fail-safe, detected, advisorily warned.

### FMEA-009 — `observe_tick()` has no per-stage isolation; a decide-stage exception drops the snapshot

**Severity:** Low · **Confidence:** Confirmed · **Status:** Open ([#97](https://github.com/dventimisupabase/pg_flight_controller/issues/97))

`observe_tick()` runs `observe()` → `classify()` → `estimate()` in one transaction (`:1167-1169`).
FMEA-003 deliberately wrapped the *trailing* `evaluate_health()` in a subtransaction so a
health-eval hiccup can never lose the just-collected observation — but `classify()` and
`estimate()` run **unguarded**, before it, in the same transaction. **Cause → effect:** an
uncaught exception in either rolls back the whole tick, discarding the snapshot `observe()`
already wrote. Triggers are low-probability (the stages are guarded set-based math): the only
in-code one is `classify` dividing by zero when `classify_floor = 0` (a code-constant, default
50), plus any exception a future estimator/classifier adds. **Fail-safe:** yes — the lost
snapshot is **detected** as `observation_lag` grows (→ degraded/emergency) and there is no bad
actuation — but it is **inconsistent** with FMEA-003's snapshot-protection of the very same loop.

**Disposition (filed — maintainer's call).** A genuine design tension to weigh, not a clear
bug: snapshot+derived-estimate **atomicity** (a snapshot without its estimate is arguably
incomplete) versus **preserve-the-observation** (isolate `classify`/`estimate` in a
subtransaction like `evaluate_health`, re-deriving next tick). The observe-loop analog of
FMEA-005's per-relation apply-loop isolation. `Low`: fail-safe, detected, low-probability trigger.

## Traceability (Phase 2 contribution)

Failure modes attach to the invariants/mechanisms they stress (extends the Phase 1 spine):

| Invariant / mechanism | Stressed by | Disposition |
|---|---|---|
| Inv 1 — never wait on locks | FMEA-004 (maintenance DDL, no `lock_timeout`) | FMEA-004 **Verified** (#81); skip-under-contention → Phase 3 |
| Inv 4 — never exceed mutation budgets | crash mid-cycle | Cited-safe (single-txn atomicity) |
| Inv 6 — every action explainable | FMEA-003 (loop errors unrecorded), FMEA-005 (silent total denial) | FMEA-003/005 **Verified** (#84/#82) |
| F1 — self-monitoring metrics | FMEA-003 (`tick_errors_last_day` structurally 0; no control-loop heartbeat) | FMEA-003 **Verified** (#84) — `control_loop_lag` heartbeat, observe↔control mutual watchdog |
| F2 — health-state machine | worst-of under conflicting signals | Cited-safe |
| F6 — load shedding | FMEA-007 (lock wait precedes health eval) | Won't-fix |
| F7 — active-control activation | FMEA-002 (standby), FMEA-005 (poison relation), FMEA-006 (post-snapshot human race) | FMEA-002/005/006 **Verified** (#80/#82/#83) |
| F1 — self-monitoring / observation liveness | FMEA-009 (a `classify()`/`estimate()` exception discards the just-collected snapshot) | `Low`, filed ([#97](https://github.com/dventimisupabase/pg_flight_controller/issues/97)); fail-safe, detected via `observation_lag` |
| Parameter governance (P1–P3) — advisory vs. enforced | FMEA-008 (`plan()`/`governor_status` divide by `aggressiveness`; `≤ 0` wedges the loop + errors the view) | `Low`, filed ([#96](https://github.com/dventimisupabase/pg_flight_controller/issues/96)); `validate_parameters` flags `CRITICAL` (advisory) |

## Exit criteria

Per the charter — every enumerated mode dispositioned, all `Critical`/`High` modes
`Verified`/`Won't-fix`, spine contribution complete. **Status (first + second pass):**

- [x] **First pass:** the `apply()` / `control_tick()` path and the observe-storage
      path (crash, overlap, upgrade, partition rotation, standby, NULL fields, health worst-of,
      the lock/isolation/visibility findings) — each dispositioned cited-safe or as a finding.
- [x] **Second pass:** per-stage failure treatment of `estimate()` / `classify()` / `plan()` /
      `verify()` (all cited-safe — guarded, atomic single-statement upserts; `verify()` is a
      stub), and the environmental faults from the Method list (clock skew, crash-restart/
      recovery, privilege loss) — each dispositioned cited-safe, with two new `Low` findings
      (FMEA-008/009) filed.
- [x] No `Critical`/`High` modes found across **both** passes — the mutation path fails safe
      (single-txn atomicity) and the decide/orient stages and environmental faults fail safe by
      **refusal** (a stage exception aborts and is detected, never mis-actuates). The hard exit
      gate is met.
- [x] Findings filed: FMEA-001 ([#79](https://github.com/dventimisupabase/pg_flight_controller/issues/79)),
      002 ([#80](https://github.com/dventimisupabase/pg_flight_controller/issues/80)),
      003 ([#84](https://github.com/dventimisupabase/pg_flight_controller/issues/84)),
      004 ([#81](https://github.com/dventimisupabase/pg_flight_controller/issues/81)),
      005 ([#82](https://github.com/dventimisupabase/pg_flight_controller/issues/82)),
      006 ([#83](https://github.com/dventimisupabase/pg_flight_controller/issues/83)),
      008 ([#96](https://github.com/dventimisupabase/pg_flight_controller/issues/96)),
      009 ([#97](https://github.com/dventimisupabase/pg_flight_controller/issues/97));
      FMEA-007 Won't-fix.
- [x] The `Medium` findings reach `Fixed`/`Verified` (regression coverage shared with Phase 3):
      FMEA-001 (#79), 002 (#80), 003 (#84), 004 (#81), 005 (#82) all Verified; 006 (#83, `Low`)
      Verified; 007 Won't-fix. Every filed finding is now resolved.
