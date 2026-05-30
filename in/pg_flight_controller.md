# pg_flight_controller

## Phase I:  PostgreSQL Autovacuum Governor

## Executive Summary

PostgreSQL's autovacuum subsystem is highly configurable but fundamentally static. Operators are expected to choose values for numerous configuration parameters and trust that those values will remain appropriate across changing workloads, table sizes, growth rates, and operational conditions.

This project proposes an Autovacuum Governor: a supervisory control system that continuously observes database state, estimates maintenance debt, and dynamically adjusts autovacuum actuator settings to drive relations toward desired maintenance equilibria.

The project is explicitly inspired by:

* Control Theory
* State Estimation
* Kalman Filtering
* Promise Theory
* CFEngine-style Convergence
* Autonomous Systems Engineering

The project is not primarily an AI system and is not initially a machine learning project.

The project treats autovacuum settings as actuator positions rather than operator-owned configuration.

The objective is not to tune autovacuum.

The objective is to continuously maintain database health.

---

# Problem Statement

PostgreSQL exposes numerous autovacuum-related settings:

* autovacuum_vacuum_scale_factor
* autovacuum_vacuum_threshold
* autovacuum_analyze_scale_factor
* autovacuum_analyze_threshold
* autovacuum_vacuum_cost_limit
* autovacuum_vacuum_cost_delay
* autovacuum_freeze_min_age
* autovacuum_freeze_table_age
* autovacuum_freeze_max_age
* autovacuum_max_workers
* others

These settings may be configured globally or on a per-table basis.

In practice:

* Most deployments rely primarily on cluster-level defaults.
* Per-table tuning is uncommon.
* Existing tuning guidance is largely heuristic.
* Operators often debate parameter values rather than system objectives.
* Static configurations frequently become suboptimal as workloads evolve.

The result is operational folklore rather than adaptive control.

---

# Core Thesis

Per-table autovacuum settings are not configuration.

They are actuator positions.

The operator should define desired outcomes.

The system should determine actuator positions required to achieve those outcomes.

---

# Design Principles

## Principle 1: Convergence Over Optimization

The system is not attempting to find mathematically optimal parameter values.

The system attempts to drive relations toward desired maintenance states.

The goal is convergence.

Not optimization.

---

## Principle 2: Policy Over Parameters

Users express policy.

Users do not manage scale factors.

Examples:

* Prioritize latency
* Prioritize storage efficiency
* Conservative freeze posture
* Aggressive cleanup posture
* Maximum maintenance I/O budget

The system translates policy into actions.

---

## Principle 3: Safety Before Performance

Anti-wraparound safety dominates all other objectives.

The governor must never compromise transaction ID safety.

---

## Principle 4: Small Corrections

The governor should make incremental adjustments.

Avoid large configuration jumps.

Avoid oscillation.

Favor stability.

---

## Principle 5: Explainability

Every action must be explainable.

Every adjustment must be logged.

Every decision should be auditable.

---

# Desired State Model

Each relation is assigned a desired maintenance equilibrium.

Examples:

Queue Table

* low vacuum debt
* aggressive cleanup
* low dead tuple tolerance

Append-Only Ledger

* low freeze risk
* low analyze urgency
* high tolerance for dead tuple accumulation

OLTP Table

* balanced latency
* balanced storage utilization
* moderate cleanup aggressiveness

Archive Table

* minimal maintenance
* freeze safety only

---

# State Estimation

The governor maintains an internal state model.

Observed State:

* relation size
* dead tuples
* inserts
* updates
* deletes
* autovacuum frequency
* autovacuum duration
* xid age
* mxid age
* table growth
* WAL generation
* vacuum statistics

Derived State:

* vacuum debt
* freeze debt
* maintenance lag
* churn rate
* cleanup efficiency
* maintenance burstiness

These derived values represent the hidden state of the maintenance system.

---

# Control Loop

Observe

Collect metrics.

Estimate

Update state model.

Evaluate

Compare observed state against desired state.

Act

Apply corrective actions.

Verify

Measure outcome.

Repeat.

---

# Initial Actuators

The MVP controls:

Per-table storage parameters

* autovacuum_vacuum_scale_factor
* autovacuum_vacuum_threshold
* autovacuum_analyze_scale_factor
* autovacuum_analyze_threshold
* autovacuum_vacuum_cost_limit
* autovacuum_vacuum_cost_delay

Optional later controls:

* freeze settings
* scheduled VACUUM
* scheduled ANALYZE

---

# Architecture

## MVP Architecture

In-Database Governor

Components:

Tables

* governor_policy
* relation_state
* relation_classification
* decision_log
* action_history

Views

* relation_health
* maintenance_debt
* governor_status

Functions

* observe()
* classify()
* estimate()
* plan()
* apply()
* tick()

Scheduling

* pg_cron

The governor runs periodically.

Recommended cadence:

1-5 minutes.

---

# Relation Classification

Tables are classified into categories:

* append_only
* oltp
* queue
* delete_heavy
* archive
* mixed

Classification may be automatic or manually overridden.

---

# Example Control Rules

If vacuum debt is increasing:

Decrease vacuum scale factor.

If vacuums are excessively frequent:

Increase threshold.

If autovacuum runs are excessively large:

Reduce trigger thresholds.

If freeze debt exceeds policy limits:

Prioritize freeze actions.

If maintenance I/O exceeds budget:

Reduce aggressiveness.

---

# Safety System

Hard Constraints

Never:

* disable autovacuum
* exceed freeze safety thresholds
* make rapid repeated adjustments
* issue conflicting actions

Rate Limiting

Maximum adjustments per relation per period.

Rollback

Every action can be reverted.

---

# Decision Logging

Every action records:

Observation

Previous state

Desired state

Decision

Action taken

Outcome

The system must support complete auditability.

---

# Out of Scope (MVP)

The MVP does not control:

* checkpointer
* bgwriter
* WAL settings
* shared buffers
* work_mem
* replication settings

The MVP may observe these subsystems.

It does not control them.

---

# Future Directions

Phase 2

Autovacuum Governor

* autonomous operation
* richer state estimation
* adaptive policies

Phase 3

Maintenance Governor

Add:

* checkpoint control
* bgwriter control
* WAL management
* maintenance scheduling

Phase 4

Database Resource Control Plane

Unified control framework for PostgreSQL operational subsystems.

---

# Long-Term Vision

Autovacuum should be viewed as a controllable subsystem rather than a collection of static parameters.

The operator defines desired maintenance behavior.

The governor continuously drives the database toward that desired state.

The resulting system resembles:

* an engine control unit
* a convergence engine
* a supervisory control system

rather than a traditional configuration manager.

The goal is not self-tuning PostgreSQL.

The goal is self-stabilizing PostgreSQL.
