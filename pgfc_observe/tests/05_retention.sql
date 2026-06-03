-- Raw retention is the fixed TRUNCATE-rotated ring (S2 / FMEA-001): rotate_ring() recycles
-- the slot rolling off — TRUNCATE, never DROP — so out-of-window data is swept while the
-- in-window days are kept, with ZERO catalog churn. The window is (slots-1) days, and the
-- boundary is inclusive (the oldest in-window day is retained).
BEGIN;
SELECT plan(6);

SELECT has_function('pgfc_observe', 'rotate_ring', ARRAY['integer'],
                    'rotate_ring(interval) exists');

-- Set up two days in their slots: one rolling OFF (d0-slots, strictly out of the window)
-- and one at the in-window boundary (d0-(slots-1), which must be KEPT).
DO $setup$
DECLARE
    d0   integer := pgfc_observe._epoch_day(now());
    n    integer := pgfc_observe._ring_slots();
    v_id bigint;
BEGIN
    -- rolling off: day d0-n lands in slot (d0-n)%n and is older than the (n-1)-day window.
    INSERT INTO pgfc_observe.snapshots (slot, collected_day, collected_at, server_version_num)
    VALUES (((d0 - n) % n)::smallint, d0 - n, to_timestamp((d0 - n)::bigint * 86400), 170000)
    RETURNING snapshot_id INTO v_id;
    INSERT INTO pgfc_observe.relation_samples (slot, snapshot_id, collected_day, relid, schemaname, relname)
    VALUES (((d0 - n) % n)::smallint, v_id, d0 - n, 1::oid, 'public', 'stale_t');
    -- in-window boundary: day d0-(n-1) lands in its slot and must survive the rotation.
    INSERT INTO pgfc_observe.snapshots (slot, collected_day, collected_at, server_version_num)
    VALUES (((d0 - (n - 1)) % n)::smallint, d0 - (n - 1),
            to_timestamp((d0 - (n - 1))::bigint * 86400), 170000)
    RETURNING snapshot_id INTO v_id;
    INSERT INTO pgfc_observe.relation_samples (slot, snapshot_id, collected_day, relid, schemaname, relname)
    VALUES (((d0 - (n - 1)) % n)::smallint, v_id, d0 - (n - 1), 2::oid, 'public', 'fresh_t');
END
$setup$;

-- Rotate for today: TRUNCATE the slot rolling off; keep the in-window day.
SELECT cmp_ok(pgfc_observe.rotate_ring(pgfc_observe._epoch_day(now())), '>=', 1::bigint,
              'rotate_ring truncates the slot rolling off (it held out-of-window data)');
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 'stale_t'),
          0::bigint, 'the rolling-off day is swept (older than the (slots-1)-day window)');
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 'fresh_t'),
          1::bigint, 'the oldest in-window day is kept (the window boundary is inclusive)');

-- Idempotent: nothing stale remains, so a second rotation for the same day truncates nothing.
SELECT is(pgfc_observe.rotate_ring(pgfc_observe._epoch_day(now())), 0::bigint,
          'a second rotation for the same day is a no-op (no needless churn)');

-- Zero catalog churn: rotation never creates or drops a partition — the ring is fixed.
SELECT is((SELECT count(*) FROM pgfc_observe._partition_inventory()),
          (2 * pgfc_observe._ring_slots())::bigint,
          'the ring partition set is unchanged after rotation (zero catalog churn)');

SELECT * FROM finish();
ROLLBACK;
