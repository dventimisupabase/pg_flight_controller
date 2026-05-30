# Appendix D: Observation Storage, Retention, and Governor Self-Maintenance

## Purpose

This appendix defines storage and retention requirements for the Autovacuum Governor.

The governor observes PostgreSQL relation state at regular intervals. Those observations are necessary for state estimation, trend analysis, control decisions, and auditability.

However, observation data can itself become a source of database growth.

The governor must therefore include a retention model from the beginning.

---

# Core Risk

The governor continuously records metadata about database health.

If unmanaged, this creates a new accumulation problem:

```text
maintenance system observes database growth
maintenance system records observations
observation records grow without bound
maintenance system becomes its own maintenance burden
```

The governor must not create the very kind of storage problem it is designed to manage.

---

# Design Principle

The governor shall retain high-resolution data only briefly and retain summarized data longer.

Recommended model:

```text
raw observations: short retention
rollups: medium retention
decisions/actions: long retention
policy history: long retention
diagnostic events: long retention
```

Observation data is operational telemetry, not permanent business data.

---

# Loop Cadence

The design assumes two major loops.

Fast Observation Loop:

```text
every 1 minute
```

Purpose:

* collect current relation state
* update short-term trend estimates
* detect urgent conditions
* feed state estimation

Control Loop:

```text
every 5 minutes
```

Purpose:

* classify relations
* compute desired state deviation
* decide whether action is warranted
* apply bounded actuator changes
* record decisions

The fast loop may generate more data than the control loop. Therefore, retention policy must distinguish between observation frequency and decision frequency.

---

# Data Classes

## 1. Raw Observations

Raw observations are high-cardinality, time-series snapshots.

Examples:

* relation OID
* timestamp
* relation size
* tuple estimates
* insert/update/delete counters
* dead tuple estimates
* last vacuum time
* last autovacuum time
* last analyze time
* xid age
* mxid age
* relevant pg_stat values

Retention:

```text
default: 24-72 hours
```

Raw observations are useful for short-term control and debugging. They should not be retained indefinitely.

---

## 2. Derived State

Derived state is computed from raw observations.

Examples:

* vacuum debt
* freeze debt
* maintenance lag
* churn rate
* cleanup effectiveness
* burstiness
* controller confidence

Retention:

```text
default: 7-14 days
```

Derived state is more compact and more useful for trend analysis than raw observations.

---

## 3. Rollups

Rollups aggregate raw and derived data.

Recommended rollups:

* 5-minute rollups
* hourly rollups
* daily rollups

Examples:

* average dead tuple estimate
* maximum dead tuple estimate
* average churn rate
* maximum xid age
* vacuum count
* autovacuum count
* action count
* inhibitor count

Retention:

```text
5-minute rollups: 7 days
hourly rollups: 30-90 days
daily rollups: 1 year or configurable
```

Rollups support long-range analysis without retaining excessive raw data.

---

## 4. Decisions and Actions

Decision records describe what the governor decided and why.

Action records describe what the governor actually changed.

Examples:

* proposed action
* applied action
* skipped action
* lock timeout
* no-op suppression
* safety-policy suppression
* rollback
* emergency override

Retention:

```text
default: 90 days or longer
```

These records are audit data and should live longer than raw observations.

---

## 5. Policy and Configuration History

Policy history records human-owned desired state.

Examples:

* maintenance policy changes
* relation class overrides
* global safety settings
* ownership changes
* governor enable/disable events

Retention:

```text
default: indefinite or explicitly pruned
```

Policy history is important for explaining past behavior.

---

## 6. Diagnostic Events

Diagnostic events record significant findings.

Examples:

* long-running transaction detected
* logical replication slot pinning xmin
* prepared transaction detected
* hot standby feedback suspected
* actuator saturation detected
* catalog mutation budget exceeded

Retention:

```text
default: 90-365 days
```

These are operationally valuable and should be retained longer than routine observations.

---

# Storage Budgeting

The governor should expose an explicit storage budget.

Example policy:

```text
maximum governor schema size: 1 GB
maximum raw observation retention: 72 hours
maximum rows per observation partition: configurable
```

If the budget is exceeded, the governor should degrade gracefully by pruning raw observations before pruning decisions, actions, or policy history.

