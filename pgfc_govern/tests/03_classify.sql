-- classify(): workload rules, the signal floor, and hysteresis on class changes.
BEGIN;
SELECT plan(8);

-- ── Snapshot pair C: one relation per rule + idle cases (new relations adopt) ──
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at)
VALUES (170000, now() - interval '60 seconds');
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del, reltuples)
VALUES
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91001, 'public', 'ao',  0,0,0, 1000),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91002, 'public', 'olt', 0,0,0, 1000),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91003, 'public', 'del', 0,0,0, 1000),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91004, 'public', 'q',   0,0,0, 1000),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91005, 'public', 'arc', 0,0,0, 200000),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91006, 'public', 'mix', 0,0,0, 1000);

INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at) VALUES (170000, now());
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del, reltuples)
VALUES
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91001, 'public', 'ao',  1000,   0,   0, 1000),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91002, 'public', 'olt',    0,1000,   0, 1000),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91003, 'public', 'del',    0,   0,1000, 1000),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91004, 'public', 'q',    500,   0, 500, 1000),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91005, 'public', 'arc',    0,   0,   0, 200000),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91006, 'public', 'mix',    0,   0,   0, 1000);

SELECT pgfc_govern.classify((SELECT max(snapshot_id) FROM pgfc_observe.snapshots));

SELECT is((SELECT kind::text FROM pgfc_govern.relation_class WHERE relid=91001),'append_only','ins-only => append_only');
SELECT is((SELECT kind::text FROM pgfc_govern.relation_class WHERE relid=91002),'oltp','update-heavy => oltp');
SELECT is((SELECT kind::text FROM pgfc_govern.relation_class WHERE relid=91003),'delete_heavy','delete-heavy => delete_heavy');
SELECT is((SELECT kind::text FROM pgfc_govern.relation_class WHERE relid=91004),'queue','balanced insert+delete => queue');
SELECT is((SELECT kind::text FROM pgfc_govern.relation_class WHERE relid=91005),'archive','idle + large => archive');
SELECT is((SELECT kind::text FROM pgfc_govern.relation_class WHERE relid=91006),'mixed','idle + small => mixed');

-- ── Hysteresis: an existing oltp relation only flips after n_sustain (3) cycles ──
INSERT INTO pgfc_govern.relation_class (relid, schemaname, relname, kind, source)
VALUES (91099, 'public', 'hyst', 'oltp', 'auto');

-- Three append-only cycles, built incrementally.
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at) VALUES (170000, now() - interval '120 seconds');
INSERT INTO pgfc_observe.relation_samples (snapshot_id, relid, schemaname, relname, n_tup_ins)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91099, 'public', 'hyst', 0);

INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at) VALUES (170000, now() - interval '90 seconds');
INSERT INTO pgfc_observe.relation_samples (snapshot_id, relid, schemaname, relname, n_tup_ins)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91099, 'public', 'hyst', 1000);
SELECT pgfc_govern.classify((SELECT max(snapshot_id) FROM pgfc_observe.snapshots));
SELECT is((SELECT kind::text FROM pgfc_govern.relation_class WHERE relid=91099),'oltp',
          'class does not flip on the first divergent cycle (hysteresis)');

INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at) VALUES (170000, now() - interval '60 seconds');
INSERT INTO pgfc_observe.relation_samples (snapshot_id, relid, schemaname, relname, n_tup_ins)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91099, 'public', 'hyst', 2000);
SELECT pgfc_govern.classify((SELECT max(snapshot_id) FROM pgfc_observe.snapshots));

INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at) VALUES (170000, now());
INSERT INTO pgfc_observe.relation_samples (snapshot_id, relid, schemaname, relname, n_tup_ins)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 91099, 'public', 'hyst', 3000);
SELECT pgfc_govern.classify((SELECT max(snapshot_id) FROM pgfc_observe.snapshots));

SELECT is((SELECT kind::text FROM pgfc_govern.relation_class WHERE relid=91099),'append_only',
          'class flips to append_only after the candidate persists 3 cycles');

SELECT * FROM finish();
ROLLBACK;
