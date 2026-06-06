# Phase 3 — Workload fixtures

**Status:** Complete · **Purpose:** a representative schema and write-mix signature for
each of pgfc's six workload classes, each with a stationary and a drift variant, grounded
in the classifier's actual predicates so each table verifiably lands in its intended class.

## Classifier predicates (single source of truth)

Every fixture is derived from `classify()`'s actual CASE tree
(`pgfc_govern/install.sql`, the `cls` CTE) and the registry defaults. The predicates,
in evaluation order:

| Class | Predicate | Registry parameters |
|---|---|---|
| `append_only` | `din/total > 0.95 AND ddel/total < 0.01` | `classify_append_only_ins_frac = 0.95`, `classify_append_only_del_frac = 0.01` |
| `queue` | `ddel/total > 0.30 AND abs(ddel/total - din/total) < 0.10` | `classify_delete_frac = 0.30`, `classify_queue_balance_frac = 0.10` |
| `delete_heavy` | `ddel/total > 0.30` (and not balanced → not queue) | `classify_delete_frac = 0.30` |
| `oltp` | `dupd/total > 0.30` (and ddel ≤ 0.30, since delete branches precede) | `classify_delete_frac = 0.30` (reused as the update threshold) |
| `mixed` | None of the above (the ELSE branch) | — |
| `archive` | `total < classify_floor` (rule\_kind is NULL) AND `reltuples > classify_large` | `classify_floor = 50`, `classify_large = 100000` |

Where `din`, `dupd`, `ddel` are `GREATEST(cur - prev, 0)` cumulative-counter deltas
between snapshots, and `total = din + dupd + ddel`.

**Critical constraints** learned from the spot-check:

- **Signal floor (50).** Every active fixture must produce `total > 50` per sample
  window, or it won't classify on fractions — it falls through to mixed/archive.
- **Stats flush.** `observe()` reads `pg_stat_user_tables` at call time; the stats
  collector updates asynchronously. The driver must flush stats
  (`pg_stat_force_next_flush()` on PG 16+, or a brief `pg_sleep` on PG 15) between
  writes and observation, or cumulative counters read as stale zeros.
- **ANALYZE before first snapshot.** `classify()` reads `reltuples` from the snapshot
  (not live `pg_class`). A table loaded but never analyzed has `reltuples = -1`, so the
  `archive` classification (`reltuples > 100000`) fails. Run `ANALYZE` on preloaded
  tables before the baseline snapshot.
- **Hysteresis (n\_sustain = 3).** A class change commits only after 3 consecutive
  cycles with the same candidate. The classification assertion must run after ≥ 3
  sustained cycles (but a *new* table with no prior class adopts immediately — no
  hysteresis on first touch).

## Fixtures

### append\_only

**Schema.** A wide-ish event/log table — the shape that only grows:

```
CREATE TABLE fix_append (
    id       bigint GENERATED ALWAYS AS IDENTITY,
    ts       timestamptz NOT NULL DEFAULT now(),
    payload  text
);
CREATE INDEX ON fix_append (ts);
```

**Stationary driver.** Pure inserts, no updates or deletes:

- Per cycle: 200 `INSERT` (din=200, dupd=0, ddel=0, total=200).
- din/total = 1.0 > 0.95 ✓; ddel/total = 0.0 < 0.01 ✓ → `append_only`.

**Drift variant — growth-at-constant-mix (scale drift, RUBRIC-001).** Same write mix
but the table grows from 1M to 100M+ rows over the run. The fractional target (0.40)
stays "healthy" while the absolute dead-tuple count and space grow to test the
proxy-outcome gap.

**Classification assertion.** `kind = 'append_only'` after the first classify cycle
(new table, adopted immediately).

### queue

**Schema.** A narrow job/message table — balanced insert + delete churn:

```
CREATE TABLE fix_queue (
    id       bigint GENERATED ALWAYS AS IDENTITY,
    status   text NOT NULL DEFAULT 'pending',
    payload  jsonb
);
```

**Stationary driver.** Balanced insert + delete (the queue pattern):

- Per cycle: 100 `INSERT`, 95 `DELETE` (din=100, dupd=0, ddel=95, total=195).
- ddel/total = 0.487 > 0.30 ✓; |ddel/total - din/total| = 0.025 < 0.10 ✓ → `queue`.

**Drift variant — rate shift.** Queue throughput doubles mid-run (200 ins / 190 del
per cycle). The class stays `queue` but the effective trigger point and bloat behavior
change; a `t0`-tuned scale factor may lag.

**Classification assertion.** `kind = 'queue'` after first cycle.

### delete\_heavy

**Schema.** A session/temp-data table — high delete rate, unbalanced:

```
CREATE TABLE fix_delheavy (
    id       bigint GENERATED ALWAYS AS IDENTITY,
    user_id  int,
    data     text,
    expires  timestamptz
);
CREATE INDEX ON fix_delheavy (expires);
```

**Stationary driver.** Skewed: many deletes, few replenishing inserts. Requires a
preloaded pool of rows to delete from sustainably:

- Preload: 5000 rows. Per cycle: 30 `INSERT`, 150 `DELETE` (din=30, dupd=0, ddel=150,
  total=180).
- ddel/total = 0.83 > 0.30 ✓; |ddel/total - din/total| = 0.67 > 0.10 (not balanced)
  → `delete_heavy`.

The **sustainability constraint** (FIX-001): an unbalanced high-delete workload that
doesn't drain the table to empty requires either a preloaded pool that lasts the run
or periodic batch refills. See finding below.

