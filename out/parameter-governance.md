# pg_flight_controller — Parameter Governance (Design)

**Status: design intent, not the as-built spec.** This is the `out/` waystation that
transforms the intent in `in/appendix_e.md` into a concrete, implementable design. Like
`out/technical-design.md`, it is a one-way input to the implementation: once the design
lands, the as-built spec lives in `docs/` and the code, and *those* may drift from this
document. This doc is frozen at that point and is never referenced backward from the
project. It is a companion to the Phase I design, deliberately kept as its own file so
the frozen Phase I narrative is not reopened.

**Lineage.** The configuration mechanism is adapted from the author's `pg_flight_recorder`,
which already ships a working parameter system: a canonical `_profile_settings()` `VALUES`
function as the single source of truth, a `pgfr_record.config` key-value table for runtime
values, a `_get_config(key, default)` getter, and a `validate_config()` health check that
grades settings `OK`/`WARNING`/`CRITICAL`. We adopt that proven shape and add the
provenance metadata appendix E requires.

---

## Purpose

`in/appendix_e.md` asks for a **parameter provenance discipline**: the governor exists to
replace static autovacuum folklore with an observable control framework, and it must not
recreate that folklore *internally*. The governor may contain constants; it may not
contain **unexplained** constants. Every governed value must have a name, meaning, unit,
rationale, owner, and provenance, and must be inspectable without reading source code.

