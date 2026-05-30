# Appendix B: Catalog Mutation and Catalog Bloat Risk

## Purpose

This appendix documents an additional operational constraint for the Autovacuum Governor: actuator changes made through `ALTER TABLE ... SET (...)` mutate PostgreSQL system catalogs.

The governor must therefore manage not only table-level locking risk, but also catalog-write frequency and potential catalog bloat.

---

# Key Question

If the governor dynamically changes per-table autovacuum settings, does that result in updates to PostgreSQL system catalogs?

Yes.

Per-table autovacuum settings are stored as relation storage parameters.

These are represented in PostgreSQL catalog metadata, principally in `pg_class.reloptions`.

Therefore, each successful `ALTER TABLE ... SET (...)` operation changes catalog state.

---

# Consequence

Catalog mutation is not free.

PostgreSQL catalogs are MVCC relations.

When catalog rows are updated, old row versions become dead tuples.

Therefore, frequent DDL can create catalog churn.

Catalog churn can contribute to catalog bloat.

---

# Risk Statement

The governor must not become a source of excessive catalog mutation.

A poorly designed governor could:

* frequently update `pg_class.reloptions`
* create unnecessary dead tuples in system catalogs
* cause catalog bloat
* increase catalog lookup cost
* increase autovacuum work on catalogs
* create secondary operational instability

This risk is especially relevant if the governor manages many relations and changes parameters frequently.

---

# Design Principle

Actuator changes should be treated as durable metadata mutations, not ephemeral control signals.

Changing a table's autovacuum setting is not equivalent to adjusting an in-memory variable.

It is a persistent DDL operation.

Therefore:

```text
Observe frequently.
Estimate continuously.
Plan cautiously.
Mutate catalogs rarely.
```

---

# Catalog Mutation Budget

The governor should enforce a catalog mutation budget.

Recommended MVP policy:

* maximum one settings change per relation per hour
* maximum N total relation-setting changes per control interval
* maximum M total relation-setting changes per day
* emergency exception only for anti-wraparound safety

The exact values should be configurable.

---

# Avoid No-Op DDL

The governor must never issue DDL if the desired value is already present.

Before applying an action, compare:

* current stored setting
* proposed setting
* inherited/default setting
* last governor-applied setting

If there is no material difference, skip the action.

---

# Avoid Tiny Adjustments

The governor should avoid changing settings by insignificant amounts.

Bad:

```text
scale_factor: 0.020 -> 0.021
```

Better:

```text
scale_factor: 0.020 -> 0.030
```

Actuator movement should require a meaningful delta.

This prevents catalog churn caused by noisy measurements.

---

# Prefer Policy Classes Over Unique Per-Table Values

The governor should avoid assigning every table a unique parameter vector unless necessary.

Instead, it should prefer policy classes.

Example:

```text
queue_aggressive
oltp_balanced
append_only_conservative
archive_freeze_only
```

Each class maps to a bounded set of actuator values.

This reduces entropy in catalog state and makes behavior easier to audit.

---

# Setting Ownership

The governor should distinguish between:

* user-owned settings
* governor-owned settings
* inherited defaults
* temporary emergency overrides

The governor should avoid overwriting user-owned settings unless policy explicitly allows it.

Every governor-owned change should be recorded in `action_history`.

---

# Catalog Health Monitoring

The governor should monitor catalog health as part of its own safety model.

At minimum, track:

* mutation count per hour
* mutation count per day
* failed DDL attempts
* changed relation count
* catalog vacuum activity, where visible
* growth of catalog relations, especially `pg_class`

Potentially useful catalog relations:

```text
pg_class
pg_attribute
pg_depend
pg_statistic
pg_attrdef
pg_constraint
pg_index
```

For the MVP, `pg_class` is the primary catalog of concern because relation storage options are stored there.

---

# Emergency Behavior

Anti-wraparound safety may override normal mutation budgets.

However, emergency override should still be logged explicitly.

Example:

```text
action_type: emergency_freeze_policy_adjustment
reason: xid_age exceeded policy threshold
catalog_budget_override: true
```

Emergency actions should remain bounded and auditable.

---

# Decision Logging Requirements

Every catalog-mutating action must record:

* relation OID
* relation name
* previous reloptions
* new reloptions
* changed parameters
* reason for change
* policy rule that triggered the change
* timestamp
* transaction outcome
* lock wait outcome
* whether mutation budget was consumed

This creates a complete audit trail.

---

# Rollback Considerations

Because actuator changes are persistent catalog mutations, rollback must be deliberate.

The governor should store enough prior state to reverse its own changes.

Rollback should not mean blindly restoring an old value if a human or another system modified the setting afterward.

The rollback procedure must check ownership and intervening modifications.

---

# Interaction With Appendix A

Appendix A establishes that actuator changes require locks.

This appendix establishes that actuator changes also mutate catalogs.

Together, these imply:

```text
Actuator movement has both lock cost and catalog cost.
```

Therefore, the controller must minimize unnecessary actuator movement.

---

# MVP Requirement

The MVP must include catalog mutation accounting.

Specifically:

1. Do not issue no-op DDL.
2. Rate-limit setting changes.
3. Batch multiple parameter changes into one `ALTER TABLE`.
4. Record every catalog-mutating action.
5. Track mutation frequency.
6. Prefer stable policy classes over continuous micro-adjustments.
7. Treat emergency overrides as explicit exceptions.

---

# Summary

Dynamic per-table autovacuum control remains feasible.

However, per-table actuator movement is implemented through persistent DDL, which updates PostgreSQL catalog metadata.

Because PostgreSQL catalogs are MVCC relations, excessive actuator movement can create catalog churn and potential catalog bloat.

The governor must therefore treat catalog mutation as a scarce resource.

The design goal is not constant adjustment.

The design goal is convergence with minimal necessary catalog mutation.
