# Phase 1 — Security + correctness of the `apply()` path

**Status:** Complete · **Lead surface:** the actuation chain
`control_tick() → plan() → apply()` in `pgfc_govern/install.sql`.

> **Closed.** Both checklists are dispositioned (each item cited-safe or attached to a
> finding); the four findings are resolved — **COR-001** (High) and **SEC-001** / **SEC-002**
> (Low) are *Verified* with regression tests, **COR-002** (Low) is *Won't-fix (by-design,
> documented)*; the traceability spine is filled for the `apply()` path, with one test-coverage
> gap (the live lock-timeout path) carried forward to Phase 3. Exit criteria met (see end).

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

- [x] **Dynamic SQL — the `ALTER TABLE`.** `%s` for `p_relid::regclass`, `%I` for the
      actuator name, `%s` for `v_prop`.
      **Disposition:** cited-safe + **SEC-002**. `p_relid::regclass` renders catalog
      output, not attacker text; the actuator is a literal constant, `%I`-quoted anyway;
      `v_prop` provenance is hardened by SEC-002 — `apply()` parses it to a number,
      range-checks `[sf_min, sf_max]`, and splices only the *validated* text. Verified by
      `21_value_validation`.
- [x] **Dynamic SQL — `set_config('lock_timeout', …)`.**
      **Disposition:** cited-safe. `_param('lock_timeout')` reads a single typed registry
      row (`pgfc_govern/install.sql:1524`, a `safety_bound` defaulting to `100`), never
      caller input; it is concatenated with `'ms'`, not attacker-controlled.
- [x] **Privilege model.**
      **Disposition:** **SEC-001** (Verified). The cron role/least-privilege model is
      documented in the operating guide ("Which role runs the loop").
- [x] **`SECURITY DEFINER` exposure.**
      **Disposition:** cited-safe + **SEC-001**. No path function is `SECURITY DEFINER`
      (all `SECURITY INVOKER`); every plpgsql function now pins an explicit `search_path`
      as defense-in-depth ahead of any future `SECURITY DEFINER` posture. `22_search_path`.
- [x] **`search_path` safety.**
      **Disposition:** **SEC-001** (Verified). All object references are schema-qualified;
      the plpgsql functions pin an explicit `search_path`, and `22_search_path` drives the
      whole path under an empty caller `search_path` to prove caller-independence.
