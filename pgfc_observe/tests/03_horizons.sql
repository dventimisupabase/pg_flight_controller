-- removability_horizons() shape + the no-inhibitor path, and observe() wiring.
-- True inhibitor attribution (held txn / slot) needs a second session and lives in
-- an integration test; here we exercise structure and the COALESCE('none') path.
BEGIN;
SELECT plan(7);

SELECT is((SELECT count(*) FROM pgfc_observe.removability_horizons()),
          1::bigint, 'removability_horizons() returns exactly one row');

SELECT isnt((SELECT oldest_xmin_owner FROM pgfc_observe.removability_horizons()),
            NULL, 'oldest_xmin_owner is never NULL');
SELECT isnt((SELECT oldest_catalog_xmin_owner FROM pgfc_observe.removability_horizons()),
            NULL, 'oldest_catalog_xmin_owner is never NULL');

SELECT ok((SELECT oldest_xmin_owner FROM pgfc_observe.removability_horizons())
          IN ('none','long_running_txn','replication_slot','standby_feedback','prepared_xact'),
          'oldest_xmin_owner is a recognized class or none');

-- quiet single-session DB: self + non-client backends excluded => no inhibitor
SELECT is((SELECT oldest_xmin_owner FROM pgfc_observe.removability_horizons()),
          'none', 'no external holder => owner is none');
SELECT is((SELECT oldest_xmin_owner_detail FROM pgfc_observe.removability_horizons()),
          NULL, 'no external holder => detail is NULL');

-- observe() carries the horizons into the snapshot header
SELECT pgfc_observe.observe();
SELECT isnt((SELECT oldest_xmin_owner FROM pgfc_observe.snapshots
              ORDER BY snapshot_id DESC LIMIT 1),
            NULL, 'observe() populates the snapshot horizon owner');

SELECT * FROM finish();
ROLLBACK;
