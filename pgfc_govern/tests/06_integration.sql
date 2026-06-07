-- Composition: the real estimate -> classify -> plan(control_tick) chain across two
-- cycles on multiple varied relations (large-churn, queue, small, and EMPTY) — the
-- regime where cross-relation bugs (e.g. the empty-table division) actually appear.
-- (pg_stat_* counters don't update inside an uncommitted txn, so samples are seeded;
-- observe()->samples is covered separately in pgfc_observe/tests.)
BEGIN;
SELECT plan(6);

-- two snapshots, 60s apart, healthy horizon
INSERT INTO pgfc_observe.snapshots
  (server_version_num, collected_at, def_vac_scale_factor, def_vac_threshold,
   def_ana_threshold, def_ana_scale_factor, def_freeze_max_age, def_mxid_freeze_max_age, oldest_xmin_owner)
VALUES (170000, '2026-02-01 00:00:00+00', 0.2, 50, 50, 0.1, 200000000, 400000000, 'none'),
       (170000, '2026-02-01 00:01:00+00', 0.2, 50, 50, 0.1, 200000000, 400000000, 'none');

-- per-relation samples: cumulative counters; deltas S1->S2 drive estimate/classify.
-- Snapshot 1 (baseline)
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del,
   n_dead_tup, n_mod_since_analyze, autovacuum_count, reltuples, last_autovacuum)
SELECT (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-02-01 00:00:00+00'),
       v.relid, 'public', v.relname, v.ins, v.upd, v.del, v.dead, v.mods, v.avc, v.reltup,
       '2026-02-01 00:00:30+00'
FROM (VALUES
   (93001,'big_oltp', 1000, 1000,    0, 100, 100, 5, 200000),
   (93002,'queue',    1000,    0, 1000, 100,  50, 5,  50000),
   (93003,'small',      10,   10,    0,   5,   5, 2,    100),
   (93004,'empty',       0,    0,    0,   0,   0, 0,      0)
 ) AS v(relid,relname,ins,upd,del,dead,mods,avc,reltup);
-- Snapshot 2 (after a cycle of activity)
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del,
   n_dead_tup, n_mod_since_analyze, autovacuum_count, reltuples, last_autovacuum)
SELECT (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-02-01 00:01:00+00'),
       v.relid, 'public', v.relname, v.ins, v.upd, v.del, v.dead, v.mods, v.avc, v.reltup,
       '2026-02-01 00:00:30+00'
FROM (VALUES
   (93001,'big_oltp', 1000, 20000,    0, 300, 200, 5, 200000),
   (93002,'queue',   11000,    0, 11000, 150,  80, 5,  50000),
   (93003,'small',      20,   20,    0,   8,   8, 2,    100),
   (93004,'empty',       0,    0,    0,   0,   0, 0,      0)
 ) AS v(relid,relname,ins,upd,del,dead,mods,avc,reltup);

-- two fast-loop cycles (estimate + classify), then the control loop (plan, advisory)
SELECT pgfc_govern.estimate((SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-02-01 00:00:00+00'));
SELECT pgfc_govern.classify((SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-02-01 00:00:00+00'));
SELECT pgfc_govern.estimate((SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-02-01 00:01:00+00'));
SELECT pgfc_govern.classify((SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-02-01 00:01:00+00'));
SELECT pgfc_govern.control_tick();

-- composition produced real derived state and decisions for every relation
SELECT cmp_ok((SELECT churn_rate FROM pgfc_govern.relation_estimate WHERE relid=93001),
              '>', 0::float8, 'high-churn relation has churn_rate > 0 (deltas across the cycle)');
SELECT is((SELECT count(*) FROM pgfc_govern.relation_estimate WHERE relid BETWEEN 93001 AND 93004),
          4::bigint, 'estimate() handled all relations, including the empty one, without error');
SELECT is((SELECT count(DISTINCT relid) FROM pgfc_govern.decision_log WHERE relid BETWEEN 93001 AND 93004),
          4::bigint, 'plan() produced a decision for every relation');

-- the empty relation gets a valid (non-garbage) decision: a real SF_GRID value
SELECT ok((SELECT proposed_value FROM pgfc_govern.decision_log
            WHERE relid=93004 ORDER BY decision_id DESC LIMIT 1)
          IN ('0.005','0.01','0.02','0.05','0.10','0.20','0.30','0.50'),
          'empty table proposes a valid grid value (no division garbage)');

-- advisory: still nothing applied across the whole loop
SELECT is((SELECT count(*) FROM pgfc_govern.action_history), 0::bigint,
          'advisory loop applied nothing');

-- operator view resolves over the real data
SELECT is((SELECT count(*) FROM pgfc_govern.governor_status WHERE relid BETWEEN 93001 AND 93004),
          4::bigint, 'governor_status reports every relation');

SELECT * FROM finish();
ROLLBACK;
