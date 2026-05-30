-- estimate(): rates, effectiveness, cycle metrics, and the saturation discriminator.
-- Synthetic snapshots with known deltas; estimate() is always called on the newest
-- snapshot (matching production), so maintenance_debt's "latest" lines up.
BEGIN;
SELECT plan(14);

-- helper header values reused below
-- thresholds: vacuum = 50 + 0.2*1000 = 250 ; analyze = 50 + 0.1*1000 = 150

-- ── Snapshot pair A: three relations, healthy horizon ('none') ────────────────
INSERT INTO pgfc_observe.snapshots
  (server_version_num, collected_at, def_vac_threshold, def_vac_scale_factor,
   def_ana_threshold, def_ana_scale_factor, def_freeze_max_age,
   def_mxid_freeze_max_age, oldest_xmin_owner)
VALUES (170000, now() - interval '60 seconds', 50, 0.2, 50, 0.1, 200000000, 400000000, 'none');

INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del,
   n_dead_tup, autovacuum_count, reltuples, relfrozenxid_age, relminmxid_age, last_autovacuum)
VALUES
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 90001, 'public', 'healthy',
   0, 0, 0, 100, 5, 1000, 100000000, 100000000, now() - interval '90 seconds'),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 90002, 'public', 'cfg',
   0, 0, 0, 500, 5, 1000, 100000000, 100000000, now() - interval '3 hours'),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 90003, 'public', 'iolim',
   0, 0, 0, 900, 5, 1000, 100000000, 100000000, now() - interval '30 seconds');

INSERT INTO pgfc_observe.snapshots
  (server_version_num, collected_at, def_vac_threshold, def_vac_scale_factor,
   def_ana_threshold, def_ana_scale_factor, def_freeze_max_age,
   def_mxid_freeze_max_age, oldest_xmin_owner)
VALUES (170000, now(), 50, 0.2, 50, 0.1, 200000000, 400000000, 'none');

INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del,
   n_dead_tup, autovacuum_count, reltuples, relfrozenxid_age, relminmxid_age, last_autovacuum)
VALUES
  -- healthy: churned 1200 tuples/60s, vacuum cleaned 100->50, frozenxid advanced
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 90001, 'public', 'healthy',
   600, 300, 300, 50, 6, 1000, 99000000, 100000000, now()),
  -- config: debt high (500/250=2) but autovacuum not running, not incrementing
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 90002, 'public', 'cfg',
   0, 0, 0, 500, 5, 1000, 100000000, 100000000, now() - interval '3 hours'),
  -- io_limited: debt high, vacuum ran (900->500, effective) but still behind
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 90003, 'public', 'iolim',
   0, 0, 0, 500, 6, 1000, 100000000, 100000000, now());

SELECT pgfc_govern.estimate((SELECT max(snapshot_id) FROM pgfc_observe.snapshots));

-- healthy relation assertions
SELECT is((SELECT churn_rate FROM pgfc_govern.relation_estimate WHERE relid = 90001),
          20::float8, 'churn_rate = 1200 tuples / 60 s');
SELECT is((SELECT effectiveness FROM pgfc_govern.relation_estimate WHERE relid = 90001),
          1::float8, 'effectiveness = 1 (vacuum removed dead tuples)');
SELECT is((SELECT cleanup_per_run FROM pgfc_govern.relation_estimate WHERE relid = 90001),
          50::bigint, 'cleanup_per_run = 100 - 50');
SELECT is(round((SELECT f_peak_current FROM pgfc_govern.relation_estimate WHERE relid = 90001)::numeric, 6),
          0.05, 'f_peak_current = 50/1000 after the cycle boundary');
SELECT is((SELECT freeze_progressing FROM pgfc_govern.relation_estimate WHERE relid = 90001),
          true, 'freeze_progressing: relfrozenxid age dropped after vacuum');
SELECT is(round((SELECT mxid_freeze_debt FROM pgfc_govern.relation_estimate WHERE relid = 90001)::numeric, 6),
          0.25, 'mxid_freeze_debt = 1e8 / 4e8');
SELECT is(round((SELECT vacuum_debt_ratio FROM pgfc_govern.relation_estimate WHERE relid = 90001)::numeric, 6),
          0.2, 'vacuum_debt_ratio = 50/250 (read from maintenance_debt)');
SELECT is((SELECT saturation_cause FROM pgfc_govern.relation_estimate WHERE relid = 90001),
          NULL, 'healthy relation has no saturation cause');

-- discriminator branches (candidate set on a single observation)
SELECT is((SELECT saturation_candidate FROM pgfc_govern.relation_estimate WHERE relid = 90002),
          'config', 'debt high + autovacuum not running => config');
SELECT is((SELECT saturation_candidate FROM pgfc_govern.relation_estimate WHERE relid = 90003),
          'io_limited', 'debt high + vacuum running + effective + healthy horizon => io_limited');

