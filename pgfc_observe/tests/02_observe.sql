-- effective_reloption() helper and observe() core behavior.
BEGIN;
SELECT plan(10);

-- ── effective_reloption() ────────────────────────────────────────────────────
SELECT is(
    pgfc_observe.effective_reloption(
        ARRAY['autovacuum_vacuum_scale_factor=0.05'], 'autovacuum_vacuum_scale_factor'),
    '0.05', 'effective_reloption reads an explicit value');
SELECT is(
    pgfc_observe.effective_reloption(
        ARRAY['autovacuum_vacuum_scale_factor=0.05'], 'autovacuum_vacuum_threshold'),
    NULL, 'effective_reloption returns NULL for an unset option');
SELECT is(
    pgfc_observe.effective_reloption(NULL, 'autovacuum_vacuum_scale_factor'),
    NULL, 'effective_reloption tolerates NULL reloptions');

-- ── observe() ────────────────────────────────────────────────────────────────
CREATE TABLE public.obs_plain (id int);
CREATE TABLE public.obs_opt (id int)
    WITH (autovacuum_vacuum_scale_factor = 0.05, autovacuum_vacuum_threshold = 1000);

SELECT lives_ok($$ SELECT pgfc_observe.observe() $$, 'observe() runs');

SELECT isnt((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), NULL,
            'a snapshot header row was written');

SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 'obs_plain'),
          1::bigint, 'obs_plain was sampled');

-- reloptions captured (assert via the helper to stay order-independent)
SELECT is(
    pgfc_observe.effective_reloption(
        (SELECT reloptions FROM pgfc_observe.relation_samples
          WHERE relname = 'obs_opt' ORDER BY snapshot_id DESC LIMIT 1),
        'autovacuum_vacuum_scale_factor'),
    '0.05', 'obs_opt reloptions captured verbatim');

-- exclusions
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE schemaname = 'pgfc_observe'),
          0::bigint, 'own schema is excluded from sampling');
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE schemaname = 'pg_catalog'),
          0::bigint, 'pg_catalog is excluded from sampling');

-- catalog self-monitoring populated
SELECT isnt((SELECT pg_class_size_bytes FROM pgfc_observe.snapshots
              ORDER BY snapshot_id DESC LIMIT 1), NULL,
            'pg_class catalog health is captured in the header');

SELECT * FROM finish();
ROLLBACK;
