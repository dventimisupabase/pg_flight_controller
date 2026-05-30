-- plan(): decision routing (advisory) and diagnostics dedup/resolve.
-- relation_class/relation_estimate are seeded directly to exercise routing in isolation.
BEGIN;
SELECT plan(14);

-- Two snapshots: S1 horizon healthy ('none'), S2 horizon pinned.
INSERT INTO pgfc_observe.snapshots
  (server_version_num, collected_at, def_vac_scale_factor, def_vac_threshold, oldest_xmin_owner)
VALUES (170000, '2026-01-01 00:00:00+00', 0.2, 50, 'none');
INSERT INTO pgfc_observe.snapshots
  (server_version_num, collected_at, def_vac_scale_factor, def_vac_threshold,
   oldest_xmin_owner, oldest_xmin_owner_detail)
VALUES (170000, '2026-01-02 00:00:00+00', 0.2, 50, 'long_running_txn', 'pid 4242');

-- relation_samples in S1 (reltuples large so base/reltuples is negligible)
INSERT INTO pgfc_observe.relation_samples (snapshot_id, relid, schemaname, relname, reltuples, reloptions)
SELECT s, v.relid, 'public', v.relname, 100000, v.reloptions
FROM (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-01-01 00:00:00+00') x(s),
     (VALUES (92001,'adj',NULL::text[]), (92002,'hold',NULL), (92003,'iol',NULL),
             (92004,'cfg',NULL), (92005,'usr',ARRAY['autovacuum_vacuum_scale_factor=0.3']),
             (92006,'frz',NULL)) v(relid,relname,reloptions);
-- relation_samples in S2
INSERT INTO pgfc_observe.relation_samples (snapshot_id, relid, schemaname, relname, reltuples)
SELECT s, v.relid, 'public', v.relname, 100000
FROM (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-01-02 00:00:00+00') x(s),
     (VALUES (92007,'inh'), (92008,'frzpin')) v(relid,relname);

INSERT INTO pgfc_govern.relation_class (relid, schemaname, relname, kind) VALUES
  (92001,'public','adj','queue'), (92002,'public','hold','oltp'),
  (92003,'public','iol','oltp'),  (92004,'public','cfg','oltp'),
  (92005,'public','usr','queue'), (92006,'public','frz','oltp'),
  (92007,'public','inh','oltp'),  (92008,'public','frzpin','oltp');

INSERT INTO pgfc_govern.relation_estimate (relid, snapshot_id, saturation_cause, freeze_debt, vacuum_debt_ratio) VALUES
  (92001, 1, NULL,         0.1, 0.3),
  (92002, 1, NULL,         0.1, 0.3),
  (92003, 1, 'io_limited', 0.1, 2.0),
  (92004, 1, 'config',     0.1, 2.0),
  (92005, 1, NULL,         0.1, 0.3),
  (92006, 1, NULL,         0.7, 0.3),     -- freeze-stressed, horizon healthy (S1)
  (92007, 1, 'inhibited',  0.1, 2.0),     -- inhibited, horizon pinned (S2)
  (92008, 1, NULL,         0.7, 0.3);     -- freeze-stressed + horizon pinned (S2)

SELECT pgfc_govern.plan(1, (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-01-01 00:00:00+00'));
SELECT pgfc_govern.plan(1, (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-01-02 00:00:00+00'));

-- decision routing (latest decision per relation)
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92001 ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'queue under lax setting => adjust');
SELECT is((SELECT proposed_value FROM pgfc_govern.decision_log WHERE relid=92001 ORDER BY decision_id DESC LIMIT 1),
          '0.05', 'queue adjust proposes sf=0.05');
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92002 ORDER BY decision_id DESC LIMIT 1),
          'hold', 'oltp already at target => hold (no-op)');
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92003 ORDER BY decision_id DESC LIMIT 1),
          'escalate:io_limited', 'io_limited => escalate, suppress');
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92004 ORDER BY decision_id DESC LIMIT 1),
          'suppressed:not_firing', 'config (debt high, not firing) => hold+diagnose, never adjust');
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92005 ORDER BY decision_id DESC LIMIT 1),
          'suppressed:user_owned', 'user-set reloption not overwritten (manage_user_owned=false)');
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92006 ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'freeze floor drives toward cleanest => adjust');
SELECT is((SELECT proposed_value FROM pgfc_govern.decision_log WHERE relid=92006 ORDER BY decision_id DESC LIMIT 1),
          '0.01', 'freeze floor target is sf_min (0.01)');
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92007 ORDER BY decision_id DESC LIMIT 1),
          'escalate:inhibited:long_running_txn', 'inhibited names the owner class');
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92008 ORDER BY decision_id DESC LIMIT 1),
          'escalate:inhibited:long_running_txn', 'freeze + pinned horizon: floor + diagnose, do not churn');

-- diagnostics opened
SELECT is((SELECT count(*) FROM pgfc_govern.diagnostics WHERE relid=92003 AND resolved_at IS NULL),
          1::bigint, 'io_limited opened one diagnostic');
SELECT is((SELECT severity FROM pgfc_govern.diagnostics WHERE relid=92007 AND resolved_at IS NULL),
          'critical', 'inhibited diagnostic is critical');

-- dedup: re-running plan on S1 does not duplicate the open io_limited finding
SELECT pgfc_govern.plan(1, (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-01-01 00:00:00+00'));
SELECT is((SELECT count(*) FROM pgfc_govern.diagnostics WHERE relid=92003 AND resolved_at IS NULL),
          1::bigint, 'no duplicate diagnostic on re-run (dedup)');

-- resolve: clear the io_limited cause, re-run -> finding is resolved
UPDATE pgfc_govern.relation_estimate SET saturation_cause = NULL WHERE relid = 92003;
SELECT pgfc_govern.plan(1, (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-01-01 00:00:00+00'));
SELECT is((SELECT count(*) FROM pgfc_govern.diagnostics WHERE relid=92003 AND resolved_at IS NULL),
          0::bigint, 'cleared condition resolves the open diagnostic');

SELECT * FROM finish();
ROLLBACK;
