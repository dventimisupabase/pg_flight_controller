# Appendix C: Maintenance Inhibitors, Actuator Saturation, and Vacuum Progress

## Purpose

This appendix documents a critical limitation of the Autovacuum Governor.

The governor may successfully command maintenance actions while the PostgreSQL storage engine remains unable to perform the desired cleanup.

In these situations, additional actuator movement cannot produce the desired outcome.

The governor must therefore distinguish between:

* insufficient maintenance configuration
* insufficient maintenance resources
* external conditions that prevent maintenance progress

Failure to make this distinction can result in futile control actions, oscillation, unnecessary catalog mutations, excessive autovacuum activity, and operator confusion.

---

# Key Principle

The governor does not control autovacuum.

The governor controls maintenance progress.

These are not equivalent.

The governor must measure outcomes rather than commands.

---

# Commanded vs Achieved Maintenance

The following statement is false:

```text
Vacuum executed.
Therefore cleanup occurred.
```

The correct model is:

```text
Vacuum executed.
Observe outcome.
Determine whether cleanup occurred.
```

A maintenance action is successful only if it produces measurable maintenance progress.

---

# Actuator Saturation

The governor must recognize actuator saturation.

Definition:

```text
The governor is issuing increasingly aggressive control inputs
while observed maintenance progress remains unchanged.
```

Examples:

* vacuum frequency increases
* vacuum cost limit increases
* scale factor decreases
* threshold decreases

Yet:

* dead tuples continue accumulating
* xid age continues increasing
* reclaimable space remains unchanged
* vacuum effectiveness remains poor

This indicates that the limiting factor lies elsewhere.

---

# Design Principle

The governor must never respond indefinitely to lack of maintenance progress by increasing autovacuum aggressiveness.

At some point:

```text
More control input ≠ More maintenance progress
```

The governor must detect this condition and transition from control mode to diagnosis mode.

---

# Maintenance Inhibitor Model

The governor shall maintain a model of known maintenance inhibitors.

These represent conditions that can prevent vacuum progress despite proper autovacuum operation.

---

# Inhibitor Class 1: Long-Running Transactions

Description

Long-running transactions may retain snapshots that require old tuple versions.

Vacuum cannot remove tuples that may still be visible to those snapshots.

Typical Symptoms

* increasing dead tuples
* repeated vacuum activity
* poor cleanup effectiveness
* old backend_xmin values

Detection Sources

```sql
pg_stat_activity
```

Relevant Signals

* transaction age
* backend_xmin age
* transaction duration

---

# Inhibitor Class 2: Logical Replication Slots

Description

Logical replication slots may pin:

```text
xmin
catalog_xmin
```

Preventing cleanup of tuples and catalogs.

Typical Symptoms

* poor vacuum effectiveness
* WAL retention growth
* catalog cleanup delays
* slot horizons lagging behind current activity

Detection Sources

```sql
pg_replication_slots
```

Relevant Signals

* xmin
* catalog_xmin
* restart_lsn
* confirmed_flush_lsn

---

# Inhibitor Class 3: Hot Standby Feedback

Description

Standby servers may report xmin horizons back to the primary.

The primary may preserve tuples required by standby queries.

Typical Symptoms

* dead tuple accumulation on primary
* healthy standby queries
* reduced cleanup effectiveness

Detection Sources

Replication configuration and standby feedback status.

Relevant Signals

* hot_standby_feedback
* replica activity
* xmin propagation

---

# Inhibitor Class 4: Prepared Transactions

Description

Prepared transactions created through two-phase commit may retain transaction horizons indefinitely.

Typical Symptoms

* unexpected xmin pinning
* apparent vacuum ineffectiveness
* absence of active long-running sessions

Detection Sources

```sql
pg_prepared_xacts
```

Relevant Signals

* prepared transaction age
* prepared transaction count

---

# Inhibitor Class 5: Catalog Horizon Pinning

Description

Catalog cleanup may be blocked independently of ordinary table cleanup.

This is especially relevant when logical replication slots retain catalog_xmin.

Typical Symptoms

* catalog growth
* catalog vacuum inefficiency
* persistent dead catalog tuples

Detection Sources

```sql
pg_replication_slots
```

Relevant Signals

* catalog_xmin
* catalog cleanup effectiveness

---

# Inhibitor Class 6: Lock and Maintenance Conflicts

Description

Vacuum operations may be unable to complete intended work because of conflicting maintenance activities or lock conflicts.

Typical Symptoms

* partial vacuum progress
* repeated interruptions
* inconsistent maintenance outcomes

Relevant Signals

* lock waits
* vacuum interruption events
* maintenance scheduling conflicts

---

# Maintenance Effectiveness

The governor shall estimate maintenance effectiveness.

Definition:

```text
Maintenance Effectiveness =
Observed Maintenance Progress
--------------------------------
Maintenance Effort
```

Exact implementation may evolve.

Possible inputs include:

* dead tuples removed
* pages reclaimed
* xid age reduction
* freeze progress
* visibility map advancement

The governor should prefer directional correctness over mathematical precision.

---

# Maintenance Debt

The governor shall maintain a hidden-state estimate called maintenance debt.

Maintenance debt represents accumulated work that has not yet been completed.

Examples:

* dead tuple debt
* freeze debt
* analyze debt

The purpose of the governor is to reduce maintenance debt.

Not merely to increase vacuum activity.

---

# Diagnostic Mode

When actuator saturation is detected, the governor enters diagnostic mode.

Diagnostic mode performs:

* inhibitor detection
* root-cause analysis
* action suppression
* operator notification

Diagnostic mode should reduce unnecessary actuator movement.

---

# Diagnostic Findings

Examples:

```text
Vacuum debt increasing.

Autovacuum frequency increased 3 times.

Cleanup effectiveness unchanged.

Probable cause:
Logical replication slot pinning xmin.
```

```text
Freeze debt increasing.

Vacuum frequency increased.

Cleanup effectiveness unchanged.

Probable cause:
Long-running transaction.
```

---

# Control Policy

The governor shall prefer diagnosis over escalation.

Incorrect behavior:

```text
Problem detected.

Increase aggressiveness.

Increase aggressiveness again.

Increase aggressiveness again.
```

Correct behavior:

```text
Problem detected.

Increase aggressiveness cautiously.

Observe outcome.

No improvement.

Investigate inhibitors.

Escalate diagnostic findings.
```

---

# Interaction With Appendix A

Appendix A establishes that actuator movement has lock cost.

---

# Interaction With Appendix B

Appendix B establishes that actuator movement has catalog mutation cost.

---

# Additional Principle

This appendix establishes that actuator movement may have no effect.

Therefore actuator movement carries:

1. Lock cost
2. Catalog mutation cost
3. Opportunity cost

The governor should avoid spending actuator budget when an inhibitor is preventing maintenance progress.

---

# MVP Requirements

The MVP shall:

1. Detect common maintenance inhibitors.
2. Estimate maintenance effectiveness.
3. Detect actuator saturation.
4. Record diagnostic findings.
5. Avoid repeated escalation when progress is absent.
6. Distinguish between configuration problems and inhibitor problems.
7. Surface actionable explanations.

---

# Summary

Autovacuum activity is not equivalent to maintenance progress.

The governor must continuously verify that maintenance actions are producing the intended effects.

External inhibitors may prevent vacuum from reclaiming space, advancing horizons, or reducing maintenance debt.

The governor must recognize these conditions, avoid futile escalation, and transition from control behavior to diagnostic behavior.

A successful governor controls maintenance outcomes, not merely autovacuum inputs.