---

# Retention Priority

When pruning is required, delete in this order:

1. Raw observations
2. Derived state records
3. Fine-grained rollups
4. Coarse rollups
5. Routine diagnostic records
6. Action history
7. Policy history

Policy history should be the last thing pruned.

---

# Partitioning

High-volume observation tables should be partitioned by time.

Recommended:

```text
daily partitions for raw observations
weekly or monthly partitions for rollups
```

Partitioning enables efficient retention by dropping old partitions rather than issuing large DELETE statements.

Preferred retention operation:

```sql
DROP TABLE governor.raw_observation_2026_05_01;
```

Avoid large row-by-row deletes where possible.

---

# Self-Vacuum Consideration

The governor's own tables are PostgreSQL tables.

Therefore, the governor's own schema must be maintained.

Recommended approach:

* keep raw observation partitions short-lived
* avoid high-churn updates
* prefer append-only observation records
* use partition drops for retention
* configure autovacuum settings for governor tables explicitly
* avoid making governor metadata tables a source of bloat

The governor must include itself in its maintenance model or explicitly exclude itself with a separate static policy.

---

# Sampling Strategy

The MVP should avoid collecting more data than it needs.

Recommended principles:

* collect per-relation data only for relevant relations
* ignore system catalogs unless explicitly monitoring catalog health
* ignore tiny relations below configurable thresholds
* use lower-frequency observation for cold/archive relations
* increase observation frequency only for active or risky relations

Not every table needs one-minute sampling forever.

---

# Relation Eligibility

The governor should classify relations into observation tiers.

Example:

Hot Tier:

```text
observe every 1 minute
```

Warm Tier:

```text
observe every 5 minutes
```

Cold Tier:

```text
observe every 1 hour
```

Inactive Tier:

```text
observe daily or on demand
```

This reduces unnecessary data accumulation.

---

# Cardinality Control

The governor must be careful in databases with many relations.

Risks:

* thousands of tables
* partition-heavy schemas
* temporary or transient relations
* multi-tenant schemas
* extension-owned objects

The MVP should include filters:

* exclude temporary tables
* optionally exclude partitions below size threshold
* optionally observe partition parents separately from child partitions
* exclude extension-owned relations unless configured
* exclude schemas by policy

---

# Data Minimization

The governor should not store full copies of large text fields or catalog metadata unless required.

For example, do not repeatedly store full reloptions arrays if unchanged.

Prefer:

```text
current_value_hash
changed_fields
foreign key to setting snapshot
```

over:

```text
full JSON blob every minute
```

Raw observations should be narrow.

Decision logs can be richer because they are lower volume.

---

# Compression and Summarization

The governor should summarize older data.

Example retention pipeline:

```text
raw observations
    ↓ after 72 hours
5-minute rollups
    ↓ after 7 days
hourly rollups
    ↓ after 90 days
daily rollups
```

This preserves useful history while bounding storage growth.

---

# MVP Requirements

The MVP shall include:

1. A documented retention policy.
2. Separate tables for raw observations, derived state, rollups, decisions, actions, and policies.
3. Short retention for raw observations.
4. Longer retention for decisions and actions.
5. Partitioning for high-volume observation tables.
6. A pruning function.
7. A scheduled retention job.
8. Storage budget reporting.
9. A governor self-health view.
10. Guardrails to prevent unbounded growth.

---

# Example Retention Configuration

```text
raw_observation_retention = 72 hours
derived_state_retention = 14 days
five_minute_rollup_retention = 7 days
hourly_rollup_retention = 90 days
daily_rollup_retention = 365 days
decision_log_retention = 180 days
action_history_retention = 180 days
policy_history_retention = indefinite
diagnostic_event_retention = 365 days
max_governor_schema_size = 1 GB
```

These values are defaults, not universal recommendations.

---

# Summary

The Autovacuum Governor must not grow without bound.

Because the governor continuously observes relation state, it must include storage management from the beginning.

The system should retain detailed observations briefly, summarized trends longer, and decision history longest.

The design goal is:

```text
enough history to control and explain behavior
without turning the governor into a storage liability
```

The governor is a maintenance system.

It must maintain itself.
