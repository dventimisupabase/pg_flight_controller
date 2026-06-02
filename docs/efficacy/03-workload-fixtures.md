# Phase 3 — Workload fixtures

**Status:** Not started · *(stub — fleshed out when reached)*

A representative schema plus a workload driver for each of pg_flight_controller's six
workload classes, each with a **stationary** and a **non-stationary (drift)** variant. Build
order stresses the extremes first: `queue` / `delete_heavy` (high churn, tight 0.05 / 0.10
targets) and `append_only` / `archive` (drift between insert-only and periodic purge); then
`oltp` / `mixed`.

Ground the fixtures in the classifier's *actual* signals so each table really lands in its
intended class: insert fraction, delete fraction, queue balance (insert ≈ delete churn), and
large-and-idle → `archive`. A fixture that does not classify as its target class is a bug in
the fixture.

To be filled, per class:

- **Schema** — table shape (width, indexes) representative of the class.
- **Stationary driver** — the steady churn signature (pgbench script or thin custom driver;
  see [Phase 5](05-harness-and-tooling.md)).
- **Drift variant** — the shift (rate, mix, or class transition) that makes a `t0`-correct
  tuning go wrong over time — the input to the headline scenario.
- **Classification check** — assert the table is assigned its intended `relation_kind`.
- `FIX-NNN` findings for any class that resists faithful synthesis.

## Exit criteria

- Each prioritized class has a schema, a stationary driver, and a drift variant.
- Each fixture verifiably classifies as its intended class.
- Drivers are reproducible (seeded, parameterized).
