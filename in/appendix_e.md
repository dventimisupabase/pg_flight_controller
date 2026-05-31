# Appendix E: Parameter Provenance and Configuration Governance

## Purpose

This appendix establishes a parameter provenance discipline for the Autovacuum Governor.

The governor exists in part to replace static autovacuum folklore and undocumented tuning heuristics with a more systematic and observable control framework.

The governor must not recreate the same problem internally.

Any constant, threshold, interval, limit, ratio, budget, or control value used by the governor shall be treated as a governed parameter with known provenance.

Undocumented magic numbers are prohibited.

---

# Core Principle

The governor may contain constants.

The governor may not contain unexplained constants.

Every parameter must have:

* a name
* a meaning
* a unit
* a rationale
* an owner
* a provenance

---

# Problem Statement

Traditional PostgreSQL tuning often relies on values whose origin is unclear.

Examples:

```text
autovacuum_vacuum_scale_factor = 0.05
autovacuum_max_workers = 10
autovacuum_vacuum_cost_limit = 2000
```

These values may have originated from:

* documentation
* community guidance
* operator experience
* production incidents
* historical cargo culting

The provenance is frequently lost.

The governor must not repeat this pattern.

---

# Parameter Categories

Every governor parameter shall be assigned a category.

---

## Category 1: PostgreSQL-Derived

Values originating from PostgreSQL behavior or documented constraints.

Examples:

```text
freeze horizons
xid limits
worker constraints
```

Source:

* PostgreSQL documentation
* PostgreSQL source code
* PostgreSQL release notes

---

## Category 2: Safety Bound

Values intended to prevent unsafe operation.

Examples:

```text
maximum actuator changes per hour
maximum lock timeout
minimum observation interval
```

Source:

* safety analysis
* operational experience
* design review

---

## Category 3: Empirical Default

Values selected based on observed behavior.

Examples:

```text
1 minute observation loop
5 minute control loop
72 hour raw observation retention
```

Source:

* testing
* benchmarking
* operational feedback

---

## Category 4: Operator Policy

Values intentionally selected by an operator.

Examples:

```text
maintenance IO budget
retention duration
latency preference
storage efficiency preference
```

Source:

* human decision

---

## Category 5: Adaptive Value

Values computed dynamically by the governor.

Examples:

```text
relation-specific scale factor
relation-specific threshold
relation-specific cost limit
```

Source:

* governor state estimation
* control logic

---

## Category 6: Implementation Convenience

Values that exist solely because of implementation details.

Examples:

```text
batch sizes
pagination limits
background worker chunk sizes
```

These should be minimized and documented.

---

# Parameter Registry

The governor shall maintain a parameter registry.

Recommended fields:

```text
parameter_name
category
value
unit
default_value
rationale
source
owner
override_allowed
last_modified
last_reviewed
```

The registry should be queryable.

---

# Configuration Over Code

Parameters should be stored as configuration rather than embedded literals.

Avoid:

```python
CONTROL_INTERVAL = 300
```

Prefer:

```text
governor.control_interval_seconds
```

loaded from a governed configuration source.

Possible implementations:

* PostgreSQL tables
* extension configuration
* configuration files
* external control plane

The implementation is not prescribed.

The discipline is prescribed.

---

# Provenance Requirements

Every parameter must answer:

```text
What is this?

Why does it exist?

Why is this value chosen?

Who chose it?

Can it be overridden?

When was it last reviewed?
```

If these questions cannot be answered, the parameter lacks sufficient provenance.

---

# Reviewability

The governor shall expose parameter provenance through views or reports.

Example:

```text
parameter:
  control_interval_seconds

value:
  300

category:
  empirical_default

rationale:
  provides sufficient responsiveness while limiting
  unnecessary planning activity

source:
  initial MVP design

last_reviewed:
  2026-05-30
```

Parameter values should be inspectable without reading source code.

---

# Parameter Evolution

Parameters are expected to evolve.

The governor must record:

* previous value
* new value
* change reason
* timestamp
* change source

This applies to:

* operator changes
* software upgrades
* governor-generated updates

---

# Adaptive Parameters

Adaptive parameters require special handling.

Example:

```text
relation-specific scale factor
```

The governor should record:

* previous value
* new value
* triggering observation
* policy rule
* estimated benefit

Adaptive values must remain explainable.

The governor should not behave as a black box.

---

# Design Goal

The governor seeks to eliminate folklore.

Not by eliminating parameters.

But by making parameters:

* explicit
* observable
* explainable
* auditable
* reviewable

The objective is traceable operational knowledge.

---

# MVP Requirements

The MVP shall include:

1. A parameter registry.
2. Parameter categories.
3. Parameter provenance metadata.
4. Parameter change history.
5. Operator-visible parameter inspection.
6. Elimination of undocumented literals in control logic.
7. Documentation for every configurable value.

---

# Summary

The Autovacuum Governor replaces static PostgreSQL tuning with a dynamic control system.

To avoid recreating the same folklore internally, every governor parameter must have explicit provenance.

The governor may contain parameters.

The governor may not contain mysteries.

All control values must be documented, inspectable, and traceable to their origin.

Parameter governance is a first-class feature of the system, not an implementation detail.
