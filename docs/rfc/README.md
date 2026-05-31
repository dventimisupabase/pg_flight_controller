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

> **Outline status.** Sections 1–4 are drafted. Section 5 (subsystems) is seeded from the
> confirmed object taxonomy — every database object has a home — but the per-subsystem prose,
> rationale, and "feedback wanted" are still to be filled. Sections 6–9 describe conventions
> now and fill in as the body lands.

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

The loop is the OODA cycle — **observe → orient → decide → act** — closed by a verify step.
It runs as **two independent cadences**, not one:

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

- **Responsibility:** take observations — sample autovacuum-relevant state, sparsely.
- **Objects:** `observe()`, `collection_policy`, `relation_last_state` (UNLOGGED change
  cache).
- **Feedback wanted:** *(tbd — e.g. sparse-logging change-detection correctness; crash
  rebuild of `relation_last_state`.)*
- ↑ [pgfc_observe](#41-pgfc_observe) · → writes the raw tables owned by
  [O2](#o2-storage-and-retention).

### O2. Storage and retention

- **Responsibility:** bounded, bloat-free persistence — partitioned raw tables, rollups,
  GC, and the extension's own table maintenance. *(Home of finding FMEA-001.)*
- **Objects:** `relation_samples`, `snapshots`, `rollup_1m`/`rollup_1h`/`rollup_1d`;
  `_ensure_partition`, `_partition_inventory`, `_epoch_day`/`_epoch_month`/`_month_start`,
  `retain`, `drop_empty_partitions`, `rollup`, `rollup_retain`, `_rollup_coarsen`,
  `_rollup_inventory`, `current_rollup`, `_telemetry_reloptions`.
- **Feedback wanted:** the partition-recycling strategy — see
  [FMEA-001](../fortification/02-failure-theory.md#fmea-001--partition-recycling-uses-createdrop-not-a-fixed-truncate-ring)
  (create/drop vs. a fixed `TRUNCATE` ring).
- ↑ [pgfc_observe](#41-pgfc_observe) · → read by [O3](#o3-derived-state-and-readers).

### O3. Derived state and readers

- **Responsibility:** turn raw, sparse telemetry into meaning (Orient).
- **Objects:** `relation_health`, `maintenance_debt`; `current_relation_state`,
  `removability_horizons`, `effective_reloption`.
- **Feedback wanted:** *(tbd.)*
- ↑ [pgfc_observe](#41-pgfc_observe) · → `effective_reloption` is also consumed cross-module
  by [G1](#g1-control-loop-ooda).

### O4. Self-monitoring and budget

- **Responsibility:** the extension watching its own storage footprint.
- **Objects:** `self_health`, `storage_budget`.
- **Feedback wanted:** *(tbd.)*
- ↑ [pgfc_observe](#41-pgfc_observe) · → mirrors govern's [G6](#g6-storage-retention-and-self-maintenance).

### O5. Parameter registry

- **Responsibility:** the observe-side typed parameter registry.
- **Objects:** `_parameter_registry`.
- **Feedback wanted:** *(tbd.)*
- ↑ [pgfc_observe](#41-pgfc_observe) · → mirrors govern's [G3](#g3-parameter-governance).

### G1. Control loop (OODA)

- **Responsibility:** the heart — orchestrate the two cadences and run classify → estimate
  → plan → apply → verify. Refines into six components.
- **Components and objects:**
  - **Orchestration:** `observe_tick`, `control_tick`, `tick_log`.
  - **Classify:** `classify`, `relation_class`, `relation_kind`, `_class_target`.
  - **Estimate:** `estimate`, `relation_estimate`, `ewma`.
  - **Plan / Decide:** `plan`, `decision_log`, `snap_sf`, `_sf_grid`.
  - **Apply / Act:** `apply`, `actuator_state`, `action_history`, `batch_seq`. *(Subject of
    fortification Phase 1.)*
  - **Verify:** `verify`.
- **Feedback wanted:** *(tbd — e.g. the `apply()` path; see
  [Phase 1](../fortification/01-security-correctness-apply.md).)*
- ↑ [pgfc_govern](#42-pgfc_govern) · → gated by [G4](#g4-self-protection-f1-f7); reads
  observe [O3](#o3-derived-state-and-readers); `action_history` is consumed by
  [G4](#g4-self-protection-f1-f7) and [G6](#g6-storage-retention-and-self-maintenance).

### G2. Policy and intent

- **Responsibility:** operator intent as outcomes, with an audited history.
- **Objects:** `policy`, `policy_history`, `_log_policy_change`.
- **Feedback wanted:** *(tbd.)*
- ↑ [pgfc_govern](#42-pgfc_govern) · → read by [G1](#g1-control-loop-ooda).

### G3. Parameter governance

- **Responsibility:** the typed parameter registry, provenance, the inline-literal **drift
  gate**, and validation.
- **Objects:** `parameter_registry`, `_parameter_registry`, `_param`,
  `_audit_control_literals`, `validate_parameters`.
- **Feedback wanted:** *(tbd.)*
- ↑ [pgfc_govern](#42-pgfc_govern) · → mirrors observe's [O5](#o5-parameter-registry);
  consumed by nearly every control function via `_param`.

### G4. Self-protection (F1-F7)

- **Responsibility:** the governor governing itself before it governs PostgreSQL — health
  state, circuit breakers, authority limiting, oscillation detection, load shedding,
  failure taxonomy.
- **Objects:** `governor_state`, `state_transitions`, `governor_health_state`,
  `governor_metrics`, `evaluate_health`, `force_state`, `clear_forced_state`, `disable`,
  `suspend_actuation`, `_oscillating_relations`, `_reconcile_oscillation`, `_failure_class`,
  `failure_taxonomy`.
- **Feedback wanted:** *(tbd.)*
- ↑ [pgfc_govern](#42-pgfc_govern) · → gates the [G1](#g1-control-loop-ooda) apply path;
  reads `action_history`.

### G5. Diagnostics

- **Responsibility:** diagnose saturation and external inhibitors rather than escalate.
- **Objects:** `diagnostics`, `active_diagnostics`, `_findings`, `_reconcile_diagnostics`.
- **Feedback wanted:** *(tbd.)*
- ↑ [pgfc_govern](#42-pgfc_govern) · → fed by [G1](#g1-control-loop-ooda) `plan()`;
  oscillation findings come from [G4](#g4-self-protection-f1-f7).

### G6. Storage, retention, and self-maintenance

- **Responsibility:** bound the govern-side audit tables and the storage budget; graceful
  degrade.
- **Objects:** `storage_config`, `storage_budget`, `self_health`, `retain`, `degrade`.
- **Feedback wanted:** *(tbd.)*
- ↑ [pgfc_govern](#42-pgfc_govern) · → mirrors observe's
  [O4](#o4-self-monitoring-and-budget); prunes [G1](#g1-control-loop-ooda) audit tables.

### G7. Status and reporting

- **Responsibility:** operator-facing rollups of governor and catalog health.
- **Objects:** `governor_status`, `catalog_health`.
- **Feedback wanted:** *(tbd.)*
- ↑ [pgfc_govern](#42-pgfc_govern) · → `catalog_health` reads observe cross-schema.

## 6. Components and code (the leaf level)

The finest level is **not written by hand here** — it is the generated reference plus the
source, linked so it cannot drift:

- Per-object documentation: [`pgfc_observe` reference](../reference/pgfc_observe.md),
  [`pgfc_govern` reference](../reference/pgfc_govern.md) (generated from `COMMENT ON` and
  the catalog; CI fails on staleness).
- Source: [`pgfc_observe/install.sql`](../../pgfc_observe/install.sql),
  [`pgfc_govern/install.sql`](../../pgfc_govern/install.sql).

**Bottom-up navigation (to build):** each object's reference entry will carry its **home
subsystem** (an up-link) and its **siblings/consumers**, generated from a subsystem tag in
the object's metadata — so "crawl up from any function" stays honest under the same
staleness gate as the reference. See [§8](#8-how-this-rfc-is-maintained).

## 7. Open questions / feedback wanted

The point of the RFC. Aggregated here, and surfaced per-subsystem in [§5](#5-subsystems).

- **FMEA-001 — partition recycling: create/drop vs. a fixed `TRUNCATE` ring**
  ([O2](#o2-storage-and-retention),
  [detail](../fortification/02-failure-theory.md#fmea-001--partition-recycling-uses-createdrop-not-a-fixed-truncate-ring)).
- *(More to come as subsystem sections and the fortification phases produce them.)*

## 8. How this RFC is maintained

The locked methodology decisions:

- **Single authored document, generated leaves.** This file is the narrative spine
  (sections 1–5); the per-object leaf level links to the generated reference and code
  rather than duplicating them.
- **Bottom-up navigation is generated.** Subsystem membership is recorded in object
  metadata; the up/sibling/consumer links are generated and CI-gated for staleness, like
  the reference.
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
