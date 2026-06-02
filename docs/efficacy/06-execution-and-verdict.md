# Phase 6 — Execution and verdict

**Status:** Not started (execution-gated) · *(stub — fleshed out when reached)*

Run the experiment, analyze the data, and render the verdict the whole stream exists to
produce. This is the one phase that is **execution-gated**: it should follow the relevant
fortification fixes landing — notably
[COR-001](../fortification/01-security-correctness-apply.md#findings)
([#66](https://github.com/dventimisupabase/pg_flight_controller/issues/66)), so that the
self-stabilizing-under-drift thesis is tested on the system *as it is meant to work* — and
after reviewer feedback on the [RFC](../rfc/README.md) has had its say.

To be filled:

- **Runs** — execute the [Phase 4](04-experimental-design.md) protocol; record each as a
  `RESULT-NNN` with its reproducible handle.
- **Analysis** — the proxy-vs-outcome relationship; arm-vs-arm outcome deltas; the fraction
  of the oracle gap pgfc closes; the vacuum-cost it spends doing so.
- **The verdict** — against the four gates: is the problem real and valuable, does pgfc solve
  it on an outcome measure, and *adequately* by the charter's bar? State plainly how close the
  observed behavior is to the happy path (drift tracked, health restored) and where it falls
  short.
- **Feed-back** — file issues for findings that imply a change (wrong class targets, wrong
  control surface, missing levers); link them here and surface the strategic ones into the
  RFC's [§7](../rfc/README.md#7-open-questions--feedback-wanted).

## Exit criteria

- The verdict is stated against all four gates, backed by reproducible runs.
- "How close to the happy path" is answered with evidence, not impression.
- Change-implying findings are filed and linked.
