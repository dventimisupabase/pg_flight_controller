-- retain() drops snapshots past the window and cascades to relation_samples.
BEGIN;
SELECT plan(4);

SELECT has_function('pgfc_observe', 'retain', ARRAY['interval'],
                    'retain(interval) exists');

-- An old snapshot (30d) and a recent one (1d), each with a sample.
INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at)
VALUES (170000, now() - interval '30 days');
INSERT INTO pgfc_observe.relation_samples (snapshot_id, relid, schemaname, relname)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 1, 'public', 'old_t');

INSERT INTO pgfc_observe.snapshots (server_version_num, collected_at)
VALUES (170000, now() - interval '1 day');
INSERT INTO pgfc_observe.relation_samples (snapshot_id, relid, schemaname, relname)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots), 2, 'public', 'new_t');

SELECT is(pgfc_observe.retain('14 days'), 1::bigint,
          'retain() deletes exactly the one out-of-window snapshot');
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 'old_t'),
          0::bigint, 'old relation_samples cascade-deleted with its snapshot');
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 'new_t'),
          1::bigint, 'in-window snapshot and its samples are kept');

SELECT * FROM finish();
ROLLBACK;
