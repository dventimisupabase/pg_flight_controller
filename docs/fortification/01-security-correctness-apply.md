# Phase 1 — Security + correctness of the `apply()` path

**Status:** Not started · **Lead surface:** the actuation chain
`control_tick() → plan() → apply()` in `pgfc_govern/install.sql`.

The only place the system mutates the catalog. Everything else observes, estimates,
decides, or reports — `apply()` is where a decision becomes an `ALTER TABLE`. This phase
reviews that path for **security** (can it be made to do something it shouldn't) and
**correctness** (does it do exactly what it's meant to, and nothing else, on every
branch). It also sets the template for phases 2–4.

## Method

- Read the path end to end against the two checklists below; for each item, either record
  a cited reason it is safe/correct or open a finding (charter
  [finding schema](00-framework.md#finding-schema)).
- Run the `/security-review` skill against the path and reconcile its output into the
  Findings table (dedup, assign severity per the project rubric).
- Adversarial pass: for each gate/guard, ask "what input or interleaving defeats this?"
  — crafted `decision_log`/`action_history` rows, concurrent human `ALTER TABLE`,
  `observe_tick` interleaving, privilege/ownership edges, upgrade state.
- Seed the [traceability spine](00-framework.md#traceability-spine) rows for the
  invariants this path is responsible for (1, 3, 4, 6).

## Inventory — the `apply()` path, stage by stage

The caller and the actuator, in execution order. (Line numbers are captured per finding
at review time; stages are named so they survive edits.) All in
`pgfc_govern/install.sql` unless noted.

Stages 1–6 are the caller (`control_tick()`); stages 7–17 are the actuator
(`apply(p_tick_id, p_relid)`).

1. **Caller `control_tick()` —** advisory xact lock
   `pg_advisory_xact_lock(hashtext('pgfc_govern.control_tick'))` serializes control
   cycles against each other.
2. `evaluate_health()` runs first — the health state `apply()` will consult is computed
   this cycle.
3. `advisory_only` resolved from the active policy, COALESCE registry default — the
   dry-run gate; `apply()` is only invoked when `false`.
4. Snapshot selection: newest **estimated** snapshot (`max(snapshot_id)` from
   `relation_estimate`) — the loop-ordering contract (F7).
5. `plan(v_tick, v_snap)` writes the per-relation `decision_log` rows.
6. Loop over `decision = 'adjust'` decisions, calling `apply(v_tick, relid)`.
7. **Actuator `apply()` —** decision lookup from `decision_log` (latest for
   tick/relid/actuator); require `decision = 'adjust'`, else `false`.
8. **Authority gate** — `governor_state.state IN ('diagnostic','emergency','disabled')`
   → `false`, silently (not recorded as failed).
9. Relation existence — `pg_class` lookup; `relname IS NULL` → `false`.
10. Vacuum-in-progress — `pg_stat_progress_vacuum` has the relid → `false`.
11. **No-op / stale-window arbiter** — re-read live `reloptions` via
    `effective_reloption`; if it already equals the proposal → `false`.
12. **Invariant-4 budget** (values from active policy COALESCE registry): per-relation
    `min_interval` (a recent applied row blocks), per-cycle
    `global_max_changes_per_cycle` (applied rows joined to this tick), and per-day
    `daily_mutation_budget` (`governor_metrics.applied_actions_last_day`).
13. Baseline capture — read/derive `actuator_state` baseline; never overwrite on a
    later touch.
14. `batch_seq` nextval.
15. **The mutation** — `set_config('lock_timeout', _param('lock_timeout')||'ms', true)`
    then `EXECUTE format('ALTER TABLE %s SET (%I = %s)', p_relid::regclass, v_act,
    v_prop)`.
16. Exception handlers — `lock_not_available` and `insufficient_privilege` each record a
    `failed` `action_history` row (with `failure_class`) and return `false`.
17. Success — insert/update `actuator_state`, insert `applied` `action_history` (with
    `revert_kind`/`revert_value`), set `decision_log.applied = true`, return `true`.

## Security checklist

- [ ] **Dynamic SQL — the `ALTER TABLE`.** `%s` for `p_relid::regclass`, `%I` for the
      actuator name, `%s` for `v_prop`. Confirm each renders un-injectable: relid via
      `regclass` (not text), actuator is a literal constant but `%I`-quoted anyway, and
      **`v_prop` provenance** — trace `decision_log.proposed_value` back through `plan()`
      / `snap_sf()` / the SF grid and confirm it can only be a bounded numeric string,
      even if a row were hand-inserted.
- [ ] **Dynamic SQL — `set_config('lock_timeout', …)`.** Confirm `_param('lock_timeout')`
      is registry-sourced and numeric-bounded; it is concatenated, not parameterized.
- [ ] **Privilege model.** What role executes the loop, and what does `apply()`'s
      `ALTER TABLE` require? Document the intended role and least privilege.
- [ ] **`SECURITY DEFINER` exposure.** Are any path functions `SECURITY DEFINER`? If so,
      are they `search_path`-pinned and arg-validated? If not, the caller needs `ALTER`
      rights — document that.
- [ ] **`search_path` safety.** Are all object references schema-qualified
      (`pgfc_govern.` / `pgfc_observe.` / `pg_catalog`), so behavior doesn't depend on
      the caller's `search_path`? Note any bare references.
- [ ] **Ownership guard.** `manage_user_owned` is honored in `plan()` (decision
      `suppressed:user_owned`), not in `apply()`. Confirm `apply()` cannot act on a
      user-owned setting via a stale/crafted decision — i.e. the guard is not bypassable
      by reaching `apply()` directly.
- [ ] **Audit integrity.** Can `action_history` be made to misrepresent what happened
      (e.g. a refusal recorded as applied, or vice versa)?

## Correctness checklist

- [ ] **Gate ordering.** Authority gate → existence → vacuum-progress → no-op → budget →
      mutate. Confirm a withheld/no-op action consumes **no** budget, and that refusals
      that must be silent are silent (no `failed` row feeding the breaker).
- [ ] **Budget arithmetic & windows.** `>=` vs `>` on each tier; the per-cycle join is
      scoped to `p_tick_id`; the per-day window matches `governor_metrics`'
      definition; concurrent ticks can't race the cap (advisory lock holds for
      `control_tick`, but direct `apply()` calls bypass it).
- [ ] **Baseline / rollback integrity.** Baseline captured on first touch and never
      overwritten; `revert_kind` (`SET`/`RESET`) and `revert_value` reconstruct the
      pre-governor state exactly; `ON CONFLICT` update path preserves the baseline.
- [ ] **Exception completeness.** Only `lock_not_available` and `insufficient_privilege`
      are caught. Confirm no other `ALTER TABLE` failure mode is plausible-and-unhandled
      (an uncaught error aborts the surrounding `control_tick` txn — is that acceptable,
      and does it roll back the tick cleanly?).
- [ ] **No-op / stale-window.** The live re-read correctly downgrades `adjust → no-op`
      when the value changed between observe and apply (covered by
      `19_activation.sql` — confirm it's the same code path and not a parallel one).
- [ ] **Concurrency.** `control_tick` is serialized vs itself by the advisory lock, and
      the loop-ordering (F7) and stale-window arbiter address `observe_tick` and human
      `ALTER` races. Confirm there is no *remaining* interleaving (e.g. two sessions
      calling `apply()` directly, or `apply()` vs `degrade()`/`retain()`) that breaks the
      budget or the baseline.
- [ ] **Idempotency / re-entrancy.** Re-invoking the same decision (retry, replay) does
      not double-apply, double-count budget, or corrupt `actuator_state`.

## Findings

| ID | Sev | Conf | Evidence | Summary | Status | Link |
|---|---|---|---|---|---|---|
| COR-001 | High | Confirmed | `pgfc_govern/install.sql:713`, `:750`, `:694-705` | The ownership guard cannot tell the governor's own prior actuation from a human's setting, so continuous control and "never overwrite a human's setting" are mutually exclusive. | Accepted | [#66](https://github.com/dventimisupabase/pg_flight_controller/issues/66) |

<!-- Prose for each finding goes here, keyed by ID. -->

### COR-001 — The ownership guard conflates "set by the governor" with "set by a user"

**Severity:** High · **Confidence:** Confirmed · **Status:** Accepted

**What the system promises.** RFC §2.4 lists "an ownership guard — never overwrite a
human's or another system's setting" as one of the gates that keep actuation safe, and the
`policy.manage_user_owned` column comment states the contract precisely
(`pgfc_govern/install.sql:84`):

> `false: never overwrite a reloption set by a user/other system **first**; true: take ownership.`

The word *first* is a temporal claim: the guard is meant to protect a setting that
pre-existed the governor's involvement.

**What the code does.** The guard is evaluated in `plan()`. The "is this user-owned?"
signal is computed live from the relation's current reloptions, with no reference to who
set them (`pgfc_govern/install.sql:713`):

```sql
(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_scale_factor') IS NOT NULL)
    AS sf_user_set
```

and drives the suppression branch (`pgfc_govern/install.sql:750`):

```sql
WHEN NOT v_manage AND sf_user_set THEN 'suppressed:user_owned'
```

`plan()`'s source CTE joins `relation_class`, `relation_estimate`,
`current_relation_state`, and `snapshots` (`pgfc_govern/install.sql:694-705`) — it never
joins `actuator_state`, so it has no knowledge of what the governor itself previously set.
`sf_user_set` therefore means only "an explicit scale-factor reloption exists right now,"
not "a user set it." But the governor's own actuation sets exactly that reloption
(`pgfc_govern/install.sql:997`, `ALTER TABLE … SET (autovacuum_vacuum_scale_factor = …)`).

**The consequence.** Once the governor actuates a relation a single time, `sf_user_set`
becomes true for that relation permanently, and with the default policy
(`manage_user_owned = false`) every subsequent cycle resolves to
`suppressed:user_owned` — the governor suppresses its *own* prior change as though a human
had made it. So:

- With `manage_user_owned = false` (the default), active control degrades to **at most one
  actuation per relation, ever** — not the continuous, self-stabilizing loop the abstract
  (§1) sells.
- The only way to restore continuous control is `manage_user_owned = true`, which by the
  same column comment "lets the governor overwrite user/other-system reloptions" — i.e. it
  turns the human-protection guard *off*, and the governor will then clobber a human's
  manual `ALTER TABLE` made after first touch.

The two stated properties — keep the database self-stabilizing (§1) and never overwrite a
human's setting (§2.4) — are **mutually exclusive in the shipped code.** This is latent
under the shipped default only because `advisory_only = true` keeps `apply()` from firing;
it becomes load-bearing the instant active control is enabled, which is precisely the
regime fortification exists to harden.

**Why it is fixable cleanly.** The signal the contract needs already exists.
`actuator_state.baseline_explicit` (`pgfc_govern/install.sql:176`) records whether the
relation carried the reloption *before* the governor's first touch — that is the literal
"set by a user first" fact the guard should test. The defect is that `plan()` consults the
cruder live `sf_user_set` instead. A correct guard suppresses only when the setting is
explicit **and** the governor did not set it — roughly: there is no `actuator_state` row
for the relation, or its `baseline_explicit` is true.

**Recommendation.** In `plan()`, cross-check `sf_user_set` against `actuator_state` so the
governor recognizes its own prior actuations and only treats a setting as user-owned when
the baseline shows it pre-existed (or no governor baseline exists). Add a regression test
asserting that a relation the governor itself set is *not* classified `suppressed:user_owned`
on the following cycle, and that a post-touch human change *is* protected when
`manage_user_owned = false`.

**Relationship to the checklists.** Distinct from the Security-checklist "Ownership guard"
item above, which asks whether `apply()` can be reached directly to *bypass* the guard.
COR-001 is a correctness defect in the guard's own logic in `plan()`: the guard misfires
even when reached normally.

## Traceability (seed)

The `apply()` path is the enforcement point for these invariants; this phase confirms
each holds in code and is backed by a test. (Filled during the review.)

| Invariant / mechanism | Enforced at | Test | Findings |
|---|---|---|---|
| Inv 1 — never wait on locks | `apply()` stage 15 (`lock_timeout`, non-blocking) | *tbd* | |
| Inv 3 — never reduce freeze safety | `plan()` freeze floor (refusal to tighten is safe) | *tbd* | |
| Inv 4 — never exceed mutation budgets | `apply()` stage 12 (three tiers) | `16_authority_gate` | |
| Inv 6 — every action explainable | `apply()` audit writes (stages 16–17) | *tbd* | |
| F4 — authority gate | `apply()` stage 8 | `16_authority_gate` | |

## Exit criteria

Per the charter, plus specific to this phase:

- Both checklists fully dispositioned (cited-safe or finding).
- `/security-review` output reconciled into the Findings table.
- The traceability seed above completed for the `apply()` path.
- All `Critical`/`High` findings `Verified` or `Won't-fix` (with rationale).
