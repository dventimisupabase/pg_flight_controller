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

> **Outline status.** Sections 1–4 are skeletons to be written. Section 5 (subsystems) is
> seeded from the confirmed object taxonomy — every database object has a home — but the
> per-subsystem prose, rationale, and "feedback wanted" are still to be filled. Sections
> 6–9 describe conventions now and fill in as the body lands.

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

*(To write.)* One paragraph: what pg_flight_controller is — a supervisory autovacuum
governor that treats per-table autovacuum settings as **actuator positions** and steers
them toward policy *outcomes* — why it exists (static autovacuum config drifts out of
appropriateness as workloads change), and how it works at a glance (observe → estimate →
decide → act, advisory by default). Seed: the top-level README abstract.

↳ Refine into [concepts](#2-concepts-and-principles).

## 2. Concepts and principles

*(Outline.)* The mental model a reviewer needs before the architecture. Frame *why each
concept matters to a reviewer*; link down to the [concepts guide](../guide/concepts.md) for
the full as-built explanation rather than restating it.

- Autovacuum settings as **actuator positions**, not static configuration.
- The **observe → estimate → decide → act** (OODA) loop; **advisory by default**.
- **Diagnose, don't escalate** — saturation causes, external inhibitors, removability
  horizons.
- The **safety invariants (1–6)** and why an autonomous actuator needs an explicit theory
  of failure.

↑ [Abstract](#1-abstract) · ↳ [Architecture](#3-architecture)

## 3. Architecture

*(Outline.)* The shape of the system:

- **Two modules**, split by role: `pgfc_observe` (Observe + Orient, read-only) and
  `pgfc_govern` (Decide + Act). The boundary — govern reads observe cross-schema and never
  writes it.
- The **two cadences**: a fast observe loop and a slower control loop, and why observing
  often does not mean acting often.
- **Cross-cutting patterns** worth naming once: a parameter registry, a storage /
  self-maintenance subsystem, and a `self_health` surface appear in *both* modules
  (mirrored — distinct objects, same role).
- Where **active control** and the **self-protection net** sit relative to the loop.

↑ [Concepts](#2-concepts-and-principles) · ↳ [Modules](#4-modules)

## 4. Modules

### 4.1 pgfc_observe

*(Outline.)* Read-only telemetry: observe the database, store it bloat-free, derive
meaning, and watch its own footprint — independently useful as a monitor. Subsystems:
[O1](#o1-collection), [O2](#o2-storage-and-retention), [O3](#o3-derived-state-and-readers),
[O4](#o4-self-monitoring-and-budget), [O5](#o5-parameter-registry).

↑ [Architecture](#3-architecture) · ↳ [Subsystems](#5-subsystems)

### 4.2 pgfc_govern

*(Outline.)* The control loop — classify, estimate, plan, apply, verify — advisory by
default, active control under a self-protection net. Depends on `pgfc_observe`. Subsystems:
[G1](#g1-control-loop-ooda) through [G7](#g7-status-and-reporting).

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
