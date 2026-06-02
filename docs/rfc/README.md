# pg_flight_controller — RFC

> **Status:** Draft outline (for review). **Audience:** reviewers and commenters.
> **Purpose:** a single, navigable account of the system *as built*, organized so a
> reviewer can drill from the name down to the code and climb back up from any object to
> its purpose — and know exactly what feedback is wanted.

This is a **Request for Comments** — it exists to be reviewed, not to teach or to archive.

- It is **not** the original design document. That document is frozen design *intent* and
  may diverge from what was built; this RFC describes the system **as built**, with the
  code as ground truth.
- It is **not** the user guides (getting started, operating, concepts, reference). Those
  serve operators. This serves reviewers: it foregrounds rationale, alternatives, and open
  questions, and it links *down* to the guides and reference rather than restating them.

## How to read this

Two traversals over one hierarchy. It is **tree-ish** — mostly a clean containment tree,
with a few explicit cross-links where an object is consumed by more than one subsystem.

- **Top-down (zoom in):** name → abstract → concepts → architecture → modules →
  subsystems → components (database objects) → code. Each level stands on its own and
  points to the next finer one.
- **Bottom-up (zoom out):** start at any function or table → understand it locally →
  follow its **home subsystem** to learn why it exists and what its siblings are → climb to
  the module and the architecture.

