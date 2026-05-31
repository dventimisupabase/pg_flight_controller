-- Phase 1.7 F6: load shedding + the failure-classification taxonomy.
--
-- Load shedding (appendix F "Load Shedding"): when the database is under connection
-- pressure, the governor sheds its own load by entering diagnostic so the F4 authority gate
-- suspends actuation cluster-wide — it stops competing for locks and consumes fewer resources
-- when the database needs them most. The stress signal is born-governed (load_shed_connection_pct,
-- a stress %) and sourced from the NEWEST snapshot's client_backends/max_connections, so it is
-- injected the same way the observation-lag signal is: write a snapshot, call evaluate_health().
--
-- Failure taxonomy (appendix F "Failure Classification"): every recorded failure carries one
-- of five categories — observation / decision / actuation / resource / safety. _failure_class()
-- is the single-source mapping (apply() stamps action_history.failure_class through it); the
-- failure_taxonomy view unifies the whole failure picture into five rows, condition_present
-- drawn from the same substrate the health-state machine reads.
BEGIN;
SELECT plan(35);

-- ════════════════════════════════════════════════════════════════════════════════
-- Load shedding
-- ════════════════════════════════════════════════════════════════════════════════

-- ── shape ────────────────────────────────────────────────────────────────────────
SELECT has_column('pgfc_govern', 'governor_metrics', 'connection_pressure',
                  'governor_metrics exposes connection_pressure');
SELECT has_column('pgfc_govern', 'governor_metrics', 'client_backends',
                  'governor_metrics exposes client_backends');
SELECT has_column('pgfc_govern', 'governor_metrics', 'max_connections',
                  'governor_metrics exposes max_connections');
SELECT is((SELECT count(*) FROM pgfc_govern.parameter_registry
            WHERE parameter_name = 'load_shed_connection_pct'), 1::bigint,
          'load_shed_connection_pct is a registered (born-governed) parameter');

-- ── boot: no snapshot → NULL pressure → not ill health ─────────────────────────────
SELECT is((SELECT connection_pressure FROM pgfc_govern.governor_metrics), NULL::numeric,
          'connection_pressure is NULL when nothing has been observed yet');
SELECT is(pgfc_govern.evaluate_health()::text, 'normal',
          'a NULL connection_pressure (boot) is not load shedding — normal');

-- ── connection pressure above the threshold → shed load (diagnostic) ───────────────
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at, client_backends, max_connections)
VALUES (170000, now(), 95, 100);   -- 95% pressure, default threshold 0.90
SELECT ok((SELECT connection_pressure = 0.95 FROM pgfc_govern.governor_metrics),
          'connection_pressure = client_backends / max_connections (0.95) from the newest snapshot');
SELECT is((SELECT connection_pressure_pct FROM pgfc_govern.governor_metrics), 95::numeric,
          'connection_pressure_pct is the whole-percent form (95) for the reason string');
SELECT is(pgfc_govern.evaluate_health()::text, 'diagnostic',
          'connection pressure past load_shed_connection_pct → diagnostic (shed load)');
SELECT ok((SELECT reason LIKE '%connection pressure%' FROM pgfc_govern.governor_state),
          'governor_state reason names the connection pressure');
SELECT ok((SELECT reason LIKE '%shedding load%' FROM pgfc_govern.governor_state),
          'governor_state reason says it is shedding load');
SELECT ok(EXISTS (SELECT 1 FROM pgfc_govern.state_transitions
                   WHERE to_state = 'diagnostic' AND reason LIKE '%connection pressure%'),
          'the load-shedding transition into diagnostic is audited');

-- ── the shed-load diagnostic is persisted to governor_state (what the F4 gate reads) ─
-- The gate's behavior on the diagnostic state is F4's contract (proved in 16/17); here we
-- only need that load shedding writes the same diagnostic state the gate keys off.
SELECT is((SELECT state::text FROM pgfc_govern.governor_state), 'diagnostic',
          'evaluate_health persists the diagnostic state the F4 authority gate consults');

-- ── just below the threshold stays normal ──────────────────────────────────────────
DELETE FROM pgfc_observe.snapshots;
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at, client_backends, max_connections)
VALUES (170000, now(), 89, 100);   -- 89% < 90%
SELECT is(pgfc_govern.evaluate_health()::text, 'normal',
          'connection pressure just below the threshold does not shed load');

-- ── a pre-F6 snapshot (NULL inputs) is not treated as load ──────────────────────────
DELETE FROM pgfc_observe.snapshots;
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at)
VALUES (170000, now());   -- client_backends / max_connections NULL
SELECT is((SELECT connection_pressure FROM pgfc_govern.governor_metrics), NULL::numeric,
          'a snapshot without the F6 inputs yields NULL pressure (not collected, not "no load")');
SELECT is(pgfc_govern.evaluate_health()::text, 'normal',
          'a NULL-input snapshot does not shed load');

-- ── recovery: pressure eases → back to normal automatically (transient, no window) ──
DELETE FROM pgfc_observe.snapshots;
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at, client_backends, max_connections)
VALUES (170000, now(), 98, 100);
SELECT is(pgfc_govern.evaluate_health()::text, 'diagnostic', 'shedding again under renewed pressure');
DELETE FROM pgfc_observe.snapshots;
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at, client_backends, max_connections)
VALUES (170000, now(), 10, 100);
SELECT is(pgfc_govern.evaluate_health()::text, 'normal',
          'once pressure eases the governor recovers to normal immediately (no cooldown window)');
