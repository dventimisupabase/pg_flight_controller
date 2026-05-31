# Changelog

All notable changes to pg_flight_controller are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Update the **Unreleased**
section in the same pull request as your change (this is a convention, not a CI gate).

## [Unreleased]

### Added

- **`pgfc_observe` (Phase 0)** — read-only autovacuum telemetry: `snapshots` and
  `relation_samples` tables, `observe()`, the `effective_reloption()` helper,
  `removability_horizons()`, the `relation_health` and `maintenance_debt` views, and
  a `retain()` retention function.
- **`pgfc_govern` (Phase 1, advisory)** — the control loop: `classify()`,
  `estimate()`, `plan()`, `verify()`, a gated `apply()`, the `observe_tick()` /
  `control_tick()` orchestrators, and the `governor_status`, `catalog_health`, and
  `active_diagnostics` views. Advisory by default (`advisory_only = true`): it plans
  and diagnoses but changes nothing.
- **Documentation** — top-level `README.md` and the `docs/` guide set (getting
  started, concepts, operating) plus the generated schema reference under
  `docs/reference/`. The concepts guide covers the **observation storage and
  self-maintenance** model (partition-rotation retention, sparse change-logging,
  rollups, governor self-maintenance) and the **Phase 1.5** storage increments
  (S1–S6), built before active control.
- **Test & docs tooling** — `test.sh` pgTAP suites across PostgreSQL 15–18; CI for
  the test matrix, markdown/shell lint, generated-reference staleness, documentation
  doctests, internal link integrity, and an advisory AI doc-drift reviewer. `main` is
  branch-protected with these checks required.

- **Storage Phase 1.5 — S1 (govern-audit retention).** A `pgfc_govern.retain()`
  function prunes the append-only audit tables by time cutoff (decisions/actions
  180 d, tick log 180 d, resolved diagnostics 365 d), closing the unbounded-growth
  gap; it respects the `action_history → decision_log` FK and never ages out an
  unresolved diagnostic. New `policy_history` table (with an `AFTER` trigger on
  `policy`) records human-owned policy changes and is retained indefinitely.

- **Storage Phase 1.5 — S2 (partition infrastructure + GC).** `pgfc_observe`'s
  high-volume tables (`snapshots`, `relation_samples`) are now **daily `RANGE`
  partitioned** on an `int4` epoch-day key (`collected_day`), with a bloat-free BRIN
  index. New `_ensure_partition()` (O(1), race-safe; called by `observe()`) and
  `_partition_inventory()` helpers. Retention is now whole-partition rotation —
  **zero dead tuples** — in two tiers: `retain()` `TRUNCATE`s out-of-window
  partitions (now default 3 days, was a 14-day `DELETE`) and the new
  `drop_empty_partitions()` `DROP`s the empty shells (default 30 days). The
  generated-reference script now lists partitioned parents once instead of flooding
  with child partitions.

- **Storage Phase 1.5 — S3 (sparse change-logging).** `observe()` now writes a
  `relation_samples` row only for relations whose observed state **changed** since
  their last sample; quiet relations produce no rows. A new `UNLOGGED`
  `relation_last_state` side table (HOT-friendly `fillfactor=70`, only the `relid`
  primary key, aggressive static autovacuum) gives the O(1) "did this change?"
  comparison and is self-healingly rebuilt from the catalogs after a crash. The
  globally-ticking `relfrozenxid_age`/`relminmxid_age` are deliberately excluded from
  the change signature; the **raw** `relfrozenxid`/`relminmxid` xids are stored
  instead, and a new `current_relation_state(p_as_of)` function reconstructs the dense
  "current state per relation" view from sparse storage with freeze ages computed
  **live** — so a quiet table's wraparound debt never goes stale. `relation_health`,
  `maintenance_debt`, and the `pgfc_govern` readers (`estimate()`, `classify()`,
  `plan()`, diagnostics) now reconcile through this function. Subsumes the reloptions
  data-minimization goal: the `reloptions` array is re-stored only when it changes.

