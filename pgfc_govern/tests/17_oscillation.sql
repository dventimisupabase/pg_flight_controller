-- Phase 1.7 F5: control-oscillation detection. A scale factor that flaps — repeatedly
-- increased then decreased — is the controller fighting itself (appendix F "Control
-- Oscillation Detection"), a SAFETY failure. The increment wires three things together:
--   1. Detection. _oscillating_relations() reads action_history (applied only) and counts
--      DIRECTION REVERSALS per relation within the governed oscillation_window; a relation
--      with >= oscillation_min_reversals is flapping. A monotonic ramp or a single overshoot
--      is NOT oscillation.
--   2. Diagnostic mode + suppression. The governor_metrics oscillating-relations count feeds
--      evaluate_health(), which trips diagnostic; the F4 authority gate then suspends
--      actuation CLUSTER-WIDE (not just for the flapping table) — proved here against a
--      separate, fresh, non-rate-limited relation so the refusal is the gate, not min_interval.
--   3. Operator visibility + recovery. _reconcile_oscillation() (run from plan()) raises ONE
--      stable critical finding per flapping relation — NOT churned by the saturation
--      reconciler each cycle — and auto-resolves it once the relation stops flapping.
-- Injected timestamps are explicit and increasing: lag()-ordered detection is only
-- deterministic when applied_at values differ (production spaces them by min_interval).
BEGIN;
SELECT plan(22);

-- ── shape ────────────────────────────────────────────────────────────────────────
SELECT has_function('pgfc_govern', '_oscillating_relations',
                    '_oscillating_relations() detector exists');
SELECT has_function('pgfc_govern', '_reconcile_oscillation',
                    '_reconcile_oscillation() exists');
SELECT has_column('pgfc_govern', 'governor_metrics', 'oscillating_relations',
                  'governor_metrics exposes the oscillating-relations count');

-- ── detection: a flap is caught, a ramp is not ─────────────────────────────────────
CREATE TABLE public.osc_a (id int);   -- A->B->A->B flap (2 reversals)
CREATE TABLE public.osc_b (id int);   -- monotonic ramp (0 reversals)
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, status, applied_at) VALUES
  (1, 'public.osc_a'::regclass, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now() - interval '4 hours'),
  (1, 'public.osc_a'::regclass, 'autovacuum_vacuum_scale_factor', '0.10', 'applied', now() - interval '3 hours'),
  (1, 'public.osc_a'::regclass, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now() - interval '2 hours'),
  (1, 'public.osc_a'::regclass, 'autovacuum_vacuum_scale_factor', '0.10', 'applied', now() - interval '1 hour'),
  (2, 'public.osc_b'::regclass, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now() - interval '3 hours'),
  (2, 'public.osc_b'::regclass, 'autovacuum_vacuum_scale_factor', '0.10', 'applied', now() - interval '2 hours'),
  (2, 'public.osc_b'::regclass, 'autovacuum_vacuum_scale_factor', '0.20', 'applied', now() - interval '1 hour');

SELECT is((SELECT reversals FROM pgfc_govern._oscillating_relations()
            WHERE relid = 'public.osc_a'::regclass),
          2::bigint, 'osc_a A->B->A->B flap = 2 direction reversals (detected)');
SELECT ok(NOT EXISTS (SELECT 1 FROM pgfc_govern._oscillating_relations()
                       WHERE relid = 'public.osc_b'::regclass),
          'a monotonic ramp is not flagged as oscillation');
SELECT is((SELECT oscillating_relations FROM pgfc_govern.governor_metrics),
          1::bigint, 'governor_metrics counts exactly the one oscillating relation');

-- ── boundary: a single overshoot (1 reversal) is below the threshold ───────────────
CREATE TABLE public.osc_c (id int);
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, status, applied_at) VALUES
  (3, 'public.osc_c'::regclass, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now() - interval '3 hours'),
  (3, 'public.osc_c'::regclass, 'autovacuum_vacuum_scale_factor', '0.10', 'applied', now() - interval '2 hours'),
  (3, 'public.osc_c'::regclass, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now() - interval '1 hour');
SELECT ok(NOT EXISTS (SELECT 1 FROM pgfc_govern._oscillating_relations()
                       WHERE relid = 'public.osc_c'::regclass),
          'a single overshoot (1 reversal) is below oscillation_min_reversals — not oscillation');

-- ── window: a flap entirely older than oscillation_window does not count ────────────
CREATE TABLE public.osc_old (id int);
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, status, applied_at) VALUES
  (4, 'public.osc_old'::regclass, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now() - interval '4 days'),
  (4, 'public.osc_old'::regclass, 'autovacuum_vacuum_scale_factor', '0.10', 'applied', now() - interval '4 days' + interval '1 hour'),
  (4, 'public.osc_old'::regclass, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now() - interval '4 days' + interval '2 hours'),
  (4, 'public.osc_old'::regclass, 'autovacuum_vacuum_scale_factor', '0.10', 'applied', now() - interval '4 days' + interval '3 hours');
