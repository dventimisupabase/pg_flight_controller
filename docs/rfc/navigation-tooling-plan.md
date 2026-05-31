# RFC bottom-up navigation — build plan

> **Status:** Plan drafted; build not started. This is a durable runbook for completing the
> RFC's §6/§8 bottom-up navigation across multiple PRs that may span agent context resets.

## How to use this document (hydration)

If you are resuming this work — possibly in a fresh context:

1. Read this document top to bottom.
2. Check **[Status](#status)** for the next incomplete step.
3. The **[object → subsystem map](#object--subsystem-map-working-checklist)** is the working
   checklist. Its **canonical** source is RFC §5 ([README.md](README.md#5-subsystems)) and,
   above that, the code itself; if this table and §5 ever disagree, §5 and the code win —
   fix the table.
4. Run the **[verification commands](#verification-quick-reference)** to confirm the current
   on-disk state before changing anything.
5. Execute the next PR's steps; honor the **[invariants & gotchas](#invariants--gotchas)**.
6. Update **Status** and the step checkboxes **in the same PR**.

## Goal

Deliver the bottom-up half of the RFC: from any database object, find its **home
subsystem** and its **siblings**, generated from object metadata and CI-gated so it cannot
drift. The richer **consumer** cross-edges stay hand-authored in RFC §5 (they are not
reliably catalog-derivable; see [scope boundary](#scope-boundary)).

## Locked decisions

- **Subsystem membership lives in `COMMENT ON` tags** (not a registry function).
- **Full scope including reference-injection** — the generated reference renders each
  object's subsystem as a field.

## Tag convention

- Every in-scope object's `COMMENT ON` **ends with** a trailing marker: `[subsystem:<ID>]`
  where `<ID>` is one of `O1`–`O5` or `G1`–`G7`.
- Parse regex: `\[subsystem:([OG][0-9])\]`.
- Objects that currently lack a comment **get one** (a real description) ending with the
  marker — a hygiene win, and the exhaustiveness gate enforces it going forward.
- `gen_reference.sql` strips the marker from the rendered prose and re-emits it as a
  dedicated **Subsystem** field, so the marker never appears as raw prose in the reference.

**In-scope object kinds** (match what `gen_reference.sql` renders): tables (`relkind`
`r`/`p`, excluding child partitions), views (`v`/`m`), functions, and enum types. Sequences
are **out of scope** — the reference has no Sequences section, so `batch_seq` is listed in
the map for completeness but is **not** tagged and **not** checked by the gate. (If we later
add a Sequences section to the reference, bring `batch_seq` into scope.)

## Status

- [x] **PR 1 — metadata + reference injection + exhaustiveness gate (atomic).** Merged
  (#55). See [steps](#pr-1--metadata--reference-injection--exhaustiveness-gate).
- [x] **PR 2 — bottom-up index + staleness gate + RFC wiring.** See
  [steps](#pr-2--bottom-up-index--staleness-gate--rfc-wiring).

Update this section and the per-PR checkboxes as each lands. Record merged PR numbers here.

## PR 1 — metadata + reference injection + exhaustiveness gate

These three land **together** (atomic): adding tags to comments would otherwise dirty the
generated reference and break the "Reference up to date" gate.

- [x] Add `[subsystem:<ID>]` to every in-scope object's `COMMENT ON` in
  [`pgfc_observe/install.sql`](../../pgfc_observe/install.sql) and
  [`pgfc_govern/install.sql`](../../pgfc_govern/install.sql), per the
  [map](#object--subsystem-map-working-checklist). Add a real comment to any object lacking
  one (~17 objects; observe has 33 comments / govern 40, vs. the in-scope counts below).
- [x] Update [`scripts/gen_reference.sql`](../../scripts/gen_reference.sql) to: parse the
  marker, strip it from the rendered comment prose, and emit a `**Subsystem:** <ID>` field
  for each object (table/view/function/type).
- [x] Regenerate the reference (`scripts/gen-reference.sh`) and commit the updated
  [`docs/reference/pgfc_observe.md`](../reference/pgfc_observe.md) and
  [`docs/reference/pgfc_govern.md`](../reference/pgfc_govern.md).
- [x] New pgTAP test (one per schema, or shared) asserting **every in-scope object carries
  exactly one valid subsystem tag** — the "every object is classified" gate. Place under
  `pgfc_observe/tests/` and `pgfc_govern/tests/`; it runs in the existing PG 15–18 matrix.
  Query `pg_description` joined to `pg_class`/`pg_proc`/`pg_type`; fail on any in-scope object
  whose comment is NULL or lacks the marker, or whose marker ID is not in the valid set.
- [x] **Exit:** all CI green — `Markdown Lint`, `Links`, `Reference up to date`, the pgTAP
  matrix (new gate passes), `Doctests`, `Doc Drift Review`, `base-is-main`.

## PR 2 — bottom-up index + staleness gate + RFC wiring

- [x] A `pg_temp` generator ([`scripts/gen_subsystem_map.sql`](../../scripts/gen_subsystem_map.sql),
  modelled on [`scripts/gen_reference.sql`](../../scripts/gen_reference.sql)) emitting
  `docs/reference/subsystem-map.md`: grouped **by subsystem**, listing each member object
  (the siblings). Each object links **down** to its reference entry (anchors reconstruct the
  exact reference headings, slugified with check-links.py's algorithm); each subsystem
  heading links **up** to its RFC §5 anchor. Deterministic ordering (ORDER BY everywhere).
  The flat object → subsystem index was dropped as redundant (the grouped view already gives
  home + siblings).
- [x] A sibling wrapper ([`scripts/gen-subsystem-map.sh`](../../scripts/gen-subsystem-map.sh))
  that writes the file in Docker on the pinned PG version.
- [x] CI **staleness gate** (`Subsystem map up to date`) for the index (regenerate, fail on
  diff) in `.github/workflows/docs.yml` — mirrors the existing "Reference up to date" job.
  No new pgTAP: PR 2 touches no `install.sql`, and the map is purely catalog-derived.
- [x] Wired RFC §6 to link `subsystem-map.md` (dropped "to build") and §8 to document the
  tag convention + both gates (exhaustiveness + staleness), pointing at this plan.
- [x] **Exit:** all CI green, including the new index-staleness gate; the RFC's §6/§8
  describe and link the generated bottom-up navigation.

## Scope boundary

- **Generated:** home subsystem + siblings (both fall out of the tag) + the up-link to RFC
  §5.
- **Authored, not generated:** consumer / cross-edges (the `→` lines in §5). PL/pgSQL bodies
  reference objects only as text and `pg_depend` misses them, so consumers are not reliably
  catalog-derivable. The per-object index entry links up to §5, where consumers are described.
- **Out:** automatic edge derivation; per-object code line-anchors (reference + source links
  already cover that); sequences (see the tag convention).

## Invariants & gotchas

- **PR 1 is atomic** — tags + generator change + regenerated reference in one PR, or the
  `Reference up to date` gate breaks.
- **Merge-then-branch** — one increment per PR, base `main`, no stacked PRs (CI-enforced by
  `base-is-main`). Merge PR 1 before branching PR 2.
- **Markdown rules** (CI-enforced): ATX headings; dash (`-`) bullets; **asterisk** emphasis
  only — never underscore (keep object names in backticks so their `_` is a code span, not
  emphasis); blank lines around lists/headings/code/tables.
- **No backward links** into `in/` or `out/` (frozen design docs).
- **Anchors are validated** by `scripts/check-links.py` and markdownlint MD051 — every
  intra-doc and cross-doc `#anchor` must resolve. RFC §5 subsystem anchors are stable:
  `#o1-collection` … `#o5-parameter-registry`, `#g1-control-loop-ooda`,
  `#g2-policy-and-intent`, `#g3-parameter-governance`, `#g4-self-protection-f1-f7`,
  `#g5-diagnostics`, `#g6-storage-retention-and-self-maintenance`, `#g7-status-and-reporting`.
- **Generators must be deterministic** (ORDER BY every loop) and pinned to one PG version, so
  the staleness diff is stable — exactly as `gen_reference.sql` / `gen-reference.sh` already do.

## Verification quick-reference

Run from the repo root:

- Markdown lint: `npx --yes markdownlint-cli2 "docs/**/*.md" "*.md"`
- Internal links + anchors: `python3 scripts/check-links.py .`
- Regenerate + check reference drift: `scripts/gen-reference.sh` then `git diff docs/reference/`
- pgTAP (fast / full): `./test.sh 17` / `./test.sh`
- Doctests: `scripts/run-doctests.sh`

CI gates that must stay green: `Markdown Lint`, `Links`, `Reference up to date`, `Doctests`,
`Doc Drift Review`, `PostgreSQL 15/16/17/18`, `base-is-main`.

## Relevant files

- Extension SQL (where tags + the trigger live):
  [`pgfc_observe/install.sql`](../../pgfc_observe/install.sql),
  [`pgfc_govern/install.sql`](../../pgfc_govern/install.sql).
- Reference generator: [`scripts/gen_reference.sql`](../../scripts/gen_reference.sql) +
  [`scripts/gen-reference.sh`](../../scripts/gen-reference.sh).
- Generated reference (PR 1 regenerates; PR 2 adds the index):
  [`docs/reference/`](../reference/pgfc_observe.md).
- The RFC: [`README.md`](README.md) — §5 anchors (up-links) and §6/§8 (wiring).
- CI: `.github/workflows/docs.yml` (Reference / Links / Doctests / Doc-drift),
  `.github/workflows/test.yml` (pgTAP matrix), `.github/workflows/pr-hygiene.yml`
  (`base-is-main`).

## Object → subsystem map (working checklist)

Canonical source is RFC §5; this is the working checklist for tagging. In-scope kinds:
table / view / function / enum type. `batch_seq` (sequence) is listed for completeness but
is out of tag scope.

**Subsystem legend** (links to RFC §5): observe — [O1](README.md#o1-collection),
[O2](README.md#o2-storage-and-retention), [O3](README.md#o3-derived-state-and-readers),
[O4](README.md#o4-self-monitoring-and-budget), [O5](README.md#o5-parameter-registry);
govern — [G1](README.md#g1-control-loop-ooda), [G2](README.md#g2-policy-and-intent),
[G3](README.md#g3-parameter-governance), [G4](README.md#g4-self-protection-f1-f7),
[G5](README.md#g5-diagnostics), [G6](README.md#g6-storage-retention-and-self-maintenance),
[G7](README.md#g7-status-and-reporting).

### pgfc_observe (30 objects; 30 in tag scope)

| Object | Kind | Subsystem |
| --- | --- | --- |
| `observe()` | function | O1 |
| `collection_policy` | table | O1 |
| `relation_last_state` | table (UNLOGGED) | O1 |
| `relation_samples` | table (partitioned) | O2 |
| `snapshots` | table (partitioned) | O2 |
| `rollup_1m` | table (partitioned) | O2 |
| `rollup_1h` | table (partitioned) | O2 |
| `rollup_1d` | table (partitioned) | O2 |
| `_ensure_partition()` | function | O2 |
| `_ensure_part()` | function | O2 |
| `_partition_inventory()` | function | O2 |
| `_epoch_day()` | function | O2 |
| `_epoch_month()` | function | O2 |
| `_month_start()` | function | O2 |
| `retain()` | function | O2 |
| `drop_empty_partitions()` | function | O2 |
| `rollup()` | function | O2 |
| `rollup_retain()` | function | O2 |
| `_rollup_coarsen()` | function | O2 |
| `_rollup_inventory()` | function | O2 |
| `current_rollup()` | function | O2 |
| `_telemetry_reloptions()` | function | O2 |
| `relation_health` | view | O3 |
| `maintenance_debt` | view | O3 |
| `current_relation_state()` | function | O3 |
| `removability_horizons()` | function | O3 |
| `effective_reloption()` | function | O3 |
| `self_health` | view | O4 |
| `storage_budget()` | function | O4 |
| `_parameter_registry()` | function | O5 |

### pgfc_govern (51 objects; 50 in tag scope — `batch_seq` excluded)

| Object | Kind | Subsystem |
| --- | --- | --- |
| `observe_tick()` | function | G1 |
| `control_tick()` | function | G1 |
| `tick_log` | table | G1 |
| `classify()` | function | G1 |
| `relation_class` | table | G1 |
| `relation_kind` | enum type | G1 |
| `_class_target()` | function | G1 |
| `estimate()` | function | G1 |
| `relation_estimate` | table | G1 |
| `ewma()` | function | G1 |
| `plan()` | function | G1 |
| `decision_log` | table | G1 |
| `snap_sf()` | function | G1 |
| `_sf_grid()` | function | G1 |
| `apply()` | function | G1 |
| `actuator_state` | table | G1 |
| `action_history` | table | G1 |
| `batch_seq` | sequence (out of scope) | G1 |
| `verify()` | function | G1 |
| `policy` | table | G2 |
| `policy_history` | table | G2 |
| `_log_policy_change()` | function | G2 |
| `parameter_registry` | view | G3 |
| `_parameter_registry()` | function | G3 |
| `_param()` | function | G3 |
| `_audit_control_literals()` | function | G3 |
| `validate_parameters()` | function | G3 |
| `governor_state` | table | G4 |
| `state_transitions` | table | G4 |
| `governor_health_state` | enum type | G4 |
| `governor_metrics` | view | G4 |
| `evaluate_health()` | function | G4 |
| `force_state()` | function | G4 |
| `clear_forced_state()` | function | G4 |
| `disable()` | function | G4 |
| `suspend_actuation()` | function | G4 |
| `_oscillating_relations()` | function | G4 |
| `_reconcile_oscillation()` | function | G4 |
| `_failure_class()` | function | G4 |
| `failure_taxonomy` | view | G4 |
| `diagnostics` | table | G5 |
| `active_diagnostics` | view | G5 |
| `_findings()` | function | G5 |
| `_reconcile_diagnostics()` | function | G5 |
| `storage_config` | table | G6 |
| `storage_budget()` | function | G6 |
| `self_health` | view | G6 |
| `retain()` | function | G6 |
| `degrade()` | function | G6 |
| `governor_status` | view | G7 |
| `catalog_health` | view | G7 |
