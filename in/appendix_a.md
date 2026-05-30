# Appendix A: Actuator Safety, Locking, and Control Loop Cadence

## Purpose

This appendix refines the actuator model used by the Autovacuum Governor and documents the locking implications of dynamically adjusting per-table autovacuum settings.

The governor is a supervisory control system. It observes frequently but should act conservatively.

A critical design requirement is that the governor itself must never become a source of operational instability.

---

# Background

The MVP governor proposes to control PostgreSQL autovacuum behavior primarily through per-table storage parameters.

Examples include:

```sql
ALTER TABLE my_table SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_threshold = 10000,
    autovacuum_analyze_scale_factor = 0.01
);
```

These operations are implemented through ALTER TABLE statements.

Because ALTER TABLE is DDL, it is necessary to understand the locking implications before treating these settings as dynamically adjustable actuator positions.

---

# Key Observation

Actuator movement is not free.

Changing a storage parameter is not equivalent to updating a row in a metadata table.

Every actuator movement carries operational cost.

The governor must account for that cost.

---

# Locking Model

Autovacuum storage parameter modifications require table-level locks.

Although these operations do not require ACCESS EXCLUSIVE locks, they are not lock-free.

The governor must assume:

* Lock acquisition may fail.
* Lock acquisition may be delayed.
* Lock acquisition may conflict with maintenance operations.
* Excessive actuator movement can create unnecessary contention.

The governor must therefore treat ALTER TABLE operations as constrained actuators.

---

# Design Principle

Observe Frequently.

Decide Carefully.

Act Rarely.

Never Wait.

The governor should collect observations continuously.

The governor should update its internal state model continuously.

The governor should modify actuator positions infrequently.

The governor should never block waiting for a lock.

---

# Lock Acquisition Policy

All actuator operations must use aggressive lock timeouts.

Example:

```sql
SET LOCAL lock_timeout = '100ms';

ALTER TABLE my_table SET (
    autovacuum_vacuum_scale_factor = 0.02
);
```

If the lock cannot be acquired immediately:

* abandon the action
* record the failure
* retry during a future control cycle

The governor should never wait indefinitely.

The governor should never become a contributor to lock queues.

---

# Rate Limiting

Actuator movement must be rate-limited.

Recommended initial policy:

* maximum one configuration change per relation per hour
* configurable global maximum changes per control interval
* emergency exceptions only for freeze-risk mitigation

The objective is to prevent oscillation and reduce unnecessary DDL activity.

---

# Hysteresis

The governor must avoid repeatedly changing settings in response to measurement noise.

Example anti-pattern:

```text
0.02 -> 0.03
0.03 -> 0.02
0.02 -> 0.03
```

Instead:

* require meaningful state deviation
* require sustained deviation
* require minimum elapsed time since previous adjustment

Actuator changes should be monotonic whenever possible.

---

# Batching

Multiple storage parameter updates should be combined into a single ALTER TABLE operation.

Preferred:

```sql
ALTER TABLE my_table SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_threshold = 10000,
    autovacuum_analyze_scale_factor = 0.01
);
```

Avoid:

```sql
ALTER TABLE ...
ALTER TABLE ...
ALTER TABLE ...
```

Batching reduces lock acquisition frequency and minimizes control overhead.

---

# Separation of Observation and Actuation

The governor's observation cadence should be significantly faster than its actuation cadence.

Example:

Observation Loop

```text
every 1 minute
```

State Estimation

```text
every 1 minute
```

Planning

```text
every 5 minutes
```

Actuation

```text
at most once per relation per hour
```

This separation improves stability and reduces control-loop oscillation.

---

# Actuator Failure Handling

Failure to move an actuator is not a system failure.

The governor should record:

* desired action
* attempted action
* reason for failure
* timestamp

Examples:

```text
lock timeout
insufficient privilege
conflicting maintenance operation
safety policy restriction
```

Future control cycles may reevaluate the action.

---

# Actuator Cost Model

Future versions of the governor may explicitly model actuator cost.

Example cost dimensions:

* lock acquisition risk
* DDL frequency
* operational disruption
* rollback complexity

This allows the planner to choose between:

Option A

```text
change storage parameters
```

or

Option B

```text
issue one targeted VACUUM
```

depending on estimated cost and expected benefit.

---

# Revised Mental Model

Autovacuum settings remain actuator positions.

However, actuator movement itself has cost.

The governor therefore controls two things simultaneously:

1. Database maintenance state.
2. Frequency of actuator movement.

The optimal controller is not one that changes settings constantly.

The optimal controller is one that achieves convergence with the minimum necessary actuator activity.

---

# Summary

The Autovacuum Governor is a convergence engine, not a tuning engine.

Its purpose is to continuously drive relations toward desired maintenance equilibria.

However, the actuator surface is implemented through PostgreSQL DDL operations that require locking.

Therefore:

* observations should be frequent
* state estimation should be continuous
* decisions should be cautious
* actuator movement should be rare
* lock acquisition should be non-blocking
* convergence should be achieved through small, deliberate corrections

The governor must never become a source of lock contention, instability, or operational risk.
