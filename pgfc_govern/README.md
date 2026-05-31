# pgfc_govern

Decide + Act for `pg_flight_controller` — the autovacuum governor's control loop. It
reads `pgfc_observe` (cross-schema, read-only), classifies each relation, estimates
its hidden maintenance state, and decides per-table autovacuum setpoints — moving
them toward per-class targets with minimal catalog mutation, and diagnosing (rather
than escalating) when an external inhibitor blocks progress.

Depends on **pgfc_observe** (install it first).

The governor is **advisory by default**, with active control a single policy flip away.
It ships in the
[v0.1.0 release](https://github.com/dventimisupabase/pg_flight_controller/releases/tag/v0.1.0)
— through Phase 1.7. For the concepts and the full guide set, see
[`docs/`](../docs/index.md).

## Advisory by default

Every policy ships with `advisory_only = true`: the loop runs `classify → estimate →
plan → verify` and writes a complete `decision_log` / `diagnostics` trail, but
`apply()` never fires — no `ALTER TABLE`, no setting is ever changed. Active control is
the supported `advisory_only = false` path (see
[Enabling active control](../docs/guide/operating.md#enabling-active-control)): it actuates
the scale-factor lever under the Phase 1.7 self-protection net — the health-state authority
gate, the Invariant-4 mutation budget, oscillation detection, and load shedding.

## Install

```sql
\i ../pgfc_observe/install.sql   -- dependency, first
\i install.sql                   -- re-runnable; also the upgrade path
```

Remove with `\i uninstall.sql` (`DROP SCHEMA ... CASCADE`); leaves pgfc_observe intact.

## Verify it works (advisory)

Run one fast loop and one control loop, then read what the governor *would* do —
with the default policy nothing is ever applied:

<!-- doctest -->

```sql
SELECT pgfc_govern.observe_tick();    -- observe + classify + estimate
SELECT pgfc_govern.control_tick();    -- plan + verify (advisory: apply() never fires)
SELECT relname, kind, decision, proposed_value
FROM pgfc_govern.governor_status
ORDER BY relname
LIMIT 5;
```

(A doctest — CI runs it against a fresh install on every PR.)

## What's here (Phase 1)

Functions: `observe_tick()` (observe + `classify` + `estimate`) and `control_tick()`
(`plan` + `apply`-if-not-advisory + `verify`), driven by pg_cron in production.
Core steps: `classify()`, `estimate()`, `plan()`, `apply()`, `verify()`, plus the
`removability`-aware diagnosis. Views: `governor_status`, `catalog_health`,
`active_diagnostics`, and `governor_metrics` (the Phase 1.7 F1 one-row
self-monitoring substrate). `retain()` prunes the append-only audit tables by time cutoff,
and `policy_history` records policy changes (kept indefinitely) — schedule `retain()`
daily with pg_cron alongside the loops.

Self-maintenance (S6): the audit/state tables carry **static** autovacuum reloptions,
`storage_budget()` reports per-relation bytes + dead tuples across **both** schemas,
and the one-row `self_health` view compares the whole-governor footprint to the
`storage_config.budget_bytes` cap (`over_budget`). `degrade()` enforces the cap by
shedding storage in a fixed order — raw → fine rollups → coarse rollups → diagnostics
→ actions — stopping once under budget; policy is never pruned, and with no cap
configured `degrade()` is a no-op.

Self-protection (Phase 1.7): `governor_metrics` (F1) is the one-row substrate
`evaluate_health()` (F2) reads to compute a health state
(`normal → degraded → diagnostic → emergency → disabled`) against born-governed
thresholds, writing the single-row `governor_state` and the `state_transitions` audit
each `control_tick()`. Operators retain ultimate authority (F3): `force_state()` /
`disable()` / `suspend_actuation()` force a more-cautious state and `clear_forced_state()`
releases it — a caution floor `evaluate_health()` honors by taking the worst of the
automatic and forced states (force more caution, never less). Advisory for now — the state
is recorded and surfaced but does not yet gate actuation (the `apply()` authority gate
consults it in a later increment).

### Deliberately deferred (so scope is explicit, not accidental)

- **Threshold lever and the analyze objective.** `plan()` moves the vacuum
  scale-factor lever only; the small-table threshold lever and the analyze-objective
  decision are follow-ups.
- **Actuation-economy gates** (per-relation / global / daily rate limits,
  sustained-deviation) — Phase 2, when `apply()` is enabled in earnest.
- **`verify()`** is a no-op in Phase 1 (nothing is applied to attribute); Phase 2
  expands it.
- **`apply()`** is implemented (single-actuator, with live no-op, ownership,
  baseline capture, 100 ms non-blocking lock, failure recording) but only ever runs
  when `advisory_only = false`.

### Activation hazards (addressed in Phase 1.7 F7)

Both were closed when active control went live; recorded here as the contract actuation
now depends on.

- **Loop ordering contract.** `control_tick()` plans against the newest snapshot whose
  `estimate()` phase has completed (`max(snapshot_id)` from `relation_estimate`), not the
  newest *observed* snapshot. The advisory lock serializes `control_tick()` against itself
  but **not** against `observe_tick()`; selecting the estimated snapshot keeps the estimates
  and the observed state `plan()` reads on the same snapshot even on independent cron
  schedules, so actuation never pairs fresh observations with stale hidden state.
- **`apply()` stale-window downgrade.** `apply()` re-reads live `pg_class.reloptions` and is
  the authoritative arbiter: it downgrades `adjust → no-op` (silently, not a failure) when a
  human changed the value to the proposal between observe and apply. Covered by
  `tests/19_activation.sql`.

## Tests

From the project root (installs both extensions, runs both suites):

```bash
./test.sh 17        # one version (fast)
./test.sh           # full matrix: PG 15, 16, 17, 18
```
