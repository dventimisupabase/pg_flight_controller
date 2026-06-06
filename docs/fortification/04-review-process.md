# Phase 4 — Review process

**Status:** Complete.

The discipline that outlives the fortification review. Phases 1–3 were a one-time deep
pass; this phase distills the reusable assets into a lightweight, standing process so the
system stays reviewed as it grows — especially as new actuators and objectives arrive.

## Standing assets (reuse, don't re-derive)

The fortification produced these durable artifacts. They are the starting point for any
future review, not something to rebuild:

- **Finding schema + severity rubric + status lifecycle** —
  [00-framework.md](00-framework.md). Use the same schema for any future finding.
- **`apply()` path checklists** — the security and correctness checklists in
  [01-security-correctness-apply.md](01-security-correctness-apply.md). Re-walk them
  when the actuation path changes.
- **Traceability spine** — the invariant/mechanism → code → test → finding matrix,
  seeded in Phase 1, extended in Phases 2–3. The complete spine is in
  [03-test-hardening.md](03-test-hardening.md). Update it when an invariant or
  mechanism changes.
- **FMEA mode inventory** — the cited-safe modes and failure modes in
  [02-failure-theory.md](02-failure-theory.md). Re-evaluate when a new failure surface
  is introduced (a new actuator, a new storage path, a new environmental dependency).
- **Property tests** — `31_property_tests.sql` characterizes the pure helpers and
  classify/estimate robustness. Extend them when a helper's contract changes.

## Actuation-path review checklist

Any change that touches the actuation path — `apply()`, `control_tick()`, `plan()`,
`evaluate_health()`, or their supporting functions — should address:

- [ ] **Security.** Dynamic SQL: is every interpolated value safe? Privilege model: does
  the change assume or confer authority the design does not intend?
- [ ] **Correctness.** Gate ordering: does every pre-mutation gate still fire before the
  budget tiers? No-op arbiter: does the live re-read still catch stale proposals?
  Baseline integrity: is the never-overwrite-baseline contract preserved?
- [ ] **Failure modes.** Does the change introduce a new way the system can fail? If so,
  what is the effect, does it fail safe, and what detects/recovers it? Add to the FMEA
  if non-trivial.
- [ ] **Traceability.** Does the change affect an invariant or mechanism in the spine?
  Update the spine row and ensure a test backs the new behavior.
- [ ] **Registry.** Does the change introduce a new governed constant? Add it to
  `_parameter_registry()`. The P3 drift gate enforces this for the control path.
- [ ] **Upgrade.** Does the change remove or retype a function? Add an explicit
  `DROP FUNCTION IF EXISTS` for the old signature (the re-run-install upgrade path).

## CI-enforced gates (already in place)

The following CI checks already enforce review discipline without manual effort:

- **P3 drift gate** (`11_registry_gate`) — fails if an unregistered numeric/interval
  literal appears in a control-path function body.
- **Reference + subsystem map staleness** — fails if a function is added/renamed/
  re-commented without regenerating the reference docs.
- **Upgrade gate** (`upgrade.sh`) — installs the latest release tag's schema, applies
  `install.sql` over it, and runs the full test suite. Catches migration breaks.
- **Doc drift reviewer** — an advisory AI reviewer that flags doc/code divergence.
- **Markdown lint + link checker** — prevents broken internal links and formatting rot.

No new CI gates are proposed. The existing gates cover the mechanical discipline; the
checklist above covers the judgment calls that automation cannot.

## How to use this going forward

- **Before opening a PR** that touches the actuation path, walk the checklist above.
  It is not a CI gate — it is a thinking tool. The judgment calls (failure modes,
  traceability) are the ones that matter.
- **When adding a new actuator or objective**, re-walk the Phase 1 checklists against
  the new path and extend the FMEA inventory. A new actuator is a new failure surface.
- **Periodically** (e.g. before a major release), re-read the traceability spine and
  confirm the test citations are still accurate — test files can be renamed or
  refactored.

## Exit criteria

Per the charter — the process is documented and committed; the checklist is actionable;
CI-enforcement decisions are explicit (existing gates suffice; no new ones proposed).

- [x] Standing review checklist for actuation-path changes documented.
- [x] CI-enforcement posture explicit (existing gates are sufficient).
- [x] Reusable assets catalogued for future review cycles.