- **Storage Phase 1.5 — S4 (rollups).** Three per-relation aggregate tiers —
  `rollup_1m`, `rollup_1h`, `rollup_1d` — let long-range trend analysis outlive the
  fast-rotating raw samples. A new `rollup()` job cascades raw → 1m → 1h → 1d
  (sample-count-weighted averages, end-of-bucket cumulative counters) and is
  idempotent (per-PK upsert); it must run at least once per raw-retention window, the
  real guarantee being the window, not nightly cron ordering. The tiers are
  partition-rotated like raw (zero dead tuples) but the partition **span tracks the
  tier**: the fine 1m tier is **daily** partitioned (7-day window), the coarse 1h/1d
  tiers **monthly** (90-/365-day windows) — added `_epoch_month()`/`_month_start()`
  keys, a generic `_ensure_part()`, and a `_rollup_inventory()`. `rollup_retain()`
  drops out-of-window rollup partitions with **cascading per-tier windows** (1m 7 d,
  1h 90 d, 1d 365 d). Rollups are sparse-in/sparse-out, so a new
  `current_rollup(tier, as_of)` carry-forward reader keeps a quiet relation answerable
  after its raw samples are gone.

- **Storage Phase 1.5 — S5 (cardinality filters).** A new single-row
  `pgfc_observe.collection_policy` table bounds *which* relations `observe()` samples,
  so the governor stays cheap in databases with thousands of relations. Four filters
  are applied set-based inside the collection query (never per-row): temporary tables
  (`exclude_temp`, default on), extension-owned relations
  (`include_extension_owned`, default off), additional schemas (`excluded_schemas`,
  additive to the always-excluded system schemas — config can never re-include
  `pg_catalog`), and child partitions below a size floor (`min_partition_size_bytes`,
  `0` disables). Rollups and `pgfc_govern`'s readers inherit the filtered set for free
  because they read what `observe()` wrote. No tiered cadence — sparse change-logging
  (S3) already handles cold tables.

- **Storage Phase 1.5 — S6 (storage budget + self-health).** The governor now bounds
  and reports its own footprint. Every telemetry/rollup partition is created with — and
  pre-S6 partitions are backfilled to — **static autovacuum reloptions**
  (`scale_factor = 0` + a fixed threshold, via a single `_telemetry_reloptions()`
  source of truth), and the `pgfc_govern` audit/state tables get matching static
  settings: the governor maintains its own schema explicitly rather than governing
  itself. New `storage_budget()` functions report per-relation on-disk bytes and dead
  tuples (`pgfc_observe`'s folds child partitions into their parent; `pgfc_govern`'s
  spans **both** schemas), and one-row `self_health` views summarize the footprint —
  `pgfc_govern.self_health` compares it to a configured cap and flags `over_budget`. A
  new single-row `pgfc_govern.storage_config(budget_bytes)` (default `NULL` = no cap)
  drives `pgfc_govern.degrade()`, which sheds storage in a **fixed graceful-degrade
  order** — raw → fine rollups → coarse rollups → diagnostics → actions → policy
  (**never** pruned) — stopping as soon as the footprint is back under budget. With no
  cap configured `degrade()` is a no-op, so it never silently destroys telemetry.

- **Parameter governance Phase 1.6 — P1 (parameter registry).** Every governed constant
  now has explicit provenance. A canonical `_parameter_registry()` function in each schema
  (the single-source-of-truth pattern) records each parameter's name, category (one of six:
  PostgreSQL-derived, safety bound, empirical default, operator policy, adaptive value,
  implementation convenience), value, unit, rationale, source, owner, `override_allowed`,
  and `config_ref`. A unified `pgfc_govern.parameter_registry` view spans both schemas as
  the operator-facing inspection surface. P1 is read-only and documents the as-built values
  (many honestly marked "MVP estimate — not yet benchmarked"); later increments make the
  control logic read from the registry and add a CI drift gate.

- **Parameter governance Phase 1.6 — P2 (single-sourced control constants).** The
  `pgfc_govern` control logic now reads its constants **from** the registry instead of inline
  literals, via three accessors — `_param(name)`, `_sf_grid()`, and `_class_target(kind)`.
  `classify()`, `estimate()`, `plan()`, `snap_sf()`, `_findings()`, `governor_status`, and
  `apply()` (its `lock_timeout`, via `set_config`) were refactored to use them (including the
  `COALESCE` policy fallbacks for `aggressiveness`, `manage_user_owned`, `advisory_only`, and
  `n_sustain`), removing the duplicated class targets and freeze threshold previously copied
  across three call sites. Behaviour is
  identical — guarded by the existing estimate/classify/plan/loop/integration suites, which
  pin concrete outcomes. The registry/code tie is now real but not yet *enforced*; the
  "registry up to date" CI gate that makes divergence impossible lands in P3.