DELETE FROM pgfc_observe.snapshots;

-- ── the live collection path: observe() itself populates the inputs ────────────────
-- The hand-injected snapshots above prove the signal PROCESSING; this proves the signal is
-- actually COLLECTED. The test's own psql session is a client backend, and the container's
-- max_connections is the live GUC, so a real observe() yields a sane sub-1 pressure.
SELECT pgfc_observe.observe();
SELECT is((SELECT max_connections FROM pgfc_govern.governor_metrics),
          current_setting('max_connections')::int,
          'observe() populates max_connections from the live GUC');
SELECT ok((SELECT client_backends >= 1 AND connection_pressure > 0 AND connection_pressure < 1
           FROM pgfc_govern.governor_metrics),
          'observe() populates a sane connection_pressure (the test session is a client backend)');

-- ════════════════════════════════════════════════════════════════════════════════
-- Failure taxonomy
-- ════════════════════════════════════════════════════════════════════════════════

-- ── shape ────────────────────────────────────────────────────────────────────────
SELECT has_function('pgfc_govern', '_failure_class', ARRAY['text'],
                    '_failure_class(text) mapping function exists');
SELECT has_column('pgfc_govern', 'action_history', 'failure_class',
                  'action_history has the failure_class column');
SELECT has_view('pgfc_govern', 'failure_taxonomy', 'the failure_taxonomy view exists');

-- ── the mapping is the single source of the five-category vocabulary ────────────────
SELECT is(pgfc_govern._failure_class('lock_timeout'), 'actuation',
          'lock_timeout is an actuation failure');
SELECT is(pgfc_govern._failure_class('insufficient_privilege'), 'actuation',
          'insufficient_privilege is an actuation failure');
SELECT is(pgfc_govern._failure_class('something_unknown'), NULL,
          'an unrecognized reason is left unclassified (NULL), never mislabeled');

-- ── the view is always five rows, one per category, condition_present never NULL ────
SELECT is((SELECT count(*) FROM pgfc_govern.failure_taxonomy), 5::bigint,
          'failure_taxonomy reports all five categories');
SELECT bag_eq(
    'SELECT failure_class FROM pgfc_govern.failure_taxonomy',
    $$ VALUES ('observation'::text),('decision'),('actuation'),('resource'),('safety') $$,
    'the five categories are exactly the appendix-F taxonomy');
SELECT is((SELECT count(*) FROM pgfc_govern.failure_taxonomy WHERE condition_present IS NULL),
          0::bigint, 'condition_present is never NULL (a clean governor reports all false)');
SELECT is((SELECT count(*) FROM pgfc_govern.failure_taxonomy WHERE condition_present), 0::bigint,
          'a clean governor has no category in failure');

-- ── recorded actuation failures are counted + classified ───────────────────────────
INSERT INTO pgfc_govern.action_history
    (batch_id, relid, actuator, new_value, status, failure_reason, failure_class, applied_at)
VALUES (1, 'pg_class'::regclass, 'autovacuum_vacuum_scale_factor', '0.05',
        'failed', 'lock_timeout', pgfc_govern._failure_class('lock_timeout'), now());
SELECT is((SELECT recorded_failures_last_day FROM pgfc_govern.failure_taxonomy
            WHERE failure_class = 'actuation'), 1::bigint,
          'a recorded lock_timeout failure is counted under actuation');
SELECT ok((SELECT condition_present FROM pgfc_govern.failure_taxonomy
            WHERE failure_class = 'actuation'),
          'a recent failed action lights up the actuation category');

-- ── the non-actuation categories surface their live conditions too (unified view) ───
-- safety: a flapping relation (F5 oscillation) is a safety-class failure
CREATE TABLE public.ls_osc (id int);
INSERT INTO pgfc_govern.action_history (batch_id, relid, actuator, new_value, status, applied_at) VALUES
  (2, 'public.ls_osc'::regclass, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now() - interval '3 hours'),
  (2, 'public.ls_osc'::regclass, 'autovacuum_vacuum_scale_factor', '0.10', 'applied', now() - interval '2 hours'),
  (2, 'public.ls_osc'::regclass, 'autovacuum_vacuum_scale_factor', '0.05', 'applied', now() - interval '1 hour'),
  (2, 'public.ls_osc'::regclass, 'autovacuum_vacuum_scale_factor', '0.10', 'applied', now());
SELECT ok((SELECT condition_present FROM pgfc_govern.failure_taxonomy WHERE failure_class = 'safety'),
          'control oscillation lights up the safety category');
-- resource: over the storage footprint budget
UPDATE pgfc_govern.storage_config SET budget_bytes = 0;
SELECT ok((SELECT condition_present FROM pgfc_govern.failure_taxonomy WHERE failure_class = 'resource'),
          'over the storage budget lights up the resource category');
UPDATE pgfc_govern.storage_config SET budget_bytes = NULL;
-- decision: a control cycle that errored
INSERT INTO pgfc_govern.tick_log (snapshot_id, started_at, error)
VALUES (NULL, now(), 'boom');
SELECT ok((SELECT condition_present FROM pgfc_govern.failure_taxonomy WHERE failure_class = 'decision'),
          'a tick error lights up the decision category');

SELECT * FROM finish();
ROLLBACK;
