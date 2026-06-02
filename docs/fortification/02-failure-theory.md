# Phase 2 — Failure theory (FMEA)

**Status:** Not started (stub — fleshed out when Phase 1 closes). One finding
(**FMEA-001**) was recorded early, from the cooling-off deep read of the storage docs,
ahead of the formal phase.

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
- **Within-cycle human-`ALTER` race** (carried from Phase 1 Concurrency): a human value set
  between `plan()` and `apply()` that *differs* from the proposal is overwritten this cycle —
  `apply()`'s no-op arbiter only catches the exact-match case, and it re-checks neither
  `actuator_state` nor `manage_user_owned`. Narrow (sub-second; COR-001 heals it next cycle);
  enumerate cause → effect → fail-safe? → detection → recovery here.

## Findings

| ID | Sev | Conf | Evidence | Summary | Status | Link |
|---|---|---|---|---|---|---|
| FMEA-001 | Medium | Confirmed | `pgfc_observe/install.sql:581,1367,1393` | Observe partitions are recycled by create-on-demand + drop-empty (calendar `RANGE`), not a fixed `TRUNCATE`-rotated ring — routine catalog DDL where the lineage's ring has none. | Triaged | — (issue on disposition) |

### FMEA-001 — partition recycling uses create/drop, not a fixed `TRUNCATE` ring

**What.** `pgfc_observe` bounds its high-volume telemetry (`relation_samples`,
`snapshots`) with daily `RANGE` partitions: `_ensure_partition()` issues
`CREATE TABLE … PARTITION OF` for each new day (`pgfc_observe/install.sql:581`),
`retain()` `TRUNCATE`s expired daily partitions (`:1367`), and
`drop_empty_partitions()` `DROP`s long-empty shells (`:1393`). The `TRUNCATE` eliminates
*row* bloat, but the routine `CREATE`/`DROP` churns the system catalogs (`pg_class`,
`pg_attribute`, `pg_inherits`, `pg_depend`, `pg_type`) — reintroducing *catalog* bloat in
a system whose stated goal is "zero bloat by construction." It fights bloat with bloat at
the catalog layer.

**The lineage solved this differently.** `pg_flight_recorder` — the direct ancestor of
this storage model — recycles its high-volume sample tables with a **fixed ring**:
`rotate_ring()` keeps `num_slots` (default 3, min 3) `LIST`-partitioned slots created
**once at install**, and rotation merely advances a pointer and `TRUNCATE`s the slot
rolling off ("zero bloat, no dead tuples, no GC needed"; its `BENCH_RING.md` measures 0
dead tuples). No `CREATE`, no `DROP` in steady state → zero catalog churn. The three-slot
arrangement is the classic Skytools PGQ / PgQue pattern: one slot being written, one
draining/readable, one being recycled.

**Why the divergence happened.** The storage design deliberately skipped a ring, on the
recorded grounds that a fixed-slot ring is an *in-memory* technique for *sub-second*
sampling. That does not match the recorder's actual ring, which is **on-disk**
`LIST`-partitioned tables sampled **every minute** and rotated every 2h — exactly this
project's cadence. The rejection answered a sampling-frequency concern; the relevant
concern is catalog churn, which the ring removes and calendar partitioning does not.

**Magnitude — do not over-weight.** The churn is modest (roughly one `CREATE`/day per
high-volume parent plus occasional `DROP`), and the resulting catalog dead tuples are
backstopped by autovacuum on the catalogs. This is a **principle-and-lineage**
inconsistency, not an incident: `Medium`, no safety consequence.

**Genuinely different for this project (weigh before adopting the ring):**

- **Read path.** Readers (`current_relation_state`, `maintenance_debt`, `rollup`) query by
  time / `snapshot_id` and lean on `RANGE` pruning; a `LIST`-by-slot ring needs slot-aware
  reader views (the recorder has these). This is the main porting cost.
- **Sparse carry-forward across a truncation boundary.** The "last known sample" a quiet
  relation relies on must survive a slot `TRUNCATE` — via `relation_last_state` and/or
  draining rollups first (this project already rolls up before raw truncation).
- **Global `snapshot_id` monotonicity.** Cross-table references assume a monotone global
  id; a ring would `TRUNCATE` data but must **not** reset that sequence (the recorder
  resets per-slot sequences — this project cannot).
- **Retention quantization.** A ring's window is `(slots − 1) × rotation_period`, not an
  arbitrary day cutoff.

**Recommendation — disposition pending (three options):**

- **(a) Adopt the ring** for `relation_samples`/`snapshots`: fixed `LIST`-by-slot
  partitions, `rotate_ring`-style `TRUNCATE`+advance, slot-aware readers. Closes the
  catalog churn; highest porting cost.
- **(b) Hybrid** — ring for the high-volume raw tables, keep calendar `RANGE` partitions
  for the lower-volume rollups where create/drop is rare.
- **(c) Keep calendar partitioning** and explicitly document the accepted catalog-churn
  cost as a conscious trade-off (cheapest; leaves the inconsistency in place).

When an option is chosen, file a `fortification` issue and move this finding to
`Accepted`.

## Exit criteria

Per the charter — every enumerated mode dispositioned, all `Critical`/`High` modes
`Verified`/`Won't-fix`, spine contribution complete.