- **Parameter governance Phase 1.6 — P3 (drift gate).** The single-sourcing is now
  **enforced**. A new `pgfc_govern._audit_control_literals()` returns any numeric or interval
  literal that is not a structural constant (`0`/`1`/`0.0`/`1.0`) in the governor's control
  functions, and a pgTAP test asserts it is empty — so an inline magic number fails the build
  on every PostgreSQL version. It is **fail-closed**: it scans *every* `pgfc_govern` function
  by default (minus a small, documented exclusion set — the registry itself, this auditor,
  the operator-retention `retain`/`degrade`, reporting `storage_budget`, and the
  `_log_policy_change` trigger) plus `governor_status`, so a control function added in a later
  phase is enforced automatically — born governed — without anyone remembering to list it.
  Function bodies are pulled by name from the catalog (`pg_proc.prosrc` / `pg_get_viewdef`),
  not by line position, so the check cannot rot; intervals/quantities are scanned first-class
  (a quoted string beginning with a digit), while prose like "(Phase 3)" does not
  false-positive. Building it red-first surfaced one straggler P2 missed — the `interval
  '1 hour'` "autovacuum recently ran" window in `estimate()` — now registered as
  `av_running_window` and read via `_param`. **Not gate-enforced** (documented in the registry
  but may still drift): the excluded functions' `retain()`/`degrade()` signature defaults, the
  `policy` table-column defaults, and `catalog_health`'s reporting windows.

- **Parameter governance Phase 1.6 — P4 (validation + adaptive provenance).** New
  `pgfc_govern.validate_parameters()` grades the live operator configuration against the
  registry's safety bounds (`OK`/`WARNING`/`CRITICAL`) — the reviewability surface, checking
  hard safety properties only (e.g. `aggressiveness <= 0` is `CRITICAL`; `advisory_only =
  false` and a zero mutation budget are `WARNING`s). `decision_log` gains an
  `estimated_benefit` column (the tightening an `adjust` applies — current scale factor minus
  proposed; `NULL` when the decision changes nothing), closing appendix E's adaptive-value
  change-history gap. **Scope note:** the `parameter_override` key-value table + `_get_config`
  getter from the design were deliberately **deferred** — every overridable parameter today
  already has a typed config home (`policy` / `storage_config` / `collection_policy`) or a
  function argument, so a key-value override table would have no consumer; it lands when a
  tunable without a typed home actually appears (likely Phase 1.7). This completes Phase 1.6.

- **Governor self-protection Phase 1.7 — F1 (self-monitoring metrics).** New one-row
  `pgfc_govern.governor_metrics` view: the read-only substrate the forthcoming F2
  health-state evaluator reads. It exposes applied/failed/lock-timeout action counts over
  1 h/1 d windows, observation lag (newest snapshot age), loop durations + tick errors
  (`tick_log`), the self-health storage footprint, and the oldest retained audit row
  (`oldest_action_at`, a threshold-free retention-backlog signal). It has no driving `FROM`, so it
  **always returns exactly one row** — counts are `0` and freshness signals `NULL` when
  nothing has happened yet — so the substrate never vanishes precisely when the governor is
  least healthy (no snapshots landing, no ticks finishing). Read-only; no behaviour change.
  The action-count columns deliberately overlap the operator-facing `catalog_health`; the
  reporting-window literals are the same out-of-scope convention (not in the drift gate).

- **Governor self-protection Phase 1.7 — F2 (health-state machine).** The governor now
  computes its own health state. New `governor_health_state` enum
  (`normal → degraded → diagnostic → emergency → disabled`, ordered by increasing caution),
  a single-row `governor_state` table (the current state), and an append-only
  `state_transitions` audit. `evaluate_health()` derives the state from the F1
  `governor_metrics` substrate against **born-governed** registry thresholds
  (`health_lag_degraded_secs`/`_emergency_secs`, `health_failed_degraded`/`_diagnostic`,
  `health_lock_timeouts_diagnostic`), takes the **worst** state any signal demands, and
  records a transition **only when the state changes**. Signals: stale observation lag →
  degraded/emergency, failed actions/hour → degraded/diagnostic, lock-timeout storm →
  diagnostic, over-budget storage → degraded. Wired into `control_tick()` as the first
  self-check step. **Advisory in F2** — the state is recorded and surfaced but does not yet
  gate actuation (the `apply()` authority gate consults it in F4); `disabled` is reserved
  for the operator-forced override (F3). Absence of data is not ill health: a fresh
  governor with no observations evaluates to `normal`, not `emergency`. `retain()` gains a
  `keep_transitions` window (default 180 d) and prunes `state_transitions`.

