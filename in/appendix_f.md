# Appendix F: Governor Self-Protection, Safety Invariants, and Failure Modes

## Purpose

This appendix defines the self-protection mechanisms, safety invariants, and failure-handling behavior of the Autovacuum Governor.

The governor is an autonomous operational subsystem.

Unlike a passive monitoring system, the governor has authority to modify PostgreSQL configuration and influence database behavior.

Therefore the governor itself must be treated as a potentially hazardous component.

The governor must include explicit mechanisms that:

* limit its authority
* detect unsafe conditions
* degrade gracefully
* fail safely
* prevent self-amplifying feedback loops

The governor must never become a source of instability.

---

# Core Principle

The governor must govern itself before it governs PostgreSQL.

The governor is subject to:

* resource limits
* operational limits
* safety limits
* authority limits

The governor must continuously evaluate its own health and behavior.

---

# Safety Philosophy

The governor should be designed according to the following principle:

```text
Observe aggressively.
Diagnose thoroughly.
Act cautiously.
Escalate slowly.
Fail safely.
```

The system should prefer inaction over unsafe action.

---

# Safety Invariants

The governor shall maintain explicit safety invariants.

Safety invariants are conditions that must never be violated.

Unlike policies, safety invariants are not optimization targets.

They are hard boundaries.

---

## Invariant 1: Never Wait on Locks

The governor shall never introduce operational risk by waiting indefinitely for locks.

All lock-acquiring operations must use bounded lock timeouts.

Failed lock acquisition shall be treated as a normal outcome.

---

## Invariant 2: Never Disable Autovacuum

The governor shall never disable autovacuum.

The governor exists to improve maintenance behavior.

It must not remove PostgreSQL's underlying safety mechanisms.

---

## Invariant 3: Never Reduce Freeze Safety

The governor shall never reduce anti-wraparound safety below configured policy limits.

Anti-wraparound protection takes precedence over all performance goals.

---

## Invariant 4: Never Exceed Mutation Budgets

The governor shall respect:

* actuator budgets
* catalog mutation budgets
* maintenance budgets

The governor shall never perform unlimited corrective actions.

---

## Invariant 5: Never Escalate Without Evidence

Repeated actuator escalation without observed improvement is prohibited.

The governor shall transition to diagnostic behavior when progress is absent.

---

## Invariant 6: Every Action Must Be Explainable

The governor shall never perform actions that cannot be explained through:

* observations
* state estimates
* policy rules
* decision logs

The governor must not behave as a black box.

---

# Governor Health Model

The governor shall maintain an internal health state.

Recommended states:

```text
normal
degraded
diagnostic
emergency
disabled
```

These states govern the authority available to the controller.

---

# Normal Mode

Description:

The governor is operating normally.

Capabilities:

* observe
* estimate
* classify
* diagnose
* actuate

All functionality is enabled.

---

# Degraded Mode

Description:

The governor detects abnormal conditions but remains operational.

Examples:

* excessive lock timeouts
* excessive failed actions
* observation lag
* elevated resource consumption

Capabilities:

* observe
* estimate
* diagnose
* limited actuation

Actuation authority may be reduced.

---

# Diagnostic Mode

Description:

The governor detects persistent inability to achieve desired outcomes.

Examples:

* actuator saturation
* maintenance inhibitors
* repeated ineffective actions

Capabilities:

* observe
* estimate
* diagnose

Actuation is suspended except for explicitly permitted safety actions.

The governor focuses on identifying root causes.

---

# Emergency Mode

Description:

The governor detects severe operational risk.

Examples:

* governor resource exhaustion
* internal corruption
* excessive catalog mutation
* runaway control behavior

Capabilities:

* minimal observation
* health reporting

No ordinary actuation is permitted.

Emergency mode is intended to stabilize the system.

---

# Disabled Mode

Description:

The governor has been explicitly disabled.

Capabilities:

* none

