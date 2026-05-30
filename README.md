# pg_flight_controller

A supervisory **autovacuum governor** for PostgreSQL. It treats per-table autovacuum
settings not as static configuration but as **actuator positions**: you express
*policy* (desired maintenance outcomes), and the governor observes the database,
estimates each relation's hidden maintenance state, and steers autovacuum's setpoints
toward those outcomes — with small, safe, auditable changes.

The goal is not to *tune* autovacuum once. It is to keep the database
**self-stabilizing** as workloads change. The design draws on control theory, state
estimation, and convergence engines — not machine learning.

> **Status.** `pgfc_observe` (Phase 0) and `pgfc_govern` (Phase 1, **advisory-only**)
> are shipped and tested on PostgreSQL 15–18. Active control (Phase 2) is in progress.
> Out of the box the governor *recommends* and *diagnoses* but changes nothing.

## Two extensions

| Extension | Role | Changes settings? |
|---|---|---|
| [`pgfc_observe`](pgfc_observe/) | Observe + Orient — read-only telemetry | never |
| [`pgfc_govern`](pgfc_govern/) | Decide + Act — the control loop | only once you enable it |

`pgfc_govern` reads `pgfc_observe` cross-schema and depends on it. `pgfc_observe` is
useful on its own as an autovacuum-health monitor.

## Quickstart

Install both (observe first):

```sql
\i pgfc_observe/install.sql
\i pgfc_govern/install.sql
```

Take one observation and see what the governor *would* do — advisory by default, so
nothing is changed:

<!-- doctest -->

```sql
SELECT pgfc_govern.observe_tick();    -- observe + classify + estimate
SELECT pgfc_govern.control_tick();    -- plan + verify (apply() never fires)

-- the per-relation recommendation:
SELECT relname, kind, decision, proposed_value
FROM pgfc_govern.governor_status
ORDER BY relname;
```

In production, drive the two loops with `pg_cron` — observe often, act rarely:

```sql
SELECT cron.schedule('pgfc_observe', '* * * * *',   $$SELECT pgfc_govern.observe_tick()$$);
SELECT cron.schedule('pgfc_control', '*/5 * * * *', $$SELECT pgfc_govern.control_tick()$$);
```

## Documentation

- **[Getting started](docs/guide/getting-started.md)** — install, first run, verify.
- **[Concepts](docs/guide/concepts.md)** — the mental model: observe → estimate →
  decide → act, and why the governor diagnoses instead of escalating.
- **[Operating the governor](docs/guide/operating.md)** — policy, the views,
  scheduling, and reading diagnostics.
- **Reference** (generated from the schema):
  [`pgfc_observe`](docs/reference/pgfc_observe.md) ·
  [`pgfc_govern`](docs/reference/pgfc_govern.md).

The full documentation hub is [`docs/`](docs/index.md); [Concepts](docs/guide/concepts.md)
covers the architecture and rationale.

## Development

```bash
./test.sh          # pgTAP suites on PostgreSQL 15/16/17/18 (Docker)
./test.sh 17       # one version, fast
```

The docs stay honest automatically: CI regenerates the reference and fails on schema
drift, executes every documented SQL example, and verifies that internal links
resolve.
