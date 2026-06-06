-- Fixture: append_only (Phase 3 spec).
-- Pure insert workload — the shape that only grows.

CREATE TABLE IF NOT EXISTS fix_append (
    id       bigint GENERATED ALWAYS AS IDENTITY,
    ts       timestamptz NOT NULL DEFAULT now(),
    payload  text
);

CREATE INDEX IF NOT EXISTS fix_append_ts_idx ON fix_append (ts);

TRUNCATE fix_append;

-- No preload for append_only (starts empty, grows via inserts).
ANALYZE fix_append;