All control activity ceases.

State history remains available.

---

# Circuit Breakers

The governor shall implement circuit breakers.

Circuit breakers temporarily disable control actions when predefined limits are exceeded.

Examples:

```text
too many failed actions
too many lock timeouts
too many catalog mutations
too many actuator changes
```

Circuit breakers reduce control authority automatically.

---

# Load Shedding

The governor shall support load shedding.

When database stress exceeds configured limits, the governor should reduce its own workload.

Examples:

```text
high CPU utilization
high IO pressure
checkpoint storms
connection exhaustion
severe lock contention
```

Responses may include:

* slower observation cadence
* reduced diagnostic activity
* suspended actuation

The governor should consume fewer resources when the database needs them most.

---

# Authority Limiting

The governor shall maintain explicit authority limits.

Examples:

```text
maximum actions per hour
maximum actions per relation
maximum catalog mutations
maximum lock acquisition attempts
```

Authority limits prevent runaway behavior.

---

# Self-Monitoring

The governor shall continuously monitor itself.

Recommended metrics:

```text
observation count
decision count
action count
failed action count
lock timeout count
catalog mutation count
storage consumption
retention backlog
control loop duration
observation loop duration
```

These metrics form the basis of governor health assessment.

---

# Self-Diagnostics

The governor shall maintain a diagnostic subsystem.

Examples:

```text
governor lagging observations
governor storage budget exceeded
governor mutation budget exceeded
governor actuator saturation detected
governor unable to acquire locks
```

Self-diagnostics should be visible to operators.

---

# Failure Classification

The governor shall classify failures.

Recommended categories:

## Observation Failure

Examples:

```text
statistics unavailable
sampling failure
observation timeout
```

---

## Decision Failure

Examples:

```text
state estimation failure
invalid policy
conflicting rules
```

---

## Actuation Failure

Examples:

```text
lock timeout
permission denied
conflicting DDL
```

---

## Resource Failure

Examples:

```text
storage budget exceeded
memory pressure
resource exhaustion
```

---

## Safety Failure

Examples:

```text
mutation budget exceeded
control oscillation detected
unexpected actuator behavior
```

---

# Control Oscillation Detection

The governor shall detect oscillatory behavior.

Examples:

```text
setting repeatedly increased
setting repeatedly decreased
setting repeatedly increased
```

Oscillation should trigger:

* diagnostic mode
* suppression of further changes
* operator visibility

The governor must prefer stability over responsiveness.

---

# Emergency Suppression

The governor shall be capable of suppressing its own activity.

Examples:

```text
stop actuating
stop planning
reduce observation frequency
enter diagnostic mode
enter emergency mode
```

The governor should always retain the ability to make itself less dangerous.

---

# Human Override

Operators shall retain ultimate authority.

Operators must be able to:

* disable the governor
* suspend actuation
* force diagnostic mode
* override policies
* review all decisions

The governor assists operators.

It does not replace them.

---

# Auditability

All mode transitions shall be recorded.

Examples:

```text
normal → degraded
degraded → diagnostic
diagnostic → emergency
emergency → normal
```

Every transition should include:

* timestamp
* reason
* triggering condition
* affected subsystem

---

# MVP Requirements

The MVP shall include:

1. Governor health states.
2. Circuit breakers.
3. Authority limits.
4. Load shedding.
5. Self-monitoring metrics.
6. Failure classification.
7. Mode transitions.
8. Operator override controls.
9. Decision logging.
10. Safety invariant enforcement.

---

# Summary

The Autovacuum Governor is an autonomous control system.

Autonomous systems must have explicit theories of failure.

The governor therefore includes:

* safety invariants
* circuit breakers
* load shedding
* authority limits
* self-monitoring
* emergency suppression
* human override

The governor's first responsibility is not optimization.

Its first responsibility is safe operation.

A governor that cannot safely govern itself cannot safely govern PostgreSQL.
