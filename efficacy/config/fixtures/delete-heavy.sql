-- Fixture: delete_heavy (Phase 3 spec).
-- High delete rate from a preloaded pool — the session/temp-data pattern.
-- Preload is required for sustainability (FIX-001).

CREATE TABLE IF NOT EXISTS fix_delheavy (
    id       bigint GENERATED ALWAYS AS IDENTITY,
    user_id  int,
    data     text,
    expires  timestamptz
);

CREATE INDEX IF NOT EXISTS fix_delheavy_expires_idx ON fix_delheavy (expires);

TRUNCATE fix_delheavy;

INSERT INTO fix_delheavy (user_id, data, expires)
SELECT
    (random() * 1000)::int,
    repeat('x', 100),
    now() + (random() * interval '30 days')
FROM generate_series(1, :rows);

ANALYZE fix_delheavy;