Navigation convention used throughout: **↑** climbs to the parent, **↳** refines to the
next finer level, **→** is a cross-link (a see-also or a consumer). The finest level —
per-object documentation — is the generated [reference](#6-components-and-code-the-leaf-level),
linked rather than copied.

> **Outline status.** Sections 1–5 are drafted — the full subsystem catalog (O1–O5, G1–G7)
> is filled. Sections 6–9 describe conventions; §6/§8's generated bottom-up navigation is the
> main remaining build.

## Contents

- [1. Abstract](#1-abstract)
- [2. Concepts and principles](#2-concepts-and-principles)
- [3. Architecture](#3-architecture)
- [4. Modules](#4-modules)
- [5. Subsystems](#5-subsystems)
  - pgfc_observe: [O1. Collection](#o1-collection) · [O2. Storage and retention](#o2-storage-and-retention) · [O3. Derived state and readers](#o3-derived-state-and-readers) · [O4. Self-monitoring and budget](#o4-self-monitoring-and-budget) · [O5. Parameter registry](#o5-parameter-registry)
  - pgfc_govern: [G1. Control loop](#g1-control-loop-ooda) · [G2. Policy and intent](#g2-policy-and-intent) · [G3. Parameter governance](#g3-parameter-governance) · [G4. Self-protection](#g4-self-protection-f1-f7) · [G5. Diagnostics](#g5-diagnostics) · [G6. Storage, retention, and self-maintenance](#g6-storage-retention-and-self-maintenance) · [G7. Status and reporting](#g7-status-and-reporting)
- [6. Components and code (the leaf level)](#6-components-and-code-the-leaf-level)
- [7. Open questions / feedback wanted](#7-open-questions--feedback-wanted)
- [8. How this RFC is maintained](#8-how-this-rfc-is-maintained)
- [9. Relationship to other documents](#9-relationship-to-other-documents)

---

## 1. Abstract

**pg_flight_controller** is a supervisory **autovacuum governor** for PostgreSQL. It treats
per-table autovacuum settings not as static configuration but as **actuator positions**:
operators express *policy* — the maintenance outcomes they want — and the governor observes
the database, estimates each relation's hidden maintenance state, and steers autovacuum's
setpoints toward those outcomes with small, safe, auditable changes. It never runs `VACUUM`
itself; it moves the setpoints that decide *when* autovacuum fires.

It exists because autovacuum's per-table knobs are typically set once and assumed to stay
appropriate, while real workloads shift and the right setting drifts with them. The goal is
not to tune autovacuum once, but to keep the database **self-stabilizing** as the workload
changes. The design draws on control theory and state estimation — not machine learning.

At a glance, two cooperating extensions — `pgfc_observe` (read-only telemetry) and
`pgfc_govern` (the control loop) — run an **observe → estimate → decide → act** feedback
cycle. It is **advisory by default**: out of the box it recommends and diagnoses but changes
nothing. Active control is opt-in and runs under a self-protection net, on the principle that
an autonomous actuator on a live production catalog must be **safe and explainable before it
is effective**.

↳ Refine into [concepts](#2-concepts-and-principles).

## 2. Concepts and principles

The mental model a reviewer needs before the architecture. Each concept below is framed for
review — what it is, and what to scrutinize about it — with the full as-built explanation in
the [concepts guide](../guide/concepts.md), linked per concept rather than restated here.

### 2.1 Autovacuum settings as actuator positions

PostgreSQL exposes per-table autovacuum knobs (scale factors, thresholds) as static
configuration you set once and hope stays appropriate. pg_flight_controller reframes them as
**actuator positions** a supervisory loop moves to hold a desired *outcome* as the workload
shifts. It never runs `VACUUM` — it changes *when* autovacuum fires. **For review:** the
whole value proposition rests on this reframing — that steering setpoints, not performing
maintenance, is the right control surface.
→ [guide](../guide/concepts.md#autovacuum-settings-are-actuator-positions); it takes
architectural shape in [§3](#3-architecture).

### 2.2 The control loop (OODA)

The system is a feedback loop — **observe** the database, **orient** (estimate hidden state,
classify the workload), **decide** a setpoint, **act**, and **verify** — drawn from control
theory and state estimation, not machine learning. **For review:** whether the loop's inputs
are sufficient and whether the feedback (`verify`) genuinely closes.
→ [guide](../guide/concepts.md#the-loop-observe--estimate--decide--act); the cadences are
[§3.2](#32-the-control-loop-and-its-two-cadences).

### 2.3 Policy as outcomes; workload classes and the control law

Operators express **intent as outcomes** — how clean a kind of table should be kept — not
raw parameters. Each relation is assigned a **workload class** with a target dead-tuple
fraction template; the control law derives the setpoint as roughly *template ÷
aggressiveness*, clamped to a safe range and snapped to a discrete grid (a deadband that
suppresses churn). **For review:** the classification taxonomy and the control law's
stability — does it converge, and are the clamps and grid right?
→ [workload classes](../guide/concepts.md#workload-classes),
[what it steers](../guide/concepts.md#what-it-steers-the-dead-tuple-fraction).

### 2.4 Act rarely: cost, deadband, and the gates

Moving a setpoint has cost — an MVCC catalog write and a behavior change — so the system is
built to act sparingly: a deadband (no-op suppression), an ownership guard (never overwrite a
human's or another system's setting), and rate/budget limits. **For review:** whether these
gates are sufficient to keep catalog churn and actuation pressure bounded.
→ [movement has cost](../guide/concepts.md#movement-has-cost-so-act-rarely),
[advisory by default](../guide/concepts.md#advisory-by-default); enforced in
[§3.4](#34-advisory-by-default-active-control-under-the-self-protection-net) and
[G1](#g1-control-loop-ooda).

### 2.5 Diagnose, don't escalate

When a table is not keeping up, more aggressiveness often cannot help — the cause may be an
external inhibitor (a long transaction or a replication slot pinning the xmin horizon) or an
I/O limit. Rather than escalate blindly, the governor **diagnoses the cause** (`config` /
`io_limited` / `inhibited`) and names it, using **removability horizons** to identify who
pins the horizon. **For review:** whether the saturation taxonomy is correct and complete,
and whether "diagnose, don't escalate" is honored consistently.
→ [diagnose, don't escalate](../guide/concepts.md#diagnose-dont-escalate),
[removability horizons](../guide/concepts.md#removability-horizons); the subsystem is
[G5](#g5-diagnostics).

### 2.6 Safety first: an explicit theory of failure

An autonomous actuator on a live catalog must be safe before it is effective. The system
holds **six safety invariants** — never wait on locks; never disable autovacuum; never
reduce freeze safety; never exceed mutation budgets; never escalate without evidence; every
action explainable — and makes every change **reversible** (a captured pre-governor baseline
plus revert). **For review:** whether the invariants are actually enforced where claimed —
the core of the fortification review.
→ [safety first](../guide/concepts.md#safety-first); architectural framing in
[§3.6](#36-safety-invariants-as-architectural-constraints); enforcement under
[G4](#g4-self-protection-f1-f7).

↑ [Abstract](#1-abstract) · ↳ [Architecture](#3-architecture)

## 3. Architecture

pg_flight_controller is an **outer control loop wrapped around PostgreSQL's autovacuum**.
It never runs `VACUUM` itself; it moves the per-table setpoints that decide *when*
autovacuum fires, holding each table near a policy-defined outcome. The architecture falls
out of one commitment: an autonomous actuator on a live production catalog must be **safe
and explainable before it is effective**. So the system is split so that *seeing* is
separate from *acting*, *acting* is off by default, and *acting* is gated by the governor's
assessment of its own health.

### 3.1 Two modules, one boundary

The system is two PostgreSQL extensions, each owning a schema, split by role:

- **`pgfc_observe`** (Observe + Orient) — read-only telemetry. It samples
  autovacuum-relevant state and derives meaning, and it **writes only its own schema and
  never changes a database setting**. It stands alone as an autovacuum-health monitor, with
  no dependency on govern.
- **`pgfc_govern`** (Decide + Act) — the control loop. It **reads `pgfc_observe`
  cross-schema, read-only**, and is the *only* component that ever mutates anything (an
  `ALTER TABLE` on a relation's autovacuum reloptions) — and only when active control is
  enabled.

The boundary is a one-way dependency: govern depends on observe; observe knows nothing of
govern. That separation is load-bearing, not cosmetic — the risky half can be reasoned
about, tested, and gated independently, and the safe half can be run on its own.
(↳ [Modules](#4-modules) details each side.)

### 3.2 The control loop and its two cadences

The loop is the OODA cycle — **observe → orient → decide → act** — intended to be closed by
a verify step. That verify step is **a no-op stub today** (see [G1](#g1-control-loop-ooda)):
the loop is closed *through the plant* — the next `observe()`/`estimate()` sees the effect
of prior actuations — but it does **not yet attribute outcomes to the actions that caused
them**, so claims about the control law's convergence are not yet instrumented (see
[§7](#7-open-questions--feedback-wanted)). It runs as **two independent cadences**, not one:

- **Fast loop — `observe_tick` (~1 min):** `observe()` → `classify()` → `estimate()`.
  Read-only; refreshes the picture and the per-relation hidden-state estimates. Never
  actuates.
- **Control loop — `control_tick` (~5 min):** `plan()` → `apply()` (only when not advisory)
  → `verify()`. The only path that can mutate.

Decoupling the cadences is deliberate: **observing often is cheap and safe; acting often is
neither.** Frequent sampling keeps estimates fresh and lets diagnosis converge, while
actuation stays rare, rate-limited, and blast-radius-bounded. The two loops meet at one
contract — the control loop plans against the **newest snapshot whose estimate phase has
completed**, never merely the newest observed one, so it cannot act on fresh observations
paired with stale hidden state. In production both loops are driven by `pg_cron`; the
control loop takes an advisory lock so cycles never overlap.
(→ [G1 Control loop](#g1-control-loop-ooda).)

### 3.3 Data flow

```text
            pg_stat_* views · pg_class · xmin/freeze horizons
                              │  (read-only)
                              ▼
  pgfc_observe   observe() ──▶ snapshots / relation_samples ──▶ rollups
  (Observe+Orient)            (sparse writes; relation_last_state cache)
                              │
                              │  cross-schema, read-only
                              ▼
  pgfc_govern    classify ─▶ estimate ─▶ plan ─▶ [self-protection gate] ─▶ apply ─▶ verify
  (Decide+Act)    (class)    (hidden     (decision_log)                    (ALTER TABLE;
                              state)                                        action_history)
                              │                                                  │
                              ├─▶ diagnostics  (diagnose, don't escalate)        │
                              └──────────────── audit + retention ◀──────────────┘
```

The catalog and statistics views are the only inputs. Observation lands in partitioned,
sparsely-written telemetry (with rollups for long-range history); govern reads that
telemetry to classify each relation, estimate its hidden maintenance state, decide a
setpoint, and — under active control — apply it, recording every action for explanation and
rollback.

### 3.4 Advisory by default; active control under the self-protection net

Two architectural facts set the risk posture:

- **Advisory by default.** With the default policy the whole loop runs and writes a complete
  decision and diagnostic trail, but `apply()` never fires — nothing changes. The resting
  state is *recommend and diagnose*. Going live is the single supported `advisory_only =
  false` flip.
- **Self-protection gates the Act stage.** Between Decide and Act sits the governor's
  assessment of its **own** health: `evaluate_health()` derives a health state from
  self-monitoring metrics, and `apply()` consults it as an authority gate — refusing or
  limiting actuation when the governor is degraded, when circuit breakers trip, when it
  detects itself oscillating, or under database stress (load shedding). A three-tier
  mutation budget caps blast radius. The principle: *the governor must govern itself before
  it governs PostgreSQL.* (→ [G4 Self-protection](#g4-self-protection-f1-f7); the apply path
  is the subject of fortification [Phase 1](../fortification/01-security-correctness-apply.md).)

### 3.5 Cross-cutting patterns

Three concerns recur in **both** modules — distinct objects, same shape — worth naming once
here rather than rediscovering per subsystem:

- **Parameter registry.** Tunable thresholds are *born governed*: declared in a typed
  registry with defaults and provenance, not scattered as literals. Govern adds a **drift
  gate** that scans the control path for inline numeric literals, so a new knob cannot slip
  in untyped. (→ [O5](#o5-parameter-registry), [G3](#g3-parameter-governance).)
- **Storage and self-maintenance.** Each module bounds its **own** footprint — observe by
  partition rotation and rollups, govern by time-cutoff audit pruning and graceful degrade —
  and reports through a `self_health` view and a `storage_budget`. The governor must not
  become its own maintenance burden. (→ [O2](#o2-storage-and-retention),
  [O4](#o4-self-monitoring-and-budget), [G6](#g6-storage-retention-and-self-maintenance);
  open question
  [FMEA-001](../fortification/02-failure-theory.md#fmea-001--partition-recycling-uses-createdrop-not-a-fixed-truncate-ring).)
- **Self-health surface.** Both modules expose a `self_health` view, for the same reason: an
  autonomous component should make its own condition observable.

### 3.6 Safety invariants as architectural constraints

Cutting across every subsystem are six invariants the system *holds* rather than re-decides
per change: never wait on locks; never disable autovacuum; never reduce freeze safety; never
exceed mutation budgets; never escalate without evidence; every action must be explainable.
They are not a subsystem — they are constraints the Act stage and the loop are built to
satisfy, and they are the backbone of the fortification review's traceability.
(→ [Concepts](#2-concepts-and-principles) for what each means; enforced across
[G1](#g1-control-loop-ooda) and [G4](#g4-self-protection-f1-f7).)

↑ [Concepts](#2-concepts-and-principles) · ↳ [Modules](#4-modules)

## 4. Modules

The two extensions in detail — each module's responsibility, the contract at its boundary,
and the subsystems it comprises. This refines
[§3.1](#31-two-modules-one-boundary); each subsystem links down to its [§5](#5-subsystems)
entry.

### 4.1 pgfc_observe

**Responsibility.** Read-only telemetry and orientation: sample autovacuum-relevant state on
a fast cadence, store it bloat-free, derive health and debt signals, and watch its own
footprint. Owns the `pgfc_observe` schema.

**Contract.** Writes *only* its own schema and *never* changes a database setting; has *no*
dependency on govern; is usable standalone as an autovacuum-health monitor. Re-running
`install.sql` is the upgrade path; uninstall is `DROP SCHEMA pgfc_observe CASCADE`.

**Subsystems** *(detail in [§5](#5-subsystems))*:

- [O1 · Collection](#o1-collection) — the act of observing, sampled sparsely.
- [O2 · Storage and retention](#o2-storage-and-retention) — bounded, bloat-free persistence
  (partitions, rollups, GC). *(Home of [FMEA-001](../fortification/02-failure-theory.md#fmea-001--partition-recycling-uses-createdrop-not-a-fixed-truncate-ring).)*
- [O3 · Derived state and readers](#o3-derived-state-and-readers) — raw telemetry → meaning
  (health/debt views, removability horizons).
- [O4 · Self-monitoring and budget](#o4-self-monitoring-and-budget) — watching its own
  storage footprint.
- [O5 · Parameter registry](#o5-parameter-registry) — typed, born-governed thresholds.

**Internal flow.** O1 writes the tables O2 owns; O3 reads them to derive meaning; O4 reports
the footprint; O5 supplies the thresholds the others read.

↑ [Architecture](#3-architecture) · ↳ [Subsystems](#5-subsystems)

### 4.2 pgfc_govern

**Responsibility.** The control loop: read observe, classify and estimate, decide, and — under
active control — act and verify, all under a self-protection net and a parameter-governance
discipline. Owns the `pgfc_govern` schema.

**Contract.** Reads `pgfc_observe` cross-schema, **read-only**; is the *only* component that
mutates the catalog (`ALTER TABLE` on a relation's autovacuum reloptions), and only when
`advisory_only = false`. Depends on observe (install observe first). **Advisory by default** —
the resting state plans and diagnoses but changes nothing.

**Subsystems** *(detail in [§5](#5-subsystems))*:

- [G1 · Control loop (OODA)](#g1-control-loop-ooda) — the heart: orchestration plus classify →
  estimate → plan → apply → verify. `apply()` is the sole mutator.
- [G2 · Policy and intent](#g2-policy-and-intent) — operator outcomes, with an audited history.
- [G3 · Parameter governance](#g3-parameter-governance) — typed registry, drift gate,
  validation.
- [G4 · Self-protection (F1-F7)](#g4-self-protection-f1-f7) — the governor governing itself;
  gates the Act stage.
- [G5 · Diagnostics](#g5-diagnostics) — diagnose, don't escalate.
- [G6 · Storage, retention, and self-maintenance](#g6-storage-retention-and-self-maintenance)
  — bound its own audit tables; graceful degrade.
- [G7 · Status and reporting](#g7-status-and-reporting) — operator-facing rollups.

**Internal flow.** G1 is the spine; G2 supplies intent and G3 supplies governed thresholds;
G4 gates G1's apply step; G5 is fed by G1's plan; G6 prunes G1's audit tables; G7 reports.
Three subsystems **mirror** their observe counterparts (G3↔O5 registry, G6↔O4 storage/
self-maintenance, and a `self_health` surface in both) — see
[§3.5](#35-cross-cutting-patterns).

↑ [Architecture](#3-architecture) · ↳ [Subsystems](#5-subsystems)

## 5. Subsystems

Each subsystem is a stub to be filled with **Responsibility**, **Role**, **Objects**
(linked to the [reference](#6-components-and-code-the-leaf-level) and code), **Consumers**
(cross-links), and **Feedback wanted**. Objects below are the confirmed home assignments;
full per-object docs live in the generated reference
([observe](../reference/pgfc_observe.md), [govern](../reference/pgfc_govern.md)).

### O1. Collection

- **Responsibility:** Collect one telemetry snapshot per run — a header row plus
  per-relation autovacuum-relevant state — sampling **sparsely**, so a relation is recorded
  only when its observed state actually changed since its last sample.
- **Role:** The Observe stage's data-acquisition surface — the sole writer that turns live
  catalog / `pg_stat` state into the persisted history the rest of the system Orients on.
- **Objects:** `observe()` is the collector; `collection_policy` is a singleton config that
  bounds *which* relations are sampled (system schemas always excluded, plus `exclude_temp`,
  `include_extension_owned`, `excluded_schemas`, and a `min_partition_size_bytes` floor on
  child partitions); `relation_last_state` is an UNLOGGED, catalog-rebuildable
  change-signature cache giving O(1) "did this change?" detection. See the
  [reference](../reference/pgfc_observe.md) and [source](../../pgfc_observe/install.sql).
- **Consumers / cross-links:** the dense-reconstruction readers
  ([O3](#o3-derived-state-and-readers)) and the rollup tiers
  ([O2](#o2-storage-and-retention)) consume what `observe()` wrote — the filtered, sparse set
  propagates downstream rather than being re-filtered.
- **Feedback wanted:** (1) the change test is a full-row `IS DISTINCT FROM` over the dense
  signature — is any governance-relevant field omitted, such that a meaningful change is
  coalesced and a sample skipped? (2) after a crash the UNLOGGED cache is empty, so the next
  `observe()` re-samples every included relation once — is that one-time dense burst
  acceptable, and is "empty cache" always safely equivalent to "never seen"? (3) are
  `collection_policy`'s four filters the right knobs?
- ↑ [pgfc_observe](#41-pgfc_observe) · → writes the raw tables owned by
  [O2](#o2-storage-and-retention).

### O2. Storage and retention

- **Responsibility:** Bounded, bloat-free persistence for telemetry — raw samples kept only
  a few days, aggregated into long-range rollups, and reclaimed by whole-partition rotation
  rather than row deletes. *(Home of finding FMEA-001.)*
- **Role:** The durable layer of `pgfc_observe`, between the collector that writes samples
  ([O1](#o1-collection)) and the readers that serve state ([O3](#o3-derived-state-and-readers)).
- **Objects:** high-volume raw tables `relation_samples` and `snapshots` (daily
  `RANGE`-partitioned); rollup tiers `rollup_1m`/`rollup_1h`/`rollup_1d` (1m daily-, 1h/1d
  monthly-partitioned). Partition lifecycle: `_ensure_partition` (on-demand day partitions,
  called hot by the collector), `_partition_inventory`, and the key encoders
  `_epoch_day`/`_epoch_month`/`_month_start`. Raw GC: `retain` (`TRUNCATE` partitions older
  than the window, ~3 days) and `drop_empty_partitions` (`DROP` long-empty shells). Rollup
  pipeline: `rollup` and `_rollup_coarsen` (cascade raw into the tiers with
  sample-count-weighted aggregates), `rollup_retain` (cascading per-tier `DROP`),
  `_rollup_inventory`, and `current_rollup` (reads a tier carrying the last bucket forward).
  `_telemetry_reloptions` supplies the static, aggressive autovacuum reloptions applied to
  every telemetry partition (self-maintenance). See the
  [reference](../reference/pgfc_observe.md) and [source](../../pgfc_observe/install.sql).
- **Consumers / cross-links:** read by [O3](#o3-derived-state-and-readers), which derives
  current and historical state from these tables (including `current_rollup`'s carry-forward
  reads).
- **Feedback wanted:** is the partition-recycling strategy sound — create/drop vs. a fixed
  `TRUNCATE` ring — see
  [FMEA-001](../fortification/02-failure-theory.md#fmea-001--partition-recycling-uses-createdrop-not-a-fixed-truncate-ring)?
  And is the rollup-before-truncate ordering (raw must be aggregated by `rollup()` before
  `retain()` truncates its window) safe under skipped or lagging maintenance runs?
- ↑ [pgfc_observe](#41-pgfc_observe) · → read by [O3](#o3-derived-state-and-readers).

### O3. Derived state and readers

- **Responsibility:** Turn the raw, sparsely-stored telemetry into meaning — dense
  per-relation current state and the maintenance signals derived from it.
- **Role:** The Orient step — interpreting what was observed before anyone decides.
- **Objects:** `current_relation_state()` is the keystone reader: it reconstructs the dense,
  as-of state per relation from sparse change-logged samples (carry-forward — the latest
  sample at or before the target snapshot) and recomputes freeze ages *live* rather than
  trusting stored ages. The `relation_health` and `maintenance_debt` views build on it
  (dead/live tuples, freeze ages, and debt signals such as `dead_tuple_fraction`,
  `vacuum_debt_ratio`, `analyze_debt_ratio`, `freeze_debt`, scored against effective
  thresholds). `removability_horizons()` reports the oldest xmin/catalog horizons and the
  class that pins each (long-running txn, replication slot, standby feedback, prepared
  xact). `effective_reloption()` extracts the explicitly-set value of a storage parameter.
  See the [reference](../reference/pgfc_observe.md) and [source](../../pgfc_observe/install.sql).
- **Consumers / cross-links:** read by operators and by the governor; `maintenance_debt`
  itself uses `effective_reloption()` to resolve per-relation thresholds, and
  `effective_reloption` is consumed cross-module by govern's planning.
- **Feedback wanted:** is the sparse→dense carry-forward (latest sample ≤ snapshot) the
  reconstruction reviewers expect, including for relations whose last change predates the
  target snapshot? Is live freeze-age recomputation consistent with what the governor plans
  against? Are the debt-ratio definitions (overdue *indicators*, not setpoints) framed
  correctly?
- ↑ [pgfc_observe](#41-pgfc_observe) · → `effective_reloption` is also consumed cross-module
  by [G1](#g1-control-loop-ooda).

### O4. Self-monitoring and budget

- **Responsibility:** Make `pgfc_observe`'s own on-disk footprint observable, so the
  telemetry collector does not become an unbounded maintenance burden of its own.
- **Role:** The schema's introspective floor — observe turning its monitoring discipline
  back on itself, beside the snapshot/rollup pipeline it measures.
- **Objects:** `storage_budget()` reports per-logical-relation bytes and dead tuples (child
  partitions folded into their parent); `self_health` rolls that into a one-row summary
  (total bytes, aggregate dead tuples, partition counts, oldest raw partition). See the
  [reference](../reference/pgfc_observe.md) and [source](../../pgfc_observe/install.sql).
- **Consumers / cross-links:** `storage_budget()`'s `bytes` is read cross-schema by govern
  (`degrade()` in [G6](#g6-storage-retention-and-self-maintenance)) to enforce a storage
  cap; this is the observable counterpart to govern's same-named self-maintenance pattern.
- **Feedback wanted:** within observe these surfaces are purely advisory (govern owns any
  enforcement) — is that the right split, or should observe carry a self-throttle? Does
  `self_health` cover the right signals, given `total_dead_tuples` should stay near zero
  because rotation is `TRUNCATE`/`DROP`, not `DELETE`?
- ↑ [pgfc_observe](#41-pgfc_observe) · → mirrors govern's [G6](#g6-storage-retention-and-self-maintenance).

### O5. Parameter registry

- **Responsibility:** Declare `pgfc_observe`'s tunable thresholds and constants as a single
  typed table — each with a category, default, unit, rationale, source, owner, override
  flag, and config reference — so they are *born governed* with explicit provenance rather
  than scattered as bare literals.
- **Role:** A cross-cutting inspection and documentation surface spanning the extension's
  collection, retention, rollup, and storage-tuning knobs.
- **Objects:** `_parameter_registry` (function). See the
  [reference](../reference/pgfc_observe.md) and [source](../../pgfc_observe/install.sql).
- **Consumers / cross-links:** govern's parameter-governance subsystem unions this into the
  operator-facing registry view; observe is the smaller, control-logic-free side of the pair
  (it has no control literals to single-source). Mirrors [G3](#g3-parameter-governance).
- **Feedback wanted:** does observe need the same drift-gate enforcement and validation G3
  carries, or is a read-only provenance registry sufficient given observe has no active
  control logic? Is the provenance set complete — any governed constant still living as an
  inline literal outside the registry?
- ↑ [pgfc_observe](#41-pgfc_observe) · → mirrors govern's [G3](#g3-parameter-governance).

### G1. Control loop (OODA)

- **Responsibility:** The heart of the governor — orchestrate the two cadences and run the
  per-cycle pipeline classify → estimate → plan → apply → verify, turning observed catalog
  state into bounded `ALTER TABLE` actuations.
- **Role:** Reads derived state from `pgfc_observe`, decides per-relation, and is the only
  loop path that mutates the host catalog.
- **Components and objects:**
  - **Orchestration:** `observe_tick`, `control_tick`, `tick_log` — two cadences:
    `observe_tick` (~1 min) snapshots, classifies, and estimates, never actuating;
    `control_tick` (~5 min) takes an advisory xact lock (no overlap), evaluates health
    first, then plans + applies-if-not-advisory + verifies, logging each cycle to `tick_log`.
  - **Classify:** `classify`, `relation_class`, `relation_kind`, `_class_target` — assign
    each relation a workload class (a `relation_kind`) with N-cycle hysteresis; `_class_target`
    maps the class to its base dead-tuple fraction.
  - **Estimate:** `estimate`, `relation_estimate`, `ewma` — derive hidden state (EWMA-smoothed
    rates, debts, effectiveness, a saturation cause) into `relation_estimate`, stamped with
    its `snapshot_id`.
  - **Plan / Decide:** `plan`, `decision_log`, `snap_sf`, `_sf_grid` — the control law: class
    target ÷ aggressiveness, clamped to `[sf_min, sf_max]`, snapped to the `_sf_grid` deadband
    via `snap_sf`, with a freeze floor that dominates saturation suppression; one
    `decision_log` row per relation (adjust / hold / escalate / suppressed).
  - **Apply / Act:** `apply`, `actuator_state`, `action_history`, `batch_seq` — the sole
    catalog mutator: actuate one approved change via `ALTER TABLE`, recording every attempt in
    `action_history` (rollback baselines in `actuator_state`); runs only when not
    `advisory_only`, then gated by G4 and the Invariant-4 budget. *(Subject of fortification
    Phase 1.)*
  - **Verify:** `verify` — currently a no-op stub that exists to close the loop on past
    actions; expanded later.
  - See the [reference](../reference/pgfc_govern.md) and [source](../../pgfc_govern/install.sql).
- **Consumers / cross-links:** `control_tick` is bounded by [G4](#g4-self-protection-f1-f7)
  before actuating; both cadences read derived observe state via
  [O3](#o3-derived-state-and-readers); the `action_history` it writes is consumed by
  [G4](#g4-self-protection-f1-f7) (oscillation/failure/budget signals) and pruned by
  [G6](#g6-storage-retention-and-self-maintenance).
- **Feedback wanted:** (1) is the `apply()` path correct and safe at the security boundary —
  argument handling, the live-vs-proposed no-op check, the `pg_stat_progress_vacuum` skip, and
  ownership of user-set reloptions (the focus of fortification
  [Phase 1](../fortification/01-security-correctness-apply.md))? (2) does the control law
  converge and stay stable (target ÷ aggressiveness, clamp, grid-snap, freeze floor), or can
  grid-snapping interact with hysteresis to flap? (3) is planning against the newest
  *estimated* snapshot the right loop-ordering contract, and does `verify` as a no-op leave a
  real gap until it is expanded?
- ↑ [pgfc_govern](#42-pgfc_govern) · → gated by [G4](#g4-self-protection-f1-f7); reads
  observe [O3](#o3-derived-state-and-readers); `action_history` is consumed by
  [G4](#g4-self-protection-f1-f7) and [G6](#g6-storage-retention-and-self-maintenance).

### G2. Policy and intent

- **Responsibility:** Capture operator intent as desired *outcomes* — aggressiveness scaling
  of per-class targets, the `advisory_only` dry-run gate, the actuation-economy budgets
  (`min_interval`, per-cycle and per-day caps), `n_sustain`, `manage_user_owned` — not raw
  per-table autovacuum parameters, with an append-only audit of every change.
- **Role:** The desired-state source for the Decide stage; a single auto-seeded `default`
  policy makes the loop operable out of the box, and `advisory_only = true` (the default)
  means the loop plans but `apply()` never fires.
- **Objects:** the `policy` table (operator-expressed outcomes), its append-only
  `policy_history` audit, and the `_log_policy_change` AFTER trigger that writes it. See the
  [reference](../reference/pgfc_govern.md) and [source](../../pgfc_govern/install.sql).
- **Consumers / cross-links:** read by [G1](#g1-control-loop-ooda), which reads
  `aggressiveness`, `manage_user_owned`, and `n_sustain` to scale class targets and gate
  suppression during a control tick.
- **Feedback wanted:** is "intent as outcomes" expressive enough, or will operators need a
  richer target vocabulary than scalar aggressiveness plus per-class templates? Does a single
  `default` policy suffice, or should the design admit multiple named/scoped policies (and how
  would relations bind to one)? Is indefinite `policy_history` retention, and not logging the
  auto-seeded default, the right call?
- ↑ [pgfc_govern](#42-pgfc_govern) · → read by [G1](#g1-control-loop-ooda).

### G3. Parameter governance

- **Responsibility:** Single-source every governed constant the control loop uses —
  thresholds, grids, class targets, health bounds, retention windows — in a typed registry
  recording each value's category and provenance ("born governed"), and guard against any
  control value escaping that registry.
- **Role:** Cross-cutting — not a stage of the loop but the substrate every stage reads its
  constants from, plus the operator-facing surfaces for inspecting and validating config.
- **Objects:** the canonical registry (`_parameter_registry`) and its single read accessor
  (`_param`); the unified operator view (`parameter_registry`); the drift gate
  (`_audit_control_literals`); and the live-config grader (`validate_parameters`). See the
  [reference](../reference/pgfc_govern.md) and [source](../../pgfc_govern/install.sql).
- **Consumers / cross-links:** `_param()` is the single accessor every control function reads
  constants through; the `parameter_registry` view unions this with observe's
  ([O5](#o5-parameter-registry)) so operators see both schemas at once. `_audit_control_literals()`
  is the CI-enforced drift gate: it scans every `pgfc_govern` function body (fail-closed, with
  a small explicit exclusion set) plus `governor_status`'s target computation and returns any
  literal not in the structural allowlist, so a new untyped knob cannot slip in.
- **Feedback wanted:** (1) is the drift gate's coverage right — does scanning by catalog name
  leave any real control path unguarded, and are the documented exclusions (`retain`/`degrade`,
  policy DEFAULTs, `catalog_health` windows) safe to leave out? (2) does `validate_parameters()`
  check the right safety properties — should any WARNING (e.g. `advisory_only = false`,
  `manage_user_owned`) be CRITICAL? (3) is the provenance vocabulary complete enough for review?
- ↑ [pgfc_govern](#42-pgfc_govern) · → mirrors observe's [O5](#o5-parameter-registry);
  consumed by nearly every control function via `_param`.

### G4. Self-protection (F1-F7)

- **Responsibility:** The appendix-F self-protection net — the governor governs itself before
  it governs PostgreSQL, deriving a health state from its own telemetry and bounding its
  authority to act so a sick controller steps back rather than thrashing the catalog.
- **Role:** Sits ahead of the Act stage. `evaluate_health()` runs first each control cycle and
  writes the singleton `governor_state`; `apply()`'s authority gate then reads that state and
  may refuse before any `ALTER TABLE`. The state machine is advisory — actuation is gated only
  at `apply()`.
- **Objects:** health state and audit — `governor_state` (singleton + operator-override
  columns), the `governor_health_state` enum (`normal` → `degraded` → `diagnostic` →
  `emergency` → `disabled`, ordered by increasing caution so worst-wins), and the append-only
  `state_transitions` log. Self-monitoring substrate (F1): the `governor_metrics` view.
  Evaluator (F2): `evaluate_health()` composes a candidate per signal and takes the worst.
  Operator override (F3): `force_state`, `clear_forced_state`, `disable`, `suspend_actuation`
  — a downward-only caution floor. Detectors: `_oscillating_relations` /
  `_reconcile_oscillation` (F5 flapping); the load-shed signal (F6) lives in the metrics view.
  Failure taxonomy (F6): `_failure_class` and the `failure_taxonomy` view. See the
  [reference](../reference/pgfc_govern.md) and [source](../../pgfc_govern/install.sql).
- **Consumers / cross-links:** derives state from `governor_metrics`; the apply authority gate
  consults `governor_state`; the F5 detector and the F4 per-relation rate limit read
  `action_history` from [G1](#g1-control-loop-ooda). The mutation-budget breaker is
  *degraded-level only* (degraded still actuates, "one step from suspension"); only
  failure-driven breakers and the F5/F6 signals reach `diagnostic`, where the gate suspends
  actuation. `disabled` is operator-forced only.
- **Feedback wanted:** (1) can the authority gate be bypassed — a direct `apply()` out of cycle
  (it reads whatever `evaluate_health()` last wrote), or crafted `action_history` skewing the
  rate limit / reversal count? (2) is the worst-of composition free of self-amplifying loops —
  refusals return `false` *silently* and are not recorded as failed actions, precisely so they
  cannot feed the failed-action breaker; is that boundary right everywhere? (3) are the
  per-signal recovery semantics intended — F5 oscillation **windowed** (must age out), F6
  load-shed **immediate/transient**?
- ↑ [pgfc_govern](#42-pgfc_govern) · → gates the [G1](#g1-control-loop-ooda) apply path;
  reads `action_history`.

### G5. Diagnostics

- **Responsibility:** Turn a relation that cannot keep up into an operator-facing root-cause
  finding with an actionable recommendation, rather than cranking actuation harder. When
  `plan()` sees high vacuum debt it discriminates the cause — `config` (autovacuum not
  firing), `io_limited` (running but I/O-bound), or `inhibited` (a pinned xmin horizon, named
  by its owner) — and says plainly when more aggressive settings will not help.
- **Role:** The diagnosis output of the loop, written as a side effect of `plan()` alongside
  the decision trail; advisory, never DDL.
- **Objects:** the `diagnostics` table (open/resolved findings) and its operator-facing
  `active_diagnostics` view (open findings only), with `_findings` computing the findings for a
  snapshot and `_reconcile_diagnostics` opening and auto-resolving them idempotently. See the
  [reference](../reference/pgfc_govern.md) and [source](../../pgfc_govern/install.sql).
- **Consumers / cross-links:** fed by [G1](#g1-control-loop-ooda)'s `plan()`, which runs the
  reconciler each cycle. Governor-scope findings such as `control_oscillation` are owned by
  [G4](#g4-self-protection-f1-f7); the saturation reconciler is scoped to leave that class
  untouched.
- **Feedback wanted:** is the three-way saturation taxonomy (`config` / `io_limited` /
  `inhibited`) complete and correctly discriminated? Is the open/auto-resolve reconciliation
  churn-free — stable findings rather than a fresh row per tick? Are the inhibitor attributions
  (the named horizon owner) reliable enough to act on?
- ↑ [pgfc_govern](#42-pgfc_govern) · → fed by [G1](#g1-control-loop-ooda) `plan()`;
  oscillation findings come from [G4](#g4-self-protection-f1-f7).

### G6. Storage, retention, and self-maintenance

- **Responsibility:** Bound the govern side's worst-case footprint and keep its own catalog
  clean: prune the append-only audit tables by time cutoff, report whole-governor storage
  against an operator budget, and shed storage gracefully under pressure.
- **Role:** The govern-side storage surface; it sits atop observe's primitives (reads observe
  cross-schema, never the reverse) and mirrors observe's self-monitoring at the whole-system
  level.
- **Objects:** `retain()` prunes the append-only audit tables (`decision_log`,
  `action_history`, `tick_log`, resolved `diagnostics`, `state_transitions`) by **time
  cutoff** — acceptable because they are low-volume, unlike observe's high-volume partition
  rotation — while `policy_history` is kept indefinitely. `storage_config` holds the
  total-bytes budget; `storage_budget()` reports usage; the `self_health` view is the one-row
  summary (with an `over_budget` flag); `degrade()` is the graceful prune order under pressure
  (raw → fine → coarse rollups → diagnostics → actions; policy never pruned), reading observe's
  storage bytes cross-schema. Govern's own state/audit tables carry static autovacuum
  reloptions because they are mutated in place and accrue dead tuples — distinct from observe's
  zero-bloat rotation. See the [reference](../reference/pgfc_govern.md) and
  [source](../../pgfc_govern/install.sql).
- **Consumers / cross-links:** the F1/F2 self-protection path reads `self_health`
  (`storage_bytes`, `over_budget`) as the storage signal feeding the health-state machine
  ([G4](#g4-self-protection-f1-f7)); mirrors observe's
  [O4](#o4-self-monitoring-and-budget); prunes the audit tables written by
  [G1](#g1-control-loop-ooda).
- **Feedback wanted:** is time-cutoff `DELETE` pruning (rather than partition rotation) the
  right call for these audit tables given the project's bloat-free thesis (cf. FMEA-001 for
  observe)? Is the `degrade()` prune order — raw telemetry before resolved diagnostics before
  actions — the correct precedence under storage pressure?
- ↑ [pgfc_govern](#42-pgfc_govern) · → mirrors observe's
  [O4](#o4-self-monitoring-and-budget); prunes [G1](#g1-control-loop-ooda) audit tables.

### G7. Status and reporting

- **Responsibility:** Expose operator-facing rollups of what the governor sees and would do:
  `governor_status` summarizes, per relation, the workload class, observed and target
  dead-tuple fraction, debt, last decision, proposed value, applied flag, and current scale
  factor; `catalog_health` rolls up catalog-mutation health (the governor's own applied/failed
  DDL counts over 1h/1d windows) against live `pg_class` state.
- **Role:** Read-only reporting surfaces at the edge of the schema — they present governor
  state, they do not feed it; neither is a control input.
- **Objects:** `governor_status` (view), `catalog_health` (view). See the
  [reference](../reference/pgfc_govern.md) and [source](../../pgfc_govern/install.sql).
- **Consumers / cross-links:** consumed by operators and dashboards; `catalog_health` reads
  `pgfc_observe` cross-schema for the live `pg_class` columns — the one outward dependency
  here.
- **Feedback wanted:** do these views give operators enough to trust and audit the governor's
  per-relation decisions, or are key columns missing? Is `catalog_health`'s cross-schema read
  acceptable here, or should that catalog-state rollup live in `pgfc_observe`?
- ↑ [pgfc_govern](#42-pgfc_govern) · → `catalog_health` reads observe cross-schema.

## 6. Components and code (the leaf level)

The finest level is **not written by hand here** — it is the generated reference plus the
source, linked so it cannot drift:

- Per-object documentation: [`pgfc_observe` reference](../reference/pgfc_observe.md),
  [`pgfc_govern` reference](../reference/pgfc_govern.md) (generated from `COMMENT ON` and
  the catalog; CI fails on staleness).
- Source: [`pgfc_observe/install.sql`](../../pgfc_observe/install.sql),
  [`pgfc_govern/install.sql`](../../pgfc_govern/install.sql).

**Bottom-up navigation:** the [subsystem map](../reference/subsystem-map.md) lets you crawl
up from any object to its **home subsystem** (an up-link to [§5](#5-subsystems)) and across
to its **siblings** (the other members of that subsystem). It is generated from a subsystem
tag in each object's `COMMENT ON`, under the same staleness gate as the reference, so it
cannot drift. Consumer / cross-edges are not catalog-derivable and stay hand-authored in
[§5](#5-subsystems); see [§8](#8-how-this-rfc-is-maintained) for the tag convention and gates.

## 7. Open questions / feedback wanted

The point of the RFC. Aggregated here, and surfaced per-subsystem in [§5](#5-subsystems).

- **FMEA-001 — partition recycling: create/drop vs. a fixed `TRUNCATE` ring**
  ([O2](#o2-storage-and-retention),
  [detail](../fortification/02-failure-theory.md#fmea-001--partition-recycling-uses-createdrop-not-a-fixed-truncate-ring)).

**From the first external review** (recorded against the
[Phase 1 finding schema](../fortification/01-security-correctness-apply.md#findings)):

- **COR-001 — the ownership guard conflates governor-set with user-set.** `plan()` derives
  "user-owned" from live reloptions without consulting `actuator_state`, so the governor
  cannot tell its own prior actuation from a human's. The consequence: continuous control
  (§1) and "never overwrite a human's setting" (§2.4) are mutually exclusive in the shipped
  code. *(High;
  [detail](../fortification/01-security-correctness-apply.md#cor-001--the-ownership-guard-conflates-set-by-the-governor-with-set-by-a-user).)*
- **SEC-001 / SEC-002 / COR-002** — defense-in-depth dispositions of the `apply()` path
  (privilege/role model + `search_path`, the `v_prop` interpolation, the authority gate's
  state freshness); all Low under the `SECURITY INVOKER` trust model. *(See the
  [Phase 1 findings](../fortification/01-security-correctness-apply.md#findings).)*

**Strategic questions the RFC does not yet confront** (raised by the review; answers wanted):

- **Is the scale factor the right control surface, and how often is it the binding
  constraint?** The one knob the governor turns changes only *when* autovacuum fires — not
  how fast (cost limits) nor whether it may run. The RFC concedes (§2.5,
  [G5](#g5-diagnostics)) that `io_limited` and `inhibited` tables cannot be helped by it. So
  in what fraction of real bloat incidents is the scale factor actually the limiting factor,
  rather than an inhibitor, an I/O ceiling, or `cost_limit`/`cost_delay`? If most are the
  latter, the system's real output is its diagnostics, and the RFC should say so.
- **What end-to-end evidence is there that *active control* helps?** Advisory-by-default
  (§3.4) plus the verify no-op ([§3.2](#32-the-control-loop-and-its-two-cadences)) means the
  act path is off by default *and* unvalidated in closed loop when on. Is there a backtest,
  simulation, or worked case showing actuation improves outcomes without harm — or is "act"
  currently asserted rather than demonstrated?
- **Until `verify()` attributes outcomes, how is the control law's convergence/stability
  established?** §1 and the concepts lean on control theory and state estimation, but the
  component that would measure whether actions achieve their predicted effect is a stub. What
  evidence supports the convergence claim today?

## 8. How this RFC is maintained

The locked methodology decisions:

- **Single authored document, generated leaves.** This file is the narrative spine
  (sections 1–5); the per-object leaf level links to the generated reference and code
  rather than duplicating them.
- **Bottom-up navigation is generated.** Subsystem membership is recorded in each object's
  `COMMENT ON` as a trailing `[subsystem:<ID>]` marker (`<ID>` is `O1`-`O5` or `G1`-`G7`).
  Two CI gates keep this honest: an **exhaustiveness** gate (pgTAP) fails if any in-scope
  object lacks exactly one valid marker, and a **staleness** gate
  (`Subsystem map up to date`) regenerates the [subsystem map](../reference/subsystem-map.md)
  and fails on any diff. The up-link and siblings are generated from the marker; consumer
  edges remain hand-authored in [§5](#5-subsystems). The full convention and build history
  are in the [navigation tooling plan](navigation-tooling-plan.md).
- **Home:** `docs/rfc/` in-repo; a GitHub Discussion is the intended line-by-line
  commenting surface for reviewers.

## 9. Relationship to other documents

- **Original design document** — frozen design *intent*; may diverge from the build. This
  RFC is the as-built counterpart. (Not linked, by the project's no-backward-reference
  convention.)
- **User guides** — [getting started](../guide/getting-started.md),
  [concepts](../guide/concepts.md), [operating](../guide/operating.md): operator-facing;
  this RFC links down to them.
- **Reference** — [observe](../reference/pgfc_observe.md),
  [govern](../reference/pgfc_govern.md): the generated leaf level.
- **Fortification** — [the review](../fortification/README.md): the RFC is the artifact
  handed to reviewers; fortification findings and open questions feed [§7](#7-open-questions--feedback-wanted).