**Drift variant — class transition (delete\_heavy → oltp).** The purge job stops and
the workload shifts to update-heavy: 0 deletes, 100 updates per cycle → dupd/total >
0.30 → `oltp`. This is a true class transition that tests whether pgfc tracks the
shift and adjusts the target.

**Classification assertion.** `kind = 'delete_heavy'` after first cycle; `kind =
'oltp'` after 3 sustained cycles of the shifted workload.

### oltp

**Schema.** A typical transactional table — update-heavy:

```
CREATE TABLE fix_oltp (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    balance  numeric NOT NULL DEFAULT 0,
    updated  timestamptz NOT NULL DEFAULT now()
);
```

**Stationary driver.** Update-dominant, low insert/delete:

- Preload: 10000 rows. Per cycle: 10 `INSERT`, 150 `UPDATE` (random id), 5 `DELETE`
  (din=10, dupd=150, ddel=5, total=165).
- ddel/total = 0.03 (< 0.30, not delete-heavy); dupd/total = 0.91 > 0.30 ✓ → `oltp`.

**Drift variant — write amplification.** Update rate triples (450 updates/cycle) while
the table stays the same size — a scale-factor that was correct at 150 upd/cycle may
accumulate dead tuples too fast at 450.

**Classification assertion.** `kind = 'oltp'` after first cycle.

### mixed

**Schema.** A general-purpose table — no single operation dominates:

```
CREATE TABLE fix_mixed (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category text,
    value    numeric,
    note     text
);
```

**Stationary driver.** Balanced across all three operations:

- Preload: 5000 rows. Per cycle: 40 `INSERT`, 40 `UPDATE`, 20 `DELETE` (din=40,
  dupd=40, ddel=20, total=100).
- din/total = 0.40 (< 0.95); ddel/total = 0.20 (< 0.30); dupd/total = 0.40 (but
  ddel check comes first and fails, so oltp branch is not reached... actually
  dupd/total = 0.40 > 0.30, but ddel/total = 0.20 < 0.30 so the delete branches
  don't fire). Wait — dupd/total = 0.40 > 0.30 → `oltp`, not `mixed`.

Corrected mix: 30 `INSERT`, 25 `UPDATE`, 20 `DELETE` (total=75).

- din/total = 0.40 (< 0.95); ddel/total = 0.27 (< 0.30); dupd/total = 0.33 > 0.30
  → `oltp`. Still not mixed.

Corrected: 40 `INSERT`, 20 `UPDATE`, 15 `DELETE` (total=75).

- din/total = 0.53 (< 0.95); ddel/total = 0.20 (< 0.30); dupd/total = 0.27 (< 0.30)
  → ELSE → `mixed` ✓.

**Drift variant — workload shift (mixed → queue).** Delete rate climbs and insert rate
matches it: 50 ins, 20 upd, 45 del (total=115). ddel/total = 0.39 > 0.30 ✓;
|0.39 - 0.43| = 0.04 < 0.10 ✓ → `queue`. Tests the class transition from a general
workload to a queue pattern.

**Classification assertion.** `kind = 'mixed'` after first cycle.

### archive

**Schema.** A large reference/lookup table — rarely written:

```
CREATE TABLE fix_archive (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code     text NOT NULL,
    label    text
);
```

**Stationary driver.** Silence — no writes after the initial load:

- Preload: 200000 rows. `ANALYZE fix_archive` before the baseline snapshot (so
  `reltuples` reads 200000, not -1).
- Per cycle: 0 writes (total=0 < 50 → rule\_kind is NULL; reltuples > 100000 →
  `archive`).

**Drift variant — periodic purge.** A quarterly cleanup deletes 10% of rows and
reloads them (batch insert + batch delete). During the purge window the table briefly
classifies as `delete_heavy` or `queue`, then returns to `archive` once idle. Tests
the hysteresis — does the system avoid thrashing between classes on a transient burst?

**Classification assertion.** `kind = 'archive'` after first cycle (new + idle +
reltuples > 100k). Requires `ANALYZE` before the baseline snapshot.

## PROB-001 overlay (deferred to Phase 4)

[PROB-001](01-problem-and-value.md#prob-001--the-lever-movable-population-may-be-a-minority)
requires fixtures covering inhibitor-bound and I/O-limited tables. These are
`estimate()`'s `saturation_cause` states, orthogonal to `classify()`'s workload class —
any class can be inhibited. They are best modeled as a **Phase 4 scenario overlay**: take
a classified fixture and layer on a long-running transaction (pinning the xmin horizon)
or I/O throttling. Forward-referenced here; specified in Phase 4.

## Findings

| ID | Statement | Evidence | Confidence | Bearing on verdict | Status | Link |
|---|---|---|---|---|---|---|
| FIX-001 | A sustainable `delete_heavy` fixture is genuinely awkward — an unbalanced high-delete workload drains toward empty unless periodically refilled, and the refill batch can temporarily misclassify the table | Spot-check: a pure del-heavy driver without preload empties the table; periodic batch inserts spike din/total and may trigger `append_only` for a cycle | Strong | Qualifies — the delete\_heavy drift variant and the preloaded pool design must account for the sustainability constraint; the Phase 5 driver needs periodic batch refills sized to stay below the append\_only threshold | Open | — |

## Exit criteria

- [x] Each prioritized class has a schema, a stationary driver, and a drift variant.
- [x] Each fixture verifiably classifies as its intended class (predicate arithmetic
  checked; queue vs delete\_heavy and archive spot-checked against the real classifier
  in Docker).
- [x] Drivers are reproducible (seeded, parameterized — exact per-cycle counts stated).
