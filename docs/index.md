# pg_flight_controller documentation

A supervisory autovacuum governor for PostgreSQL. Start with the [project
README](../README.md) for the pitch and a quickstart; this hub points at everything
else.

## Guides

- **[Getting started](guide/getting-started.md)** — install both extensions, run the
  loops once, and verify what you're seeing.
- **[Concepts](guide/concepts.md)** — the control-loop mental model (observe →
  estimate → decide → act), per-class dead-tuple targets, and saturation/inhibitor
  diagnosis.
- **[Operating the governor](guide/operating.md)** — expressing policy, reading the
  status and diagnostics views, scheduling with `pg_cron`, and (when you're ready)
  enabling active control.

## Reference

Generated directly from the installed schema and its `COMMENT ON` metadata, so it
cannot drift from the code:

- [`pgfc_observe`](reference/pgfc_observe.md) — telemetry tables, views, functions.
- [`pgfc_govern`](reference/pgfc_govern.md) — control-loop tables, views, functions.

The [Concepts](guide/concepts.md) guide covers the architecture and the reasoning
behind it — the control law, saturation diagnosis, and the safety system.

## How these docs stay accurate

The reference is generated; documented SQL examples are executed in CI; internal
links are checked. A change that breaks any of these fails the build, so the
documentation cannot silently drift from the implementation.