- **Governor self-protection Phase 1.7 — F3 (human-override surface).** Operators retain
  ultimate authority (appendix F "Human Override"). The `governor_state` singleton gains
  additive `operator_forced` / `forced_reason` / `forced_by` / `forced_at` columns, and four
  operator functions set and release a hold: `force_state(state, reason)` (rejects `normal`),
  `disable(reason)` → `disabled`, `suspend_actuation(reason)` → `diagnostic` (actuation off,
  diagnosis retained), and `clear_forced_state(reason)` to return to automatic. The override
  is a caution **floor**, not a setpoint: `evaluate_health()` now takes the **worst** of the
  auto-computed state and `operator_forced`, so a human can force *more* caution but never
  less — `disabled` is reachable only this way. Every force/release runs through
  `evaluate_health()`, so it is audited as a `state_transitions` row exactly like an
  automatic transition. F3 sets state only; it does not itself gate actuation (that is the
  F4 authority gate, which reads the state these functions set). No new registry parameters
  — the override carries no governed constants.

- **Governor self-protection Phase 1.7 — F4 (authority gate + Invariant-4 mutation budget).**
  The active-control gate: the health state is now **load-bearing**, not advisory. `apply()`
  consults `governor_state` and refuses ordinary actuation when the governor is `diagnostic`,
  `emergency`, or `disabled`; `normal` and `degraded` permit it (`degraded` is "limited" — one
  breaker-step from suspension, not suspended). A withheld actuation returns `false`
  **silently** — deliberately *not* recorded as `status='failed'`, which would feed the
  failed-action breaker and create a self-amplifying suspension loop. The existing
  failure-driven F2 transitions (failed actions, lock timeouts) thus become real circuit
  breakers now that the state gates `apply()`. **Invariant 4** is enforced at the single
  `apply()` chokepoint as a three-tier mutation budget — per-relation `min_interval`, per-cycle
  `global_max_changes_per_cycle`, and per-day `daily_mutation_budget` — read live from the
  active policy (registry default as fallback). Spending the daily budget also trips a
  `degraded`-level circuit breaker in `evaluate_health()` (a visible signal, never a
  suspension; the hard cap already holds the line). Refusing to *tighten* never violates
  Invariant 3 — the prior setting and PostgreSQL's own anti-wraparound autovacuum stay in
  place. No new tables, columns, or registry parameters: the budget reuses the existing
  `policy` knobs and registry safety-bounds, and every new comparison is literal-free so the
  decision/actuation path stays clean under the P3 drift gate. `advisory_only` stays `true`
  by default — flipping it to live operation is F7.

- **Governor self-protection Phase 1.7 — F5 (control-oscillation detection).** The governor
  now detects when it is fighting itself. A new `_oscillating_relations()` detector reads
  `action_history` (applied changes only) and, per relation, counts **direction reversals**
  in the applied scale-factor sequence within a born-governed window — flapping is a *safety*
  failure (appendix F), not a tuning question. Two registry parameters: `oscillation_window`
  (default 1 day) and `oscillation_min_reversals` (default 2 — a full up-down-up flap).
  `governor_metrics` gains an `oscillating_relations` count, and `evaluate_health()` gains an
  oscillation signal that trips **`diagnostic`** — so the F4 authority gate suspends actuation
  **cluster-wide**, preferring inaction to a self-amplifying control loop. `plan()` now also
  runs `_reconcile_oscillation()`, which raises one **`critical`** `control_oscillation`
  finding per flapping relation in `active_diagnostics` (appendix F "operator visibility") and
  auto-resolves it once the flap ages out — recovery is automatic, since the diagnostic
  suspension means no new changes are recorded. The existing saturation reconciler is scoped
  **not** to touch the `control_oscillation` class, so the finding is one stable alert, not a
  per-cycle churn. All thresholds flow through the registry, so the new control functions stay
  clean under the P3 drift gate (which scans them automatically). The `diagnostics` table now
  carries governor-scope findings alongside per-relation saturation causes.

