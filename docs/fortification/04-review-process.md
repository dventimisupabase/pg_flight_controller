# Phase 4 — Review process

**Status:** Not started (stub — fleshed out when Phase 3 closes).

The discipline that outlives this phase. Fortification is a one-time deep pass; this phase
distills it into a repeatable, lightweight process so the system stays reviewed as it
grows — especially as new actuators and objectives (beyond Phase 1.7) arrive.

## Method (intended)

- Capture the durable artifacts from Phases 1–3 as reusable assets: the finding schema,
  the severity rubric, the `apply()`-path checklists, and the traceability spine.
- Decide what becomes a **standing gate** vs. a **periodic review**: e.g. a security
  checklist required for any change touching the actuation path; a traceability-spine
  update required when an invariant/mechanism changes; a periodic FMEA refresh.
- Consider automation hooks (CI or PR template) that keep the spine and checklists honest
  without manual nagging — analogous to the existing doc-drift and reference-staleness
  gates.
- Define how external reviewers plug in (the `fortification` label, an RFC/review doc
  pattern, the umbrella-issue model) given there is no project chat.

## Deliverables (intended)

- A short, committed **review checklist** for actuation-path changes.
- A note in `CLAUDE.md` / contributor docs pointing here.
- A decision on which checks (if any) become CI-enforced.

## Exit criteria

Per the charter — the process is documented, committed, and referenced from the
contributor guidance; any agreed automation is filed as issues.
