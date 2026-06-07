-- plan(): decision routing (advisory) and diagnostics dedup/resolve.
-- relation_class/relation_estimate are seeded directly to exercise routing in isolation.
BEGIN;
SELECT plan(20);

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
             (92006,'frz',NULL),
             -- COR-001 (#66): 92009 carries a value the governor itself set (still
             -- unchanged); 92010 carries a value a human set AFTER the governor's touch.
             (92009,'gov',ARRAY['autovacuum_vacuum_scale_factor=0.1']),
             (92010,'hov',ARRAY['autovacuum_vacuum_scale_factor=0.3']),
             -- 92011: the governor took over a setting the user had set FIRST
             -- (baseline_explicit=true) — still protected under manage_user_owned=false.
             (92011,'usrfirst',ARRAY['autovacuum_vacuum_scale_factor=0.2'])) v(relid,relname,reloptions);
-- relation_samples in S2
INSERT INTO pgfc_observe.relation_samples (snapshot_id, relid, schemaname, relname, reltuples)
SELECT s, v.relid, 'public', v.relname, 100000
FROM (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-01-02 00:00:00+00') x(s),
     (VALUES (92007,'inh'), (92008,'frzpin')) v(relid,relname);

INSERT INTO pgfc_govern.relation_class (relid, schemaname, relname, kind) VALUES
  (92001,'public','adj','queue'), (92002,'public','hold','oltp'),
  (92003,'public','iol','oltp'),  (92004,'public','cfg','oltp'),
  (92005,'public','usr','queue'), (92006,'public','frz','oltp'),
  (92007,'public','inh','oltp'),  (92008,'public','frzpin','oltp'),
  (92009,'public','gov','queue'), (92010,'public','hov','queue'),
  (92011,'public','usrfirst','queue');

INSERT INTO pgfc_govern.relation_estimate (relid, snapshot_id, saturation_cause, freeze_debt, vacuum_debt_ratio) VALUES
  (92001, 1, NULL,         0.1, 0.3),
  (92002, 1, NULL,         0.1, 0.3),
  (92003, 1, 'io_limited', 0.1, 2.0),
  (92004, 1, 'config',     0.1, 2.0),
  (92005, 1, NULL,         0.1, 0.3),
  (92006, 1, NULL,         0.7, 0.3),     -- freeze-stressed, horizon healthy (S1)
  (92007, 1, 'inhibited',  0.1, 2.0),     -- inhibited, horizon pinned (S2)
  (92008, 1, NULL,         0.7, 0.3),     -- freeze-stressed + horizon pinned (S2)
  (92009, 1, NULL,         0.1, 0.3),     -- governor-owned (COR-001 #66)
  (92010, 1, NULL,         0.1, 0.3),     -- human-overridden after governor touch (COR-001 #66)
  (92011, 1, NULL,         0.1, 0.3);     -- user-set-first, governor took over (COR-001 #66)

-- COR-001 (#66): seed actuator_state so plan() can distinguish the governor's own prior
-- actuation from a human's. 92009: governor set 0.1 and it is still 0.1 (unchanged) ->
-- the governor must keep controlling, not suppress itself. 92010: governor set 0.05 but
-- the live value is now 0.3 (a human changed it after the touch) -> protect it. 92011:
-- baseline_explicit=true (a user set 0.2 first, the governor then took over to 0.05) ->
-- still protected, because the contract guards what the user set FIRST.
INSERT INTO pgfc_govern.actuator_state
  (relid, actuator, current_value, baseline_explicit, baseline_value) VALUES
  (92009, 'autovacuum_vacuum_scale_factor', '0.1',  false, NULL),
  (92010, 'autovacuum_vacuum_scale_factor', '0.05', false, NULL),
  (92011, 'autovacuum_vacuum_scale_factor', '0.05', true,  '0.2');

-- S1 (horizon healthy). Under sparse-storage reconciliation plan() always evaluates
-- EVERY current relation against the snapshot it is given, so the healthy-horizon
-- relations (92001-92006) are asserted here, before plan(S2) re-evaluates them (carried
-- forward) under the pinned horizon -- which is correct production behavior but would
-- otherwise overwrite 92006's "latest decision" with a pinned-horizon escalation.
SELECT pgfc_govern.plan(1, (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-01-01 00:00:00+00'));

-- decision routing under the healthy horizon (latest decision per relation)
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92001 ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'queue under lax setting => adjust');
SELECT is((SELECT proposed_value FROM pgfc_govern.decision_log WHERE relid=92001 ORDER BY decision_id DESC LIMIT 1),
          '0.02', 'queue adjust proposes sf=0.02');
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92002 ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'oltp at PG default (0.20) with target 0.05 => adjust');
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

-- COR-001 (#66): the ownership guard must distinguish governor-set from user-set.
-- 92009 carries a reloption the governor itself set and nobody has changed since, so the
-- governor must keep controlling it (here: refine 0.1 -> 0.05), NOT freeze itself out as
-- 'suppressed:user_owned'. This is the regression that fails on the pre-fix code.
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92009 ORDER BY decision_id DESC LIMIT 1),
          'adjust', 'governor recognizes its own prior actuation and keeps controlling (not suppressed:user_owned)');
-- 92010 carries a value a human set AFTER the governor's touch (live 0.3 != governor 0.05),
-- so it IS protected under manage_user_owned=false. Guards against an over-correction that
-- would treat every governor-touched relation as fair game.
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92010 ORDER BY decision_id DESC LIMIT 1),
          'suppressed:user_owned', 'post-touch human override is protected (live differs from governor current_value)');
-- 92011: a setting the user established FIRST (baseline_explicit=true) stays protected even
-- though the governor later took it over — the contract guards what pre-existed the governor.
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92011 ORDER BY decision_id DESC LIMIT 1),
          'suppressed:user_owned', 'user-set-first setting (baseline_explicit) stays protected');

-- estimated_benefit (P4): populated for an adjust (the tightening), NULL when nothing changes.
SELECT ok((SELECT estimated_benefit FROM pgfc_govern.decision_log WHERE relid=92001 ORDER BY decision_id DESC LIMIT 1) IS NOT NULL,
          'adjust records an estimated_benefit');
SELECT ok((SELECT estimated_benefit FROM pgfc_govern.decision_log WHERE relid=92002 ORDER BY decision_id DESC LIMIT 1) IS NOT NULL,
          'oltp adjust records an estimated_benefit');
SELECT ok((SELECT estimated_benefit FROM pgfc_govern.decision_log WHERE relid=92004 ORDER BY decision_id DESC LIMIT 1) IS NULL,
          'suppressed records no estimated_benefit (NULL)');

-- diagnostic opened under the healthy horizon
SELECT is((SELECT count(*) FROM pgfc_govern.diagnostics WHERE relid=92003 AND resolved_at IS NULL),
          1::bigint, 'io_limited opened one diagnostic');

-- S2 (horizon pinned): the two pinned-horizon relations
SELECT pgfc_govern.plan(1, (SELECT snapshot_id FROM pgfc_observe.snapshots WHERE collected_at='2026-01-02 00:00:00+00'));

SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92007 ORDER BY decision_id DESC LIMIT 1),
          'escalate:inhibited:long_running_txn', 'inhibited names the owner class');
SELECT is((SELECT decision FROM pgfc_govern.decision_log WHERE relid=92008 ORDER BY decision_id DESC LIMIT 1),
          'escalate:inhibited:long_running_txn', 'freeze + pinned horizon: floor + diagnose, do not churn');

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
