# Phase 1 — The problem and its value

**Status:** Not started · **Gate:** if the value question collapses here, the later phases
are moot.

This phase does no experiments. It writes down, precisely, *what problem
pg_flight_controller claims to solve*, and decides which part of that claim is settled prior
art and which part is genuinely open and worth an experiment.

## The problem chain

Work down from the mechanism to the claim. Each layer states what the layer below leaves
unsolved.

- **What vacuuming solves.** PostgreSQL's MVCC leaves dead tuples (old row versions) behind
  on every `UPDATE`/`DELETE`. Unreclaimed, they cause three distinct harms: **bloat** (wasted
  space, colder cache, slower scans), **transaction-ID / multixact wraparound** (the
  existential one — old xids must be frozen or the database forces a shutdown to avoid data
  loss), and **stale planner statistics** (handled by the coupled `ANALYZE`). `VACUUM`
  reclaims, freezes, and (via `ANALYZE`) re-measures.
- **What autovacuum solves.** Scheduling `VACUUM` by hand is toil and easy to get wrong.
  Autovacuum automates *when* to vacuum each table, firing when dead tuples cross a per-table
  threshold (`scale_factor × reltuples + threshold`, with analogous insert/freeze triggers).
- **What *operating* autovacuum solves (the pgfc claim).** Autovacuum's per-table knobs are
  static. Defaults are one-size-fits-all and often wrong for a specific table; tuning them is
  expert work, typically set-once-and-forgotten; and the right value **drifts** as the
  workload changes. pg_flight_controller claims to keep those setpoints continuously
  appropriate as the workload moves — without ongoing human tuning.

State the claim in one sentence the rest of the stream can test, e.g.: *"Per-table autovacuum
setpoints that were right become wrong as workloads drift, and a supervisory loop can keep
them right — and the database healthier — than a human tuning once."*

## The value question, split

- **Settled (cite, don't re-test).** That autovacuum mis-tuning is costly — bloat incidents,
  wraparound emergencies, the operational toil of per-table tuning at scale — is established.
  Phase 1 collects citations and, ideally, concrete incident lore; it does not rebuild this
  with a harness.
- **Open (the only part the experiment earns).** Does *continuous automated re-tuning* beat
  *good static per-table tuning* under workloads that move? A human can tune well once; the
  pgfc-specific bet is that *standing still loses to drift* and that an automated loop tracks
  it better. That is the claim Phases 2–6 exist to test.

## What this phase produces

- The problem statement above, sharpened to a single testable sentence.
- A short prior-art annex for the settled half of the value question.
- A go/no-go on the open half: is "continuous vs. good static, under drift" a real,
  unresolved question worth the experimental cost? (Expected: yes — but stated, not assumed.)
- `PROB-NNN` findings for anything that reframes the problem (e.g. evidence the dominant cost
  is inhibitor-bound tables the scale factor cannot touch — which would shift the whole claim
  toward diagnostics; cf. RFC [§2.5](../rfc/README.md#25-diagnose-dont-escalate) and §7).

## Exit criteria

- The claim is stated as one testable sentence.
- The value question is split into cited-settled and experimentally-open, with a go/no-go on
  the open part.
- Any problem-reframing findings are recorded with evidence.