- **Governor self-protection Phase 1.7 — F6 (load shedding + failure taxonomy).** Two
  appendix-F items land together. **Load shedding:** `observe()` now captures the cluster's
  client-backend count and `max_connections` into the `snapshots` header (two additive,
  nullable columns), and `governor_metrics` derives a `connection_pressure` ratio from the
  newest snapshot. `evaluate_health()` gains a load-shedding signal — when pressure reaches
  the born-governed `load_shed_connection_pct` (default `0.90`), the governor enters
  **`diagnostic`** so the F4 authority gate suspends actuation **cluster-wide**: it stops
  competing for locks and consumes fewer resources when the database needs them most (the
  `pg_flight_recorder` `load_shedding_active_pct` pattern, adapted from collector sampling to
  actuation authority). Recovery is immediate and windowless — the next snapshot showing
  eased pressure returns the governor to `normal`. A pre-F6 (or boot) snapshot has a NULL
  pressure and never sheds. **Failure taxonomy:** a new `_failure_class()` function is the
  single source mapping a recorded `failure_reason` to one of appendix F's five categories
  (observation / decision / actuation / resource / safety); `action_history` gains a
  `failure_class` column (CHECK-pinned, backfilled) that `apply()` now stamps on every failed
  attempt. The new `failure_taxonomy` view unifies the governor's whole failure picture into
  five rows — `condition_present` (the live signal, from the same substrate the health-state
  machine reads) and `recorded_failures_last_day` per category. Both new control functions are
  clean under the P3 drift gate (no inline literals — the percentage display lives in the
  un-scanned `governor_metrics` view). New pgTAP suite `18_load_shedding.sql` (33 tests, green
  on PG 15–18).

- **Governor self-protection Phase 1.7 — F7 (active-control activation).** The culmination of
  Phase 1.7: with the safety net built and proven (F1–F6), the supported `advisory_only =
  false` path is now first-class, not experimental. No new actuation machinery — `apply()`,
  the F4 authority gate, and the Invariant-4 budget already existed — F7 closes the two
  activation hazards the project recorded against turning actuation on. **Loop-ordering
  contract:** `control_tick()` now plans against the newest snapshot whose `estimate()` phase
  has *completed* (`max(snapshot_id)` from `relation_estimate`) rather than the newest
  *observed* snapshot. The advisory lock serializes `control_tick()` against itself but not
  against `observe_tick()`; on independent cron schedules the old selection could pair fresh
  observations with the prior cycle's hidden state, so actuation could act on a half-built
  picture. Selecting the estimated snapshot makes the ordering explicit and is literal-free
  (clean under the P3 drift gate). **Stale-window arbiter:** `apply()`'s existing re-read of
  live `pg_class.reloptions` — which downgrades a planned `adjust` to a *silent* no-op when a
  human changed the value to the proposal between observe and apply — now has the test the
  README earmarked for activation. **De-experimentalized:** `validate_parameters()` no longer
  frames `advisory_only = false` as experimental (still a `WARNING` — it is the most
  consequential operational state), and the operating guide documents activation as a
  supported path with its two safety guarantees. New pgTAP suite `19_activation.sql` (9 tests,
  green on PG 15–18).

### Changed

- **`docs/` is now the self-contained, as-built spec.** The hand-written guides no
  longer link into `out/technical-design.md` for substance — `concepts.md` explains
  the workload classes, control law, gates, removability horizons, and safety
  guarantees directly. All backward references from the project into `in/`/`out/`
  (docs, READMEs, SQL/test comments, CHANGELOG) were removed; `in/`–`out/` are frozen
  design intent the implementation may diverge from. The doc-drift CI reviewer was
  repointed to treat the code as ground truth and `docs/` as the spec under review.

- **`pgfc_observe.retain(interval)` is no longer row-by-row `DELETE`** — it `TRUNCATE`s
  whole daily partitions, and its default window changed from 14 days to 3 days
  (raw-telemetry retention; long-range history is served by rollups in a later
  increment). The `relation_samples → snapshots` foreign key was removed (partition
  rotation makes a row-level cascade both unused and an obstacle to `TRUNCATE`).

### Removed

- The `relation_samples.snapshot_id → snapshots` foreign key (see Changed).

### Breaking

- **Upgrading `pgfc_observe` across S2 destructively recreates the telemetry tables.**
  Partitioning cannot be added in place, and telemetry is disposable, so re-running
  `pgfc_observe/install.sql` over a pre-S2 install drops and recreates `snapshots`
  and `relation_samples` (existing rows are discarded). The `DROP ... CASCADE` also
  drops dependent cross-schema views such as `pgfc_govern.catalog_health`; re-run
  `pgfc_govern/install.sql` afterward to restore them. This is a deliberate one-time
  exception to `pgfc_observe`'s additive-only rule and does not extend to
  `pgfc_govern`'s audit tables.

### Notes

- No tagged releases yet; the project is pre-1.0 and active control (Phase 2) is in
  progress. Active control is **experimental** in the current code.