-- ── Inhibited: vacuum keeps running but cleans nothing, horizon pinned ─────────
-- Built incrementally so each estimate() runs on the newest snapshot. Cause is
-- declared only after the candidate persists v_k (=3) observations.
INSERT INTO pgfc_observe.snapshots
  (server_version_num, collected_at, def_vac_threshold, def_vac_scale_factor,
   def_ana_threshold, def_ana_scale_factor, def_freeze_max_age, def_mxid_freeze_max_age,
   oldest_xmin_owner, oldest_xmin_age)
VALUES (170000, now() - interval '180 seconds', 50, 0.2, 50, 0.1, 200000000, 400000000,
        'long_running_txn', 200000000);
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_dead_tup, autovacuum_count, reltuples, last_autovacuum)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 90004, 'public', 'inhib',
        500, 10, 1000, now());

-- three more cycles, each: vacuum ran (autovacuum_count++) but n_dead_tup unchanged
INSERT INTO pgfc_observe.snapshots
  (server_version_num, collected_at, def_vac_threshold, def_vac_scale_factor,
   def_ana_threshold, def_ana_scale_factor, def_freeze_max_age, def_mxid_freeze_max_age,
   oldest_xmin_owner, oldest_xmin_age)
VALUES (170000, now() - interval '120 seconds', 50, 0.2, 50, 0.1, 200000000, 400000000,
        'long_running_txn', 200000000);
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_dead_tup, autovacuum_count, reltuples, last_autovacuum)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 90004, 'public', 'inhib',
        500, 11, 1000, now());
SELECT pgfc_govern.estimate((SELECT max(snapshot_id) FROM pgfc_observe.snapshots));

INSERT INTO pgfc_observe.snapshots
  (server_version_num, collected_at, def_vac_threshold, def_vac_scale_factor,
   def_ana_threshold, def_ana_scale_factor, def_freeze_max_age, def_mxid_freeze_max_age,
   oldest_xmin_owner, oldest_xmin_age)
VALUES (170000, now() - interval '60 seconds', 50, 0.2, 50, 0.1, 200000000, 400000000,
        'long_running_txn', 200000000);
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_dead_tup, autovacuum_count, reltuples, last_autovacuum)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 90004, 'public', 'inhib',
        500, 12, 1000, now());
SELECT pgfc_govern.estimate((SELECT max(snapshot_id) FROM pgfc_observe.snapshots));

INSERT INTO pgfc_observe.snapshots
  (server_version_num, collected_at, def_vac_threshold, def_vac_scale_factor,
   def_ana_threshold, def_ana_scale_factor, def_freeze_max_age, def_mxid_freeze_max_age,
   oldest_xmin_owner, oldest_xmin_age)
VALUES (170000, now(), 50, 0.2, 50, 0.1, 200000000, 400000000,
        'long_running_txn', 200000000);
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_dead_tup, autovacuum_count, reltuples, last_autovacuum)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 90004, 'public', 'inhib',
        500, 13, 1000, now());
SELECT pgfc_govern.estimate((SELECT max(snapshot_id) FROM pgfc_observe.snapshots));

SELECT is((SELECT saturation_cause FROM pgfc_govern.relation_estimate WHERE relid = 90004),
          'inhibited', 'inhibited cause declared after the candidate persists 3 cycles');
SELECT is((SELECT saturation_streak FROM pgfc_govern.relation_estimate WHERE relid = 90004),
          3, 'saturation_streak reached 3');

-- ── live freeze debt across a skipped (quiet) snapshot (S3 safety property) ────
-- 90005 is sampled once with a RAW relfrozenxid (an old xid => large live age) and a
-- deliberately stale stored relfrozenxid_age (5); the next snapshot omits it (it went
-- quiet). estimate() on that later snapshot must derive its freeze debt from the LIVE
-- age of the raw xid, not the stale stored age -- the wraparound-safety justification
-- for sparse storage, exercised end-to-end through current_relation_state ->
-- maintenance_debt -> estimate. (Within one test txn the cluster xid is fixed, so
-- age('100') is identical on both sides of the equality.)
INSERT INTO pgfc_observe.snapshots (server_version_num, def_freeze_max_age, collected_at)
VALUES (170000, 200000000, now() - interval '120 seconds');
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_dead_tup, reltuples, relfrozenxid_age, relfrozenxid)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
        90005, 'public', 'frz_quiet', 0, 1000, 5, '100'::xid);
INSERT INTO pgfc_observe.snapshots (server_version_num, def_freeze_max_age, collected_at)
VALUES (170000, 200000000, now());     -- later snapshot, no sample for 90005
SELECT pgfc_govern.estimate((SELECT max(snapshot_id) FROM pgfc_observe.snapshots));

SELECT is(
    (SELECT round(freeze_debt::numeric, 9) FROM pgfc_govern.relation_estimate WHERE relid = 90005),
    round((age('100'::xid)::float8 / 200000000)::numeric, 9),
    'estimate() freeze_debt tracks the LIVE freeze age across a skipped quiet snapshot');
SELECT cmp_ok(
    (SELECT freeze_debt FROM pgfc_govern.relation_estimate WHERE relid = 90005),
    '>', (5::float8 / 200000000),
    'live freeze_debt exceeds the stale stored-age value (raw-xid path, not the fallback)');

SELECT * FROM finish();
ROLLBACK;