SELECT ok(NOT EXISTS (SELECT 1 FROM pgfc_govern._oscillating_relations()
                       WHERE relid = 'public.osc_old'::regclass),
          'a flap entirely outside oscillation_window is not detected');

-- ── diagnostic mode: an oscillating relation drives the governor to diagnostic ──────
SELECT is(pgfc_govern.evaluate_health()::text, 'diagnostic',
          'an oscillating relation drives evaluate_health() to diagnostic');
SELECT ok((SELECT reason LIKE '%oscillating%' FROM pgfc_govern.governor_state),
          'governor_state reason names the oscillation');
SELECT ok(EXISTS (SELECT 1 FROM pgfc_govern.state_transitions WHERE to_state = 'diagnostic'),
          'the transition into diagnostic is audited');

-- ── suppression is cluster-wide: a fresh, non-rate-limited relation is also refused ──
-- (so the refusal is the authority gate, not the per-relation min_interval rate limit).
CREATE TABLE public.osc_fresh (id int);
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.osc_fresh'::regclass;
SELECT pgfc_govern.control_tick();   -- evaluate_health -> diagnostic (osc_a still flaps); plans osc_fresh
CREATE TEMP TABLE _tk AS SELECT max(tick_id) AS id FROM pgfc_govern.tick_log;

SELECT is((SELECT state::text FROM pgfc_govern.governor_state), 'diagnostic',
          'control_tick keeps the governor in diagnostic while osc_a flaps');
SELECT is((SELECT decision FROM pgfc_govern.decision_log
            WHERE tick_id = (SELECT id FROM _tk) AND relid = 'public.osc_fresh'::regclass
              AND actuator = 'autovacuum_vacuum_scale_factor'
            ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'osc_fresh was planned an adjust (so a refusal is the gate, not a no-op)');
SELECT ok(NOT pgfc_govern.apply((SELECT id FROM _tk), 'public.osc_fresh'::regclass),
          'authority gate: a fresh, non-oscillating relation is ALSO refused (cluster-wide suspension)');
SELECT is(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.osc_fresh'::regclass),
              'autovacuum_vacuum_scale_factor'),
          NULL, 'osc_fresh was never actuated while actuation was suspended');

-- ── operator visibility: ONE stable critical finding, not churned each cycle ───────
SELECT is((SELECT count(*) FROM pgfc_govern.diagnostics
            WHERE relid = 'public.osc_a'::regclass AND inhibitor_class = 'control_oscillation'
              AND resolved_at IS NULL),
          1::bigint, 'exactly one unresolved oscillation diagnostic for osc_a');
CREATE TEMP TABLE _d AS SELECT detected_at FROM pgfc_govern.diagnostics
  WHERE relid = 'public.osc_a'::regclass AND inhibitor_class = 'control_oscillation'
    AND resolved_at IS NULL;
SELECT pgfc_govern.control_tick();   -- a second cycle, osc_a still flapping
SELECT is((SELECT count(*) FROM pgfc_govern.diagnostics
            WHERE relid = 'public.osc_a'::regclass AND inhibitor_class = 'control_oscillation'
              AND resolved_at IS NULL),
          1::bigint, 'still exactly one — the saturation reconciler does not churn the F5 class');
SELECT is((SELECT detected_at FROM pgfc_govern.diagnostics
            WHERE relid = 'public.osc_a'::regclass AND inhibitor_class = 'control_oscillation'
              AND resolved_at IS NULL),
          (SELECT detected_at FROM _d),
          'detected_at is stable across cycles (one continuous finding, not re-opened)');
SELECT is((SELECT severity FROM pgfc_govern.diagnostics
            WHERE relid = 'public.osc_a'::regclass AND inhibitor_class = 'control_oscillation'
              AND resolved_at IS NULL),
          'critical', 'the oscillation diagnostic is critical (a cluster-wide actuation halt)');
SELECT ok(EXISTS (SELECT 1 FROM pgfc_govern.active_diagnostics
                   WHERE relid = 'public.osc_a'::regclass
                     AND inhibitor_class = 'control_oscillation'),
          'the oscillation is operator-visible in active_diagnostics');

-- ── recovery: once the flapping ages out, the governor returns to normal and resolves ──
DELETE FROM pgfc_govern.action_history WHERE relid = 'public.osc_a'::regclass;
SELECT is(pgfc_govern.evaluate_health()::text, 'normal',
          'with the oscillation gone, the governor recovers to normal automatically');
SELECT pgfc_govern.control_tick();   -- plan() -> _reconcile_oscillation resolves the finding
SELECT ok(NOT EXISTS (SELECT 1 FROM pgfc_govern.active_diagnostics
                       WHERE relid = 'public.osc_a'::regclass
                         AND inhibitor_class = 'control_oscillation'),
          'the oscillation diagnostic resolves once the relation stops flapping');

SELECT * FROM finish();
ROLLBACK;