The appendix prescribes the *discipline*, not the *implementation* ("The implementation is
not prescribed. The discipline is prescribed."). This document chooses the implementation.

## Scope boundary

In scope: a queryable **parameter registry** with provenance metadata and change history,
categorisation of every governed constant, operator-visible inspection and validation,
and — the load-bearing part — a mechanism that keeps the registry and the code from
drifting apart. Out of scope: turning every literal into a runtime-loaded setting
(appendix E never asks for that, and it would tax hot functions like `plan()` and
`classify()`).

---

## The constants we have today (honest inventory)

The starting point is the truth, not an aspiration. Provenance below is recorded as it
**actually is** — most "empirical" values are unbenchmarked MVP estimates, and saying so
is the point: it produces a validation backlog.

### Category 2 — Safety bound

| Constant | Where | Value | Unit | Provenance (honest) |
|---|---|---|---|---|
| `sf_min` | `plan()` | 0.01 | fraction | safety analysis — floor of the actuator range |
| `sf_max` | `plan()` | 0.50 | fraction | safety analysis — ceiling of the actuator range |
| `freeze_thr` | `plan()`, `_findings()`, `governor_status` | 0.6 | fraction of wraparound | safety analysis — when the freeze floor overrides |
| `lock_timeout` | `apply()` | 100 | ms | safety analysis — never block on actuation |
| `daily_mutation_budget` | `policy` | 500 | changes/day | design review (also operator policy) |
| `global_max_changes_per_cycle` | `policy` | 50 | changes/cycle | design review (also operator policy) |
| `min_interval` | `policy` | 1 | hour | design review (also operator policy) |

### Category 3 — Empirical default

| Constant | Where | Value | Unit | Provenance (honest) |
|---|---|---|---|---|
| observe cadence | `pg_cron` | 1 | min | MVP initial estimate, not yet benchmarked |
| control cadence | `pg_cron` | 5 | min | MVP initial estimate, not yet benchmarked |
| `tau` (rate EWMA) | `estimate()` | 3600 | s | MVP initial estimate, not yet benchmarked |
| `effa` (effectiveness EWMA weight) | `estimate()` | 0.5 | weight | MVP initial estimate, not yet benchmarked |
| `k` (saturation persistence) | `estimate()` | 3 | cycles | MVP initial estimate, not yet benchmarked |
| `n_sustain` (class persistence) | `policy`/`classify()` | 3 | cycles | MVP initial estimate, not yet benchmarked |
| classify `floor` | `classify()` | 50 | writes | MVP initial estimate, not yet benchmarked |
| classify `large` | `classify()` | 100000 | rows | MVP initial estimate, not yet benchmarked |
| classify fraction thresholds | `classify()` | 0.95 / 0.30 / 0.10 / 0.01 | fraction | MVP initial estimate, not yet benchmarked |
| `eff_low` | `estimate()` | 0.5 | fraction | MVP initial estimate, not yet benchmarked |
| class targets | `plan()`, `governor_status` | queue 0.05 … archive 0.50 | fraction | MVP initial estimate, not yet benchmarked |
| `SF_GRID` | `snap_sf()` | {0.01,0.02,0.05,0.10,0.20,0.30,0.50} | fraction | MVP initial estimate, not yet benchmarked |

### Category 4 — Operator policy (already configuration, not literals)

`policy` (`aggressiveness`, `freeze_posture`, `manage_user_owned`, `advisory_only`, and the
three economy knobs above), `storage_config.budget_bytes`, `collection_policy`
(`exclude_temp`, `excluded_schemas`, `min_partition_size_bytes`, …), and the retention
windows that are overridable function arguments (`retain`, `rollup_retain`, `degrade`,
govern `retain`). These are already "configuration over code." The registry **describes**
them and points at their config home; it does not duplicate their storage.

### Category 1 — PostgreSQL-derived

`86400` (s/day) and the `1970` epoch base (calendar math); the wraparound denominators
(`autovacuum_freeze_max_age`, `autovacuum_multixact_freeze_max_age`) which are **read live
from the GUCs**, not embedded — already correct.

### Category 5 — Adaptive value

The per-relation scale-factor target (`sf_target`) and the relation estimates — computed by
the control logic, already recorded in `decision_log` / `action_history` with the
triggering observation and policy rule.

### Category 6 — Implementation convenience

The static reloptions thresholds (`_telemetry_reloptions` = 1000, govern audit/state = 200,
`relation_last_state` = 50), `fillfactor = 70`, and the `rollup()` lookback default
(`'3 days'`). Appendix E says these "should be minimized and documented."

---

## What governance yields immediately: a worked example

Provenance discipline pays off before any table exists. Two separate constants both equal
3 and both mean "persist for N cycles": `k` (a saturation *cause* must hold for 3 cycles
before `estimate()` commits it) and `n_sustain` (a candidate *class* must hold for 3
cycles before `classify()` commits it). The discipline forces the question the code never
asked: **same concept (consolidate to one parameter) or coincidentally equal (two
parameters, independently tunable)?** They are arguably the same hysteresis idea applied
to two state machines. **Decision:** keep two — they govern different state machines — but
give them a shared, explicit rationale rather than a coincidental `3`. This is the
folklore-elimination appendix E is after.

---

## Design (decided)

Three decisions were taken up front; the design below reflects them.

- **Enforcement reach: full.** Every Category 2 and 3 control literal is single-sourced and
  covered by the CI gate (not just a hand-picked "core").
- **Registry scope: document all.** Every governed constant — all six categories,
  including Cat 1 calendar math and Cat 6 reloptions thresholds — gets a registry entry for
  complete inspection. The CI gate enforces the control literals (Cat 2/3); Cat 1/6 are
  documented but not single-sourced where doing so adds no safety.
- **Sequencing: standalone increment before Phase 2.** Build the registry + enforcement
  first, so every new Phase 2 constant (cost-limit bounds, rate-limit enforcement, the
  threshold lever, the analyze objective) is *born governed* — it cannot be added without a
  registry entry, because the gate fails otherwise. This also surfaces the
  "not-yet-benchmarked" validation backlog before active control relies on those values.

### The canonical registry (single source of truth)

Per schema, a `VALUES`-returning function — `pgfc_observe._parameter_registry()` and
`pgfc_govern._parameter_registry()` — is the **one** definition of every governed constant,
exactly the `pg_flight_recorder._profile_settings()` pattern. Each row carries appendix E's
provenance fields, with **category and configurability kept orthogonal**:

| Field | Meaning |
|---|---|
| `parameter_name` | unique key |
| `category` | one of the six (Cat 1–6) — *what kind of value* |
| `default_value` | the canonical value, as text |
| `unit` | e.g. `fraction`, `ms`, `cycles`, `rows` |
| `rationale` | why it exists / why this value |
| `source` | provenance (e.g. `safety analysis`, `MVP estimate — not yet benchmarked`) |
| `owner` | who owns the value |
| `override_allowed` | boolean — *can an operator change it* (independent of category) |
| `config_ref` | where it is tunable, e.g. `policy.aggressiveness`; `NULL` for a fixed literal |

`pgfc_observe` keeps its own function so it stays independently installable; a unified
`pgfc_govern.parameter_registry` **view** unions both into one queryable surface (the
`storage_budget()` layering precedent — already decided, not relitigated here).

### Reading constants through the single source

The control logic reads its Category 2/3 constants **from** `_parameter_registry()` so code
and registry cannot disagree by construction:

- Scalars (`sf_min`, `sf_max`, `freeze_thr`, `tau`, `effa`, `k`, `floor`, `large`,
  `eff_low`, the classify fraction thresholds) come from a thin `IMMUTABLE`
  `_param(name)` accessor that selects `default_value` from the registry function — the
  planner can fold it, so there is no hot-path cost.
- Set-valued constants (`SF_GRID`, the class→target map) move into their own canonical
  `IMMUTABLE` functions (`_sf_grid()`, `_class_target(kind)`); `snap_sf()`, `plan()`, and
  `governor_status` call those instead of re-listing literals. This also removes the
  existing duplication of the class targets and `freeze_thr` across `plan()`,
  `_findings()`, and `governor_status`.

### Operator overrides and effective value

For `override_allowed` parameters the effective value is `COALESCE(operator value,
registry default)`, read through a `_get_config(name, default)` getter — the
`pg_flight_recorder` pattern. Two override homes, no new storage where it already exists:

- Values already in a **typed config table** (`policy`, `storage_config`,
  `collection_policy`) keep that home; `config_ref` points at the column and the registry
  view reads the live value from it.
- A small key-value `parameter_override(name, value, updated_at)` table backs any
  *future* control literal we choose to make tunable without adding a typed column. It is
  empty at install (everything runs on canonical defaults) and is the only mutable runtime
  surface, so it is the only thing needing change-history.

### Inspection and validation

- `parameter_registry` (view): the unified registry joined to effective values — one row
  per parameter with category, default, effective value, whether overridden, and full
  provenance. This is the "inspect without reading source" surface (MVP req 5) and feeds
  `docs/reference` generation (MVP req 7).
- `validate_parameters()`: the `validate_config()` pattern — returns
  `(parameter, status, message)` graded `OK`/`WARNING`/`CRITICAL`, checking overrides
  against the safety bounds the registry knows (e.g. an override that drives a scale factor
  outside `[sf_min, sf_max]`, or a `min_interval` below a safe floor).

### Change history

Reuse, don't reinvent. Operator policy changes already flow through `policy_history`
(AFTER-trigger pattern); adaptive (Cat 5) changes already flow through `action_history` /
`decision_log`. The new `parameter_override` table gets the *same* trigger pattern. The
canonical defaults live in the `_parameter_registry()` function — i.e. in code — so changes
to a default are code changes whose provenance is git history + PR review, enforced by the
gate below. The one real gap against appendix E's "Adaptive Parameters" list is
`estimated_benefit`, which `decision_log` does not record; flag it as a follow-up, not part
of this increment.

---

## The load-bearing mechanism: keeping the registry honest

A registry that *can* disagree with the code recreates appendix E's disease one level up.
Two patterns, both already proven in these repos, make the registry **governance** rather
than a spreadsheet:

1. **Single source of truth.** The `_parameter_registry()` / `_sf_grid()` /
   `_class_target()` functions are the only definition; control logic reads them. This is
   `pg_flight_recorder._profile_settings()` and our own `_telemetry_reloptions()` (S6),
   applied to every Cat 2/3 constant (the "full" decision).
2. **A "registry up to date" CI gate** (the `gen-reference.sh` / "Reference up to date"
   pattern). A check that fails the build when a governed control-logic literal exists with
   **no** registry entry, or when an entry disagrees with the live single-source value.
   This is what turns appendix E's **MVP requirement #6 ("elimination of undocumented
   literals in control logic")** from a hope into an enforced invariant — and it is what
   forces every future Phase 2 constant to arrive with provenance.

---

## MVP requirement coverage (appendix E §"MVP Requirements")

| # | Requirement | This design |
|---|---|---|
| 1 | Parameter registry | `_parameter_registry()` per schema + unified `parameter_registry` view |
| 2 | Parameter categories | the six categories, on every row |
| 3 | Provenance metadata | `rationale` / `source` / `owner` / `unit` / `default_value` |
| 4 | Change history | `parameter_override` trigger + existing `policy_history` / `action_history`; defaults via git |
| 5 | Operator-visible inspection | the unified view + `validate_parameters()` |
| 6 | Eliminate undocumented literals in control logic | **single source + CI gate** (full reach) |
| 7 | Documentation for every configurable value | registry rows render into `docs/reference` generation |

---

## Implementation increments (proposed)

A standalone phase ("Phase 1.6 — Parameter governance"), sequenced before Phase 2:

- **P1 — Registry + inventory.** `_parameter_registry()` in both schemas populated from the
  honest inventory above; the unified view; `docs/` + reference coverage. (Reading-only;
  no behaviour change.)
- **P2 — Single-source the control constants.** Introduce `_sf_grid()`,
  `_class_target()`, and the `_param()` accessor; refactor `snap_sf()`, `plan()`,
  `classify()`, `estimate()`, `governor_status`, `_findings()` to read from them; resolve
  the `k`/`n_sustain` rationale and the class-target/`freeze_thr` duplication. Behaviour
  identical — pure de-duplication, guarded by the existing pgTAP suite.
- **P3 — The CI gate.** The "registry up to date" check; wire it into CI as a required gate
  alongside "Reference up to date".
- **P4 — Override + validation surface.** `parameter_override` + `_get_config()` getter +
  `validate_parameters()`; promote a constant to tunable only on demonstrated need.

Each increment is a separate PR through the existing gates, per the project's working
style. Profiles (`pg_flight_recorder`'s `apply_profile`/`list_profiles`) are noted as an
available pattern but deferred — appendix E does not require them, and `policy`
(`aggressiveness`, `freeze_posture`) already covers preset-like intent.