- [x] **Ownership guard (bypass).** `manage_user_owned` is honored in `plan()`, not in
      `apply()`.
      **Disposition:** cited-safe under the trust model (distinct from **COR-001**, which
      is the guard's own logic in `plan()`). `apply()` acts only on a `decision = 'adjust'`
      row and re-checks neither `actuator_state` nor `manage_user_owned`, so the ownership
      guard *is* a `plan()`-layer policy; reaching `apply()` with a crafted `adjust` row for
      a user-owned relation would bypass it — but that requires write access to
      `decision_log` (a caller who could `ALTER` the table directly), the same boundary as
      SEC-002, and **COR-002** records `control_tick()` as the sole sanctioned entrypoint.
      Not a separate finding. (The related human-`ALTER` race — where `apply()` overwrites a
      human value set after the planning snapshot — is treated under **Concurrency** below and
      is now closed at the actuation point by FMEA-006, [#83](https://github.com/dventimisupabase/pg_flight_controller/issues/83).)
- [x] **Audit integrity.**
      **Disposition:** cited-safe. `action_history` is written only on the real outcome —
      `applied` on success (stage 17), `failed` only inside the `lock_not_available` /
      `insufficient_privilege` handlers; every pre-mutation refusal returns `false` without
      writing a row (verified `16_authority_gate`, `21_value_validation`). `status` and
      `failure_class` CHECKs pin the vocabulary; no path records a refusal as `applied` or a
      success as `failed`.

## Correctness checklist

- [x] **Gate ordering.** Authority → existence → vacuum-progress → no-op → value
      validation → budget → mutate.
      **Disposition:** cited-safe, tested. Each gate returns `false` *before* the budget
      tiers, so a withheld or no-op action consumes no budget; all of them are silent (no
      `failed` row). `16_authority_gate` (authority/budget silent), `21_value_validation`
      (validation silent), `19_activation` (no-op silent).
- [x] **Budget arithmetic & windows.**
      **Disposition:** cited-safe + **COR-002**. Per-relation rate limit via `EXISTS` on a
      recent `applied` row; per-cycle (`>=`) join scoped to `p_tick_id`; per-day (`>=`)
      from `governor_metrics.applied_actions_last_day`. All three tiers exercised by
      `16_authority_gate`. A direct out-of-cycle `apply()` bypasses `control_tick`'s
      advisory lock → **COR-002** (by-design; the live budget checks still bound the blast
      radius).
- [x] **Baseline / rollback integrity.**
      **Disposition:** cited-safe, tested. Baseline captured on first touch (the `NOT FOUND`
      branch); the `ON CONFLICT` update touches only `current_value` / `set_at_snapshot` /
      `av_count_at_apply`, never `baseline_explicit` / `baseline_value`; `revert_kind`
      (`SET`/`RESET`) and `revert_value` derive from `baseline_explicit`. `05_loop`
      (no-explicit-baseline ⇒ RESET).
- [x] **Exception completeness.**
      **Disposition:** cited-safe, with a Phase-3 note. Only `lock_not_available` and
      `insufficient_privilege` are caught; each records a `failed` row and returns `false`.
      SEC-002 closes the one realistic other path (a bad value is refused *before* the
      `EXECUTE`). A residual `ALTER` error (a value `float8in` accepts but the reloption
      parser rejects) aborts and **cleanly rolls back** the `control_tick` txn — fail-closed,
      and reachable only by a `decision_log` tamper (same boundary as SEC-002). The live
      lock-timeout exception path is exercised only via *seeded* failure rows (`13`, `18`),
      not an end-to-end lock contention → **Phase 3 coverage gap** (see traceability).
- [x] **No-op / stale-window.**
      **Disposition:** cited-safe, tested. The single live re-read
      (`effective_reloption(v_live, …)`) is the sole arbiter and downgrades `adjust → no-op`
      when the live value already equals the proposal — the same code path, covered by
      `19_activation`.
- [x] **Concurrency.**
      **Disposition:** cited-safe + **COR-002** + **FMEA-006** (closed). `control_tick` is
      serialized against itself by `pg_advisory_xact_lock`; loop-ordering (F7) addresses the
      `observe_tick` race. The no-op re-read catches a human-`ALTER` race **only when the human
      set exactly the proposal**; a human value set after the planning snapshot that *differs*
      from the proposal was originally overwritten that cycle — now closed by **FMEA-006**
      ([#83](https://github.com/dventimisupabase/pg_flight_controller/issues/83)): `apply()`
      re-checks ownership against the live value and refuses unless `manage_user_owned`. The
      remaining interleavings (direct out-of-cycle `apply()` bypassing the advisory lock, and
      one poison relation aborting the whole cycle) are **COR-002** and **FMEA-005** — the
      Phase 2 FMEA surface.
- [x] **Idempotency / re-entrancy.**
      **Disposition:** cited-safe, tested. Replaying a decision after success is a no-op (the
      live re-read sees the value already applied); a rapid second `apply()` is blocked by
      the per-relation `min_interval`; `decision_log.applied` is set on success.
      `19_activation` (no-op), `16_authority_gate` (min_interval).

## Findings

| ID | Sev | Conf | Evidence | Summary | Status | Link |
|---|---|---|---|---|---|---|
| COR-001 | High | Confirmed | `pgfc_govern/install.sql:713`, `:750`, `:694-705` | The ownership guard cannot tell the governor's own prior actuation from a human's setting, so continuous control and "never overwrite a human's setting" are mutually exclusive. | Verified | [#66](https://github.com/dventimisupabase/pg_flight_controller/issues/66) |
| SEC-001 | Low | Confirmed | `pgfc_govern/install.sql:898-899`, `:997` | SECURITY INVOKER is a sound least-privilege posture (cited safe); residual: the intended cron/role identity is undocumented and no function pins `SET search_path`. | Verified | [#68](https://github.com/dventimisupabase/pg_flight_controller/issues/68) |
| SEC-002 | Low | Confirmed | `pgfc_govern/install.sql:997` | `apply()` interpolates `v_prop` into the `ALTER TABLE` with `%s` (not cast/validated); safe today because the value is a computed numeric, un-hardened against a crafted `decision_log` row. | Verified | [#69](https://github.com/dventimisupabase/pg_flight_controller/issues/69) |
| COR-002 | Low | Confirmed | `pgfc_govern/install.sql:935-938`, `:1084` | The authority gate reads the last-written `governor_state` singleton, so a direct out-of-cycle `apply()` would act on stale health state. Likely by-design (`control_tick` is the sole sanctioned caller). | Won't-fix | — |

<!-- Prose for each finding goes here, keyed by ID. -->

### COR-001 — The ownership guard conflates "set by the governor" with "set by a user"

**Severity:** High · **Confidence:** Confirmed · **Status:** Verified (fixed in [#66](https://github.com/dventimisupabase/pg_flight_controller/issues/66))

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

**Resolution.** `plan()` now `LEFT JOIN`s `actuator_state` and derives `sf_user_set` as
"an explicit setting the governor is not responsible for." The governor owns the live value
only when it has a baseline row, *introduced* the option (`baseline_explicit = false`, i.e.
not user-set-first), **and** the live value still equals what it last set
(`current_value`) — so it recognizes its own prior actuation (continuous control restored)
while still protecting both a pre-existing user setting and a human `ALTER TABLE` made after
first touch. Regression tests in `pgfc_govern/tests/04_plan.sql`: a governor-set relation is
*not* `suppressed:user_owned` on the following cycle, and a post-touch human change *is*
protected under `manage_user_owned = false`.

### SEC-001 — Privilege model undocumented; functions do not pin `SET search_path`

**Severity:** Low · **Confidence:** Confirmed · **Status:** Verified (fixed in [#68](https://github.com/dventimisupabase/pg_flight_controller/issues/68))

> The "Cited safe" grep below describes the **reviewed baseline** (v0.1.0); see the
> Resolution at the end of this finding for what changed.

Dispositions the Security-checklist items **Privilege model**, **`SECURITY DEFINER`
exposure**, and **`search_path` safety** — most as *cited-safe*, with a Low residual.

**Cited safe.** No function in either extension is `SECURITY DEFINER` (`grep -nE
"SECURITY DEFINER|search_path|GRANT|REVOKE"` over both `install.sql` files returns
nothing); `apply()` is a plain `SECURITY INVOKER` function (`pgfc_govern/install.sql:898-899`).
This is a sound least-privilege posture: the caller runs the `ALTER TABLE` with their own
rights and must already hold `ALTER` on the relation, so `apply()` confers no authority a
direct `ALTER TABLE` would not. The schema objects the path touches are schema-qualified
(`pgfc_govern.`, `pgfc_observe.`), and the bare references that remain (`pg_class`,
`pg_stat_progress_vacuum`, `pg_stat_all_tables`, `format`, `now`, `count`) resolve through
`pg_catalog`, which is searched ahead of a mutable `search_path` in any normal
configuration — so a hostile `search_path` does not hijack them as built.

**Residual (Low).** Two gaps, both defense-in-depth:

1. The intended execution identity is undocumented. Production drives the loop via
   `pg_cron` (RFC §3.2), but neither the RFC nor the install scripts state *which role*
   owns the cron jobs, what privileges it needs, or why the design is `SECURITY INVOKER`
   rather than a privilege-confined `SECURITY DEFINER`. For an autonomous catalog actuator,
   that role/privilege model should be explicit, not implied.
2. No function carries `SET search_path = pgfc_govern, pgfc_observe, pg_catalog`. This is
   harmless under `SECURITY INVOKER` today, but it is fragile: if any path function is later
   wrapped `SECURITY DEFINER` (a natural step toward least-privilege deployment), the absent
   pinned `search_path` becomes a real injection surface for the dynamic `ALTER TABLE`
   (`pgfc_govern/install.sql:997`). It also aligns with Supabase's
   `function_search_path_mutable` linter.

**Recommendation.** Document the intended cron/role identity and least privilege in the RFC
and operating guide; add `SET search_path` to the control-path functions as defense-in-depth
ahead of any future `SECURITY DEFINER` posture.

**Resolution.** Both residuals closed in [#68](https://github.com/dventimisupabase/pg_flight_controller/issues/68).
(1) The operating guide now documents the execution identity and least privilege — the cron
role needs `USAGE`/`EXECUTE` on both schemas, write access to their tables, and (for active
control only) `ALTER` on the governed tables, since `apply()` is `SECURITY INVOKER` and
mutates with the caller's own rights; the guide states why `SECURITY INVOKER` is preferred
over a confined `SECURITY DEFINER` (revoking the role's `ALTER` instantly and verifiably
disables actuation). (2) Every **plpgsql** function in both extensions now pins an explicit
`SET search_path` (`pgfc_govern, pgfc_observe, pg_catalog` for govern; `pgfc_observe,
pg_catalog` for observe). Scope note: SQL-language functions are deliberately left unpinned —
a `SET` clause blocks planner inlining, and the hot helpers (`effective_reloption`,
`snap_sf`) back the incident-analysis views; plpgsql is never inlined, so pinning it is
perf-neutral. This is broader than the finding's literal "control-path functions" so the
invariant is CI-enforceable. Regression test `pgfc_govern/tests/22_search_path.sql` asserts
no plpgsql function in either schema leaves `search_path` mutable, and drives a full
`observe_tick → control_tick → apply` cycle under an **empty** caller `search_path` to prove
the path resolves its own objects regardless of the caller.

### SEC-002 — `apply()` interpolates `v_prop` into the `ALTER TABLE` without a cast

**Severity:** Low · **Confidence:** Confirmed · **Status:** Verified (fixed in [#69](https://github.com/dventimisupabase/pg_flight_controller/issues/69))

Dispositions the Security-checklist **Dynamic SQL** item for `v_prop`. The mutation
(`pgfc_govern/install.sql:997`) is:

```sql
EXECUTE format('ALTER TABLE %s SET (%I = %s)', p_relid::regclass, v_act, v_prop);
```

`%s` for `p_relid::regclass` and `%I` for the actuator name are safe (regclass, and an
identifier-quoted literal constant). `v_prop` is interpolated raw with `%s`. Traced back,
`v_prop` is `decision_log.proposed_value`, written by `plan()` as `sf_target::text`
(`pgfc_govern/install.sql:766`), where `sf_target` is the output of `snap_sf()` — a bounded
`double precision`. So **as built it is a clean numeric string and not injectable**, and the
`SECURITY INVOKER` posture (SEC-001) means the caller could `ALTER` the table anyway.

**Residual (Low).** The safety rests entirely on the provenance of a row in a writable
table. A hand-inserted or corrupted `decision_log.proposed_value` (a row with
`decision = 'adjust'` and a crafted `proposed_value`) would be interpolated verbatim into
DDL. This is defense-in-depth, not a live exploit.

**Recommendation.** Validate/cast `v_prop` to `double precision` before interpolation (e.g.
interpolate `v_prop::double precision`, or parse-and-range-check against `[sf_min, sf_max]`)
so a non-numeric `proposed_value` fails closed rather than reaching the catalog. Note: `%L`
is **not** the right fix — it would render `SET (... = '0.1')` (a quoted string literal),
which is not a valid reloption value; the value must remain an unquoted numeric.

**Resolution.** `apply()` now parses `v_prop` to a number in a scoped sub-block (so a bad
cast fails closed instead of aborting `control_tick` — `WHEN others`, since invalid syntax
and out-of-range raise different SQLSTATEs, and `pg_input_is_valid()` is PG16+ while we
support PG15) and range-checks it against `[sf_min, sf_max]` before the mutation. A bad
value is refused **silently**, like the other pre-mutation gates — the `decision_log` row
is the audit trail, and recording it `failed` would feed the failed-action breaker. The
*validated* original `v_prop` text is then spliced (not the parsed double), keeping the
catalog value byte-identical to `actuator_state.current_value` — the equality COR-001's
ownership guard depends on. Regression test `pgfc_govern/tests/21_value_validation.sql`
drives a crafted `proposed_value = '0.05, autovacuum_enabled = false'` (a DDL-valid
reloption injection that, pre-fix, silently disabled autovacuum on the table) plus
non-numeric, out-of-range, and `NaN` payloads through `apply()` directly, asserting each is
refused with nothing actuated and no `failed` row, while a legitimate in-range value still
applies.

### COR-002 — Authority gate reads the last-written `governor_state` (stale out of cycle)

**Severity:** Low · **Confidence:** Confirmed · **Status:** Won't-fix (by-design; documented)

The authority gate reads the singleton health state rather than recomputing it
(`pgfc_govern/install.sql:935-938`):

```sql
SELECT state INTO v_state FROM pgfc_govern.governor_state;
IF v_state IN ('diagnostic', 'emergency', 'disabled') THEN RETURN false; END IF;
```

So `apply()` gates on whatever `evaluate_health()` last wrote. A direct, out-of-cycle
`apply()` call would therefore act on a possibly-stale health state. (This is the mechanism
behind RFC G4 Q1.)

**Why this is likely by-design, not a defect.** In the sanctioned flow, `control_tick()` —
the only intended entrypoint — calls `evaluate_health()` immediately before the apply loop
(`pgfc_govern/install.sql:1084`), so the state is fresh. `apply()` is not a public
interface, and even with a stale state the live Invariant-4 budget checks
(`pgfc_govern/install.sql:951-981`) bound the blast radius. Recomputing health inside
`apply()` would also re-run `evaluate_health()` per relation per cycle, which is wasteful and
could itself introduce mid-cycle state churn.

**Recommendation.** Leave the behavior as-is and **document that `control_tick()` is the
sole sanctioned entrypoint** (and that `apply()` must not be called directly), or add a
cheap freshness assertion. Final disposition (Won't-fix vs. Accepted) is the author's call;
recorded here per the charter rather than filed as an issue.

**Disposition: Won't-fix (by-design).** The recomputation alternative is rejected for the
reasons above (per-relation `evaluate_health()` churn). The documentation half of the
recommendation is taken: the operating guide's "Schedule" section states that
`control_tick()` is the sole sanctioned entrypoint and that `apply()` is internal. No code
change; no issue filed.

## Traceability (seed)

The `apply()` path is the enforcement point for these invariants; this phase confirms
each holds in code and is backed by a test. (Filled during the review.)

| Invariant / mechanism | Enforced at | Test | Findings |
|---|---|---|---|
| Inv 1 — never wait on locks | `apply()` stage 15 (`lock_timeout`, non-blocking) | `13`/`18` (seeded failure rows → metrics/taxonomy); **live lock-timeout path untested → Phase 3 gap** | — |
| Inv 3 — never reduce freeze safety | `plan()` freeze floor (refusal to tighten is safe) | `04_plan` (freeze floor → `sf_min`) | — |
| Inv 4 — never exceed mutation budgets | `apply()` stage 12 (three tiers) | `16_authority_gate` | COR-002 |
| Inv 6 — every action explainable | `apply()` audit writes (stages 16–17) | `05_loop`, `19_activation` (applied + baseline/revert); `16`/`21` (refusals not misrecorded) | — |
| F4 — authority gate | `apply()` stage 8 | `16_authority_gate` | — |
| Ownership guard | `plan()` `suppressed:user_owned` | `04_plan`, `19_activation` | COR-001 |
| Value validation (DDL splice) | `apply()` (post-no-op, pre-budget) | `21_value_validation` | SEC-002 |
| Object resolution / privilege | all plpgsql `SET search_path`; `SECURITY INVOKER` | `22_search_path` | SEC-001 |

## Exit criteria

Per the charter, plus specific to this phase — **all met:**

- [x] Both checklists fully dispositioned (cited-safe or finding).
- [x] `/security-review` output reconciled into the Findings table (SEC-001/002, COR-001/002).
- [x] The traceability seed above completed for the `apply()` path (one Phase-3 coverage gap
      recorded: the live lock-timeout path).
- [x] All `Critical`/`High` findings `Verified` or `Won't-fix` (with rationale) — COR-001
      (the only High) is Verified.
